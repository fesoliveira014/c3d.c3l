module c3d::test::probe_update;

import c3d;
import c3d::light;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import std::math;

const float UNIT_TOLERANCE @local = 1e-5f;
const float BALANCE_LIMIT @local = 0.02f;
const float SPREAD_FACTOR @local = 0.6f;
const uint ROTATION_CASES @local = 100;
const Vec3 ORIGIN @local = { 1, 2, 3 };

fn ProbeUpdateDesc update_desc(uint probes_per_frame) @local {
    ProbeUpdateDesc desc = light::PROBE_UPDATE_DEFAULT;
    desc.probes_per_frame = probes_per_frame;
    return desc;
}

fn ProbeFillState environment_filled() @local {
    ProbeFillIdentity identity = {
        .environment       = { .index = 1, .generation = 1 },
        .lighting_revision = 1,
        .intensity         = 1,
        .rotation          = quaternion::IDENTITY,
    };
    ProbeFillState state;
    render::plan_probe_fill(&state, ENVIRONMENT, &identity, 1);
    return state;
}

fn void test_spherical_fibonacci_is_balanced_and_spread() @test {
    uint[3] counts = { 32, 128, 256 };
    foreach (count : counts) {
        Vec3 sum;
        float smallest = (float)math::PI;
        for (uint first = 0; first < count; first++) {
            Vec3 direction = maths::spherical_fibonacci(first, count);
            assert(math::abs(direction.length() - 1) <= UNIT_TOLERANCE);
            sum += direction;
            for (uint second = first + 1; second < count; second++) {
                float cosine = math::clamp(direction.dot(maths::spherical_fibonacci(second, count)), -1.0f, 1.0f);
                smallest = math::min(smallest, math::acos(cosine));
            }
        }
        assert((sum / (float)count).length() < BALANCE_LIMIT);
        assert(smallest > SPREAD_FACTOR * math::sqrt(4 * (float)math::PI / (float)count));
    }
}

fn void test_random_rotation_is_unit_and_deterministic() @test {
    Quat previous;
    for (uint index = 1; index <= ROTATION_CASES; index++) {
        Vec3 uniform = { maths::halton(index, 2), maths::halton(index, 3), maths::halton(index, 5) };
        Quat rotation = maths::random_rotation(uniform);
        assert(math::abs(rotation.v.length() - 1) <= UNIT_TOLERANCE);
        assert(maths::random_rotation(uniform).v == rotation.v);
        if (index > 1) assert(!(rotation.v == previous.v));
        previous = rotation;
    }
}

fn void test_probe_window_covers_every_probe() @test {
    bool[4096] visited;
    uint cursor;
    for (uint window_index = 0; window_index < 8; window_index++) {
        ProbeWindow window = render::probe_update_window(cursor, 4096, 512);
        for (uint probe = window.first; probe < window.first + window.count; probe++) {
            assert(!visited[probe]);
            visited[probe] = true;
        }
        cursor = window.next;
    }
    assert(cursor == 0);
    foreach (seen : visited) assert(seen);

    uint[4] expected = { 30, 30, 30, 10 };
    cursor = 0;
    foreach (count : expected) {
        ProbeWindow window = render::probe_update_window(cursor, 100, 30);
        assert(window.count == count);
        cursor = window.next;
    }
    assert(cursor == 0);
    assert(render::probe_update_window(0, 100, 0).count == 100);
    assert(render::probe_update_window(0, 100, 200).count == 100);
    ProbeWindow rest = render::probe_update_window(40, 100, 0);
    assert(rest.first == 40 && rest.count == 60 && rest.next == 0);
}

fn void test_probe_volume_valid_checks_the_update() @test {
    ProbeVolume volume = light::probe_volume({ 1, 1, 1 }, { 2, 2, 2 });
    assert(light::probe_volume_valid(&volume));
    uint[2] bad_rays = { 16, 257 };
    foreach (rays : bad_rays) {
        ProbeVolume changed = volume;
        changed.update.rays_per_probe = rays;
        assert(!light::probe_volume_valid(&changed));
    }
    float[3] bad_hysteresis = { 1, -0.1f, float::nan };
    foreach (hysteresis : bad_hysteresis) {
        ProbeVolume changed = volume;
        changed.update.hysteresis = hysteresis;
        assert(!light::probe_volume_valid(&changed));
    }
    ProbeVolume odd_rays = volume;
    odd_rays.update.rays_per_probe = 100;
    assert(light::probe_volume_valid(&odd_rays));
    assert(volume.fill == ProbeFill.ENVIRONMENT);
}

fn void test_scene_plan_sweeps_then_blends() @test {
    ProbeFillState state;
    ProbeScenePlan plan = render::plan_probe_scene(&state, ORIGIN, 1, 100, update_desc(40));
    assert(plan.clear && plan.first == 0 && plan.count == 40 && plan.hysteresis == 0);
    assert(state.in_hit_set() && !state.in_view_set());

    plan = render::plan_probe_scene(&state, ORIGIN, 1, 100, update_desc(40));
    assert(!plan.clear && plan.first == 40 && plan.count == 40 && plan.hysteresis == 0);
    assert(!state.in_view_set());

    plan = render::plan_probe_scene(&state, ORIGIN, 1, 100, update_desc(40));
    assert(plan.first == 80 && plan.count == 20 && plan.hysteresis == 0);
    assert(state.in_view_set());

    plan = render::plan_probe_scene(&state, ORIGIN, 1, 100, update_desc(40));
    assert(!plan.clear && plan.first == 0 && plan.count == 40);
    assert(plan.hysteresis == light::PROBE_UPDATE_DEFAULT.hysteresis);
}

