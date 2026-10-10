module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;

const double ROOT_FRAME_MOTION_EPSILON @local = 1e-6;
const double ROOT_FRAME_RATE_EPSILON @local = 1e-6;
const double ROOT_FRAME_FIRST_DECAY @local = 0.99144; // H0(0.1), from the independent quintic polynomial.

struct RootFrameFixture @local {
    LayerFixture ordinary;
    Transform[1] placements;
    CrowdPlaybackState* crowd;
    CrowdPlayer player;
}

fn void create_root_frame_fixture(RootFrameFixture* fixture, bool crowd) @local {
    create_layer_fixture(&fixture.ordinary);
    fixture.ordinary.scene.remove_component(fixture.ordinary.root, Animator);
    fixture.ordinary.animator = anim::add_animator(
        &fixture.ordinary.scene, fixture.ordinary.root, { .inertia_enabled = true });
    if (!crowd) return;
    fixture.placements[0] = maths::TRANSFORM_IDENTITY;
    fixture.crowd = anim::create_crowd_playback(
        allocator: mem,
        template: &fixture.ordinary.assets.model(fixture.ordinary.model).data,
        placements: fixture.placements[..],
        actions_per_instance: 4,
        event_capacity: 0,
        inertia_enabled: true,
    )!!;
    fixture.crowd.model = fixture.ordinary.model;
    fixture.crowd.count = 1;
    fixture.player = fixture.crowd.player(fixture.crowd.instance_id(0)!!)!!;
}

fn void destroy_root_frame_fixture(RootFrameFixture* fixture) @local {
    if (fixture.crowd) anim::destroy_crowd_playback(fixture.crowd);
    destroy_layer_fixture(&fixture.ordinary);
}

