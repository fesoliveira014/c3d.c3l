module c3d::test::reflection_lights;

import c3d;
import c3d::light;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;

fn Frustum unit_box_frustum() @local {
    return {
        .planes = {
            { .normal = { 1, 0, 0 }, .d = 1 },
            { .normal = { -1, 0, 0 }, .d = 1 },
            { .normal = { 0, 1, 0 }, .d = 1 },
            { .normal = { 0, -1, 0 }, .d = 1 },
            { .normal = { 0, 0, 1 }, .d = 1 },
            { .normal = { 0, 0, -1 }, .d = 1 },
        },
        .plane_count = 6,
    };
}

fn void test_reflection_lights_keep_a_finite_light_outside_the_view_frustum() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* lamp = scene.add_light(light::point({ 1, 1, 1 }, 1, 2))!!;
    lamp.local.position = { 50, 0, 0 };
    scene.update_world();

    Frustum frustum = unit_box_frustum();
    LightCounts view_counts;
    LightCounts reflection_counts;
    @pool() {
        LightExtraction view = render::extract_lights(
            allocator: tmem,
            scene: &scene,
            frustum: &frustum,
            view_layers: 1,
            capacity: 4,
            counts: &view_counts,
            atmosphere: null,
            altitude: 0,
        );
        LightGpu[] reflected = render::extract_reflection_lights(
            allocator: tmem,
            scene: &scene,
            view_layers: 1,
            capacity: 4,
            counts: &reflection_counts,
            atmosphere: null,
            altitude: 0,
            origin: {},
        );
        assert(view.lights.len == 0 && view_counts.culled == 1);
        assert(reflected.len == 1 && reflection_counts.culled == 0);
        assert(reflected[0].position_range.x == 50 && reflected[0].position_range.w == 2);
    };
}

fn void test_reflection_lights_gate_on_camera_layers_and_keep_receiver_masks() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    Node* off_layer = scene.add_light(light::point({ 1, 1, 1 }, 1))!!;
    off_layer.layers = 2;
    Node* hidden = scene.add_light(light::point({ 1, 1, 1 }, 2))!!;
    hidden.visible = false;
    Light no_receivers = light::point({ 1, 1, 1 }, 3);
    no_receivers.layers = 0;
    scene.add_light(no_receivers)!!;
    Light selective = light::point({ 1, 1, 1 }, 4);
    selective.layers = 6;
    scene.add_light(selective)!!;
    scene.update_world();

    LightCounts counts;
    @pool() {
        LightGpu[] reflected = render::extract_reflection_lights(
            allocator: tmem,
            scene: &scene,
            view_layers: 1,
            capacity: 4,
            counts: &counts,
            atmosphere: null,
            altitude: 0,
            origin: {},
        );
        assert(reflected.len == 1 && counts.packed == 1 && counts.dropped == 0);
        assert(reflected[0].color_intensity.w == 4 && reflected[0].layers == 6);
    };
}

fn void test_reflection_lights_follow_budget_order_and_stop_at_capacity() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    scene.add_light(light::point({ 1, 1, 1 }, 1))!!;
    scene.add_light(light::point({ 1, 1, 1 }, 2))!!;
    scene.add_light(light::point({ 1, 1, 1 }, 3))!!;
    scene.update_world();

    LightCounts counts;
    @pool() {
        LightGpu[] reflected = render::extract_reflection_lights(
            allocator: tmem,
            scene: &scene,
            view_layers: 1,
            capacity: 2,
            counts: &counts,
            atmosphere: null,
            altitude: 0,
            origin: {},
        );
        assert(reflected.len == 2 && counts.dropped == 1);
        assert(reflected[0].color_intensity.w == 1 && reflected[1].color_intensity.w == 2);
    };
}

fn void test_reflection_lights_trace_every_shadowing_light() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    scene.add_light(light::directional({ 1, 1, 1 }, 1, shadow: true))!!;
    scene.add_light(light::directional({ 1, 1, 1 }, 2, shadow: false))!!;
    scene.update_world();

    LightCounts counts;
    @pool() {
        LightGpu[] reflected = render::extract_reflection_lights(
            allocator: tmem,
            scene: &scene,
            view_layers: 1,
            capacity: 2,
            counts: &counts,
            atmosphere: null,
            altitude: 0,
            origin: {},
        );
        assert(reflected.len == 2);
        assert((reflected[0].flags & shader::LIGHT_RT_SHADOW) != 0);
        assert((reflected[1].flags & shader::LIGHT_RT_SHADOW) == 0);
    };
}
