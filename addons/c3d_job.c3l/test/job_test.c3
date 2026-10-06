module c3d_job_test;

import std::thread;
import std::atomic::types;
import c3d;
import c3d::job;

const uint TEST_WORKERS @local = 3; // the 4-vCPU CI runners: three workers and the caller
const uint[2] WORKER_COUNTS @local = { 0, TEST_WORKERS };
const uint BATCH @local = 64;
const uint LARGE_COUNT @local = 100_003; // prime, so the last range is short
const uint[6] COVERAGE_COUNTS @local = { 0, 1, BATCH - 1, BATCH, BATCH + 1, LARGE_COUNT };
const uint SPIN_LIMIT @local = 20_000_000; // yields before a stuck gate fails the test instead of hanging CI
const uint MIXED_COUNT @local = 10_007;
const uint MIXED_BATCH @local = 37;
const ulong MIXED_SALT @local = 0x9e37;
const uint MIX_SHIFT @local = 33;
const ulong[2] MIX_MULTIPLIERS @local = { 0xff51afd7ed558ccd, 0xc4ceb9fe1a85ec53 }; // murmur3's 64-bit finalizer
const ulong RANDOM_INCREMENT @local = 0x9e3779b97f4a7c15; // the golden-ratio Weyl step
const uint NESTED_OUTER @local = 8;
const uint NESTED_INNER @local = 16;
const uint TABLE_COUNT @local = 5;
const uint STALE_COUNT @local = 4;
const uint DESTROY_WORKERS @local = 2;
const uint DESTROY_COUNT @local = 64;
const usz SCRATCH_WORKER_TEMP_BYTES @local = 64 * 1024;
const usz SCRATCH_BYTES @local = 256 * 1024; // four times the workers' temp allocator
const uint SCRATCH_COUNT @local = 32;
const uint STRESS_ITERATIONS @local = 70;
const uint STRESS_RUNS @local = 3;
const uint STRESS_WAIT_ALL_EVERY @local = 3;
const uint STRESS_MAX_COUNT @local = 20_000;
const uint STRESS_MAX_BATCH @local = 128; // also the reference size of a run at batch 0
const uint STRESS_RUN_SLOTS @local = 2;
const uint STRESS_BACKGROUND_SLOTS @local = 1; // a second background run in one iteration is refused
const uint STRESS_BACKGROUND_ODDS @local = 3; // one run in three asks for the background class
const ulong STRESS_SEED @local = 0x5eed;
const uint STRESS_AUTO_BATCH_ODDS @local = 4; // one run in four uses batch 0
const uint STRESS_COUNT_KINDS @local = 6; // 0, 1, batch - 1 and batch + 1, or uniform twice as often
const uint REFUSED_COUNT @local = 8;
const uint PARTITION_COUNT @local = 32;
const uint CAPPED_WORKERS @local = 2;
const uint CAPPED_RANGES @local = TEST_WORKERS; // one more than the cap, so a range must wait for it
const uint ORDER_COUNT @local = 2;
const uint PUMPED_RUNS @local = 3;
const uint SPAWN_COUNT @local = 16;

struct Coverage @local {
    Atomic{uint}[] visits;
    Atomic{uint}   ranges;
    Atomic{uint}   largest;
}

struct Gate @local {
    Atomic{uint} started;
    Atomic{uint} open;
    Atomic{uint} finished;
}

struct GatedCoverage @local {
    Gate     gate;
    Coverage coverage;
}

struct Ordered @local {
    Atomic{uint}*     sequence;
    uint[ORDER_COUNT] order; // sequence value when each item ran
}

struct Mixed @local {
    ulong[] output;
    ulong   salt;
}

struct Nested @local {
    JobPool                              pool;
    Thread[NESTED_OUTER]                 outer_threads;
    Thread[NESTED_OUTER * NESTED_INNER]  inner_threads;
    Coverage                             inner_items;
}

struct NestedItem @local {
    Nested* nested;
    uint    outer;
}

struct Spawner @local {
    JobPool* pool;
    JobId    id;
    Coverage coverage;
}

struct Scratch @local {
    ulong[] output;
}

struct Holder @local {
    JobPool pool;
}

