module landscape_bounds;

import std::bits;
import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;
import c3d;
import c3d::asset;
import c3d::job;
import c3d::landscape::terrain;
import c3d::maths;
import c3d::scene;

const uint RUNS @local = 5; // whole rebuilds per configuration; the rows report medians
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const String RANGE_LABEL @local = "terrain.bounds";

<* A prepared terrain whose bounds the serial update built, and what that build cost. *>
struct BoundsSubject {
    Scene*      scene;
    AssetStore* assets;
    Node*       node;
    double      serial_ms; // the terrain::update of one whole rebuild
}

// The serial result, copied before any job rebuilds the same height map.
struct BoundsReference @local {
    ushort[]    minimum;
    ushort[]    maximum;
    float[]     trace_deviation;
    float[]     drawn_chunk_deviation;
    float       trace_error;
    float[terrain::MAX_TERRAIN_LEVELS] drawn_deviation;
    Transform[] transforms;
    Vec4[]      colors;
}

struct PhaseSamples @local {
    double[RUNS] leaf;
    double[RUNS] commit;
}

struct RangeCounts @local @feat(C3D_PROFILE_CPU) {
    uint   ranges;
    uint   lanes;
    double busy_ms;
}

fn void run_bounds_range(void* job, uint first, uint count) @local {
    ((BoundsJob*)job).run_range(first, count);
}

fn double elapsed_ms(time::Clock started) @local => (double)(long)started.to_now() / NANOSECONDS_PER_MILLISECOND;

fn double median(double[] samples) @local {
    sort::quicksort(samples);
    return samples[samples.len / 2];
}

fn BoundsReference capture_reference(BoundsSubject* subject) @local {
    TerrainRuntime* runtime = subject.scene.get(subject.node, TerrainRuntime);
    InstancedMesh* batch = subject.scene.get(subject.node, InstancedMesh);
    BoundsReference reference = {
        .minimum               = alloc::new_array(mem, ushort, runtime.minimum.len),
        .maximum               = alloc::new_array(mem, ushort, runtime.maximum.len),
        .trace_deviation       = alloc::new_array(mem, float, runtime.trace_deviation.len),
        .drawn_chunk_deviation = alloc::new_array(mem, float, runtime.drawn_chunk_deviation.len),
        .trace_error           = runtime.trace_error,
        .drawn_deviation       = runtime.drawn_deviation,
        .transforms            = alloc::new_array(mem, Transform, batch.count),
        .colors                = alloc::new_array(mem, Vec4, batch.count),
    };
    reference.minimum[..] = runtime.minimum[..];
    reference.maximum[..] = runtime.maximum[..];
    reference.trace_deviation[..] = runtime.trace_deviation[..];
    reference.drawn_chunk_deviation[..] = runtime.drawn_chunk_deviation[..];
    reference.transforms[..] = batch.transforms[:batch.count];
    reference.colors[..] = batch.colors[:batch.count];
    return reference;
}

fn void free_reference(BoundsReference* reference) @local {
    alloc::free(mem, reference.minimum.ptr);
    alloc::free(mem, reference.maximum.ptr);
    alloc::free(mem, reference.trace_deviation.ptr);
    alloc::free(mem, reference.drawn_chunk_deviation.ptr);
    alloc::free(mem, reference.transforms.ptr);
    alloc::free(mem, reference.colors.ptr);
}

fn bool same_records(InstancedMesh* batch, BoundsReference* reference) @local {
    if (batch.count != reference.transforms.len) return false;
    for (uint index = 0; index < batch.count; index++) {
        Transform a = batch.transforms[index];
        Transform b = reference.transforms[index];
        if (bitcast(a.position, uint[<3>]) != bitcast(b.position, uint[<3>])) return false;
        if (bitcast(a.rotation.v, uint[<4>]) != bitcast(b.rotation.v, uint[<4>])) return false;
        if (bitcast(a.scale, uint[<3>]) != bitcast(b.scale, uint[<3>])) return false;
        if (bitcast(batch.colors[index], uint[<4>]) != bitcast(reference.colors[index], uint[<4>])) return false;
    }
    return true;
}

// Every bound, gap and published record, bit for bit.
fn bool same_bounds(BoundsSubject* subject, BoundsReference* reference) @local {
    TerrainRuntime* runtime = subject.scene.get(subject.node, TerrainRuntime);
    return mem::equals(runtime.minimum, reference.minimum)
      && mem::equals(runtime.maximum, reference.maximum)
      && mem::equals(runtime.trace_deviation, reference.trace_deviation)
      && mem::equals(runtime.drawn_chunk_deviation, reference.drawn_chunk_deviation)
      && bitcast(runtime.trace_error, uint) == bitcast(reference.trace_error, uint)
      && mem::equals(runtime.drawn_deviation[..], reference.drawn_deviation[..])
      && same_records(subject.scene.get(subject.node, InstancedMesh), reference);
}

