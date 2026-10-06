module c3d_job_profile_test @feat(C3D_PROFILE_CPU);

import std::thread;
import std::atomic::types;
import c3d::job;
import c3d::profile;

const uint PROFILED_WORKERS @local = 3; // every range blocks on a worker, so the caller runs none
const uint RECORD_RING @local = 2; // one less than the ranges of a profiled run
const uint RECORD_BUFFER @local = 8;
const uint SPIN_LIMIT @local = 20_000_000; // yields before a stuck gate fails the test instead of hanging CI
const String RUN_NAME @local = "integrate";

struct ProfileGate @local {
    Atomic{uint} started;
    Atomic{uint} open;
}

fn void profile_spin_until(Atomic{uint}* value, uint target) @local {
    for (uint spins = 0; value.load() < target; spins++) {
        assert(spins < SPIN_LIMIT, "Gate not reached.");
        thread::yield();
    }
}

fn void profile_gate_range(void* data, uint first, uint count) @local {
    ProfileGate* gate = data;
    gate.started.add(count);
    profile_spin_until(&gate.open, 1);
}

fn JobPool create_profiled_pool(uint record_capacity) @local {
    JobPoolDesc desc = job::default_job_pool_desc();
    desc.worker_count = PROFILED_WORKERS;
    desc.background_workers = job::default_background_workers(PROFILED_WORKERS);
    desc.record_capacity = record_capacity;
    return job::create_job_pool(mem, desc)!!;
}

fn void run_on_every_worker(JobPool* pool) @local {
    ProfileGate gate;
    JobId id = pool.run(
        range: &profile_gate_range,
        data:  &gate,
        count: PROFILED_WORKERS,
        batch: 1,
        name:  RUN_NAME,
    );
    profile_spin_until(&gate.started, PROFILED_WORKERS);
    gate.open.store(1);
    for (uint spins = 0; !pool.is_finished(id); spins++) {
        assert(spins < SPIN_LIMIT, "Run not finished.");
        thread::yield();
    }
}

fn void test_workers_record_their_ranges_under_the_run_name() @test {
    JobPool pool = create_profiled_pool(job::DEFAULT_RECORD_CAPACITY);
    defer job::destroy_job_pool(&pool);
    JobRangeRecord[RECORD_BUFFER] records;
    run_on_every_worker(&pool);
    assert(pool.take_records(&records).count == 0);

    pool.set_recording(true);
    run_on_every_worker(&pool);
    JobRecordDrain drain = pool.take_records(&records);
    assert(drain.count == PROFILED_WORKERS && drain.dropped == 0);
    bool[PROFILED_WORKERS] seen;
    foreach (record : records[:drain.count]) {
        assert(record.name == RUN_NAME);
        assert(record.worker < PROFILED_WORKERS && !seen[record.worker]);
        assert(record.end_ns >= record.start_ns);
        seen[record.worker] = true;
    }
    assert(pool.take_records(&records).count == 0);
}

fn void test_full_record_ring_drops_and_counts() @test {
    JobPool pool = create_profiled_pool(RECORD_RING);
    defer job::destroy_job_pool(&pool);
    pool.set_recording(true);
    run_on_every_worker(&pool);
    JobRangeRecord[RECORD_BUFFER] records;
    JobRecordDrain drain = pool.take_records(&records);
    assert(drain.count == RECORD_RING && drain.dropped == PROFILED_WORKERS - RECORD_RING);
    drain = pool.take_records(&records);
    assert(drain.count == 0 && drain.dropped == 0);
}

fn void test_forwarded_records_land_in_the_open_capture() @test {
    Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 2,
        .cpu_scopes_per_frame = 8,
        .max_depth = 4,
        .worker_samples_per_frame = RECORD_BUFFER,
        .label_bytes_per_frame = 128,
    })!!;
    defer profile::destroy_recorder(&recorder);
    JobPool pool = create_profiled_pool(job::DEFAULT_RECORD_CAPACITY);
    defer job::destroy_job_pool(&pool);
    pool.set_recording(true);

    run_on_every_worker(&pool);
    profile::@capture(&recorder, 0) {
        assert(pool.forward_records(&recorder) == PROFILED_WORKERS);
    };
    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.workers.len == PROFILED_WORKERS && frame.dropped_worker_samples == 0);
    foreach (sample : frame.workers) {
        assert(sample.label == RUN_NAME && sample.lane < PROFILED_WORKERS);
        assert(sample.start_ns < 0 && sample.start_ns + (long)sample.duration_ns <= 0);
    }

    run_on_every_worker(&pool);
    assert(pool.forward_records(&recorder) == PROFILED_WORKERS);
    assert(recorder.frame(0)!!.workers.len == PROFILED_WORKERS);
    profile::@capture(&recorder, 1) {
        assert(pool.forward_records(&recorder) == 0);
    };
    assert(recorder.frame(1)!!.workers.len == 0);
}