fn JobPool create_test_pool(uint workers, uint run_capacity = job::DEFAULT_RUN_CAPACITY) @local {
    JobPoolDesc desc = job::default_job_pool_desc();
    desc.worker_count = workers;
    desc.run_capacity = run_capacity;
    desc.background_workers = job::default_background_workers(workers);
    return job::create_job_pool(mem, desc)!!;
}

fn JobPool create_class_pool(
    uint workers,
    uint background_workers,
    uint background_run_capacity = job::DEFAULT_BACKGROUND_RUN_CAPACITY,
    uint run_capacity = job::DEFAULT_RUN_CAPACITY,
) @local {
    JobPoolDesc desc = job::default_job_pool_desc();
    desc.worker_count = workers;
    desc.background_workers = background_workers;
    desc.background_run_capacity = background_run_capacity;
    desc.run_capacity = run_capacity;
    return job::create_job_pool(mem, desc)!!;
}

fn Coverage create_coverage(uint count) @local => { .visits = mem::new_array(Atomic{uint}, count) };

fn void destroy_coverage(Coverage* coverage) @local {
    free(coverage.visits);
}

fn void cover_range(void* data, uint first, uint count) @local {
    Coverage* coverage = data;
    for (uint item = first; item < first + count; item++) coverage.visits[item].add(1);
    coverage.ranges.add(1);
    coverage.largest.max(count);
}

fn void assert_covered_once(Coverage* coverage, uint count) @local {
    for (uint item = 0; item < count; item++) assert(coverage.visits[item].load() == 1);
}

fn void assert_untouched(Coverage* coverage) @local {
    foreach (&visit : coverage.visits) assert(visit.load() == 0);
    assert(coverage.ranges.load() == 0);
}

fn void spin_until(Atomic{uint}* value, uint target) @local {
    for (uint spins = 0; value.load() < target; spins++) {
        assert(spins < SPIN_LIMIT, "Gate not reached.");
        thread::yield();
    }
}

fn void spin_until_finished(JobPool* pool, JobId id) @local {
    for (uint spins = 0; !pool.is_finished(id); spins++) {
        assert(spins < SPIN_LIMIT, "Run not finished.");
        thread::yield();
    }
}

macro void @assert_refused(#submission) @local {
    bool refused;
    if (catch excuse = #submission) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
        refused = true;
    }
    assert(refused, "Submission was accepted.");
}

fn void gate_range(void* data, uint first, uint count) @local {
    Gate* gate = data;
    gate.started.add(count);
    spin_until(&gate.open, 1);
    gate.finished.add(count);
}

fn void gated_cover_range(void* data, uint first, uint count) @local {
    GatedCoverage* gated = data;
    gate_range(&gated.gate, first, count);
    cover_range(&gated.coverage, first, count);
}

fn void ordered_range(void* data, uint first, uint count) @local {
    Ordered* ordered = data;
    for (uint item = first; item < first + count; item++) ordered.order[item] = ordered.sequence.add(1);
}

fn void spawn_background_range(void* data, uint first, uint count) @local {
    Spawner* spawner = data;
    spawner.id = spawner.pool.try_run(
        job_class: BACKGROUND,
        range:     &cover_range,
        data:      &spawner.coverage,
        count:     SPAWN_COUNT,
        batch:     1,
    )!!;
}

fn ulong mix(ulong value) @local {
    value ^= value >> MIX_SHIFT;
    value *= MIX_MULTIPLIERS[0];
    value ^= value >> MIX_SHIFT;
    value *= MIX_MULTIPLIERS[1];
    value ^= value >> MIX_SHIFT;
    return value;
}

fn ulong next_random(ulong* state) @local {
    *state += RANDOM_INCREMENT;
    return mix(*state);
}

fn Mixed create_mixed(uint count, ulong salt) @local => { .output = mem::new_array(ulong, count), .salt = salt };

fn void mix_range(void* data, uint first, uint count) @local {
    Mixed* mixed = data;
    for (uint item = first; item < first + count; item++) mixed.output[item] = mix(item ^ mixed.salt);
}

fn void inner_range(void* data, uint first, uint count) @local {
    NestedItem* item = data;
    Nested* nested = item.nested;
    for (uint inner = first; inner < first + count; inner++) {
        uint index = item.outer * NESTED_INNER + inner;
        nested.inner_threads[index] = thread::current();
        nested.inner_items.visits[index].add(1);
    }
}