// Rebuilds the whole map through the job API RUNS times and compares each result with the serial one.
fn bool? measure_bounds(
    BoundsSubject* subject,
    JobPool* pool,
    BoundsReference* reference,
    PhaseSamples* samples,
) @local {
    bool identical = true;
    TextureId height_map = subject.scene.get(subject.node, Terrain).desc.height_map;
    for (uint run = 0; run < RUNS; run++) {
        subject.assets.mark_texture_dirty(height_map);
        @pool() {
            BoundsJob job = terrain::bounds_job(
                scene:   subject.scene,
                assets:  subject.assets,
                node:    subject.node,
                scratch: tmem,
            )!;
            time::Clock started = clock::now();
            pool.wait(pool.run(
                range: &run_bounds_range,
                data:  &job,
                count: job.range_count(),
                batch: 0,
                name:  RANGE_LABEL,
            ));
            samples.leaf[run] = elapsed_ms(started);

            started = clock::now();
            terrain::commit_bounds(subject.scene, subject.assets, &job)!;
            samples.commit[run] = elapsed_ms(started);
        };
        if (!same_bounds(subject, reference)) identical = false;
    }
    return identical;
}

fn RangeCounts range_counts(JobRangeRecord[] records) @local @feat(C3D_PROFILE_CPU) {
    RangeCounts counts;
    ulong lanes;
    foreach (record : records) {
        if (record.name != RANGE_LABEL) continue;

        counts.ranges++;
        counts.busy_ms += (double)(record.end_ns - record.start_ns) / NANOSECONDS_PER_MILLISECOND;
        lanes |= 1UL << min(record.worker, 63u);
    }
    counts.lanes = (uint)lanes.popcount();
    return counts;
}

fn void print_ranges(JobPool* pool) @local @feat(C3D_PROFILE_CPU) {
    JobRangeRecord[] records = alloc::new_array(mem, JobRangeRecord, (sz)job::DEFAULT_RECORD_CAPACITY);
    defer alloc::free(mem, records.ptr);
    JobRecordDrain drain = pool.take_records(records);
    RangeCounts counts = range_counts(records[:drain.count]);
    io::printfn(
        "bounds_job_ranges ranges_per_run=%d lanes=%d busy_ms_per_run=%.3f dropped=%d",
        counts.ranges / RUNS,
        counts.lanes,
        counts.busy_ms / RUNS,
        drain.dropped,
    );
}

fn bool? report_configuration(
    BoundsSubject* subject,
    BoundsReference* reference,
    JobPool* pool,
    String mode,
    uint workers,
) @local {
    PhaseSamples samples;
    $if $feat(C3D_PROFILE_CPU):
        pool.set_recording(true);
    $endif
    bool identical = measure_bounds(
        subject:   subject,
        pool:      pool,
        reference: reference,
        samples:   &samples,
    )!;
    io::printfn(
        "bounds_job_timing mode=%s workers=%d leaf_ms=%.3f commit_ms=%.3f identical=%s",
        mode,
        workers,
        median(samples.leaf[..]),
        median(samples.commit[..]),
        identical,
    );
    $if $feat(C3D_PROFILE_CPU):
        pool.set_recording(false);
        if (workers > 0) print_ranges(pool);
    $endif
    return identical;
}

fn JobPool? create_bounds_pool(uint workers) @local {
    JobPoolDesc desc = job::default_job_pool_desc();
    desc.worker_count = workers;
    desc.background_workers = job::default_background_workers(workers);
    return job::create_job_pool(mem, desc);
}

<*
 Rebuild the terrain's whole bounds through the job API and compare each result with the serial one.
 Measures a pool without workers, then a pool with the given workers.
 @param [&in] subject
 @return "Whether every rebuild matches the serial bounds bit for bit."
*>
fn bool? report_bounds_jobs(BoundsSubject* subject, uint workers) {
    BoundsReference reference = capture_reference(subject);
    defer free_reference(&reference);
    TerrainRuntime* runtime = subject.scene.get(subject.node, TerrainRuntime);
    uint chunks_per_side = (runtime.texels - 1) / terrain::CHUNK_CELLS;
    io::printfn(
        "bounds_job texels=%d finest_chunks=%d traced=%s serial_ms=%.3f runs=%d",
        runtime.texels,
        chunks_per_side * chunks_per_side,
        runtime.trace_deviation.len > 0,
        subject.serial_ms,
        RUNS,
    );

    JobPool inline_pool = create_bounds_pool(0)!;
    defer job::destroy_job_pool(&inline_pool);
    bool identical = report_configuration(
        subject:   subject,
        reference: &reference,
        pool:      &inline_pool,
        mode:      "inline",
        workers:   0,
    )!;
    if (workers > 0) {
        JobPool pool = create_bounds_pool(workers)!;
        defer job::destroy_job_pool(&pool);
        if (!report_configuration(
            subject:   subject,
            reference: &reference,
            pool:      &pool,
            mode:      "workers",
            workers:   workers,
        )!) identical = false;
    }
    return identical;
}
