module c3d::render::acceptance;

import c3d;
import c3d::anim @public;
import c3d::camera;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import std::math;

const uint MOTION_NATIVE_FRAMES @private = 1200;
const double MOTION_NATIVE_POSITION_EPSILON @private = 1e-5;
const double MOTION_NATIVE_ROTATION_EPSILON @private = 1e-4;
const double MOTION_NATIVE_SCALE_EPSILON @private = 1e-5;
const double MOTION_NATIVE_MORPH_EPSILON @private = 1e-6;
const double MOTION_NATIVE_DRIFT_EPSILON @private = 0.0005;
const float MOTION_NATIVE_TRANSITION_SECONDS @private = 1;

fn void configure_motion_native_pair(Fixture* fixture, CrowdNativePair* pair) @private {
    AnimatedCrowd* original = pair.scene.get(pair.crowd, AnimatedCrowd);
    CrowdInstance[CROWD_NATIVE_INSTANCES] instances;
    foreach (index, &instance : instances) {
        *instance = {
            .placement = original.placements[index],
            .pose = original.seeds[index],
            .color = original.colors[index],
        };
    }
    foreach (part : original.parts) pair.scene.remove(pair.scene.node(part.batch));
    pair.scene.remove_component(pair.crowd, AnimatedCrowd);
    model::attach_crowd(
        assets: &fixture.assets,
        scene: &pair.scene,
        node: pair.crowd,
        model: pair.model,
        capacity: CROWD_NATIVE_INSTANCES,
        pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
        instances: instances[..],
        actions_per_instance: anim::MAX_ACTIONS,
        event_capacity: 0,
    )!!;
    pair.scene.get(pair.crowd, AnimatedCrowd).inertia_enabled = true;
    model::prepare_crowd(&fixture.assets, &pair.scene, pair.crowd)!!;
    uint root = authoring_native_node(&fixture.assets.model(pair.model).data, "root");
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        pair.scene.remove_component(pair.ordinary[source], Animator);
        Animator* animator = anim::add_animator(&pair.scene, pair.ordinary[source], { .inertia_enabled = true });
        animator.root_node = root;
        CrowdPlayer player = crowd_native_player(pair, source)!!;
        player.stop(player.state.slots[source].base_action)!!;
        player.state.slots[source].root_node = root;
    }
}

fn void check_motion_native_pair(CrowdNativePair* pair) @private {
    CrowdPlaybackState* playback = pair.scene.get(pair.crowd, AnimatedCrowd).playback;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        ModelInstance* instance = pair.scene.get(pair.ordinary[source], ModelInstance);
        Mat4 carrier_inverse = maths::inverse_affine(pair.ordinary[source].world);
        Transform[] locals = playback.poses[(usz)source * playback.base_pose.len:playback.base_pose.len];
        foreach (index, local : locals) {
            Transform reference = instance.present_node((usz)index).local;
            assert(local.position.distance(reference.position) <= MOTION_NATIVE_POSITION_EPSILON);
            assert(local.scale.distance(reference.scale) <= MOTION_NATIVE_SCALE_EPSILON);
            Quat difference = local.rotation.mul(reference.rotation.conjugate()).normalize();
            Vec3 axis = { difference.i, difference.j, difference.k };
            float angle = 2 * math::atan2(axis.length(), math::abs(difference.l));
            assert(angle <= MOTION_NATIVE_ROTATION_EPSILON);
            Mat4 actual_relative = local.to_mat4();
            for (int parent = playback.parents[index]; parent >= 0; parent = playback.parents[parent]) {
                actual_relative = locals[parent].to_mat4().mul(actual_relative);
            }
            Mat4 expected_relative = carrier_inverse.mul(instance.present_node((usz)index).world);
            Vec3 actual_position = maths::transform_point(actual_relative, {});
            Vec3 expected_position = maths::transform_point(expected_relative, {});
            assert(actual_position.distance(expected_position) <= MOTION_NATIVE_DRIFT_EPSILON);
        }
        foreach (usz mesh, node : playback.mesh_nodes) {
            float[] actual = playback.logical_weights[(usz)source * playback.mesh_nodes.len + mesh];
            float[] expected = pair.scene.get(instance.present_node(node), Mesh).morph_weights;
            assert(actual.len == expected.len);
            foreach (index, weight : actual) assert(math::abs(weight - expected[index]) <= MOTION_NATIVE_MORPH_EPSILON);
        }
    }
}

