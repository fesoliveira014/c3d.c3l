module c3d::test::instance_sort;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import std::math;

const uint SEED @local = 0x2545f491;
const uint CAMERA_POSES @local = 100;
const float DEPTH_TOLERANCE @local = 1e-4f;
const uint SOURCE_STRIDE @local = 7919; // prime, so slot * stride % count visits every source once
const uint DEPTH_LEVELS @local = 64; // few enough that equal depths are common
const uint PLACED_INSTANCES @local = 101; // odd, so the list needs its 8-byte pad before the keys
const uint CORE_WORKGROUP_LIMIT @local = 65535; // Vulkan 1.3 core minimum of maxComputeWorkGroupCount[0]
const usz ROOMY_ARENA_BYTES @local = 1 << 30; // room for MAX_SORTED_INSTANCES, so only the cap refuses one more

struct Random @local {
    uint state;
}

fn uint next_bits(Random* random) @local {
    random.state ^= random.state << 13;
    random.state ^= random.state >> 17;
    random.state ^= random.state << 5;
    return random.state;
}

fn float next_float(Random* random, float low, float high) @local {
    return low + (high - low) * (float)(next_bits(random) >> 8) / (float)(1u << 24);
}

fn Vec3 next_point(Random* random, float low, float high) @local {
    return { next_float(random, low, high), next_float(random, low, high), next_float(random, low, high) };
}

fn void order_pair(
    ulong[] keys,
    uint low,
    uint distance,
    uint stage,
) @local {
    uint high = low + distance;
    if (((low & stage) == 0) == (keys[low] < keys[high])) {
        ulong held = keys[low];
        keys[low] = keys[high];
        keys[high] = held;
    }
}

fn uint pair_low(uint pair, uint distance) @local => pair / distance * 2 * distance + pair % distance;

fn void run_sort_plan(
    ulong[] keys,
    SortStep[] plan,
    uint visible,
    uint[] list,
) @local {
    uint capacity = (uint)keys.len;
    uint length = math::min(capacity, shader::INSTANCE_SORT_BLOCK);
    foreach (step : plan) {
        if (step.mode & shader::INSTANCE_SORT_GLOBAL) {
            for (uint pair = 0; pair < capacity / 2; pair++) {
                order_pair(
                    keys:     keys,
                    low:      pair_low(pair, step.distance),
                    distance: step.distance,
                    stage:    step.stage,
                );
            }
            continue;
        }
        bool blocks = (step.mode & shader::INSTANCE_SORT_BLOCKS) != 0;
        for (uint base = 0; base < capacity; base += length) {
            if (blocks) {
                for (uint index = math::max(base, visible); index < base + length; index++) keys[index] = 0;
            }
            for (uint stage = blocks ? 2 : step.stage; stage <= step.stage; stage <<= 1) {
                for (uint distance = blocks ? stage / 2 : step.distance; distance > 0; distance >>= 1) {
                    for (uint pair = 0; pair < length / 2; pair++) {
                        order_pair(
                            keys:     keys,
                            low:      base + pair_low(pair, distance),
                            distance: distance,
                            stage:    stage,
                        );
                    }
                }
            }
        }
        if (step.mode & shader::INSTANCE_SORT_WRITE_LIST) {
            foreach (index, &entry : list) *entry = ~(uint)keys[index];
        }
    }
}

fn void test_sort_key_orders_far_first_then_storage_order() @test {
    assert(render::instance_sort_key(10, 3) > render::instance_sort_key(2, 1));
    assert(render::instance_sort_key(0.5f, 9) > render::instance_sort_key(-1, 3));
    assert(render::instance_sort_key(2, 4) > render::instance_sort_key(2, 9));
    assert(render::instance_sort_key(-1e30f, 0xFFFFFFFE) > 0);
}

fn void test_view_depth_axis_matches_view_space_depth() @test {
    Random random = { .state = SEED };
    for (uint pose = 0; pose < CAMERA_POSES; pose++) {
        Vec3 eye = next_point(&random, -20, 20);
        Vec3 forward = next_point(&random, -1, 1) + (Vec3){ 0.01f, 0, 0 };
        Mat4 view = matrix::look_at{float}(eye, eye + forward, { 0, 1, 0 });
        Vec4 axis = render::view_depth_axis(view);
        Vec3 point = next_point(&random, -50, 50);
        float expected = -view.apply({ point.x, point.y, point.z, 1 }).z;
        float actual = axis.xyz.dot(point) + axis.w;
        assert(math::abs(actual - expected) <= DEPTH_TOLERANCE * math::max(math::abs(expected), 1.0f));
    }
}

