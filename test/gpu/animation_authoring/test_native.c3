module c3d::render::acceptance;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::io;
import std::math;

const uint AUTHORING_NATIVE_FRAMES @private = 1200;
const float AUTHORING_NATIVE_DT @private = 1.0f / 60;
const float AUTHORING_NATIVE_POSITION_EPSILON @private = 1e-5f;
const float AUTHORING_NATIVE_ROTATION_EPSILON @private = 1e-4f;
const float AUTHORING_NATIVE_SCALE_EPSILON @private = 1e-5f;
const float AUTHORING_NATIVE_MORPH_EPSILON @private = 1e-6f;
const double AUTHORING_NATIVE_WEIGHT_EPSILON @private = 5e-6;
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
    Action*[CROWD_NATIVE_INSTANCES] ordinary_overlay;
    Action*[CROWD_NATIVE_INSTANCES] crowd_overlay;
    Action*[CROWD_NATIVE_INSTANCES] ordinary_scale;
    Action*[CROWD_NATIVE_INSTANCES] crowd_scale;
    double[CROWD_NATIVE_INSTANCES] expected_phase;
}

struct AuthoringNativeErrors @private {
    float position;
    float rotation;
    float scale;
    float morph;
    double weight;
    double phase;
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

fn double[9] authoring_native_expected_weights(Vec2 parameter) @private {
    double x = math::clamp((double)parameter.x, -1.0, 1.0);
    double y = math::clamp((double)parameter.y, -1.0, 1.0);
    uint column = x > 0 ? 1 : 0;
    uint row = y > 0 ? 1 : 0;
    uint base = row * 3 + column;
    double horizontal = x - ((double)column - 1);
    double vertical = y - ((double)row - 1);
    double[9] weights;
    if (horizontal + vertical <= 1) {
        weights[base] = 1 - horizontal - vertical;
        weights[base + 1] = horizontal;
        weights[base + 3] = vertical;
    } else {
        weights[base + 1] = 1 - vertical;
        weights[base + 4] = horizontal + vertical - 1;
        weights[base + 3] = 1 - horizontal;
    }
    return weights;
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
        controls.ordinary_overlay[source] = animator.action(ordinary);
        controls.crowd_overlay[source] = player.action(crowded);
        controls.ordinary_overlay[source].weight = 0.6f;
        controls.crowd_overlay[source].weight = 0.6f;
        controls.ordinary_overlay[source].speed = -0.75f;
        controls.crowd_overlay[source].speed = -0.75f;
        if (!morph) {
            desc = { .layer = 2, .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE };
            ordinary = animator.play(&fixture.assets, scale, desc)!;
            crowded = player.play(&fixture.assets, scale, desc)!;
            controls.ordinary_scale[source] = animator.action(ordinary);
            controls.crowd_scale[source] = player.action(crowded);
            controls.ordinary_scale[source].weight = 0.5f;
            controls.crowd_scale[source].weight = 0.5f;
        }
    }
}

fn double authoring_native_linear_component(Track* track, float time, uint component) @private {
    uint width = track.stride();
    uint key;
    while (key + 1 < (uint)track.times.len && track.times[key + 1] < time) key++;
    if (time <= track.times[0]) return track.values[component];
    if (key + 1 >= (uint)track.times.len) return track.values[(usz)key * width + component];
    double fraction = ((double)time - track.times[key]) / ((double)track.times[key + 1] - track.times[key]);
    return (1 - fraction) * track.values[(usz)key * width + component]
      + fraction * track.values[(usz)(key + 1) * width + component];
}

