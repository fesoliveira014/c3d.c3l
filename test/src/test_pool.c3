module c3d_pool_test;

import c3d;
import c3d::pool;

struct Sample
{
    int value;
}

typedef SampleId = Id;

alias SamplePool = Pool{Sample, SampleId};

fn SamplePool make_pool(uint capacity) @local
{
    return pool::create_pool{Sample, SampleId}(mem, capacity);
}

fn void test_add_returns_live_id() @test
{
    SamplePool samples = make_pool(4);
    defer pool::destroy_pool{Sample, SampleId}(&samples);

    SampleId first = samples.add({ .value = 7 })!!;
    assert(samples.is_live(first));
    assert(samples.get(first).value == 7);
}

fn void test_stale_id_does_not_resolve() @test
{
    SamplePool samples = make_pool(4);
    defer pool::destroy_pool{Sample, SampleId}(&samples);

    SampleId first = samples.add({ .value = 7 })!!;
    samples.remove(first);

    assert(!samples.is_live(first));
    if (catch error = samples.try_get(first)) {
        assert(error == c3d::INVALID_ID);
    } else {
        assert(false, "try_get resolved a stale id");
    }
}

fn void test_slot_reuse_bumps_generation() @test
{
    SamplePool samples = make_pool(2);
    defer pool::destroy_pool{Sample, SampleId}(&samples);

    SampleId first = samples.add({ .value = 1 })!!;
    samples.remove(first);
    SampleId second = samples.add({ .value = 2 })!!;

    assert(second.index == first.index);
    assert(second.generation > first.generation);
    assert(!samples.is_live(first));
    assert(samples.is_live(second));
}

fn void test_full_pool_faults() @test
{
    SamplePool samples = make_pool(2);
    defer pool::destroy_pool{Sample, SampleId}(&samples);

    samples.add({ .value = 1 })!!;
    samples.add({ .value = 2 })!!;

    if (catch error = samples.add({ .value = 3 })) {
        assert(error == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a full pool accepted a value");
    }
}

fn void test_zero_id_does_not_resolve() @test
{
    SamplePool samples = make_pool(4);
    defer pool::destroy_pool{Sample, SampleId}(&samples);

    SampleId zero;
    assert(!samples.is_live(zero));
    if (catch error = samples.try_get(zero)) {
        assert(error == c3d::INVALID_ID);
    } else {
        assert(false, "try_get resolved a zero id");
    }
}

fn void test_remove_frees_a_slot() @test
{
    SamplePool samples = make_pool(3);
    defer pool::destroy_pool{Sample, SampleId}(&samples);

    SampleId[3] ids;
    for (uint index = 0; index < 3; index++) {
        ids[index] = samples.add({ .value = (int)index })!!;
    }
    for (uint index = 0; index < 3; index++) {
        samples.remove(ids[index]);
    }
    for (uint index = 0; index < 3; index++) {
        samples.add({ .value = (int)index })!!;
    }
    if (catch error = samples.add({ .value = 99 })) {
        assert(error == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a refilled pool exceeded its capacity");
    }
}
