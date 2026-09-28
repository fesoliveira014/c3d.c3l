module c3d::test::instance_cull;

import c3d;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const uint SEED @local = 0x2545f491;
const uint RANDOM_CASES @local = 1000;
const float HALF_DIAGONAL @local = 0.70710678f; // a unit half-diagonal once turned 45 degrees about y
const Vec3 BESIDE_RIGHT_PLANE @local = { 7.044f, 0, -10 }; // corners 0.23 outside the right plane, box corner 0.27 in
const gpu::GpuAddress RECORDS @local = (gpu::GpuAddress)0x10000;
const gpu::GpuAddress SKIN @local = (gpu::GpuAddress)0x20000;
const gpu::GpuAddress MORPH @local = (gpu::GpuAddress)0x30000;
const uint CROWD_JOINTS @local = 4;

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

fn Frustum infinite_frustum() @local {
    Mat4 projection = maths::perspective_reverse_z(fov_y: math::PI / 3, aspect: 1, near: 0.1f);
    return maths::frustum_from_view_proj(projection, infinite_far: true);
}

fn void test_instance_visible_is_tighter_than_the_world_aabb() @test {
    Frustum frustum = infinite_frustum();
    Random random = { .state = SEED };
    uint visible;
    for (uint index = 0; index < RANDOM_CASES; index++) {
        Vec3 corner = next_point(&random, -2, 1);
        Aabb local = { .min = corner, .max = corner + next_point(&random, 0.1f, 2) };
        Vec3 axis = next_point(&random, -1, 1) + (Vec3){ 0, 0.01f, 0 };
        Transform placement = {
            .position = next_point(&random, -20, 20),
            .rotation = quaternion::from_axis_angle{float}(axis.normalize(), next_float(&random, 0, 2 * math::PI)),
            .scale    = next_point(&random, 0.2f, 3),
        };
        Mat4 model = placement.to_mat4();
        if (!render::instance_visible(&frustum, local, model)) continue;
        visible++;
        assert(maths::frustum_intersects_aabb(&frustum, maths::aabb_transform(local, model)));
    }
    assert(visible > 0 && visible < RANDOM_CASES);

    Aabb slab = { .min = { -HALF_DIAGONAL, -0.5f, -HALF_DIAGONAL }, .max = { HALF_DIAGONAL, 0.5f, HALF_DIAGONAL } };
    Transform turned = {
        .position = BESIDE_RIGHT_PLANE,
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::PI / 4),
        .scale    = { 1, 1, 1 },
    };
    Mat4 model = turned.to_mat4();
    assert(!render::instance_visible(&frustum, slab, model));
    assert(maths::frustum_intersects_aabb(&frustum, maths::aabb_transform(slab, model)));
}

fn void test_cull_root_planes_pad_the_missing_far_plane() @test {
    Frustum frustum = infinite_frustum();
    assert(frustum.plane_count == 5);
    InstanceCullRoot root;
    render::write_cull_planes(&root, &frustum);
    for (uint index = 0; index < 5; index++) {
        Plane plane = frustum.planes[index];
        Vec4f written = root.planes[index];
        assert(written.x == plane.normal.x && written.y == plane.normal.y && written.z == plane.normal.z);
        assert(written.w == plane.d);
    }
    assert(root.planes[5] == (Vec4f){ 0, 0, 0, 1 });
}