fn void test_animation_authoring_motion_native_quaternius_turns_reverse_loops_and_interrupted_requests() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model_id = load_crowd_native_cc0(
        fixture: &fixture,
        filename: CROWD_NATIVE_QUATERNIUS,
        expected_hash: CROWD_NATIVE_QUATERNIUS_SHA,
    )!!;
    crowd_native_flat_source_materials(&fixture, model_id);
    ClipId initial = crowd_native_clip_named(&fixture, model_id, "Walk_Loop")!!;
    Transform[CROWD_NATIVE_INSTANCES] placements;
    foreach (index, &placement : placements) {
        *placement = maths::TRANSFORM_IDENTITY;
        placement.position.x = ((float)index - 1) * 3;
        placement.scale = { 0.6f, 0.6f, 0.6f };
    }
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: &tracker,
        fixture: &fixture,
        pair: &pair,
        model: model_id,
        clip: initial,
        bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
        placements: placements[..],
    )!!;
    defer scene::destroy_scene(&pair.scene);
    configure_motion_native_pair(&fixture, &pair);

    PlayDesc config = {
        .root_motion = EXTRACT,
        .extraction = {
            .generalized = true,
            .translation_axes = { true, true, true },
            .up = { 0, 1, 0 },
            .twist = true,
        },
    };
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        AnimationActionId ordinary = animator.play(&fixture.assets, initial, config)!!;
        AnimationActionId crowded = player.play(&fixture.assets, initial, config)!!;
        float speed = source == 1 ? -0.75f : 1;
        float time = speed < 0 ? fixture.assets.clip(initial).data.duration : 0;
        foreach (action : (Action*[2]){ animator.action(ordinary), player.action(crowded) }) {
            action.speed = speed;
            action.time = time;
        }
    }

    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    ViewDesc view_desc = render::texture_view_desc(output.target);
    view_desc.depth_prepass = true;
    view_desc.post.motion_blur = true;
    render::configure_view(&fixture.renderer, output.view, view_desc)!!;
    crowd_native_update(&fixture, &pair, 0);

    String[4] names = { "Jog_Fwd_Loop", "Turn90_L", "Turn90_R", "Walk_Loop" };
    float[4] steps = { 1.0f / 120, 1.0f / 120, 1.0f / 120, 1.0f / 24 };
    double simulated;
    float radius;
    uint request_ordinal;
    for (uint frame = 0; frame < MOTION_NATIVE_FRAMES; frame++) {
        float dt = steps[frame % (uint)steps.len];
        bool request = frame == 120 || frame == 150 || frame == 300 || frame == 420 || frame == 450
          || frame == 600 || frame == 780 || frame == 900 || frame == 930 || frame == 1050;
        if (request) {
            request_ordinal++;
            ClipId clip = crowd_native_clip_named(&fixture, model_id, names[(request_ordinal - 1) % (uint)names.len])!!;
            for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
                Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
                CrowdPlayer player = crowd_native_player(&pair, source)!!;
                AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
                targets[0].clip = clip;
                targets[0].play = config;
                targets[0].speed = source == 1 ? -0.75f : (request_ordinal % 2 == 0 ? 1.25f : 1.0f);
                targets[0].start_time = targets[0].speed < 0 ? fixture.assets.clip(clip).data.duration : 0;
                targets[0].loop = source == 2 || (request_ordinal - 1) % 4 == 0;
                animator.inertialize(&fixture.assets, {
                    .duration = MOTION_NATIVE_TRANSITION_SECONDS,
                    .actions = targets[..],
                })!!;
                player.inertialize(&fixture.assets, {
                    .duration = MOTION_NATIVE_TRANSITION_SECONDS,
                    .actions = targets[..],
                })!!;
            }
        }
        bool playing = !(frame >= 360 && frame < 390) && !(frame >= 720 && frame < 750);
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            CrowdPlayer player = crowd_native_player(&pair, source)!!;
            animator.action(animator.order[0]).playing = playing;
            player.action(player.state.slots[source].order[0]).playing = playing;
        }

        sz acquisitions = tracker.total_allocation_count();
        crowd_native_update(&fixture, &pair, dt);
        assert(tracker.total_allocation_count() == acquisitions, "Inertial/generalized update allocated owner storage");
        AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            anim::apply_root_motion(pair.ordinary[source], animator.root_motion);
            radius = math::max(radius, pair.ordinary[source].local.position.length());
        }
        pair.scene.apply_crowd_root_motion(crowd);
        pair.scene.update_world();
        check_motion_native_pair(&pair);

        pair.crowd.visible = true;
        pair.references.visible = false;
        Vec3 center;
        foreach (placement : crowd.placements[:crowd.count]) center += placement.position / (float)crowd.count;
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(6 + radius, 0.1f, 100);
        pair.camera.local.position = center + (Vec3){ 0, 1, 15 };
        pair.scene.update_world();
        fixture.renderer.begin_frame({ .time = simulated, .delta = dt })!!;
        fixture.renderer.render_view(&pair.scene, pair.camera, output.view)!!;
        fixture.renderer.finish_view(output.view)!!;
        fixture.renderer.end_frame()!!;
        simulated += dt;
        if (frame == 0 || frame == 150 || frame == 450 || frame + 1 == MOTION_NATIVE_FRAMES) {
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
