module landscape_scatter;

import std::bits;
import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;
import c3d;
import c3d::asset;
import c3d::job;
import c3d::landscape::foliage;
import c3d::maths;
import c3d::scene;
import landscape_foliage;

const uint RUNS @local = 5; // fresh layers per configuration; the rows report medians
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const String COUNT_LABEL @local = "foliage.count";
const String PLACE_LABEL @local = "foliage.place";

<* A serially scattered layer and the inputs of scattering it again through jobs. *>
struct ScatterSubject {
    Scene*      scene;
    AssetStore* assets;
    Node*       ground;
    FoliageDesc desc;
    Node*       reference; // prepared by add_foliage
    ZString     name;
    double      serial_ms; // that add_foliage call
}

struct PhaseSamples @local {
    double[RUNS] count;
    double[RUNS] reserve;
    double[RUNS] place;
    double[RUNS] commit;
}

struct RangeCounts @local @feat(C3D_PROFILE_CPU) {
    uint   ranges;
    uint   lanes;
    double busy_ms;
}

fn void run_count_range(void* job, uint first, uint count) @local {
    ((ScatterJob*)job).count_range(first, count);
}

fn void run_place_range(void* job, uint first, uint count) @local {
    ((ScatterJob*)job).place_range(first, count);
}

fn double elapsed_ms(time::Clock started) @local => (double)(long)started.to_now() / NANOSECONDS_PER_MILLISECOND;

fn double median(double[] samples) @local {
    sort::quicksort(samples);
    return samples[samples.len / 2];
}

// One range on this thread without a pool; otherwise the pool's ranges, joined before the return.
fn void run_phase(
    JobPool* pool,
    RangeFn range,
    ScatterJob* job,
    String label,
) @local {
    if (!pool) {
        range(job, 0, job.cell_count());
        return;
    }
    pool.wait(pool.run(
        range: range,
        data:  job,
        count: job.cell_count(),
        batch: 0,
        name:  label,
    ));
}

fn Node*? add_pending_layer(ScatterSubject* subject) @local {
    Node* node = subject.scene.add_node()!;
    defer catch subject.scene.remove(node);
    node.local = subject.ground.local;
    node.layers = landscape_foliage::FOLIAGE_LAYER;
    subject.scene.update_world();
    foliage::attach_foliage(
        scene:  subject.scene,
        assets: subject.assets,
        node:   node,
        desc:   subject.desc,
    )!;
    return node;
}

fn bool same_instances(InstancedMesh* first, InstancedMesh* second) @local {
    if (first.count != second.count) return false;
    for (uint index = 0; index < first.count; index++) {
        Transform a = first.transforms[index];
        Transform b = second.transforms[index];
        if (bitcast(a.position, uint[<3>]) != bitcast(b.position, uint[<3>])) return false;
        if (bitcast(a.rotation.v, uint[<4>]) != bitcast(b.rotation.v, uint[<4>])) return false;
        if (bitcast(a.scale, uint[<3>]) != bitcast(b.scale, uint[<3>])) return false;
        if (bitcast(first.colors[index], uint[<4>]) != bitcast(second.colors[index], uint[<4>])) return false;
    }
    return true;
}

// Cell by cell, instance by instance, bit for bit.
fn bool same_layers(Scene* scene, Node* first, Node* second) @local {
    FoliageRuntime* a = scene.get(first, FoliageRuntime);
    FoliageRuntime* b = scene.get(second, FoliageRuntime);
    if (a.cells.len != b.cells.len || a.instances != b.instances || a.cell_nodes != b.cell_nodes) return false;
    foreach (index, cell : a.cells) {
        if ((cell.generation != 0) != (b.cells[index].generation != 0)) return false;
        if (!cell.generation) continue;

        if (!same_instances(scene.world.get(cell, InstancedMesh), scene.world.get(b.cells[index], InstancedMesh))) {
            return false;
        }
    }
    return true;
}

// Scatters fresh pending layers through the job API RUNS times; each is compared with the serial layer and removed.
fn bool? measure_scatter(ScatterSubject* subject, JobPool* pool, PhaseSamples* samples) @local {
    bool identical = true;
    for (uint run = 0; run < RUNS; run++) {
        Node* node = add_pending_layer(subject)!;
        defer subject.scene.remove(node);
        @pool() {
            ScatterJob job = foliage::scatter_job(
                scene:   subject.scene,
                assets:  subject.assets,
                layer:   node.id,
                scratch: tmem,
            )!;
            time::Clock started = clock::now();
            run_phase(
                pool:  pool,
                range: &run_count_range,
                job:   &job,
                label: COUNT_LABEL,
            );
            samples.count[run] = elapsed_ms(started);

            usz total = job.instance_count();
            Transform[] transforms = alloc::new_array(tmem, Transform, (sz)total);
            Vec4[] colors = alloc::new_array(tmem, Vec4, (sz)total);
            started = clock::now();
            job.reserve_output(transforms, colors)!;
            samples.reserve[run] = elapsed_ms(started);

            started = clock::now();
            run_phase(
                pool:  pool,
                range: &run_place_range,
                job:   &job,
                label: PLACE_LABEL,
            );
            samples.place[run] = elapsed_ms(started);

            started = clock::now();
            foliage::commit_scatter(subject.scene, subject.assets, &job)!;
            samples.commit[run] = elapsed_ms(started);
        };
        if (!same_layers(subject.scene, subject.reference, node)) identical = false;
    }
    return identical;
}