fn void test_scene_plan_restarts_only_on_a_jump() @test {
    ProbeFillState state;
    Vec3 origin = ORIGIN;
    render::plan_probe_scene(&state, origin, 1, 8, update_desc(0));
    for (uint step = 0; step < 10; step++) {
        origin.x += 0.1f;
        assert(!render::plan_probe_scene(&state, origin, 1, 8, update_desc(0)).clear);
    }

    origin.x += 0.6f;
    ProbeScenePlan jump = render::plan_probe_scene(&state, origin, 1, 8, update_desc(0));
    assert(jump.clear && jump.first == 0 && jump.hysteresis == 0);
    assert(state.traced_origin == origin);

    origin.z += 0.6f;
    assert(render::plan_probe_scene(&state, origin, 1, 8, update_desc(0)).clear);
}

fn void test_fill_switches_start_no_sweep() @test {
    ProbeFillState state = environment_filled();
    ProbeScenePlan plan = render::plan_probe_scene(&state, ORIGIN, 1, 8, update_desc(0));
    assert(!plan.clear && plan.hysteresis == light::PROBE_UPDATE_DEFAULT.hysteresis);
    assert(state.in_view_set() && !state.filled());

    ProbeFillIdentity identity = {
        .environment       = { .index = 1, .generation = 1 },
        .lighting_revision = 1,
        .intensity         = 1,
        .rotation          = quaternion::IDENTITY,
    };
    ProbeFillWork work = render::plan_probe_fill(&state, ENVIRONMENT, &identity, 1);
    assert(work.irradiance && work.visibility);
    assert(!state.scene_defined && !state.scene_swept && state.cursor == 0);

    plan = render::plan_probe_scene(&state, ORIGIN, 1, 8, update_desc(0));
    assert(!plan.clear && state.in_view_set());

    render::plan_probe_fill(&state, ENVIRONMENT, null, 1);
    assert(!state.in_view_set() && !state.in_hit_set());
}

fn void test_discard_restores_the_fill_state() @test {
    ProbeVolumeRes mirror;
    render::plan_probe_scene(&mirror.fill, ORIGIN, 1, 100, update_desc(40));
    mirror.frame_fill = mirror.fill;
    render::plan_probe_scene(&mirror.fill, ORIGIN, 1, 100, update_desc(40));
    mirror.fill_recorded = true;
    mirror.updated_frame = 7;

    render::Renderer renderer;
    renderer.probe_volumes[0] = mirror;
    render::discard_probe_fills(&renderer);
    ProbeVolumeRes* restored = &renderer.probe_volumes[0];
    assert(restored.fill.cursor == 40 && !restored.fill.scene_swept);
    assert(restored.updated_frame == 0 && !restored.fill_recorded);
}

fn void test_hit_set_ignores_layers_and_keeps_unswept_volumes() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    Node* unswept = scene.add_node(name: "unswept")!!;
    Node* swept = scene.add_node(name: "swept")!!;
    Node* hidden = scene.add_node(name: "hidden")!!;
    Node* no_layers = scene.add_node(name: "no_layers")!!;
    unswept.layers = 2;
    hidden.visible = false;
    no_layers.layers = 0;
    scene.add(unswept, light::probe_volume({ 0.5f, 0.5f, 0.5f }, { 2, 2, 2 }, SCENE));
    scene.add(swept, light::probe_volume({ 2, 2, 2 }, { 2, 2, 2 }, SCENE));
    scene.add(hidden, light::probe_volume({ 1, 1, 1 }, { 2, 2, 2 }, SCENE));
    scene.add(no_layers, light::probe_volume({ 1.5f, 1.5f, 1.5f }, { 2, 2, 2 }, SCENE));
    scene.update_world();

    ProbeVolumeRes[shader::PROBE_VOLUME_CAPACITY] mirrors;
    Node*[4] nodes = { unswept, swept, hidden, no_layers };
    foreach (index, node : nodes) {
        mirrors[index] = { .scene = scene.identity, .entity = node.id };
        render::plan_probe_scene(&mirrors[index].fill, ORIGIN, 1, 8, update_desc(node == unswept ? 4 : 0));
    }
    mirrors[4] = { .scene = scene.identity + 1, .entity = swept.id };
    render::plan_probe_scene(&mirrors[4].fill, ORIGIN, 1, 8, update_desc(0));

    usz[shader::PROBE_VOLUME_CAPACITY] order;
    usz hits = render::order_hit_probe_volumes(&mirrors, &scene, &order);
    assert(hits == 3 && order[0] == 0 && order[1] == 3 && order[2] == 1);
    usz views = render::order_view_probe_volumes(&mirrors, &scene, 1, &order);
    assert(views == 1 && order[0] == 1);
    views = render::order_view_probe_volumes(&mirrors, &scene, 2, &order);
    assert(views == 1 && order[0] == 0);
    assert(!mirrors[0].fill.in_view_set() && mirrors[0].fill.in_hit_set());
}
