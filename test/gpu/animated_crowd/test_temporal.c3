module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import gpu;
import std::io;
import std::math;

const float CROWD_NATIVE_VELOCITY_TOLERANCE @private = 2e-3f;

fn void? record_crowd_native_temporal_view(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeOutput* output,
    bool crowd_visible,
) @private {
    pair.crowd.visible = crowd_visible;
    pair.references.visible = !crowd_visible;
    pair.scene.update_world();
    Renderer* renderer = &fixture.renderer;
    renderer.render_view(&pair.scene, pair.camera, output.view)!;
    ViewRecord* record = renderer.views.get(output.view);
    assert(record.velocity.format == gpu::Format.RGBA16_FLOAT);
    record_crowd_native_target(
        fixture: fixture,
        probe: &output.probe,
        target: &record.depth,
        mapped: output.probe.depth,
    )!;
    record_crowd_native_target(
        fixture: fixture,
        probe: &output.probe,
        target: &record.velocity,
        mapped: output.probe.velocity,
    )!;
    renderer.finish_view(output.view)!;
}

fn void? read_crowd_native_temporal(Fixture* fixture, CrowdNativeOutput* output) @private {
    gpu::invalidate_mapped_span(&fixture.renderer.device, output.probe.depth.span)!;
    gpu::invalidate_mapped_span(&fixture.renderer.device, output.probe.velocity.span)!;
    mem::copy(output.actual.depth.ptr, output.probe.depth.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
    mem::copy(output.actual.velocity.ptr, output.probe.velocity.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
    output.actual.velocity_format = gpu::Format.RGBA16_FLOAT;
}

fn void? crowd_native_temporal_frame(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeOutput* crowd,
    CrowdNativeOutput* ordinary,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    record_crowd_native_temporal_view(
        fixture: fixture,
        pair: pair,
        output: crowd,
        crowd_visible: true,
    )!;
    record_crowd_native_temporal_view(
        fixture: fixture,
        pair: pair,
        output: ordinary,
        crowd_visible: false,
    )!;
    assert(renderer.deformation.crowd_palettes.len() == 1, "Current source palette was uploaded more than once");
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    read_crowd_native_temporal(fixture, crowd)!;
    read_crowd_native_temporal(fixture, ordinary)!;
}

fn void check_crowd_native_temporal_flags(CrowdNativeImages* images, float rejection, bool still = true) @private {
    uint covered;
    foreach (index, depth : images.depth) {
        if (depth.x <= 0) continue;
        covered++;
        Vec4 velocity = images.velocity[index];
        assert(velocity.w == rejection, "Crowd source correspondence rejection differs");
        if (still) {
            assert(math::abs(velocity.x) < CROWD_NATIVE_STILL_TOLERANCE);
            assert(math::abs(velocity.y) < CROWD_NATIVE_STILL_TOLERANCE);
        }
    }
    assert(covered > 0);
}

fn void check_crowd_native_velocity(Vec4[] actual, Vec4[] expected) @private {
    for (int y = 1; y + 1 < (int)CROWD_NATIVE_HEIGHT; y++) {
        for (int x = 1; x + 1 < (int)CROWD_NATIVE_WIDTH; x++) {
            Vec4 pixel = actual[y * (int)CROWD_NATIVE_WIDTH + x];
            bool matched;
            for (int dy = -1; dy <= 1 && !matched; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    Vec4 delta = math::abs(pixel - expected[(y + dy) * (int)CROWD_NATIVE_WIDTH + x + dx]);
                    if (math::max(delta.x, delta.y) < CROWD_NATIVE_VELOCITY_TOLERANCE) matched = true;
                }
            }
            assert(matched, "Crowd velocity read another logical source's previous pose");
        }
    }
}

fn void? configure_crowd_native_temporal(Fixture* fixture, CrowdNativeOutput* output) @private {
    ViewDesc desc = render::texture_view_desc(output.target);
    desc.post.anti_aliasing = AntiAliasing.TAA;
    desc.post.motion_blur = true;
    return render::configure_view(&fixture.renderer, output.view, desc);
}

fn void test_crowd_native_rgba_history_equal_count_parity_swap_and_replacement() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: parts.mixed,
        clip: parts.posing,
        bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(24, 0.1f, 100);
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        float phase = 0.1f + 0.35f * (float)source;
        crowd_native_action_controls(player.base_action()!!, phase);
        crowd_native_action_controls(animator.action(pair.ordinary_base[source]), phase);
    }
    crowd_native_update(&fixture, &pair, 0);
    CrowdNativeOutput actual;
    create_crowd_native_output(&fixture, &actual)!!;
    defer destroy_crowd_native_output(&fixture, &actual);
    CrowdNativeOutput expected;
    create_crowd_native_output(&fixture, &expected)!!;
    defer destroy_crowd_native_output(&fixture, &expected);
    configure_crowd_native_temporal(&fixture, &actual)!!;
    configure_crowd_native_temporal(&fixture, &expected)!!;
    crowd_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 1);
    crowd_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0);
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    crowd.placements[0].scale.x = -crowd.placements[0].scale.x;
    crowd.placements[2].scale.x = -crowd.placements[2].scale.x;
    pair.ordinary[0].local.scale.x = -pair.ordinary[0].local.scale.x;
    pair.ordinary[2].local.scale.x = -pair.ordinary[2].local.scale.x;
    pair.scene.write_crowd_batches(crowd);
    crowd_native_update(&fixture, &pair, 0);
    assert(crowd.count == CROWD_NATIVE_INSTANCES && crowd.parts.len == animated_crowd_fixtures::PARTS_MESH_COUNT);
    crowd_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0, false);
    check_crowd_native_image(actual.actual.depth, expected.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(expected.actual.depth, actual.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_velocity(actual.actual.velocity, expected.actual.velocity);
    check_crowd_native_velocity(expected.actual.velocity, actual.actual.velocity);
    float largest_motion;
    foreach (index, depth : expected.actual.depth) {
        if (depth.x <= 0) continue;
        Vec4 velocity = expected.actual.velocity[index];
        largest_motion = math::max(largest_motion, math::max(math::abs(velocity.x), math::abs(velocity.y)));
    }
    assert(largest_motion > 10 * CROWD_NATIVE_VELOCITY_TOLERANCE);
    io::printfn("RGBA equal-count swap instances=%s parts=%s largest_expected_uv=%s", crowd.count, crowd.parts.len, largest_motion);
    crowd_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0);
    CrowdInstance[CROWD_NATIVE_INSTANCES] replacement;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        replacement[source] = {
            .placement = crowd.placements[source],
            .pose = { .clip = parts.posing, .time = player.base_action()!!.time, .speed = 0, .loop = false },
            .color = crowd.colors[source],
        };
    }
    model::set_crowd(
        assets: &fixture.assets,
        scene: &pair.scene,
        node: pair.crowd,
        instances: replacement[..],
    )!!;
    crowd_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 1);
    crowd_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0);
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_crowd_native_consumed_root_motion_events_and_shadow_pose_match_animator() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    ClipId motion = add_crowd_native_controls_clip(&fixture.assets)!!;
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: parts.mixed,
        clip: parts.posing,
        bounds: { .min = { -8, -4, -8 }, .max = { 16, 8, 8 } },
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(24, 0.1f, 100);
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    crowd_native_stop_all(&pair)!!;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        crowd.placements[source].scale = { 0.6f, 0.6f, 0.6f };
        pair.ordinary[source].local.scale = { 0.6f, 0.6f, 0.6f };
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        PlayDesc desc = { .root_motion = RootMotion.EXTRACT, .root_yaw = true };
        AnimationActionId action = player.play(&fixture.assets, motion, desc)!!;
        AnimationActionId reference = animator.play(&fixture.assets, motion, desc)!!;
        player.action(action).speed = animator.action(reference).speed = source == 2 ? -1 : 1;
        player.action(action).time = animator.action(reference).time = source == 2 ? 0.9f : 0;
    }
    pair.scene.write_crowd_batches(crowd);
    crowd_native_update(&fixture, &pair, 0);
    crowd_native_update(&fixture, &pair, 0.35f);
    uint expected_events;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        RootMotionDelta delta = crowd.playback.slots[source].root_motion;
        assert(delta.translation == animator.root_motion.translation && delta.rotation.v == animator.root_motion.rotation.v);
        assert(delta.translation.length() > 0);
        expected_events += animator.event_count;
        anim::apply_root_motion(pair.ordinary[source], animator.root_motion);
    }
    assert(expected_events > 0 && crowd.playback.event_count == expected_events);
    pair.scene.apply_crowd_root_motion(crowd);
    pair.scene.update_world();
    Light light = light::directional({ 1, 1, 1 }, 2);
    light.shadow.cascades = 1;
    light.shadow.max_distance = 100;
    Node* sun = pair.scene.add_light(light)!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0, -0.3f, -1 }.normalize(), { 0, 1, 0 });
    pair.scene.update_world();
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    compare_crowd_native_paths(
        fixture: &fixture,
        pair: &pair,
        output: &output,
        standard: false,
        tinted: true,
        shadow: true,
    )!!;
    io::printfn("Consumed root/event pose instances=%s events=%s shadow_layers=%s", crowd.count, expected_events, output.actual.stats.shadow_layers);
}