fn void print_timing(
    ScatterSubject* subject,
    String mode,
    uint workers,
    PhaseSamples* samples,
    bool identical,
) @local {
    io::printfn(
        "scatter_job_timing layer=%s mode=%s workers=%d count_ms=%.3f reserve_ms=%.3f place_ms=%.3f "
          "commit_ms=%.3f identical=%s",
        subject.name,
        mode,
        workers,
        median(samples.count[..]),
        median(samples.reserve[..]),
        median(samples.place[..]),
        median(samples.commit[..]),
        identical,
    );
}

fn RangeCounts range_counts(JobRangeRecord[] records, String label) @local @feat(C3D_PROFILE_CPU) {
    RangeCounts counts;
    ulong lanes;
    foreach (record : records) {
        if (record.name != label) continue;

        counts.ranges++;
        counts.busy_ms += (double)(record.end_ns - record.start_ns) / NANOSECONDS_PER_MILLISECOND;
        lanes |= 1UL << min(record.worker, 63u);
    }
    counts.lanes = (uint)lanes.popcount();
    return counts;
}

fn void print_ranges(ScatterSubject* subject, JobPool* pool) @local @feat(C3D_PROFILE_CPU) {
    JobRangeRecord[] records = alloc::new_array(mem, JobRangeRecord, (sz)job::DEFAULT_RECORD_CAPACITY);
    defer alloc::free(mem, records.ptr);
    JobRecordDrain drain = pool.take_records(records);
    String[2] labels = { COUNT_LABEL, PLACE_LABEL };
    foreach (label : labels) {
        RangeCounts counts = range_counts(records[:drain.count], label);
        io::printfn(
            "scatter_job_ranges layer=%s phase=%s ranges_per_run=%d lanes=%d busy_ms_per_run=%.3f dropped=%d",
            subject.name,
            label,
            counts.ranges / RUNS,
            counts.lanes,
            counts.busy_ms / RUNS,
            drain.dropped,
        );
    }
}

fn bool? report_configuration(
    ScatterSubject* subject,
    JobPool* pool,
    String mode,
    uint workers,
) @local {
    PhaseSamples samples;
    $if $feat(C3D_PROFILE_CPU):
        if (pool) pool.set_recording(true);
    $endif
    bool identical = measure_scatter(subject, pool, &samples)!;
    print_timing(
        subject:   subject,
        mode:      mode,
        workers:   workers,
        samples:   &samples,
        identical: identical,
    );
    $if $feat(C3D_PROFILE_CPU):
        if (pool) {
            pool.set_recording(false);
            if (workers > 0) print_ranges(subject, pool);
        }
    $endif
    return identical;
}

fn JobPool? create_scatter_pool(uint workers) @local {
    JobPoolDesc desc = job::default_job_pool_desc();
    desc.worker_count = workers;
    desc.background_workers = job::default_background_workers(workers);
    return job::create_job_pool(mem, desc);
}

<*
 Scatter the layer again through the job API and compare it with the serial scatter.
 Measures one range here, a pool without workers, and a pool with the given workers.
 @param [&in] subject
 @return "Whether every scatter matches the serial layer bit for bit."
*>
fn bool? report_scatter_jobs(ScatterSubject* subject, uint workers) {
    @pool() {
        Node* node = add_pending_layer(subject)!;
        defer subject.scene.remove(node);
        ScatterJob job = foliage::scatter_job(
                scene:   subject.scene,
                assets:  subject.assets,
                layer:   node.id,
                scratch: tmem,
            )!;
        io::printfn(
            "scatter_job layer=%s cells=%d instances=%d serial_ms=%.3f runs=%d",
            subject.name,
            job.cell_count(),
            subject.scene.get(subject.reference, FoliageRuntime).instances,
            subject.serial_ms,
            RUNS,
        );
    };

    bool identical = report_configuration(
        subject: subject,
        pool:    null,
        mode:    "serial",
        workers: 0,
    )!;
    JobPool inline_pool = create_scatter_pool(0)!;
    defer job::destroy_job_pool(&inline_pool);
    if (!report_configuration(
        subject: subject,
        pool:    &inline_pool,
        mode:    "inline",
        workers: 0,
    )!) identical = false;
    if (workers > 0) {
        JobPool pool = create_scatter_pool(workers)!;
        defer job::destroy_job_pool(&pool);
        if (!report_configuration(
            subject: subject,
            pool:    &pool,
            mode:    "workers",
            workers: workers,
        )!) identical = false;
    }
    return identical;
}
