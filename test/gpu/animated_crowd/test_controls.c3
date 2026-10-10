module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import std::math;
import std::math::quaternion;

struct CrowdNativeOutput @private {
    RenderTargetId target;
    ViewId view;
    CrowdNativeProbe probe;
    CrowdNativeImages actual;
    CrowdNativeImages expected;
}

fn void? create_crowd_native_output(Fixture* fixture, CrowdNativeOutput* output) @private {
    output.target = render::create_render_target(
        &fixture.renderer,
        render::render_target_desc(CROWD_NATIVE_WIDTH, CROWD_NATIVE_HEIGHT, PixelFormat.RGBA32_FLOAT),
    )!;
    output.view = render::create_view(&fixture.renderer, render::texture_view_desc(output.target))!;
    create_crowd_native_probe(fixture, &output.probe)!;
    output.actual = create_crowd_native_images(fixture.allocator);
    output.expected = create_crowd_native_images(fixture.allocator);
}

fn void destroy_crowd_native_output(Fixture* fixture, CrowdNativeOutput* output) @private {
    destroy_crowd_native_images(fixture.allocator, &output.expected);
    destroy_crowd_native_images(fixture.allocator, &output.actual);
    destroy_crowd_native_probe(&fixture.renderer, &output.probe);
}

fn void? compare_crowd_native_paths(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeOutput* output,
    bool standard = false,
    bool tinted = true,
) @private {
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    for (uint path = 0; path < 3; path++) {
        ViewDesc desc = render::texture_view_desc(output.target);
        desc.shading = path == 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        desc.depth_prepass = path == 1 || (!standard && path == 2);
        desc.post.motion_blur = true;
        render::configure_view(&fixture.renderer, output.view, desc)!;
        capture_crowd_native(
            fixture: fixture,
            pair: pair,
            probe: &output.probe,
            output: output.target,
            view: output.view,
            crowd_visible: true,
            images: &output.actual,
        )!;
        uint passes = desc.depth_prepass ? 2 : 1;
        assert(output.actual.stats.instances_tested == passes * crowd.parts.len * crowd.count);
        assert(output.actual.stats.instances_visible == passes * crowd.parts.len * crowd.count);
        capture_crowd_native(
            fixture: fixture,
            pair: pair,
            probe: &output.probe,
            output: output.target,
            view: output.view,
            crowd_visible: false,
            images: &output.expected,
        )!;
        check_crowd_native_parity(&output.actual, &output.expected, tinted);
        if (standard && path == 2) {
            assert(output.actual.has_normal && output.expected.has_normal);
            check_crowd_native_image(output.actual.normal, output.expected.normal, CROWD_NATIVE_COLOR_TOLERANCE);
            check_crowd_native_image(output.expected.normal, output.actual.normal, CROWD_NATIVE_COLOR_TOLERANCE);
            uint normal_coverage;
            foreach (index, depth : output.actual.depth) {
                if (depth.x > 0 && output.actual.normal[index].w > 0.5f) normal_coverage++;
            }
            assert(normal_coverage > 0, "Standard geometry did not write the G-buffer normal attachment");
        }
    }
    check_crowd_native_validation(&fixture.renderer);
}

fn Track crowd_native_track(
    Allocator allocator,
    uint target,
    TargetPath path,
    float[] values,
) @private {
    Track track = {
        .target = target,
        .path = path,
        .interpolation = Interpolation.LINEAR,
        .times = alloc::new_array(allocator, float, 2),
        .values = alloc::clone_slice(allocator, values),
    };
    track.times[1] = 1;
    return track;
}