fn void outer_range(void* data, uint first, uint count) @local {
    Nested* nested = data;
    for (uint outer = first; outer < first + count; outer++) {
        nested.outer_threads[outer] = thread::current();
        NestedItem item = { .nested = nested, .outer = outer };
        nested.pool.wait(nested.pool.run(
            range: &inner_range,
            data:  &item,
            count: NESTED_INNER,
            batch: 1,
        ));
    }
}

fn void scratch_range(void* data, uint first, uint count) @local {
    Scratch* scratch = data;
    char[] bytes = mem::temp_array(char, SCRATCH_BYTES);
    for (uint item = first; item < first + count; item++) {
        foreach (index, &byte : bytes) *byte = (char)(index + item);
        ulong sum;
        foreach (ulong index, byte : bytes) sum += index * byte;
        scratch.output[item] = sum;
    }
}

fn uint random_batch(ulong* seed) @local {
    if (next_random(seed) % STRESS_AUTO_BATCH_ODDS == 0) return 0;
    return (uint)(next_random(seed) % STRESS_MAX_BATCH) + 1;
}

fn uint random_count(ulong* seed, uint batch) @local {
    uint reference = batch ? batch : STRESS_MAX_BATCH;
    switch (next_random(seed) % STRESS_COUNT_KINDS) {
        case 0: return 0;
        case 1: return 1;
        case 2: return reference - 1;
        case 3: return reference + 1;
        default: return (uint)(next_random(seed) % STRESS_MAX_COUNT);
    }
}

fn JobId submit_random_run(
    JobPool* pool,
    Mixed* run,
    uint count,
    uint batch,
    bool background,
) @local {
    if (background) {
        JobId? id = pool.try_run(
            job_class: BACKGROUND,
            range:     &mix_range,
            data:      run,
            count:     count,
            batch:     batch,
        );
        if (try id) return id;
        @assert_refused(id);
    }
    return pool.run(
        range: &mix_range,
        data:  run,
        count: count,
        batch: batch,
    );
}

fn void test_ranges_cover_each_item_exactly_once() @test {
    foreach (workers : WORKER_COUNTS) {
        JobPool pool = create_test_pool(workers);
        defer job::destroy_job_pool(&pool);
        foreach (count : COVERAGE_COUNTS) {
            Coverage batched = create_coverage(count);
            defer destroy_coverage(&batched);
            pool.wait(pool.run(
                range: &cover_range,
                data:  &batched,
                count: count,
                batch: BATCH,
            ));
            assert_covered_once(&batched, count);
            assert(batched.ranges.load() == (count + BATCH - 1) / BATCH);
            assert(batched.largest.load() <= BATCH);

            Coverage chosen = create_coverage(count);
            defer destroy_coverage(&chosen);
            pool.wait(pool.run(
                range: &cover_range,
                data:  &chosen,
                count: count,
                batch: 0,
            ));
            assert_covered_once(&chosen, count);
        }
    }
}

fn void test_results_match_across_worker_counts() @test {
    Mixed reference = create_mixed(MIXED_COUNT, MIXED_SALT);
    defer free(reference.output);
    mix_range(&reference, 0, MIXED_COUNT);

    foreach (workers : WORKER_COUNTS) {
        JobPool pool = create_test_pool(workers);
        defer job::destroy_job_pool(&pool);
        Mixed pooled = create_mixed(MIXED_COUNT, MIXED_SALT);
        defer free(pooled.output);
        pool.wait(pool.run(
            range: &mix_range,
            data:  &pooled,
            count: MIXED_COUNT,
            batch: MIXED_BATCH,
        ));
        assert(pooled.output == reference.output);
    }
}

fn void test_nested_run_executes_inline_on_the_range_thread() @test {
    foreach (workers : WORKER_COUNTS) {
        Nested nested = {
            .pool        = create_test_pool(workers),
            .inner_items = create_coverage(NESTED_OUTER * NESTED_INNER),
        };
        defer job::destroy_job_pool(&nested.pool);
        defer destroy_coverage(&nested.inner_items);
        ulong inline_before = nested.pool.inline_ranges();

        nested.pool.wait(nested.pool.run(
            range: &outer_range,
            data:  &nested,
            count: NESTED_OUTER,
            batch: 1,
        ));

        for (uint outer = 0; outer < NESTED_OUTER; outer++) {
            for (uint inner = 0; inner < NESTED_INNER; inner++) {
                assert(nested.inner_threads[outer * NESTED_INNER + inner].equals(nested.outer_threads[outer]));
            }
        }
        assert_covered_once(&nested.inner_items, NESTED_OUTER * NESTED_INNER);
        assert(nested.pool.inline_ranges() == inline_before);
    }
}