fn void test_sort_plan_sorts_partial_lists() @test {
    uint[8] counts = { 1, 2, 3, 1000, 1024, 1025, 3000, 20000 };
    Random random = { .state = SEED };
    foreach (count : counts) {
        uint[2] visibles = { count, count / 2 };
        foreach (visible : visibles) {
            @pool() {
                uint capacity = render::sort_capacity(count);
                ulong[] keys = alloc::new_array(tmem, ulong, capacity);
                bool[] survivor = alloc::new_array(tmem, bool, count);
                for (uint slot = 0; slot < capacity; slot++) {
                    if (slot >= visible) {
                        keys[slot] = (ulong)next_bits(&random) << 32 | next_bits(&random);
                        continue;
                    }
                    uint source = slot * SOURCE_STRIDE % count;
                    survivor[source] = true;
                    float depth = (float)(next_bits(&random) % DEPTH_LEVELS) - DEPTH_LEVELS / 2;
                    keys[slot] = render::instance_sort_key(depth, source);
                }
                uint[] list = alloc::new_array(tmem, uint, visible);
                run_sort_plan(
                    keys:    keys,
                    plan:    render::sort_plan(tmem, capacity),
                    visible: visible,
                    list:    list,
                );

                for (uint index = 0; index + 1 < visible; index++) assert(keys[index] > keys[index + 1]);
                foreach (key : keys[visible..]) assert(key == 0);
                foreach (index, source : list) {
                    assert(source == ~(uint)keys[index]);
                    assert(source < count && survivor[source]);
                    survivor[source] = false;
                }
            };
        }
    }
}

fn void test_sort_plan_dispatch_counts() @test {
    uint[4] capacities = { 1024, 8192, 16384, 131072 };
    usz[4] lengths = { 1, 10, 15, 36 };
    @pool() {
        foreach (index, capacity : capacities) {
            SortStep[] plan = render::sort_plan(tmem, capacity);
            assert(plan.len == lengths[index]);
            foreach (step_index, step : plan) {
                assert(((step.mode & shader::INSTANCE_SORT_WRITE_LIST) != 0) == (step_index == plan.len - 1));
            }
        }
        uint largest = render::sort_capacity(render::MAX_SORTED_INSTANCES);
        foreach (step : render::sort_plan(tmem, largest)) {
            uint groups = render::sort_groups(step, largest);
            assert(groups <= CORE_WORKGROUP_LIMIT);
            uint covered = step.mode & shader::INSTANCE_SORT_GLOBAL
              ? groups * shader::INSTANCE_SORT_GROUP_SIZE * 2
              : groups * shader::INSTANCE_SORT_BLOCK;
            assert(covered == largest);
        }
    };
    uint cull_groups = (render::MAX_SORTED_INSTANCES + shader::INSTANCE_CULL_GROUP_SIZE - 1)
      / shader::INSTANCE_CULL_GROUP_SIZE;
    assert(cull_groups <= CORE_WORKGROUP_LIMIT);
}

fn void test_sorted_placement_is_all_or_nothing() @test {
    usz list_bytes = render::sorted_list_bytes(PLACED_INSTANCES);
    usz key_bytes = (usz)render::sort_capacity(PLACED_INSTANCES) * ulong::size;
    render::CullArena arena = {
        .capacity = render::CULL_COUNTER_BYTES + list_bytes + key_bytes,
        .head     = render::CULL_COUNTER_BYTES,
    };
    usz list_offset = render::arena_place_sorted(&arena, PLACED_INSTANCES)!!;
    usz keys_offset = list_offset + list_bytes;
    assert(keys_offset % ulong::size == 0);
    assert(keys_offset + key_bytes == arena.capacity);

    usz head_before = arena.head;
    if (catch excuse = render::arena_place_sorted(&arena, PLACED_INSTANCES)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(arena.head == head_before);

    render::CullArena roomy = { .capacity = ROOMY_ARENA_BYTES, .head = render::CULL_COUNTER_BYTES };
    if (catch excuse = render::arena_place_sorted(&roomy, render::MAX_SORTED_INSTANCES + 1)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(roomy.head == render::CULL_COUNTER_BYTES);
    render::arena_place_sorted(&roomy, render::MAX_SORTED_INSTANCES)!!;
}

fn void test_only_blended_batch_ranges_sort() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    MaterialCommon blended = material::MATERIAL_COMMON_DEFAULT;
    blended.alpha_mode = AlphaMode.BLEND;
    MaterialCommon masked = material::MATERIAL_COMMON_DEFAULT;
    masked.alpha_mode = AlphaMode.MASK;
    MaterialRes[3] materials = {
        { .asset = assets.add_material(material::basic())!! },
        { .asset = assets.add_material(material::basic({}, masked))!! },
        { .asset = assets.add_material(material::basic({}, blended))!! },
    };
    InstancedMesh batch;
    MeshCandidate[4] candidates = {
        { .batch = &batch },
        { .batch = &batch },
        { .batch = &batch },
        {},
    };
    DrawItem[4] items = {
        { .candidate = &candidates[0], .material = &materials[0] },
        { .candidate = &candidates[1], .material = &materials[1] },
        { .candidate = &candidates[2], .material = &materials[2] },
        { .candidate = &candidates[3], .material = &materials[2] },
    };
    DrawItem[][2] groups = { items[:2], items[2..] };
    Frustum frustum;
    Vec4 axis = { 0, 0, -1, 3 };
    @pool() {
        CullItem[] culls = render::batch_cull_items(
            assets:     &assets,
            groups:     groups[..],
            frustum:    &frustum,
            depth_axis: axis,
        );
        assert(culls.len == 3);
        assert(!culls[0].sorted && !culls[1].sorted && culls[2].sorted);
        assert(culls[2].depth_axis == axis && culls[2].range == &items[2].range);
    };
}