fn ClipId root_frame_source_clip(RootFrameFixture* fixture) @local {
    float[2] times = { 0, 1 };
    float[6] positions = { 0, 0, 0, 1, 2, 3 };
    Quat endpoint = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 1.0f);
    float[8] rotations = { 0, 0, 0, 1, endpoint.v.x, endpoint.v.y, endpoint.v.z, endpoint.v.w };
    Track[2] tracks = {
        make_track(
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: positions[..],
        ),
        make_track(
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rotations[..],
        ),
    };
    uint[1] targets = { 2 };
    return add_clip(
        assets: &fixture.ordinary.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn void root_frame_play_source(RootFrameFixture* fixture, ClipId clip) @local {
    PlayDesc extraction = {
        .root_motion = RootMotion.EXTRACT,
        .extraction = {
            .generalized = true,
            .translation_axes = { true, true, true },
            .up = { 0, 0, 1 },
            .twist = true,
        },
    };
    if (fixture.crowd) {
        fixture.player.play(&fixture.ordinary.assets, clip, extraction)!!;
    } else {
        fixture.ordinary.animator.play(&fixture.ordinary.assets, clip, extraction)!!;
    }
}

fn void root_frame_update(RootFrameFixture* fixture, float dt) @local {
    if (fixture.crowd) {
        fixture.crowd.update(&fixture.ordinary.assets, dt);
    } else {
        anim::update(&fixture.ordinary.assets, &fixture.ordinary.scene, dt);
    }
}

fn RootMotionDelta root_frame_motion(RootFrameFixture* fixture) @local {
    return fixture.crowd ? fixture.crowd.slots[0].root_motion : fixture.ordinary.animator.root_motion;
}

fn InertialRow* root_frame_history(RootFrameFixture* fixture) @local {
    return fixture.crowd ? &fixture.crowd.inertial_storage.rows[0]
      : &fixture.ordinary.animator.inertial_storage.rows[0];
}

fn Transform root_frame_pose(RootFrameFixture* fixture) @local {
    if (fixture.crowd) return fixture.crowd.poses[2];
    ModelInstance* instance = fixture.ordinary.scene.get(fixture.ordinary.root, ModelInstance);
    return instance.present_node(2).local;
}

fn void? root_frame_transition(RootFrameFixture* fixture, AnimationTransitionDesc description) @local {
    if (fixture.crowd) return fixture.player.inertialize(&fixture.ordinary.assets, description);
    return fixture.ordinary.animator.inertialize(&fixture.ordinary.assets, description);
}

fn void assert_root_frame_decay(
    RootMotionDelta actual,
    RootMotionDelta source,
    double source_twist_rate,
    double step,
) @local {
    double[<3>] published = { actual.translation.x, actual.translation.y, actual.translation.z };
    double[<3>] saved = { source.translation.x, source.translation.y, source.translation.z };
    assert((published - saved * ROOT_FRAME_FIRST_DECAY).length() < ROOT_FRAME_MOTION_EPSILON);
    assert(actual.translation.z != 0);
    assert(actual.rotation.v.x == 0 && actual.rotation.v.y == 0 && actual.rotation.v.z != 0);
    double angle = 2 * math::atan2((double)actual.rotation.v.z, (double)actual.rotation.v.w);
    double expected = source_twist_rate * step * ROOT_FRAME_FIRST_DECAY;
    assert(math::abs(angle - expected) < ROOT_FRAME_MOTION_EPSILON);
}

fn void test_animation_inertial_root_frame_generalized_z_source_survives_keep_and_keep_interruption() @test {
    foreach (bool crowd : { false, true }) {
        RootFrameFixture fixture;
        create_root_frame_fixture(&fixture, crowd);
        defer destroy_root_frame_fixture(&fixture);
        ClipId source_clip = root_frame_source_clip(&fixture);
        ClipId first_keep = layer_translation(&fixture.ordinary, { 8, 0, 0 });
        ClipId second_keep = layer_translation(&fixture.ordinary, { -4, 0, 0 });
        root_frame_play_source(&fixture, source_clip);
        root_frame_update(&fixture, 0.1f);
        root_frame_update(&fixture, 0.1f);
        RootMotionDelta source = root_frame_motion(&fixture);
        InertialRow* row = root_frame_history(&fixture);
        double step = (double)0.1f;
        double[<3>] source_rate = row.root.translation_rate;
        double source_twist_rate = row.root.twist_rate;
        assert(source.translation.z > 0 && row.control.history_valid);
        assert(math::abs(source_twist_rate - 1) < ROOT_FRAME_RATE_EPSILON);
        AnimationTargetDesc[1] target = { anim::ANIMATION_TARGET_DEFAULT };
        target[0].clip = first_keep;
        root_frame_transition(&fixture, { .duration = 1, .actions = target[..] })!!;
        Transform displayed = root_frame_pose(&fixture);
        root_frame_update(&fixture, 0);
        assert(row.control.elapsed == 0 && row.control.active);
        assert(row.root.translation_rate == source_rate && row.root.twist_rate == source_twist_rate);
        Transform zero_pose = root_frame_pose(&fixture);
        assert(zero_pose.position == displayed.position && zero_pose.rotation.v == displayed.rotation.v);
        RootMotionDelta zero = root_frame_motion(&fixture);
        assert(zero.translation == (Vec3){} && zero.rotation.v == quaternion::IDENTITY{float}.v);
        root_frame_update(&fixture, 0.1f);
        RootMotionDelta first = root_frame_motion(&fixture);
        assert_root_frame_decay(
            actual: first,
            source: source,
            source_twist_rate: source_twist_rate,
            step: step,
        );
        assert((row.root.translation_rate - source_rate * ROOT_FRAME_FIRST_DECAY).length() < ROOT_FRAME_RATE_EPSILON);
        assert(math::abs(row.root.twist_rate - source_twist_rate * ROOT_FRAME_FIRST_DECAY) < ROOT_FRAME_RATE_EPSILON);
        assert(math::abs(2 * math::atan2((double)first.rotation.v.z, (double)first.rotation.v.w) - 0.099144)
          < ROOT_FRAME_MOTION_EPSILON);
        double[<3>] first_rate = row.root.translation_rate;
        double first_twist_rate = row.root.twist_rate;
        target[0].clip = second_keep;
        root_frame_transition(&fixture, { .duration = 1, .actions = target[..] })!!;
        root_frame_update(&fixture, 0);
        assert(row.control.elapsed == 0);
        assert(row.root.translation_rate == first_rate && row.root.twist_rate == first_twist_rate);
        root_frame_update(&fixture, 0.1f);
        RootMotionDelta interrupted = root_frame_motion(&fixture);
        assert_root_frame_decay(
            actual: interrupted,
            source: first,
            source_twist_rate: first_twist_rate,
            step: step,
        );
        assert((row.root.translation_rate - first_rate * ROOT_FRAME_FIRST_DECAY).length() < ROOT_FRAME_RATE_EPSILON);
        assert(math::abs(row.root.twist_rate - first_twist_rate * ROOT_FRAME_FIRST_DECAY) < ROOT_FRAME_RATE_EPSILON);
    }
}

fn void test_animation_inertial_root_frame_differing_target_extract_up_is_rejected_without_source_mutation() @test {
    foreach (bool crowd : { false, true }) {
        RootFrameFixture fixture;
        create_root_frame_fixture(&fixture, crowd);
        defer destroy_root_frame_fixture(&fixture);
        ClipId source_clip = root_frame_source_clip(&fixture);
        root_frame_play_source(&fixture, source_clip);
        root_frame_update(&fixture, 0.1f);
        root_frame_update(&fixture, 0.1f);
        InertialRow* row = root_frame_history(&fixture);
        InertialControl control_before = row.control;
        RootInertialState root_before = row.root;
        RootMotionDelta motion_before = root_frame_motion(&fixture);
        PlaybackView playback = fixture.crowd
          ? anim::crowd_playback_view(fixture.crowd, &fixture.crowd.slots[0]) : fixture.ordinary.animator.playback();
        AnimationActionId id = playback.order[0];
        Action* action = playback.actions.get(id);
        char[Action::size] action_before;
        mem::copy(&action_before, action, Action::size);
        AnimationTargetDesc[1] target = { anim::ANIMATION_TARGET_DEFAULT };
        target[0].clip = source_clip;
        target[0].play = {
            .root_motion = RootMotion.EXTRACT,
            .extraction = {
                .generalized = true,
                .translation_axes = { true, true, true },
                .up = { 0, 1, 0 },
                .twist = true,
            },
        };
        bool caught;
        if (catch excuse = root_frame_transition(&fixture, { .duration = 1, .actions = target[..] })) {
            assert(excuse == c3d::INVALID_ARGUMENT);
            caught = true;
        }
        assert(caught && playback.actions.is_live(id) && *playback.action_count == 1);
        assert(mem::equals((char*)&control_before, (char*)&row.control, InertialControl::size));
        assert(mem::equals((char*)&root_before, (char*)&row.root, RootInertialState::size));
        assert(mem::equals((char*)&action_before, (char*)action, Action::size));
        RootMotionDelta after = root_frame_motion(&fixture);
        assert(after.translation == motion_before.translation && after.rotation.v == motion_before.rotation.v);
    }
}