fn ClipId? add_crowd_native_controls_clip(AssetStore* assets) @private {
    Allocator allocator = assets.allocator;
    AnimationClip clip = {
        .name = "native_controls".copy(allocator),
        .duration = 1,
        .tracks = alloc::new_array(allocator, Track, 4),
        .targets = alloc::new_array(allocator, uint, 3),
        .events = alloc::new_array(allocator, ClipEvent, 2),
    };
    defer catch asset::free_clip(allocator, &clip);
    uint[3] targets = {
        animated_crowd_fixtures::PARTS_RIGID_NODE,
        animated_crowd_fixtures::PARTS_MORPH_B,
        animated_crowd_fixtures::PARTS_JOINT_ROOT,
    };
    clip.targets[..] = targets[..];
    Quat rigid = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.9f);
    Quat yaw = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.5f);
    float[8] rigid_values = { 0, 0, 0, 1, rigid.v.x, rigid.v.y, rigid.v.z, rigid.v.w };
    float[2] morph_values = { 0.75f, 0.1f };
    float[6] root_values = { 2, 0, 0, 4, 0, 0.5f };
    float[8] yaw_values = { 0, 0, 0, 1, yaw.v.x, yaw.v.y, yaw.v.z, yaw.v.w };
    clip.tracks[0] = crowd_native_track(
        allocator: allocator,
        target: 0,
        path: TargetPath.ROTATION,
        values: rigid_values[..],
    );
    clip.tracks[1] = crowd_native_track(
        allocator: allocator,
        target: 1,
        path: TargetPath.MORPH_WEIGHTS,
        values: morph_values[..],
    );
    clip.tracks[2] = crowd_native_track(
        allocator: allocator,
        target: 2,
        path: TargetPath.TRANSLATION,
        values: root_values[..],
    );
    clip.tracks[3] = crowd_native_track(
        allocator: allocator,
        target: 2,
        path: TargetPath.ROTATION,
        values: yaw_values[..],
    );
    ClipEvent[2] events = { { .time = 0.2f, .id = 20 }, { .time = 0.7f, .id = 70 } };
    clip.events[..] = events[..];
    return assets.add_clip_owned(&clip);
}

fn void crowd_native_action_controls(Action* action, float time, float weight = 1) @private {
    action.time = time;
    action.speed = 0;
    action.weight = weight;
    action.loop = false;
}

fn void? crowd_native_play_both(
    Fixture* fixture,
    CrowdNativePair* pair,
    uint source,
    ClipId clip,
    PlayDesc desc,
    float time,
    float weight = 1,
) @private {
    CrowdPlayer player = crowd_native_player(pair, source)!;
    AnimationActionId crowd_action = player.play(&fixture.assets, clip, desc)!;
    crowd_native_action_controls(player.action(crowd_action), time, weight);
    Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
    AnimationActionId ordinary_action = animator.play(&fixture.assets, clip, desc)!;
    crowd_native_action_controls(animator.action(ordinary_action), time, weight);
}

fn void check_crowd_native_affines(CrowdNativePair* pair) @private {
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        ModelInstance* ordinary = pair.scene.get(pair.ordinary[source], ModelInstance);
        foreach (index, part : crowd.parts) {
            if (part.skinned) continue;
            Mat4 actual = pair.crowd.world.mul(crowd.part_transform(source, (uint)index));
            Mat4 expected = ordinary.present_node(part.template_node).world;
            foreach (point : (Vec3[4]){ {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }) {
                assert((maths::transform_point(actual, point) - maths::transform_point(expected, point)).length()
                  <= CROWD_NATIVE_CORNER_TOLERANCE);
            }
        }
    }
    Mat4 rigid = crowd.part_transform(2, 1);
    Vec3 axis_x = { rigid.m00, rigid.m10, rigid.m20 };
    Vec3 axis_y = { rigid.m01, rigid.m11, rigid.m21 };
    assert(math::abs(axis_x.dot(axis_y)) > CROWD_NATIVE_CORNER_TOLERANCE, "Rigid fixture did not create affine shear");
    assert(rigid.determinant() < 0);
}

fn void? use_crowd_native_standard_materials(Fixture* fixture, CrowdNativePair* pair) @private {
    ModelTemplate* template = &fixture.assets.model(pair.model).data;
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.metallic = 0;
    params.roughness = 0.7f;
    params.emissive = { 0.2f, 0.2f, 0.2f };
    foreach (mesh : template.meshes) {
        fixture.assets.material(mesh.material).data = material::standard(params);
        fixture.assets.mark_material_dirty(mesh.material);
    }
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        params.base_color = CROWD_NATIVE_TINTS[source];
        ModelInstance* instance = pair.scene.get(pair.ordinary[source], ModelInstance);
        foreach (node : instance.mesh_nodes) {
            Mesh* mesh = pair.scene.get(instance.present_node(node), Mesh);
            fixture.assets.material(mesh.material).data = material::standard(params);
            fixture.assets.mark_material_dirty(mesh.material);
        }
    }
    Node* sun = pair.scene.add_light(light::directional({ 1, 1, 1 }, 2, false))!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0, -0.3f, -1 }.normalize(), { 0, 1, 0 });
}