fn void test_full_frame_partition_runs_the_whole_run_inline() @test {
    JobPool pool = create_test_pool(1, run_capacity: 1);
    defer job::destroy_job_pool(&pool);
    Gate gate;
    pool.run(
        range: &gate_range,
        data:  &gate,
        count: 1,
        batch: 1,
    );
    spin_until(&gate.started, 1);

    Coverage coverage = create_coverage(TABLE_COUNT);
    defer destroy_coverage(&coverage);
    ulong inline_before = pool.inline_ranges();
    JobId id = pool.run(
        range: &cover_range,
        data:  &coverage,
        count: TABLE_COUNT,
        batch: 1,
    );
    assert(id.generation == 0);
    assert_covered_once(&coverage, TABLE_COUNT);
    assert(pool.inline_ranges() - inline_before == TABLE_COUNT);
    assert(gate.finished.load() == 0);
    gate.open.store(1);
    pool.wait_all();

    JobPool inline_pool = create_test_pool(0, run_capacity: 1);
    defer job::destroy_job_pool(&inline_pool);
    Coverage inline_coverage = create_coverage(TABLE_COUNT);
    defer destroy_coverage(&inline_coverage);
    inline_pool.wait(inline_pool.run(
        range: &cover_range,
        data:  &inline_coverage,
        count: TABLE_COUNT,
        batch: 1,
    ));
    assert_covered_once(&inline_coverage, TABLE_COUNT);
    assert(inline_pool.inline_ranges() == 0);
}

fn void test_stale_id_does_not_wait_on_the_reused_slot() @test {
    JobPool pool = create_test_pool(1, run_capacity: 1);
    defer job::destroy_job_pool(&pool);
    Coverage coverage = create_coverage(STALE_COUNT);
    defer destroy_coverage(&coverage);
    JobId first = pool.run(
        range: &cover_range,
        data:  &coverage,
        count: STALE_COUNT,
        batch: 1,
    );
    pool.wait(first);

    Gate gate;
    JobId second = pool.run(
        range: &gate_range,
        data:  &gate,
        count: 1,
        batch: 1,
    );
    spin_until(&gate.started, 1);
    assert(first.index == second.index);
    assert(first.generation != second.generation);
    pool.wait(first);
    assert(gate.finished.load() == 0);

    gate.open.store(1);
    pool.wait(second);
    assert(gate.finished.load() == 1);
}

fn void test_finished_turns_true_without_wait() @test {
    JobPool pool = create_test_pool(TEST_WORKERS, run_capacity: 1);
    defer job::destroy_job_pool(&pool);
    assert(pool.is_finished({}));

    GatedCoverage gated = { .coverage = create_coverage(TEST_WORKERS) };
    defer destroy_coverage(&gated.coverage);
    JobId first = pool.run(
        range: &gated_cover_range,
        data:  &gated,
        count: TEST_WORKERS,
        batch: 1,
    );
    spin_until(&gated.gate.started, 1);
    assert(!pool.is_finished(first));
    gated.gate.open.store(1);
    spin_until_finished(&pool, first);
    assert_covered_once(&gated.coverage, TEST_WORKERS);

    Gate gate;
    JobId second = pool.run(
        range: &gate_range,
        data:  &gate,
        count: 1,
        batch: 1,
    );
    spin_until(&gate.started, 1);
    assert(second.index == first.index && second.generation != first.generation);
    assert(pool.is_finished(first));
    assert(!pool.is_finished(second));
    gate.open.store(1);
    spin_until_finished(&pool, second);
}

