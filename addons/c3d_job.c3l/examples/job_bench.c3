module job_bench;

import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;
import std::thread;
import std::thread::cpu;
import std::atomic::types;
import c3d::job;

const uint OVERHEAD_RANGES @local = 1024; // the gate's workload: one run of 1024 empty ranges
const uint[3] FIXED_WORKER_COUNTS @local = { 0, 1, 3 }; // inline, one worker and the CI runners' three
const uint KERNEL_MULTIPLIES @local = 16; // 64 multiply-adds each; 262 144 items cost 268M multiply-adds a pass
const uint[3] ITEM_COUNTS @local = { 16384, 65536, 262144 };
const uint[2] FIXED_BATCHES @local = { 64, 1024 };
const uint RANGES_PER_THREAD @local = 4; // the sweep's third batch: about four ranges per pool thread
const float CHAIN_STEP @local = 0.001f; // keeps the chained translations small
const uint WARMUP_SAMPLES @local = 2; // wakes the workers and fills the temp pages before timing
const uint SAMPLES @local = 11; // the median of eleven timed passes
const uint PASSES @local = WARMUP_SAMPLES + SAMPLES;
const double NANOSECONDS_PER_MICROSECOND @local = 1000;
const uint LOADED_ITEMS @local = 65536; // the frame kernel timed beside background work
const uint LOADED_BATCH @local = 1024; // about 64 ranges: scheduling stays a small share of the timed kernel
const uint BACKGROUND_RANGES @local = 16384; // about 0.25 s of serial work, so it outlasts the timed frame passes
const uint BACKGROUND_RANGE_ITEMS @local = 256; // about 15 us of chain multiplies a range

struct Load @local {
    Mat4[] chain;
    Mat4[] products; // one per range
}

struct Kernel @local {
    Mat4[]       chain;
    Mat4[]       output;
    Atomic{uint} ranges;
    Atomic{usz}  peak_scratch_bytes;
}

fn void empty_range(void* data, uint first, uint count) @local {
}

fn void kernel_range(void* data, uint first, uint count) @local {
    Kernel* kernel = data;
    Mat4[] products = mem::temp_array(Mat4, count);
    for (uint offset = 0; offset < count; offset++) {
        Mat4 product = matrix::IDENTITY4.translate({ (float)(first + offset), 0, 0 });
        foreach (link : kernel.chain) product = product.mul(link);
        products[offset] = product;
    }
    kernel.output[first : count] = products[..];
    kernel.ranges.add(1);
    kernel.peak_scratch_bytes.max(count * Mat4::size);
}

fn void load_range(void* data, uint first, uint count) @local {
    Load* load = data;
    Mat4 product = matrix::IDENTITY4;
    for (uint offset = 0; offset < count; offset++) {
        foreach (link : load.chain) product = product.mul(link);
    }
    load.products[first / BACKGROUND_RANGE_ITEMS] = product;
}

fn double median(double[] samples) @local {
    sort::quicksort(samples);
    return samples[samples.len / 2];
}

fn double time_run(
    JobPool* pool,
    RangeFn range,
    void* data,
    uint count,
    uint batch,
) @local {
    double[SAMPLES] samples;
    for (uint pass = 0; pass < PASSES; pass++) {
        time::Clock started = clock::now();
        pool.wait(pool.run(
            range: range,
            data:  data,
            count: count,
            batch: batch,
        ));
        double elapsed = (double)(clock::now() - started) / NANOSECONDS_PER_MICROSECOND;
        if (pass >= WARMUP_SAMPLES) samples[pass - WARMUP_SAMPLES] = elapsed;
    }
    return median(&samples);
}

fn void count_range(void* data, uint first, uint count) @local {
    Atomic{uint}* ranges = data;
    ranges.add(1);
}