fn void test_crowd_native_independent_controls_and_affine_shear_match_standard_deferred() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    ClipId controls = add_crowd_native_controls_clip(&fixture.assets)!!;
    Transform[CROWD_NATIVE_INSTANCES] placements;
    foreach (source, &placement : placements) {
        *placement = maths::TRANSFORM_IDENTITY;
        placement.position.x = ((float)source - 1) * 11;
        placement.scale = { source == 2 ? -0.6f : 0.6f, 0.8f, 0.5f };
        placement.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.1f * (float)source);
    }
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: parts.mixed,
        clip: parts.posing,
        bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        placements: placements[..],
    )!!;
    defer scene::destroy_scene(&pair.scene);
    use_crowd_native_standard_materials(&fixture, &pair)!!;
    String[2] names = { "rigid_mesh", "morph_b" };
    JointMask mask = anim::create_joint_mask(
        allocator: mem,
        template: &fixture.assets.model(pair.model).data,
        names: names[..],
    )!!;
    defer anim::destroy_joint_mask(&mask);
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        float phase = 0.2f + 0.25f * (float)source;
        crowd_native_action_controls(player.base_action()!!, phase, 0.6f);
        crowd_native_action_controls(animator.action(pair.ordinary_base[source]), phase, 0.6f);
        crowd_native_play_both(
            fixture: &fixture,
            pair: &pair,
            source: source,
            clip: controls,
            desc: { .layer = 1, .mask = &mask },
            time: 0.3f + 0.25f * (float)source,
            weight: 0.5f,
        )!!;
    }
    mask.nodes[..] = false;
    crowd_native_play_both(
        fixture: &fixture,
        pair: &pair,
        source: 0,
        clip: parts.missing_weights,
        desc: {},
        time: 0.8f,
        weight: 0.4f,
    )!!;
    crowd_native_play_both(
        fixture: &fixture,
        pair: &pair,
        source: 1,
        clip: parts.posing,
        desc: { .layer = 2, .additive = true },
        time: 0.7f,
        weight: 0.5f,
    )!!;
    CrowdPlayer space_player = crowd_native_player(&pair, 2)!!;
    Animator* space_animator = pair.scene.get(pair.ordinary[2], Animator);
    space_player.stop(pair.crowd_base[2])!!;
    space_animator.stop(pair.ordinary_base[2])!!;
    ClipId[2] clips = { parts.posing, parts.missing_weights };
    float[2] positions = { 0, 1 };
    BlendSpace1D* crowd_space = space_player.add_blend_space(
        assets: &fixture.assets,
        clips: clips[..],
        positions: positions[..],
        desc: {},
    )!!;
    BlendSpace1D* ordinary_space = space_animator.add_blend_space(
        assets: &fixture.assets,
        clips: clips[..],
        positions: positions[..],
        desc: {},
    )!!;
    crowd_space.parameter = ordinary_space.parameter = 0.65f;
    crowd_space.phase = ordinary_space.phase = 0.45;
    crowd_space.speed = ordinary_space.speed = 0;
    CrowdPlayer fading_player = crowd_native_player(&pair, 0)!!;
    Animator* fading_animator = pair.scene.get(pair.ordinary[0], Animator);
    AnimationActionId incoming = fading_player.play(&fixture.assets, parts.posing, { .fade_in = 0.5f })!!;
    AnimationActionId ordinary_incoming = fading_animator.play(&fixture.assets, parts.posing, { .fade_in = 0.5f })!!;
    crowd_native_action_controls(fading_player.action(incoming), 0.9f, 0);
    crowd_native_action_controls(fading_animator.action(ordinary_incoming), 0.9f, 0);
    fading_player.cross_fade(pair.crowd_base[0], incoming, 0.5f)!!;
    fading_animator.cross_fade(pair.ordinary_base[0], ordinary_incoming, 0.5f)!!;
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    for (uint step = 0; step < 3; step++) {
        crowd_native_update(&fixture, &pair, step == 0 ? 0 : 0.2f);
        check_crowd_native_affines(&pair);
        compare_crowd_native_paths(
            fixture: &fixture,
            pair: &pair,
            output: &output,
            standard: true,
            tinted: false,
        )!!;
    }
}