fn void check_authoring_native_pose(
    Fixture* fixture,
    CrowdNativePair* pair,
    AuthoringNativeControls* controls,
    AuthoringNativeErrors* errors,
    bool morph,
) @private {
    CrowdPlaybackState* playback = pair.scene.get(pair.crowd, AnimatedCrowd).playback;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        ModelInstance* reference = pair.scene.get(pair.ordinary[source], ModelInstance);
        Transform[] actual = playback.poses[(usz)source * playback.base_pose.len:playback.base_pose.len];
        foreach (uint node, pose : actual) {
            Transform expected = reference.present_node(node).local;
            errors.position = math::max(errors.position, pose.position.distance(expected.position));
            for (uint axis = 0; axis < 3; axis++) {
                errors.scale = math::max(errors.scale, math::abs(pose.scale[axis] - expected.scale[axis]));
            }
            Quat difference = pose.rotation.mul(expected.rotation.conjugate()).normalize();
            Vec3 axis = { difference.i, difference.j, difference.k };
            errors.rotation = math::max(errors.rotation, 2 * math::atan2(axis.length(), math::abs(difference.l)));
        }
        foreach (mesh, node : playback.mesh_nodes) {
            float[] actual_weights = playback.logical_weights[(usz)source * playback.mesh_nodes.len + mesh];
            float[] expected_weights = pair.scene.get(reference.present_node(node), Mesh).morph_weights;
            foreach (index, weight : actual_weights) {
                errors.morph = math::max(errors.morph, math::abs(weight - expected_weights[index]));
            }
        }
        if (morph) {
            AnimationClip* clip = &fixture.assets.clip(controls.ordinary_overlay[source].clip).data;
            assert(clip.tracks.len == 1 && clip.tracks[0].path == TargetPath.MORPH_WEIGHTS);
            assert(clip.tracks[0].interpolation == Interpolation.LINEAR && clip.tracks[0].stride() == 2);
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            Action* base = animator.action(controls.ordinary[source].actions[0]);
            float[] weights = playback.logical_weights[(usz)source * playback.mesh_nodes.len];
            foreach (uint component, weight : weights) {
                double base_sample = authoring_native_linear_component(&clip.tracks[0], base.time, component);
                double overlay_sample = authoring_native_linear_component(
                    &clip.tracks[0], controls.ordinary_overlay[source].time, component);
                double below = controls.ordinary[source].weight * base_sample
                  + (1 - controls.ordinary[source].weight) * playback.base_morph_weights[0][component];
                double expected = 0.7 * below + 0.3 * overlay_sample;
                assert(math::abs((double)weight - expected) <= AUTHORING_NATIVE_MORPH_EPSILON);
            }
        }
    }
    assert(errors.position <= AUTHORING_NATIVE_POSITION_EPSILON);
    assert(errors.rotation <= AUTHORING_NATIVE_ROTATION_EPSILON);
    assert(errors.scale <= AUTHORING_NATIVE_SCALE_EPSILON);
    assert(errors.morph <= AUTHORING_NATIVE_MORPH_EPSILON);
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
        tinted: false,
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
    AuthoringNativeErrors errors;
    uint native_captures;
    for (uint frame = 0; frame < AUTHORING_NATIVE_FRAMES; frame++) {
        uint interval = frame / 120;
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Vec2 parameter = AUTHORING_NATIVE_PARAMETERS[(interval + source) % (uint)AUTHORING_NATIVE_PARAMETERS.len];
            double[9] weights = authoring_native_expected_weights(parameter);
            float speed = source == 1 ? -0.75f : (interval >= 5 ? -1.25f : 1.0f);
            bool playing = interval != 2 && interval != 7;
            float weight = interval == 3 ? 0 : (interval == 4 ? 0.25f : 1);
            foreach (space : (BlendSpace2D*[2]){ controls.ordinary[source], controls.crowd[source] }) {
                space.parameter = parameter;
                space.speed = speed;
                space.playing = playing;
                space.weight = weight;
            }
            double duration;
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            foreach (sample, member_weight : weights) {
                ClipId clip = animator.action(controls.ordinary[source].actions[sample]).clip;
                duration += member_weight * fixture.assets.clip(clip).data.duration;
            }
            double travel = playing ? (double)AUTHORING_NATIVE_DT * speed / duration : 0;
            double start = controls.expected_phase[source];
            if (start == 0 && travel < 0) start = 1;
            controls.expected_phase[source] = start + travel - math::floor(start + travel);
        }
        sz acquisitions = tracker.total_allocation_count();
        crowd_native_update(&fixture, &pair, AUTHORING_NATIVE_DT);
        assert(tracker.total_allocation_count() == acquisitions, "Representative update allocated owner storage");
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            double[9] expected = authoring_native_expected_weights(controls.ordinary[source].parameter);
            foreach (sample, value : expected) {
                double actual = animator.action(controls.ordinary[source].actions[sample]).weight;
                errors.weight = math::max(errors.weight, math::abs(actual - value * controls.ordinary[source].weight));
            }
            double phase_error = math::abs(controls.ordinary[source].phase - controls.expected_phase[source]);
            errors.phase = math::max(errors.phase, math::min(phase_error, 1 - phase_error));
            assert(controls.ordinary[source].phase == controls.crowd[source].phase);
        }
        check_authoring_native_pose(
            fixture: &fixture,
            pair: &pair,
            controls: &controls,
            errors: &errors,
            morph: morph,
        );
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
            check_crowd_native_parity(&output.actual, &output.expected, false);
            native_captures++;
        }
    }
    assert(errors.weight <= AUTHORING_NATIVE_WEIGHT_EPSILON && errors.phase <= AUTHORING_NATIVE_WEIGHT_EPSILON);
    io::printfn(
        "animation authoring morph=%s frames=%s simulated_seconds=20 native_pairs=%s",
        morph,
        AUTHORING_NATIVE_FRAMES,
        native_captures,
    );
    io::printfn(
        "max position=%s rotation=%s scale=%s morph=%s weight=%s phase=%s retained_bytes=%s",
        errors.position,
        errors.rotation,
        errors.scale,
        errors.morph,
        errors.weight,
        errors.phase,
        tracker.allocated(),
    );
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_animation_authoring_native_quaternius_nine_samples_weighted_upper_body_and_ratio_overlay() @test {
    run_authoring_native_window(false);
}

fn void test_animation_authoring_native_morph_cube_complete_weights_over_twenty_seconds() @test {
    run_authoring_native_window(true);
}