fn void test_refused_run_queues_nothing() @test {
    JobPool pool = create_class_pool(
        workers:                 1,
        background_workers:      1,
        background_run_capacity: 1,
        run_capacity:            1,
    );
    defer job::destroy_job_pool(&pool);
    Gate frame_gate;
    pool.run(
        range: &gate_range,
        data:  &frame_gate,
        count: 1,
        batch: 1,
    );
    spin_until(&frame_gate.started, 1);
    Gate background_gate;
    pool.try_run(
        job_class: BACKGROUND,
        range:     &gate_range,
        data:      &background_gate,
        count:     1,
        batch:     1,
    )!!;

    Coverage coverage = create_coverage(REFUSED_COUNT);
    defer destroy_coverage(&coverage);
    ulong inline_before = pool.inline_ranges();
    @assert_refused(pool.try_run(
        job_class: FRAME,
        range:     &cover_range,
        data:      &coverage,
        count:     REFUSED_COUNT,
        batch:     1,
    ));
    @assert_refused(pool.try_run(
        job_class: BACKGROUND,
        range:     &cover_range,
        data:      &coverage,
        count:     REFUSED_COUNT,
        batch:     1,
    ));
    assert(pool.inline_ranges() == inline_before);
    assert_untouched(&coverage);
    frame_gate.open.store(1);
    background_gate.open.store(1);
    pool.wait_all();

    foreach (workers : WORKER_COUNTS) {
        JobPool refusing = create_class_pool(
            workers:                 workers,
            background_workers:      job::default_background_workers(workers),
            background_run_capacity: 0,
        );
        defer job::destroy_job_pool(&refusing);
        @assert_refused(refusing.try_run(
            job_class: BACKGROUND,
            range:     &cover_range,
            data:      &coverage,
            count:     REFUSED_COUNT,
            batch:     1,
        ));
        assert_untouched(&coverage);
    }
}

fn void test_partitions_keep_the_classes_apart() @test {
    JobPool pool = create_class_pool(
        workers:                 TEST_WORKERS,
        background_workers:      1,
        background_run_capacity: 2,
        run_capacity:            1,
    );
    defer job::destroy_job_pool(&pool);
    Gate[2] background_gates;
    JobId[2] background_ids;
    foreach (index, &gate : background_gates) {
        background_ids[index] = pool.try_run(
            job_class: BACKGROUND,
            range:     &gate_range,
            data:      gate,
            count:     1,
            batch:     1,
        )!!;
    }
    spin_until(&background_gates[0].started, 1);

    Coverage frame_coverage = create_coverage(PARTITION_COUNT);
    defer destroy_coverage(&frame_coverage);
    ulong inline_before = pool.inline_ranges();
    JobId frame = pool.run(
        range: &cover_range,
        data:  &frame_coverage,
        count: PARTITION_COUNT,
        batch: 1,
    );
    assert(frame.generation != 0);
    spin_until_finished(&pool, frame);
    assert_covered_once(&frame_coverage, PARTITION_COUNT);
    assert(pool.inline_ranges() == inline_before);
    foreach (&gate : background_gates) gate.open.store(1);
    foreach (id : background_ids) spin_until_finished(&pool, id);

    Gate frame_gate;
    JobId held = pool.run(
        range: &gate_range,
        data:  &frame_gate,
        count: 1,
        batch: 1,
    );
    spin_until(&frame_gate.started, 1);
    Coverage background_coverage = create_coverage(PARTITION_COUNT);
    defer destroy_coverage(&background_coverage);
    JobId background = pool.try_run(
        job_class: BACKGROUND,
        range:     &cover_range,
        data:      &background_coverage,
        count:     PARTITION_COUNT,
        batch:     1,
    )!!;
    spin_until_finished(&pool, background);
    assert_covered_once(&background_coverage, PARTITION_COUNT);
    frame_gate.open.store(1);
    spin_until_finished(&pool, held);
}

fn void test_frame_run_finishes_past_capped_background() @test {
    JobPool pool = create_class_pool(workers: TEST_WORKERS, background_workers: CAPPED_WORKERS);
    defer job::destroy_job_pool(&pool);
    Gate gate;
    JobId background = pool.try_run(
        job_class: BACKGROUND,
        range:     &gate_range,
        data:      &gate,
        count:     CAPPED_RANGES,
        batch:     1,
    )!!;
    spin_until(&gate.started, CAPPED_WORKERS);

    Coverage coverage = create_coverage(PARTITION_COUNT);
    defer destroy_coverage(&coverage);
    JobId frame = pool.run(
        range: &cover_range,
        data:  &coverage,
        count: PARTITION_COUNT,
        batch: 1,
    );
    spin_until_finished(&pool, frame);
    assert_covered_once(&coverage, PARTITION_COUNT);
    assert(gate.started.load() == CAPPED_WORKERS);
    assert(!pool.is_finished(background));

    gate.open.store(1);
    spin_until_finished(&pool, background);
    assert(gate.finished.load() == CAPPED_RANGES);
}