fn double time_background_run(JobPool* pool) @local {
    double[SAMPLES] samples;
    for (uint pass = 0; pass < PASSES; pass++) {
        Atomic{uint} ranges;
        time::Clock started = clock::now();
        JobId id = pool.try_run(
            job_class: BACKGROUND,
            range:     &count_range,
            data:      &ranges,
            count:     OVERHEAD_RANGES,
            batch:     1,
        )!!;
        while (ranges.load() < OVERHEAD_RANGES) thread::yield();
        while (!pool.is_finished(id)) thread::yield();
        double elapsed = (double)(clock::now() - started) / NANOSECONDS_PER_MICROSECOND;
        if (pass >= WARMUP_SAMPLES) samples[pass - WARMUP_SAMPLES] = elapsed;
    }
    return median(&samples);
}

fn JobPool create_bench_pool(uint workers) @local {
    JobPoolDesc desc = job::default_job_pool_desc();
    desc.worker_count = workers;
    desc.background_workers = job::default_background_workers(workers);
    return job::create_job_pool(mem, desc)!!;
}

fn void report_loaded_kernel(
    JobPool* pool,
    Mat4[] chain,
    uint workers,
    double idle_microseconds,
) @local {
    Mat4[] output = mem::new_array(Mat4, LOADED_ITEMS);
    defer free(output);
    Kernel kernel = { .chain = chain, .output = output };
    Mat4[] products = mem::new_array(Mat4, BACKGROUND_RANGES);
    defer free(products);
    Load load = { .chain = chain, .products = products };
    JobId background = pool.try_run(
        job_class: BACKGROUND,
        range:     &load_range,
        data:      &load,
        count:     BACKGROUND_RANGES * BACKGROUND_RANGE_ITEMS,
        batch:     BACKGROUND_RANGE_ITEMS,
    )!!;
    double loaded_microseconds = time_run(
        pool:  pool,
        range: &kernel_range,
        data:  &kernel,
        count: LOADED_ITEMS,
        batch: LOADED_BATCH,
    );
    bool still_loaded = !pool.is_finished(background);
    pool.wait(background);
    io::printfn(
        "loaded,%d,%d,%d,%d,%.1f,%.1f,%.2f,%d",
        workers,
        job::default_background_workers(workers),
        LOADED_ITEMS,
        LOADED_BATCH,
        idle_microseconds,
        loaded_microseconds,
        loaded_microseconds / idle_microseconds,
        still_loaded ? 1 : 0,
    );
}

fn bool report_kernel(
    JobPool* pool,
    JobPool* serial_pool,
    Mat4[] chain,
    uint workers,
    uint items,
    uint batch,
    double microseconds_per_range,
) @local {
    Mat4[] serial_output = mem::new_array(Mat4, items);
    defer free(serial_output);
    Mat4[] pooled_output = mem::new_array(Mat4, items);
    defer free(pooled_output);
    Kernel serial = { .chain = chain, .output = serial_output };
    Kernel pooled = { .chain = chain, .output = pooled_output };

    double serial_microseconds = time_run(
        pool:  serial_pool,
        range: &kernel_range,
        data:  &serial,
        count: items,
        batch: batch,
    );
    ulong inline_before = pool.inline_ranges();
    double pooled_microseconds = time_run(
        pool:  pool,
        range: &kernel_range,
        data:  &pooled,
        count: items,
        batch: batch,
    );

    uint ranges = pooled.ranges.load() / PASSES;
    bool equal = mem::equals(serial_output, pooled_output);
    io::printfn(
        "kernel,%d,%d,%d,%d,%.1f,%.1f,%.2f,%.4f,%d,%d,%d",
        workers,
        items,
        batch,
        ranges,
        serial_microseconds,
        pooled_microseconds,
        serial_microseconds / pooled_microseconds,
        ranges * microseconds_per_range / serial_microseconds,
        pooled.peak_scratch_bytes.load(),
        pool.inline_ranges() - inline_before,
        equal ? 1 : 0,
    );
    return equal;
}

