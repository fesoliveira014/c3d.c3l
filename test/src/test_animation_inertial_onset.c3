module c3d::test::inertial_onset;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;

const double ONSET_TEST_EPSILON @local = 1e-6;

struct OnsetFixture @local {
    AssetStore assets;
    Scene scene;
    Animator* animator;
    CrowdPlaybackState* crowd;
    CrowdPlayer player;
    ModelId model;
    Transform[1] placements;
}

fn void create_onset_fixture(
    OnsetFixture* fixture,
    bool crowded,
    bool evaluate_base = true,
    Vec3 baseline_child = {},
) @local {
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 1,
        .max_textures = 8,
        .max_materials = 1,
        .max_samplers = 8,
        .max_models = 1,
        .max_skeletons = 1,
        .max_clips = 8,
    });
    fixture.scene = scene::create_scene(mem, { .max_nodes = 8 });
    ModelTemplate template = { .nodes = alloc::new_array(mem, NodeTemplate, 3) };
    foreach (index, &node : template.nodes) {
        *node = { .parent = index == 0 ? -1 : 0, .local = maths::TRANSFORM_IDENTITY };
    }
    template.nodes[1].local.position = baseline_child;
    fixture.model = fixture.assets.add_model_owned(&template)!!;
    if (crowded) {
        fixture.placements[0] = maths::TRANSFORM_IDENTITY;
        fixture.crowd = anim::create_crowd_playback(
            allocator: mem,
            template: &fixture.assets.model(fixture.model).data,
            placements: fixture.placements[..],
            actions_per_instance: 4,
            event_capacity: 16,
            inertia_enabled: true,
        )!!;
        fixture.crowd.model = fixture.model;
        fixture.crowd.count = 1;
        fixture.player = fixture.crowd.player(fixture.crowd.instance_id(0)!!)!!;
        fixture.player.set_root_node(0)!!;
    } else {
        Node* owner = model::instantiate(&fixture.assets, &fixture.scene, fixture.model)!!;
        fixture.animator = anim::add_animator(&fixture.scene, owner, { .inertia_enabled = true });
        fixture.animator.root_node = 0;
    }

    if (evaluate_base) onset_update(fixture, 0);
}

