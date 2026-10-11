module c3d::render::acceptance;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import std::math;

const uint AUTHORING_NATIVE_FRAMES @private = 1200;
const float AUTHORING_NATIVE_DT @private = 1.0f / 60;
const Vec2[9] AUTHORING_NATIVE_POINTS @private = {
    { -1, -1 }, { 0, -1 }, { 1, -1 },
    { -1, 0 }, { 0, 0 }, { 1, 0 },
    { -1, 1 }, { 0, 1 }, { 1, 1 },
};
const BlendTriangle[8] AUTHORING_NATIVE_TRIANGLES @private = {
    { .indices = { 0, 1, 3 } }, { .indices = { 1, 4, 3 } },
    { .indices = { 1, 2, 4 } }, { .indices = { 2, 5, 4 } },
    { .indices = { 3, 4, 6 } }, { .indices = { 4, 7, 6 } },
    { .indices = { 4, 5, 7 } }, { .indices = { 5, 8, 7 } },
};
const String[9] AUTHORING_NATIVE_CLIPS @private = {
    "Jog_Bwd_L_Loop", "Jog_Bwd_Loop", "Jog_Bwd_R_Loop",
    "Jog_Left_Loop", "Idle_Loop", "Jog_Right_Loop",
    "Jog_Fwd_L_Loop", "Jog_Fwd_Loop", "Jog_Fwd_R_Loop",
};
const Vec2[10] AUTHORING_NATIVE_PARAMETERS @private = {
    { -1, -1 }, { 0, 0 }, { 0.25f, 0.25f }, { -0.4f, 0.7f }, { 1, 0.2f },
    { 2, 0.2f }, { 0, -2 }, { 0.75f, -0.2f }, { 0.1f, 0.8f }, { 1, 1 },
};

struct AuthoringNativeControls @private {
    BlendSpace2D*[CROWD_NATIVE_INSTANCES] ordinary;
    BlendSpace2D*[CROWD_NATIVE_INSTANCES] crowd;
}

fn uint authoring_native_node(ModelTemplate* template, String name) @private {
    foreach (index, node : template.nodes) if (node.name == name) return (uint)index;
    unreachable();
}

fn ClipId? authoring_native_scale_clip(Fixture* fixture, ModelId model_id) @private {
    ModelTemplate* template = &fixture.assets.model(model_id).data;
    uint head = authoring_native_node(template, "DEF-head");
    Vec3 rest = template.nodes[head].local.scale;
    Allocator allocator = fixture.assets.allocator;
    AnimationClip clip = {
        .duration = 2,
        .tracks = alloc::new_array(allocator, Track, 1),
        .targets = alloc::new_array(allocator, uint, 1),
    };
    defer catch asset::free_clip(allocator, &clip);
    clip.targets[0] = head;
    clip.tracks[0] = {
        .path = TargetPath.SCALE,
        .interpolation = Interpolation.LINEAR,
        .times = alloc::new_array(allocator, float, 3),
        .values = alloc::new_array(allocator, float, 9),
    };
    float[3] times = { 0, 1, 2 };
    float[9] values = {
        rest.x, rest.y, rest.z, rest.x * 1.12f, rest.y * 1.12f, rest.z * 1.12f, rest.x, rest.y, rest.z,
    };
    clip.tracks[0].times[..] = times[..];
    clip.tracks[0].values[..] = values[..];
    return fixture.assets.add_clip_owned(&clip, "authoring_native/head_scale");
}

fn void? configure_authoring_native(
    Fixture* fixture,
    CrowdNativePair* pair,
    AuthoringNativeControls* controls,
    bool morph,
) @private {
    crowd_native_stop_all(pair)!;
    ModelTemplate* template = &fixture.assets.model(pair.model).data;
    ClipId[9] clips;
    foreach (index, name : AUTHORING_NATIVE_CLIPS) {
        clips[index] = morph ? template.clips[0] : crowd_native_clip_named(fixture, pair.model, name)!;
    }
    String[1] names = { morph ? template.nodes[template.meshes[0].node].name : "DEF-spine.001" };
    float[1] mask_weights = { morph ? 0.5f : 0.8f };
    uint[1] depths = { morph ? 0u : 2u };
    WeightedJointMask mask = anim::create_feathered_joint_mask(
        allocator: mem,
        assets: &fixture.assets,
        model: pair.model,
        names: names[..],
        weights: mask_weights[..],
        depths: depths[..],
    )!;
    defer anim::destroy_weighted_joint_mask(&mask);
    ClipId overlay = morph ? template.clips[0] : crowd_native_clip_named(fixture, pair.model, "Pistol_Idle_Loop")!;
    ClipId scale = morph ? (ClipId){} : authoring_native_scale_clip(fixture, pair.model)!;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        CrowdPlayer player = crowd_native_player(pair, source)!;
        controls.ordinary[source] = animator.add_blend_space_2d(
            assets: &fixture.assets,
            clips: clips[..],
            coordinates: AUTHORING_NATIVE_POINTS[..],
            triangles: AUTHORING_NATIVE_TRIANGLES[..],
        )!;
        controls.crowd[source] = player.add_blend_space_2d(
            assets: &fixture.assets,
            clips: clips[..],
            coordinates: AUTHORING_NATIVE_POINTS[..],
            triangles: AUTHORING_NATIVE_TRIANGLES[..],
        )!;
        PlayDesc desc = { .layer = 1, .weighted_mask = &mask };
        AnimationActionId ordinary = animator.play(&fixture.assets, overlay, desc)!;
        AnimationActionId crowded = player.play(&fixture.assets, overlay, desc)!;
        foreach (action : (Action*[2]){ animator.action(ordinary), player.action(crowded) }) {
            action.weight = 0.6f;
            action.speed = -0.75f;
        }
        if (!morph) {
            desc = { .layer = 2, .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE };
            ordinary = animator.play(&fixture.assets, scale, desc)!;
            crowded = player.play(&fixture.assets, scale, desc)!;
            animator.action(ordinary).weight = 0.5f;
            player.action(crowded).weight = 0.5f;
        }
    }
}