<* Measure the job pool's per-range overhead and a parallel kernel's speedup. *>
fn int main() {
    JobPoolDesc defaults = job::default_job_pool_desc();
    io::printfn(
        "# job_bench logical_cpus=%d default_workers=%d background_workers=%d runs=%d background_runs=%d "
        "worker_temp_bytes=%d",
        cpu::native_cpu(),
        defaults.worker_count,
        defaults.background_workers,
        defaults.run_capacity,
        defaults.background_run_capacity,
        defaults.worker_temp_bytes,
    );

    uint[FIXED_WORKER_COUNTS.len + 1] worker_counts;
    usz worker_kinds;
    foreach (workers : FIXED_WORKER_COUNTS) worker_counts[worker_kinds++] = workers;
    if (!array::contains(worker_counts[:worker_kinds], defaults.worker_count)) {
        worker_counts[worker_kinds++] = defaults.worker_count;
    }

    double[FIXED_WORKER_COUNTS.len + 1] microseconds_per_range;
    io::printn("# overhead,workers,ranges,us_per_range,inline_ranges");
    foreach (index, workers : worker_counts[:worker_kinds]) {
        JobPool pool = create_bench_pool(workers);
        defer job::destroy_job_pool(&pool);
        double pass_microseconds = time_run(
            pool:  &pool,
            range: &empty_range,
            data:  null,
            count: OVERHEAD_RANGES,
            batch: 1,
        );
        microseconds_per_range[index] = pass_microseconds / OVERHEAD_RANGES;
        io::printfn(
            "overhead,%d,%d,%.4f,%d",
            workers,
            OVERHEAD_RANGES,
            microseconds_per_range[index],
            pool.inline_ranges(),
        );
    }

    io::printn("# background,workers,background_workers,ranges,us_per_range");
    foreach (workers : worker_counts[:worker_kinds]) {
        if (!workers) continue;
        JobPool pool = create_bench_pool(workers);
        defer job::destroy_job_pool(&pool);
        io::printfn(
            "background,%d,%d,%d,%.4f",
            workers,
            job::default_background_workers(workers),
            OVERHEAD_RANGES,
            time_background_run(&pool) / OVERHEAD_RANGES,
        );
    }

    Mat4[KERNEL_MULTIPLIES] chain;
    foreach (index, &link : chain) *link = matrix::IDENTITY4.translate({ 0, index * CHAIN_STEP, 1 });
    JobPool serial_pool = create_bench_pool(0);
    defer job::destroy_job_pool(&serial_pool);
    bool all_equal = true;
    io::printn(
        "# kernel,workers,items,batch,ranges,serial_us,pooled_us,speedup,"
        "overhead_share,peak_scratch_bytes,inline_ranges,equal"
    );
    foreach (index, workers : worker_counts[:worker_kinds]) {
        if (!workers) continue;
        JobPool pool = create_bench_pool(workers);
        defer job::destroy_job_pool(&pool);
        foreach (items : ITEM_COUNTS) {
            uint[FIXED_BATCHES.len + 1] batches = {
                FIXED_BATCHES[0],
                FIXED_BATCHES[1],
                (items - 1) / (RANGES_PER_THREAD * (workers + 1)) + 1,
            };
            foreach (batch_index, batch : batches) {
                if (array::contains(batches[:batch_index], batch)) continue;
                bool equal = report_kernel(
                    pool:                   &pool,
                    serial_pool:            &serial_pool,
                    chain:                  &chain,
                    workers:                workers,
                    items:                  items,
                    batch:                  batch,
                    microseconds_per_range: microseconds_per_range[index],
                );
                all_equal = all_equal && equal;
            }
        }
    }

    io::printn("# loaded,workers,background_workers,items,batch,idle_us,loaded_us,ratio,background_outlasted");
    foreach (workers : worker_counts[:worker_kinds]) {
        if (!workers) continue;
        JobPool pool = create_bench_pool(workers);
        defer job::destroy_job_pool(&pool);
        Mat4[] idle_output = mem::new_array(Mat4, LOADED_ITEMS);
        defer free(idle_output);
        Kernel idle = { .chain = &chain, .output = idle_output };
        double idle_microseconds = time_run(
            pool:  &pool,
            range: &kernel_range,
            data:  &idle,
            count: LOADED_ITEMS,
            batch: LOADED_BATCH,
        );
        report_loaded_kernel(
            pool:              &pool,
            chain:             &chain,
            workers:           workers,
            idle_microseconds: idle_microseconds,
        );
    }
    return all_equal ? 0 : 1;
}
