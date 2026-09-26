module c3d::test::debug;

import c3d::anim::ik;
import c3d::debug;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import std::math;

const float TOLERANCE @local = 0.0001f;

fn uint corner_index(Vec3 position, float threshold) @local {
    return (position.x > threshold ? 1u : 0u) | (position.y > threshold ? 2u : 0u) | (position.z > threshold ? 4u : 0u);
}

fn void test_debug_aabb_emits_twelve_edges() @test {
    DebugDraw draw = debug::create_debug_draw(mem, 64);
    defer debug::destroy_debug_draw(&draw);

    draw.aabb({ .min = { 0, 0, 0 }, .max = { 1, 1, 1 } }, debug::COLOR_WHITE);

    assert(draw.vertices.len() == 24);
    uint[8] hits;
    foreach (vertex : draw.vertices.array_view()) hits[corner_index(vertex.position, 0.5f)]++;
    foreach (count : hits) assert(count == 3, "every corner joins three edges");
}

fn void test_debug_box_transforms_corners() @test {
    DebugDraw draw = debug::create_debug_draw(mem, 64);
    defer debug::destroy_debug_draw(&draw);
    Transform transform = {
        .position = { 1, 2, 3 },
        .rotation = quaternion::IDENTITY,
        .scale    = { 2, 2, 2 },
    };

    draw.box(transform.to_mat4(), { .min = { 0, 0, 0 }, .max = { 1, 1, 1 } }, debug::COLOR_WHITE);

    Vec3 minimum = { float::max, float::max, float::max };
    Vec3 maximum = { -float::max, -float::max, -float::max };
    foreach (vertex : draw.vertices.array_view()) {
        minimum = math::min(minimum, vertex.position);
        maximum = math::max(maximum, vertex.position);
    }
    assert((minimum - (Vec3){ 1, 2, 3 }).length() <= TOLERANCE);
    assert((maximum - (Vec3){ 3, 4, 5 }).length() <= TOLERANCE);
}

fn void test_debug_frustum_unprojects_reverse_z_corners() @test {
    DebugDraw draw = debug::create_debug_draw(mem, 64);
    defer debug::destroy_debug_draw(&draw);
    Mat4 projection = maths::orthographic_reverse_z(
        left:   -1,
        right:  1,
        bottom: -1,
        top:    1,
        near:   1,
        far:    10,
    );

    draw.frustum(projection.inverse()!!, debug::COLOR_WHITE);

    uint near_count;
    uint far_count;
    foreach (vertex : draw.vertices.array_view()) {
        assert(math::abs(math::abs(vertex.position.x) - 1) <= TOLERANCE);
        assert(math::abs(math::abs(vertex.position.y) - 1) <= TOLERANCE);
        if (math::abs(vertex.position.z + 1) <= TOLERANCE) near_count++;
        if (math::abs(vertex.position.z + 10) <= TOLERANCE) far_count++;
    }
    assert(near_count == 12 && far_count == 12);
}

fn void test_debug_line_capacity_truncates() @test {
    DebugDraw draw = debug::create_debug_draw(mem, 4);
    defer debug::destroy_debug_draw(&draw);

    draw.line({ 0, 0, 0 }, { 1, 0, 0 }, debug::COLOR_WHITE);
    draw.line({ 0, 0, 0 }, { 0, 1, 0 }, debug::COLOR_WHITE);
    draw.line({ 0, 0, 0 }, { 0, 0, 1 }, debug::COLOR_WHITE);

    assert(draw.vertices.len() == 4);
    draw.clear();
    assert(draw.vertices.len() == 0);
}

fn void test_debug_vertex_layout_matches_gpu() @test {
    assert(DebugVertex::size == DebugVertexGpu::size);
    assert($reflect(DebugVertex.position).offset == $reflect(DebugVertexGpu.x).offset);
    assert($reflect(DebugVertex.rgba).offset == $reflect(DebugVertexGpu.rgba).offset);
}

fn void test_debug_rgba_packs_red_low() @test {
    assert(debug::rgba(1, 0, 0) == 0xFF0000FF);
    assert(debug::rgba(0, 0, 1, 0.5f) == 0x80FF0000);
    assert(debug::rgba(2, -1, 0.5f, 3) == debug::rgba(1, 0, 0.5f, 1), "channels clamp");
}

fn void test_debug_ik_draws_chain_target_and_pole() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    Node* root = scene.add_node()!!;
    Node* middle = scene.add_node(root)!!;
    Node* end = scene.add_node(middle)!!;
    Node* target = scene.add_node()!!;
    Node* pole = scene.add_node()!!;
    middle.local.position = { 0, 1, 0 };
    end.local.position = { 0, 1, 0 };
    target.local.position = { 1, 1, 0 };
    pole.local.position = { 0, 1, 1 };
    IkChain chain = ik::ik_chain(
        root:   root,
        middle: middle,
        end:    end,
        target: target,
        pole:   pole,
    );
    scene.add(root, chain);
    scene.add(end, ik::look_at((&end)[:1], target, { 0, 0, -1 }));
    scene.update_world();
    DebugDraw draw = debug::create_debug_draw(mem, 256);
    defer debug::destroy_debug_draw(&draw);

    draw.ik(&scene, debug::COLOR_WHITE);

    assert(draw.vertices.len() == 2 * (2 + debug::DEBUG_CIRCLE_SEGMENTS + 1 + 1));
}