fn void test_frame_ranges_go_before_queued_background_ranges() @test {
    JobPool pool = create_class_pool(workers: 1, background_workers: 1);
    defer job::destroy_job_pool(&pool);
    Gate gate;
    pool.run(
        range: &gate_range,
        data:  &gate,
        count: 1,
        batch: 1,
    );
    spin_until(&gate.started, 1);

    Atomic{uint} sequence;
    Ordered background_order = { .sequence = &sequence };
    Ordered frame_order = { .sequence = &sequence };
    JobId background = pool.try_run(
        job_class: BACKGROUND,
        range:     &ordered_range,
        data:      &background_order,
        count:     ORDER_COUNT,
        batch:     1,
    )!!;
    JobId frame = pool.run(
        range: &ordered_range,
        data:  &frame_order,
        count: ORDER_COUNT,
        batch: 1,
    );
    assert(!pool.is_finished(background) && !pool.is_finished(frame));

    gate.open.store(1);
    spin_until_finished(&pool, background);
    spin_until_finished(&pool, frame);
    foreach (frame_step : frame_order.order) {
        foreach (background_step : background_order.order) assert(frame_step < background_step);
    }
}

fn void test_background_without_workers_runs_only_when_pumped() @test {
    foreach (workers : WORKER_COUNTS) {
        JobPool pool = create_class_pool(workers: workers, background_workers: 0);
        defer job::destroy_job_pool(&pool);
        Atomic{uint} sequence;
        Ordered[PUMPED_RUNS] runs;
        JobId[PUMPED_RUNS] ids;
        foreach (index, &run : runs) {
            run.sequence = &sequence;
            ids[index] = pool.try_run(
                job_class: BACKGROUND,
                range:     &ordered_range,
                data:      run,
                count:     ORDER_COUNT,
                batch:     1,
            )!!;
        }
        assert(sequence.load() == 0);
        foreach (id : ids) assert(!pool.is_finished(id));

        assert(pool.pump(1) == 1);
        assert(sequence.load() == 1 && runs[0].order[0] == 0);
        assert(!pool.is_finished(ids[0]));
        assert(pool.pump() == PUMPED_RUNS * ORDER_COUNT - 1);
        foreach (index, run : runs) {
            assert(pool.is_finished(ids[index]));
            foreach (step, value : run.order) assert(value == index * ORDER_COUNT + step);
        }

        Spawner spawner = { .pool = &pool, .coverage = create_coverage(SPAWN_COUNT) };
        defer destroy_coverage(&spawner.coverage);
        JobId outer = pool.try_run(
            job_class: BACKGROUND,
            range:     &spawn_background_range,
            data:      &spawner,
            count:     1,
            batch:     1,
        )!!;
        assert(pool.pump() == 1);
        assert(pool.is_finished(outer) && !pool.is_finished(spawner.id));
        assert_untouched(&spawner.coverage);
        assert(pool.pump() == SPAWN_COUNT);
        assert_covered_once(&spawner.coverage, SPAWN_COUNT);
    }

    JobPool destroyed = create_class_pool(workers: 0, background_workers: 0);
    Coverage left = create_coverage(SPAWN_COUNT);
    defer destroy_coverage(&left);
    destroyed.try_run(
        job_class: BACKGROUND,
        range:     &cover_range,
        data:      &left,
        count:     SPAWN_COUNT,
        batch:     1,
    )!!;
    assert_untouched(&left);
    job::destroy_job_pool(&destroyed);
    assert_covered_once(&left, SPAWN_COUNT);
}