fn void test_cull_arena_places_all_or_nothing() @test {
    usz args_block = 3 * render::CULL_ARGS_STRIDE;
    render::CullArena arena = {
        .capacity = render::CULL_COUNTER_BYTES + args_block + 100 * uint::size,
        .head     = render::CULL_COUNTER_BYTES,
    };
    assert(render::arena_place(&arena, args_block)!! == render::CULL_COUNTER_BYTES);
    usz first_list = render::arena_place(&arena, 60 * uint::size)!!;
    assert(first_list == render::CULL_COUNTER_BYTES + args_block);
    usz head_before = arena.head;
    if (catch excuse = render::arena_place(&arena, 60 * uint::size)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(arena.head == head_before);
    usz third_list = render::arena_place(&arena, 30 * uint::size)!!;
    assert(third_list == head_before);

    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    renderer.cull_arenas[1] = arena;
    renderer.cull_counter_cleared = true;
    renderer.cull_tested = 90;
    render::reset_instance_culling(renderer, 1);
    assert(renderer.cull_arenas[1].head == render::CULL_COUNTER_BYTES);
    assert(!renderer.cull_counter_cleared && renderer.cull_tested == 0);
}

fn void test_cull_range_addressing_keeps_parity_ranges() @test {
    render::CullArena arena = { .capacity = 1024, .head = render::CULL_COUNTER_BYTES };
    usz even_list = render::arena_place(&arena, 3 * uint::size)!!;
    usz odd_list = render::arena_place(&arena, 2 * uint::size)!!;
    assert(even_list + 3 * uint::size <= odd_list);

    InstancedMesh mesh;
    MeshCandidate batch = { .batch = &mesh };
    CullRange even = { .count = 3, .first = 0, .visible = (gpu::GpuAddress)even_list, .culled = true };
    CullRange odd = { .count = 2, .first = 3, .visible = (gpu::GpuAddress)odd_list, .culled = true };
    assert(render::instance_offset(&even) == 0 && render::instance_offset(&odd) == 0);
    render::BatchAddresses culled = render::batch_addresses(
        candidate: &batch,
        range:     &odd,
        skin:      (gpu::GpuAddress)0,
        morph:     (gpu::GpuAddress)0,
        records:   RECORDS,
    );
    assert(culled.instance_data == RECORDS && culled.instance_indices == odd.visible);

    even.culled = false;
    odd.culled = false;
    assert(render::instance_offset(&even) == 0 && render::instance_offset(&odd) == 3);
    render::BatchAddresses unculled = render::batch_addresses(
        candidate: &batch,
        range:     &odd,
        skin:      (gpu::GpuAddress)0,
        morph:     (gpu::GpuAddress)0,
        records:   RECORDS,
    );
    assert((ulong)unculled.instance_data == (ulong)RECORDS + 3 * InstanceGpu::size);
    assert(unculled.instance_indices == (gpu::GpuAddress)0);

    AnimatedCrowd crowd = { .joint_count = CROWD_JOINTS };
    MeshCandidate part = { .batch = &mesh, .crowd = &crowd };
    render::BatchAddresses crowd_unculled = render::batch_addresses(
        candidate: &part,
        range:     &odd,
        skin:      SKIN,
        morph:     MORPH,
        records:   RECORDS,
    );
    assert((ulong)crowd_unculled.skin == (ulong)SKIN + 3 * CROWD_JOINTS * Mat4f::size);
    assert((ulong)crowd_unculled.morph == (ulong)MORPH + 3 * MorphWeightsGpu::size);
    odd.culled = true;
    render::BatchAddresses crowd_culled = render::batch_addresses(
        candidate: &part,
        range:     &odd,
        skin:      SKIN,
        morph:     MORPH,
        records:   RECORDS,
    );
    assert(crowd_culled.skin == SKIN && crowd_culled.morph == MORPH && crowd_culled.instance_data == RECORDS);
}

fn void test_cull_bound_follows_the_batch_kind() @test {
    GpuGeometry geometry = { .bounds = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } } };
    InstancedMesh plain;
    MeshCandidate plain_batch = { .batch = &plain };
    Aabb plain_bound = render::cull_bound(&plain_batch, &geometry)!!;
    assert(plain_bound.min == geometry.bounds.min && plain_bound.max == geometry.bounds.max);

    InstancedMesh overridden = {
        .has_bounds_override = true,
        .local_bounds        = { .min = { -5, -5, -5 }, .max = { 5, 5, 5 } },
    };
    AnimatedCrowd crowd = { .pose_bounds = { .min = { -2, 0, -2 }, .max = { 2, 3, 2 } } };
    MeshCandidate crowd_part = { .batch = &overridden, .crowd = &crowd };
    Aabb crowd_bound = render::cull_bound(&crowd_part, &geometry)!!;
    assert(crowd_bound.min == crowd.pose_bounds.min && crowd_bound.max == crowd.pose_bounds.max);

    MeshCandidate overridden_batch = { .batch = &overridden };
    if (catch excuse = render::cull_bound(&overridden_batch, &geometry)) {
        assert(excuse == render::NO_INSTANCE_BOUND);
    } else {
        assert(false);
    }
}

fn void test_cull_readback_pairs_tested_and_visible() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    uint[4] counter @align(16) = { 40, 0, 0, 0 };
    renderer.cull_readbacks[0] = {
        .mapped  = { .bytes = ((char*)&counter)[:render::CULL_COUNTER_BYTES] },
        .tested  = 100,
        .pending = true,
    };
    render::pair_cull_stats(&renderer.cull_readbacks[0], &renderer.stats);
    assert(renderer.stats.instances_tested == 100 && renderer.stats.instances_visible == 40);
    assert(!renderer.cull_readbacks[0].pending);

    renderer.stats = {};
    render::read_cull_stats(renderer, 1)!!;
    assert(renderer.stats.instances_tested == 0 && renderer.stats.instances_visible == 0);
}