fn void destroy_onset_fixture(OnsetFixture* fixture) @local {
    if (fixture.crowd) anim::destroy_crowd_playback(fixture.crowd);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn ClipId onset_clip(
    OnsetFixture* fixture,
    float first,
    float later,
    bool smooth,
) @local {
    AnimationClip clip = {
        .duration = 1,
        .tracks = alloc::new_array(mem, Track, smooth ? 4 : 2),
        .targets = alloc::new_array(mem, uint, smooth ? 4 : 2),
    };
    foreach (index, &track : clip.tracks) {
        *track = {
            .target = (uint)index,
            .path = index == 3 ? TargetPath.SCALE : TargetPath.TRANSLATION,
            .interpolation = index < 2 ? Interpolation.STEP : Interpolation.LINEAR,
            .times = alloc::new_array(mem, float, 3),
            .values = alloc::new_array(mem, float, 9),
        };
        track.times[..] = ((float[3]){ 0, 0.5f, 1 })[..];
        if (index < 2) {
            track.values[..] = ((float[9]){ first, 0, 0, later, 0, 0, later, 0, 0 })[..];
        } else if (index == 2) {
            track.values[..] = ((float[9]){ 0, 0, 0, 0, 1, 0, 0, 2, 0 })[..];
        } else {
            track.values[..] = ((float[9]){ 1, 1, 1, 1.5f, 1.5f, 1.5f, 2, 2, 2 })[..];
        }
        clip.targets[index] = index == 3 ? 0 : (uint)index;
    }
    ClipId id = fixture.assets.add_clip_owned(&clip)!!;
    if (smooth) {
        ClipEvent[1] events = { { .time = 0.5f, .id = 91 } };
        fixture.assets.set_clip_events(id, events[..])!!;
    }
    return id;
}

fn PlaybackView onset_playback(OnsetFixture* fixture) @local {
    return fixture.crowd ? anim::crowd_playback_view(fixture.crowd, &fixture.crowd.slots[0])
      : fixture.animator.playback();
}

fn Transform[] onset_pose(OnsetFixture* fixture) @local {
    return fixture.crowd ? fixture.crowd.poses[:3] : fixture.animator.pose_storage.destination.pose;
}

fn InertialRow* onset_history(OnsetFixture* fixture) @local {
    return fixture.crowd ? &fixture.crowd.inertial_storage.rows[0] : &fixture.animator.inertial_storage.rows[0];
}

fn RootMotionDelta onset_motion(OnsetFixture* fixture) @local {
    return fixture.crowd ? fixture.crowd.slots[0].root_motion : fixture.animator.root_motion;
}

fn uint onset_events(OnsetFixture* fixture) @local {
    return fixture.crowd ? fixture.crowd.event_count : fixture.animator.event_count;
}

fn void onset_update(OnsetFixture* fixture, float dt) @local {
    if (fixture.crowd) {
        fixture.crowd.update(&fixture.assets, dt);
    } else {
        anim::update(&fixture.assets, &fixture.scene, dt);
    }
}

fn AnimationTransitionResult onset_request(OnsetFixture* fixture, AnimationTransitionDesc desc) @local {
    if (fixture.crowd) return fixture.player.inertialize(&fixture.assets, desc)!!;

    return fixture.animator.inertialize(&fixture.assets, desc)!!;
}

fn double onset_reference_h0(double fraction) @local {
    return 1 - 10 * fraction * fraction * fraction + 15 * fraction * fraction * fraction * fraction
      - 6 * fraction * fraction * fraction * fraction * fraction;
}

fn double onset_reference_h1(double fraction) @local {
    return fraction - 6 * fraction * fraction * fraction + 8 * fraction * fraction * fraction * fraction
      - 3 * fraction * fraction * fraction * fraction * fraction;
}

fn void onset_assert_zero_motion(OnsetFixture* fixture) @local {
    RootMotionDelta delta = onset_motion(fixture);
    assert(delta.translation == (Vec3){});
    assert(delta.rotation.v == (Vec4){ 0, 0, 0, 1 });
}

fn void test_animation_inertial_onset_step_side_survives_zero_updates_and_first_positive_endpoint() @test {
    foreach (crowded : (bool[2]){ false, true }) {
        foreach (generalized : (bool[2]){ false, true }) {
            for (uint group = 0; group < 3; group++) {
                for (uint mode = 0; mode < 5; mode++) {
                    foreach (duration : (float[2]){ 0, 0.75f }) {
                        OnsetFixture fixture;
                        create_onset_fixture(&fixture, crowded);
                        defer destroy_onset_fixture(&fixture);
                        bool equal = mode == 4;
                        float expected = mode == 0 ? 0 : equal ? 5 : 10;
                        ClipId source = onset_clip(
                            fixture: &fixture,
                            first: expected,
                            later: expected,
                            smooth: false,
                        );
                        PlaybackView playback = onset_playback(&fixture);
                        AnimationActionId source_id = fixture.crowd
                          ? fixture.player.play(&fixture.assets, source)!!
                          : fixture.animator.play(&fixture.assets, source)!!;
                        onset_update(&fixture, 0.125f);
                        onset_update(&fixture, 0.125f);
                        ClipId target = onset_clip(
                            fixture: &fixture,
                            first: equal ? 5 : 0,
                            later: equal ? 5 : 10,
                            smooth: true,
                        );
                        AnimationTargetDesc[3] targets;
                        targets[..] = anim::ANIMATION_TARGET_DEFAULT;
                        uint count = group == 0 ? 1 : group == 1 ? 2 : 3;
                        float speed = mode == 0 ? -1 : mode == 3 ? 0 : 1;
                        bool playing = mode != 2;
                        foreach (&action : targets[:count]) {
                            action.clip = target;
                            action.start_time = group ? 0 : 0.5f;
                            action.speed = speed;
                            action.playing = playing;
                            action.loop = false;
                            action.play = {
                                .root_motion = RootMotion.EXTRACT,
                                .extraction = {
                                    .generalized = generalized,
                                    .translation_axes = generalized ? (bool[3]){ true, false, false } : (bool[3]){},
                                    .up = generalized ? (Vec3){ 0, 1, 0 } : (Vec3){},
                                },
                            };
                        }
                        uint[3] members = { 0, 1, 2 };
                        float[2] positions = { 0, 1 };
                        Vec2[3] points = { { 0, 0 }, { 1, 0 }, { 0, 1 } };
                        BlendTriangle[1] triangles = { { .indices = { 0, 1, 2 } } };
                        AnimationTransitionSpaceDesc[1] spaces = { {
                            .phase = 0.5f,
                            .space = {
                                .actions = members[:count],
                                .positions = group == 1 ? positions[..] : (float[]) {},
                                .parameter = group == 1 ? 0.25f : 0,
                                .weight = 1,
                                .speed = speed,
                                .playing = playing,
                                .kind = group == 1 ? AnimationSpaceKind.ONE_DIMENSIONAL
                                  : AnimationSpaceKind.TWO_DIMENSIONAL,
                                .points = group == 2 ? points[..] : (Vec2[]) {},
                                .triangles = group == 2 ? triangles[..] : (BlendTriangle[]) {},
                                .parameter_2d = group == 2 ? (Vec2){ 0.25f, 0.25f } : (Vec2){},
                            },
                        } };
                        AnimationTransitionDesc desc = {
                            .duration = duration,
                            .actions = targets[:count],
                            .spaces = group ? spaces[..] : (AnimationTransitionSpaceDesc[]) {},
                        };
                        AnimationTransitionResult installed = onset_request(&fixture, desc);
                        playback = onset_playback(&fixture);
                        assert(installed.count == count && installed.space_count == (group ? 1 : 0));
                        assert(!playback.actions.is_live(source_id));
                        foreach (index, id : installed.actions[:installed.count]) {
                            assert(playback.actions.is_live(id) && c3d::same_id(id, playback.order[index]));
                            assert(c3d::same_id(playback.actions.get(id).clip, targets[index].clip));
                            if (id.index == source_id.index) assert(id.generation != source_id.generation);
                        }
                        if (group == 1) {
                            AnimationTransitionGroup installed_group = installed.spaces[0];
                            assert(installed_group.kind == AnimationSpaceKind.ONE_DIMENSIONAL);
                            assert(installed_group.one_dimensional && installed_group.one_dimensional.phase == 0.5);
                            foreach (index, member : installed_group.one_dimensional.actions[:count]) {
                                assert(c3d::same_id(member, installed.actions[members[index]]));
                            }
                        } else if (group == 2) {
                            AnimationTransitionGroup installed_group = installed.spaces[0];
                            assert(installed_group.kind == AnimationSpaceKind.TWO_DIMENSIONAL);
                            assert(installed_group.two_dimensional && installed_group.two_dimensional.phase == 0.5);
                            foreach (index, member : installed_group.two_dimensional.actions[:count]) {
                                assert(c3d::same_id(member, installed.actions[members[index]]));
                            }
                        }
                        double scale_offset = generalized ? math::ln(2.0 / 3) : -0.5;
                        double scale_rate = playing ? generalized ? -(double)speed / 1.5 : -(double)speed : 0;
                        InertialRow* row = onset_history(&fixture);
                        foreach (axis : (uint[3]){ 0, 1, 2 }) {
                            assert(math::abs(row.offset[0].scale[axis] - scale_offset) < 1e-12);
                            assert(math::abs(row.offset_velocity[0].scale[axis] - scale_rate) < 1e-12);
                        }
                        assert(onset_pose(&fixture)[0].scale == (duration == 0
                          ? (Vec3){ 1.5f, 1.5f, 1.5f } : (Vec3){ 1, 1, 1 }));
                        assert(onset_pose(&fixture)[1].position.x == expected);
                        assert(onset_pose(&fixture)[2].position.y == (duration == 0 ? 1 : 0));
                        assert(onset_history(&fixture).control.onset_pending);
                        double previous_dt = onset_history(&fixture).control.previous_dt;
                        playback = onset_playback(&fixture);
                        foreach (id : playback.order[:count]) {
                            Action* action = playback.actions.get(id);
                            assert(action.time == 0.5f && action.published_time == 0.5f);
                        }
                        for (uint frame = 0; frame < 3; frame++) {
                            onset_update(&fixture, 0);
                            assert(onset_pose(&fixture)[1].position.x == expected);
                            assert(onset_pose(&fixture)[2].position.y == (duration == 0 ? 1 : 0));
                            assert(onset_history(&fixture).control.onset_pending);
                            assert(onset_history(&fixture).control.elapsed == 0);
                            assert(onset_history(&fixture).control.previous_dt == previous_dt);
                            assert(onset_events(&fixture) == 0);
                            onset_assert_zero_motion(&fixture);
                            foreach (id : playback.order[:count]) {
                                Action* action = playback.actions.get(id);
                                assert(action.time == 0.5f && action.clock_delta == 0);
                            }
                            assert(fixture.assets.clip(target).data.events[0].time == 0.5f);
                        }
                        onset_update(&fixture, 0.125f);
                        onset_assert_zero_motion(&fixture);
                        assert(!onset_history(&fixture).control.onset_pending);
                        assert(onset_pose(&fixture)[1].position.x == expected);
                        double travel = playing ? (double)speed * 0.125 : 0;
                        double smooth = 1 + 2 * travel;
                        if (duration > 0) {
                            smooth -= onset_reference_h0(1.0 / 6)
                              + 0.75 * (playing ? (double)speed * 2 : 0) * onset_reference_h1(1.0 / 6);
                        }
                        assert(math::abs((double)onset_pose(&fixture)[2].position.y - smooth) < ONSET_TEST_EPSILON);
                        foreach (id : playback.order[:count]) {
                            assert(playback.actions.get(id).time == (float)(0.5 + travel));
                        }
                        assert(fixture.assets.clip(target).data.events[0].time == 0.5f);
                    }
                }
            }
        }
    }
}

fn void test_animation_inertial_onset_new_request_changes_direction_and_stop_removes_residual() @test {
    foreach (crowded : (bool[2]){ false, true }) {
        foreach (generalized : (bool[2]){ false, true }) {
            OnsetFixture fixture;
            create_onset_fixture(&fixture, crowded);
            defer destroy_onset_fixture(&fixture);
            ClipId target = onset_clip(
                fixture: &fixture,
                first: 0,
                later: 10,
                smooth: false,
            );
            AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
            targets[0].clip = target;
            targets[0].start_time = 0.5f;
            targets[0].speed = -1;
            targets[0].loop = false;
            targets[0].play = {
                .root_motion = RootMotion.EXTRACT,
                .extraction = {
                    .generalized = generalized,
                    .translation_axes = generalized ? (bool[3]){ true, false, false } : (bool[3]){},
                    .up = generalized ? (Vec3){ 0, 1, 0 } : (Vec3){},
                },
            };
            onset_request(&fixture, { .duration = 0.75f, .actions = targets[..] });
            onset_update(&fixture, 0);
            assert(onset_pose(&fixture)[1].position.x == 0);
            targets[0].speed = 1;
            onset_request(&fixture, { .duration = 0.75f, .actions = targets[..] });
            onset_update(&fixture, 0);
            assert(onset_pose(&fixture)[1].position.x == 0);
            onset_update(&fixture, 0.125f);
            onset_assert_zero_motion(&fixture);
            double expected = 10 - 10 * onset_reference_h0(1.0 / 6);
            assert(math::abs((double)onset_pose(&fixture)[1].position.x - expected) < ONSET_TEST_EPSILON);
            assert(onset_history(&fixture).control.active);
            PlaybackView playback = onset_playback(&fixture);
            playback.stop(playback.order[0])!!;
            onset_update(&fixture, 0);
            assert(onset_pose(&fixture)[1].position.x == 0);
            assert(!onset_history(&fixture).control.active && !onset_history(&fixture).control.onset_pending);
            onset_assert_zero_motion(&fixture);
        }
    }
}

fn void test_animation_inertial_onset_first_reverse_step_past_completion_keeps_directional_begin_endpoint() @test {
    foreach (crowded : (bool[2]){ false, true }) {
        foreach (generalized : (bool[2]){ false, true }) {
            OnsetFixture fixture;
            create_onset_fixture(&fixture, crowded);
            defer destroy_onset_fixture(&fixture);
            ClipId target = onset_clip(
                fixture: &fixture,
                first: 0,
                later: 10,
                smooth: false,
            );
            AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
            targets[0].clip = target;
            targets[0].start_time = 0.5f;
            targets[0].speed = -1;
            targets[0].loop = false;
            targets[0].play = {
                .root_motion = RootMotion.EXTRACT,
                .extraction = {
                    .generalized = generalized,
                    .translation_axes = generalized ? (bool[3]){ true, false, false } : (bool[3]){},
                    .up = generalized ? (Vec3){ 0, 1, 0 } : (Vec3){},
                },
            };
            onset_request(&fixture, { .duration = 0.5f, .actions = targets[..] });
            onset_update(&fixture, 0);
            onset_update(&fixture, 0.75f);
            onset_assert_zero_motion(&fixture);
            assert(onset_pose(&fixture)[1].position.x == 0);
            assert(!onset_history(&fixture).control.active && !onset_history(&fixture).control.onset_pending);
            PlaybackView playback = onset_playback(&fixture);
            assert(playback.actions.get(playback.order[0]).time == 0);
            assert(!playback.actions.get(playback.order[0]).playing);
            onset_update(&fixture, 0);
            onset_assert_zero_motion(&fixture);
            assert(onset_pose(&fixture)[1].position.x == 0);
        }
    }
}

fn void test_animation_inertial_onset_immediate_request_captures_authored_pose_without_source_history() @test {
    foreach (crowded : (bool[2]){ false, true }) {
        foreach (generalized : (bool[2]){ false, true }) {
            OnsetFixture fixture;
            create_onset_fixture(
                fixture: &fixture,
                crowded: crowded,
                evaluate_base: false,
                baseline_child: { 7, 0, 0 },
            );
            defer destroy_onset_fixture(&fixture);
            InertialRow* row = onset_history(&fixture);
            assert(!row.control.history_valid && row.control.previous_dt == 0);
            assert(onset_pose(&fixture)[1].position == (Vec3){ 7, 0, 0 });
            assert(onset_pose(&fixture)[1].scale == (Vec3){ 1, 1, 1 });
            assert(onset_pose(&fixture)[1].rotation.v == (Vec4){ 0, 0, 0, 1 });
            ClipId target = onset_clip(
                fixture: &fixture,
                first: 0,
                later: 10,
                smooth: false,
            );
            AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
            targets[0].clip = target;
            targets[0].start_time = 0.5f;
            targets[0].play = {
                .root_motion = RootMotion.EXTRACT,
                .extraction = {
                    .generalized = generalized,
                    .translation_axes = generalized ? (bool[3]){ true, false, false } : (bool[3]){},
                    .up = generalized ? (Vec3){ 0, 1, 0 } : (Vec3){},
                },
            };
            onset_request(&fixture, { .duration = 0.5f, .actions = targets[..] });
            assert(onset_pose(&fixture)[1].position == (Vec3){ 7, 0, 0 });
            assert(!row.control.history_valid && row.control.previous_dt == 0);
            assert(row.previous_pose[1].position == (Vec3){ 7, 0, 0 });
            assert(row.offset[1].translation == (double[<3>]){ -3, 0, 0 });
            assert(row.offset_velocity[1].translation == (double[<3>]){});
            foreach (velocity : row.velocity) {
                assert(velocity.translation == (double[<3>]){});
                assert(velocity.angular == (double[<3>]){});
                assert(velocity.scale == (double[<3>]){});
            }
            assert(row.root.source_translation_rate == (double[<3>]){} && row.root.source_twist_rate == 0);
            onset_update(&fixture, 0);
            assert(onset_pose(&fixture)[1].position == (Vec3){ 7, 0, 0 });
            assert(!row.control.history_valid && row.control.previous_dt == 0);
            onset_assert_zero_motion(&fixture);
        }
    }
}

fn void test_animation_inertial_onset_cancel_keeps_target_side_until_first_positive_update() @test {
    foreach (crowded : (bool[2]){ false, true }) {
        foreach (generalized : (bool[2]){ false, true }) {
            foreach (speed : (float[2]){ -1, 1 }) {
                OnsetFixture fixture;
                create_onset_fixture(&fixture, crowded);
                defer destroy_onset_fixture(&fixture);
                ClipId target = onset_clip(
                    fixture: &fixture,
                    first: 0,
                    later: 10,
                    smooth: false,
                );
                AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
                targets[0].clip = target;
                targets[0].start_time = 0.5f;
                targets[0].speed = speed;
                targets[0].loop = false;
                targets[0].play = {
                    .root_motion = RootMotion.EXTRACT,
                    .extraction = {
                        .generalized = generalized,
                        .translation_axes = generalized ? (bool[3]){ true, false, false } : (bool[3]){},
                        .up = generalized ? (Vec3){ 0, 1, 0 } : (Vec3){},
                    },
                };
                AnimationTransitionResult installed = onset_request(
                    fixture: &fixture,
                    desc: { .duration = 0.75f, .actions = targets[..] },
                );
                if (crowded) {
                    fixture.player.cancel_inertial_transition()!!;
                } else {
                    fixture.animator.cancel_inertial_transition();
                }
                InertialRow* row = onset_history(&fixture);
                assert(!row.control.active && row.control.onset_pending);
                assert(row.control.duration == 0 && row.control.elapsed == 0);
                PlaybackView playback = onset_playback(&fixture);
                Action* action = playback.actions.get(installed.actions[0]);
                float expected = speed < 0 ? 0 : 10;
                for (uint frame = 0; frame < 3; frame++) {
                    onset_update(&fixture, 0);
                    assert(onset_pose(&fixture)[1].position.x == expected);
                    assert(row.control.onset_pending);
                    assert(action.time == 0.5f && action.clock_delta == 0);
                    assert(onset_events(&fixture) == 0);
                    onset_assert_zero_motion(&fixture);
                }
                onset_update(&fixture, 0.125f);
                assert(onset_pose(&fixture)[1].position.x == expected);
                assert(!row.control.onset_pending && !row.control.active);
                assert(action.time == 0.5f + speed * 0.125f);
                assert(onset_events(&fixture) == 0);
                onset_assert_zero_motion(&fixture);
            }
        }
    }
}