fn void test_pump_runs_queued_background_beside_capped_workers() @test {
    JobPool pool = create_class_pool(workers: 1, background_workers: 1);
    defer job::destroy_job_pool(&pool);
    Gate gate;
    pool.try_run(
        job_class: BACKGROUND,
        range:     &gate_range,
        data:      &gate,
        count:     1,
        batch:     1,
    )!!;
    spin_until(&gate.started, 1);

    Coverage background_coverage = create_coverage(PARTITION_COUNT);
    defer destroy_coverage(&background_coverage);
    JobId background = pool.try_run(
        job_class: BACKGROUND,
        range:     &cover_range,
        data:      &background_coverage,
        count:     PARTITION_COUNT,
        batch:     1,
    )!!;
    Coverage frame_coverage = create_coverage(PARTITION_COUNT);
    defer destroy_coverage(&frame_coverage);
    JobId frame = pool.run(
        range: &cover_range,
        data:  &frame_coverage,
        count: PARTITION_COUNT,
        batch: 1,
    );

    assert(pool.pump() == PARTITION_COUNT);
    assert(pool.is_finished(background));
    assert_covered_once(&background_coverage, PARTITION_COUNT);
    assert(!pool.is_finished(frame));
    assert_untouched(&frame_coverage);
    gate.open.store(1);
    spin_until_finished(&pool, frame);
    assert_covered_once(&frame_coverage, PARTITION_COUNT);
}

fn void test_nested_try_run_queues_on_the_pool() @test {
    JobPool pool = create_test_pool(TEST_WORKERS);
    defer job::destroy_job_pool(&pool);
    Spawner spawner = { .pool = &pool, .coverage = create_coverage(SPAWN_COUNT) };
    defer destroy_coverage(&spawner.coverage);
    JobId outer = pool.run(
        range: &spawn_background_range,
        data:  &spawner,
        count: 1,
        batch: 1,
    );
    spin_until_finished(&pool, outer);
    assert(spawner.id.generation != 0);
    spin_until_finished(&pool, spawner.id);
    assert_covered_once(&spawner.coverage, SPAWN_COUNT);
}

fn void test_background_only_workers_run_background_outside_the_cap() @test {
    foreach (workers : WORKER_COUNTS) {
        JobPoolDesc desc = job::default_job_pool_desc();
        desc.worker_count = workers;
        desc.background_workers = 0;
        desc.background_only_workers = 1;
        JobPool pool = job::create_job_pool(mem, desc)!!;
        defer job::destroy_job_pool(&pool);
        Coverage background_coverage = create_coverage(PARTITION_COUNT);
        defer destroy_coverage(&background_coverage);
        JobId background = pool.try_run(
            job_class: BACKGROUND,
            range:     &cover_range,
            data:      &background_coverage,
            count:     PARTITION_COUNT,
            batch:     1,
        )!!;
        spin_until_finished(&pool, background);
        assert_covered_once(&background_coverage, PARTITION_COUNT);

        Coverage frame_coverage = create_coverage(PARTITION_COUNT);
        defer destroy_coverage(&frame_coverage);
        JobId frame = pool.run(
            range: &cover_range,
            data:  &frame_coverage,
            count: PARTITION_COUNT,
            batch: 1,
        );
        assert((frame.generation == 0) == (workers == 0));
        pool.wait(frame);
        assert_covered_once(&frame_coverage, PARTITION_COUNT);
    }
}

fn void test_background_only_workers_do_not_count_against_the_cap() @test {
    JobPoolDesc desc = job::default_job_pool_desc();
    desc.worker_count = 1;
    desc.background_workers = 1;
    desc.background_only_workers = 1;
    JobPool pool = job::create_job_pool(mem, desc)!!;
    defer job::destroy_job_pool(&pool);
    Gate frame_gate;
    Gate background_gate;
    defer {
        frame_gate.open.store(1);
        background_gate.open.store(1);
    }

    JobId frame = pool.run(
        range: &gate_range,
        data:  &frame_gate,
        count: 1,
        batch: 1,
    );
    spin_until(&frame_gate.started, 1);
    JobId background = pool.try_run(
        job_class: BACKGROUND,
        range:     &gate_range,
        data:      &background_gate,
        count:     2,
        batch:     1,
    )!!;
    spin_until(&background_gate.started, 1);
    assert(background_gate.started.load() == 1);

    frame_gate.open.store(1);
    spin_until(&background_gate.started, 2);
    background_gate.open.store(1);
    spin_until_finished(&pool, frame);
    spin_until_finished(&pool, background);
}