fn void run_authoring_native_window(bool morph) @private {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model_id = load_crowd_native_cc0(
        fixture: &fixture,
        filename: morph ? CROWD_NATIVE_MORPH_CUBE : CROWD_NATIVE_QUATERNIUS,
        expected_hash: morph ? CROWD_NATIVE_MORPH_CUBE_SHA : CROWD_NATIVE_QUATERNIUS_SHA,
    )!!;
    crowd_native_flat_source_materials(&fixture, model_id);
    ClipId first = fixture.assets.model(model_id).data.clips[0];
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: &tracker,
        fixture: &fixture,
        pair: &pair,
        model: model_id,
        clip: first,
        bounds: { .min = { -2, -2, -2 }, .max = { 2, 3, 2 } },
        placements: placements[..],
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(morph ? 5.0f : 6.0f, 0.1f, 100);
    pair.camera.local.position = { 0, morph ? 0.0f : 1.0f, 12 };
    AuthoringNativeControls controls;
    configure_authoring_native(
        fixture: &fixture,
        pair: &pair,
        controls: &controls,
        morph: morph,
    )!!;
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    ViewDesc desc = render::texture_view_desc(output.target);
    desc.depth_prepass = true;
    desc.post.motion_blur = true;
    render::configure_view(&fixture.renderer, output.view, desc)!!;
    for (uint frame = 0; frame < AUTHORING_NATIVE_FRAMES; frame++) {
        uint interval = frame / 120;
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Vec2 parameter = AUTHORING_NATIVE_PARAMETERS[(interval + source) % (uint)AUTHORING_NATIVE_PARAMETERS.len];
            float speed = source == 1 ? -0.75f : (interval >= 5 ? -1.25f : 1.0f);
            bool playing = interval != 2 && interval != 7;
            float weight = interval == 3 ? 0 : (interval == 4 ? 0.25f : 1);
            foreach (space : (BlendSpace2D*[2]){ controls.ordinary[source], controls.crowd[source] }) {
                space.parameter = parameter;
                space.speed = speed;
                space.playing = playing;
                space.weight = weight;
            }
        }
        sz acquisitions = tracker.total_allocation_count();
        crowd_native_update(&fixture, &pair, AUTHORING_NATIVE_DT);
        assert(tracker.total_allocation_count() == acquisitions, "Representative update allocated owner storage");
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            assert(controls.ordinary[source].phase == controls.crowd[source].phase);
        }
        pair.crowd.visible = true;
        pair.references.visible = false;
        pair.scene.update_world();
        fixture.renderer.begin_frame({ .time = (double)frame * AUTHORING_NATIVE_DT, .delta = AUTHORING_NATIVE_DT })!!;
        fixture.renderer.render_view(&pair.scene, pair.camera, output.view)!!;
        fixture.renderer.finish_view(output.view)!!;
        fixture.renderer.end_frame()!!;
        if (frame == 0 || frame == 400 || frame == 800 || frame + 1 == AUTHORING_NATIVE_FRAMES) {
            capture_crowd_native(
                fixture: &fixture,
                pair: &pair,
                probe: &output.probe,
                output: output.target,
                view: output.view,
                crowd_visible: true,
                images: &output.actual,
            )!!;
            capture_crowd_native(
                fixture: &fixture,
                pair: &pair,
                probe: &output.probe,
                output: output.target,
                view: output.view,
                crowd_visible: false,
                images: &output.expected,
            )!!;
            check_crowd_native_parity(&output.actual, &output.expected);
        }
    }
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_animation_authoring_native_quaternius_nine_samples_weighted_upper_body_and_ratio_overlay() @test {
    run_authoring_native_window(false);
}

fn void test_animation_authoring_native_morph_cube_complete_weights_over_twenty_seconds() @test {
    run_authoring_native_window(true);
}