fn void test_pool_survives_a_move_of_its_handle() @test {
    Holder holder = { .pool = create_test_pool(TEST_WORKERS) };
    Coverage coverage = create_coverage(LARGE_COUNT);
    defer destroy_coverage(&coverage);

    holder.pool.wait(holder.pool.run(
        range: &cover_range,
        data:  &coverage,
        count: LARGE_COUNT,
        batch: BATCH,
    ));
    assert_covered_once(&coverage, LARGE_COUNT);
    job::destroy_job_pool(&holder.pool);
}

fn void test_destroy_waits_for_outstanding_runs() @test {
    JobPool pool = create_test_pool(DESTROY_WORKERS);
    Gate gate;
    pool.run(
        range: &gate_range,
        data:  &gate,
        count: DESTROY_WORKERS,
        batch: 1,
    );
    spin_until(&gate.started, DESTROY_WORKERS);

    Coverage coverage = create_coverage(DESTROY_COUNT);
    defer destroy_coverage(&coverage);
    pool.run(
        range: &cover_range,
        data:  &coverage,
        count: DESTROY_COUNT,
        batch: 1,
    );
    Coverage background_coverage = create_coverage(DESTROY_COUNT);
    defer destroy_coverage(&background_coverage);
    pool.try_run(
        job_class: BACKGROUND,
        range:     &cover_range,
        data:      &background_coverage,
        count:     DESTROY_COUNT,
        batch:     1,
    )!!;
    gate.open.store(1);
    job::destroy_job_pool(&pool);

    assert_covered_once(&coverage, DESTROY_COUNT);
    assert_covered_once(&background_coverage, DESTROY_COUNT);
    assert(gate.finished.load() == DESTROY_WORKERS);
}

fn void test_range_scratch_beyond_worker_temp_bytes_still_works() @test {
    Scratch reference = { .output = mem::new_array(ulong, SCRATCH_COUNT) };
    defer free(reference.output);
    @pool() {
        scratch_range(&reference, 0, SCRATCH_COUNT);
    };

    foreach (workers : WORKER_COUNTS) {
        JobPoolDesc desc = job::default_job_pool_desc();
        desc.worker_count = workers;
        desc.background_workers = job::default_background_workers(workers);
        desc.worker_temp_bytes = SCRATCH_WORKER_TEMP_BYTES;
        JobPool pool = job::create_job_pool(mem, desc)!!;
        defer job::destroy_job_pool(&pool);
        Scratch pooled = { .output = mem::new_array(ulong, SCRATCH_COUNT) };
        defer free(pooled.output);

        pool.wait(pool.run(
            range: &scratch_range,
            data:  &pooled,
            count: SCRATCH_COUNT,
            batch: 1,
        ));
        assert(pooled.output == reference.output);
    }
}

fn void test_randomized_runs_match_the_serial_reference() @test {
    Mixed reference = create_mixed(STRESS_MAX_COUNT, 0);
    defer free(reference.output);
    Mixed[STRESS_RUNS] runs;
    foreach (&run : runs) *run = create_mixed(STRESS_MAX_COUNT, 0);
    defer foreach (run : runs) free(run.output);

    foreach (workers : WORKER_COUNTS) {
        JobPool pool = create_class_pool(
            workers:                 workers,
            background_workers:      job::default_background_workers(workers),
            background_run_capacity: STRESS_BACKGROUND_SLOTS,
            run_capacity:            STRESS_RUN_SLOTS,
        );
        defer job::destroy_job_pool(&pool);
        ulong seed = STRESS_SEED;
        for (uint iteration = 0; iteration < STRESS_ITERATIONS; iteration++) {
            JobId[STRESS_RUNS] ids;
            uint[STRESS_RUNS] counts;
            foreach (index, &run : runs) {
                uint batch = random_batch(&seed);
                counts[index] = random_count(&seed, batch);
                run.salt = next_random(&seed);
                ids[index] = submit_random_run(
                    pool:       &pool,
                    run:        run,
                    count:      counts[index],
                    batch:      batch,
                    background: next_random(&seed) % STRESS_BACKGROUND_ODDS == 0,
                );
            }

            if (iteration % STRESS_WAIT_ALL_EVERY == 0) {
                pool.wait_all();
            } else {
                for (usz index = STRESS_RUNS; index > 0; index--) pool.wait(ids[index - 1]);
            }

            foreach (index, &run : runs) {
                reference.salt = run.salt;
                mix_range(&reference, 0, counts[index]);
                assert(run.output[:counts[index]] == reference.output[:counts[index]]);
            }
        }
    }
}
