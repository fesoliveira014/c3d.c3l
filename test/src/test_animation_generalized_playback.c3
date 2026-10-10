module c3d::test::generalized_playback;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::pool;
import c3d::model;
import c3d::scene;
import std::io;
import std::math;

const double PLAYBACK_TEST_POINT_EPSILON @local = 1e-5;
const double PLAYBACK_TEST_MOTION_EPSILON @local = 2e-6;
const uint PLAYBACK_TEST_CROWD_CAPACITY @local = 4096;

struct PlaybackTestMatrix @local {
    double[4][4] cells;
}

struct GeneralizedPlaybackFixture @local {
    NodeTemplate[5] nodes;
    Transform[5] base_pose;
    Transform[5] reference_pose;
    Track[5] tracks;
    uint[5] targets;
    float[2] times;
    float[6] ancestor_positions;
    float[8] ancestor_rotations;
    float[6] ancestor_scales;
    float[6] motion_positions;
    float[8] motion_rotations;
    uint[5] cursors;
    uint[5] second_cursors;
    bool[5] mask;
    AssetStore assets;
    Pool{Action, AnimationActionId} actions;
    CapturedMotionChain chain;
    AnimationActionId[2] order;
    uint action_count;
    PlaybackView view;
    PoseStorage* pose;
    GeneralizedPlaybackState state;
}

struct PlaybackOwnerAllocationProbe (Allocator) @local {
    Allocator backing;
    uint acquisitions;
    uint resizes;
}

fn void*? PlaybackOwnerAllocationProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.acquisitions++;
    return self.backing.acquire(size, init_type, alignment);
}

fn void*? PlaybackOwnerAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.resizes++;
    return self.backing.resize(pointer, size, alignment);
}

fn void PlaybackOwnerAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
}
fn PlaybackTestMatrix playback_test_identity() @local {
    PlaybackTestMatrix result;
    for (uint axis = 0; axis < 4; axis++) result.cells[axis][axis] = 1;
    return result;
}

fn PlaybackTestMatrix playback_test_product(PlaybackTestMatrix left, PlaybackTestMatrix right) @local {
    PlaybackTestMatrix result;
    for (uint row = 0; row < 4; row++) for (uint column = 0; column < 4; column++) {
        for (uint axis = 0; axis < 4; axis++) {
            result.cells[row][column] += left.cells[row][axis] * right.cells[axis][column];
        }
    }
    return result;
}

fn double[<3>] playback_test_point(PlaybackTestMatrix matrix, double[<3>] point) @local {
    double[<3>] result;
    for (uint row = 0; row < 3; row++) {
        result[row] = matrix.cells[row][3];
        for (uint axis = 0; axis < 3; axis++) result[row] += matrix.cells[row][axis] * point[axis];
    }
    return result;
}

fn PlaybackTestMatrix playback_test_rigid_inverse(PlaybackTestMatrix matrix) @local {
    PlaybackTestMatrix result = playback_test_identity();
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.cells[row][column] = matrix.cells[column][row];
        result.cells[row][3] -= matrix.cells[column][row] * matrix.cells[column][3];
    }
    return result;
}

fn PlaybackTestMatrix playback_test_rodrigues(double[<3>] up, double angle) @local {
    PlaybackTestMatrix result = playback_test_identity();
    double[3][3] skew = {
        { 0, -up.z, up.y },
        { up.z, 0, -up.x },
        { -up.y, up.x, 0 },
    };
    double sine = math::sin(angle);
    double cosine = math::cos(angle);
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.cells[row][column] = (row == column ? cosine : 0)
          + (1 - cosine) * up[row] * up[column] + sine * skew[row][column];
    }
    return result;
}

fn PlaybackTestMatrix playback_test_local(Transform local) @local {
    double[<4>] rotation = { local.rotation.v.x, local.rotation.v.y, local.rotation.v.z, local.rotation.v.w };
    rotation /= rotation.length();
    double x = rotation.x;
    double y = rotation.y;
    double z = rotation.z;
    double w = rotation.w;
    PlaybackTestMatrix result = { .cells = {
        { 1 - 2*y*y - 2*z*z, 2*x*y - 2*z*w, 2*x*z + 2*y*w, local.position.x },
        { 2*x*y + 2*z*w, 1 - 2*x*x - 2*z*z, 2*y*z - 2*x*w, local.position.y },
        { 2*x*z - 2*y*w, 2*y*z + 2*x*w, 1 - 2*x*x - 2*y*y, local.position.z },
        { 0, 0, 0, 1 },
    } };
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.cells[row][column] *= local.scale[column];
    }
    return result;
}

fn PlaybackTestMatrix playback_test_motion(GeneralizedMotion motion, double[<3>] up) @local {
    PlaybackTestMatrix result = playback_test_rodrigues(up, motion.twist);
    for (uint axis = 0; axis < 3; axis++) result.cells[axis][3] = motion.translation[axis];
    return result;
}

fn void playback_test_worlds(
    GeneralizedPlaybackFixture* fixture,
    Transform[] pose,
    PlaybackTestMatrix[] worlds,
) @local {
    foreach (index, node : fixture.nodes) {
        PlaybackTestMatrix local = playback_test_local(pose[index]);
        worlds[index] = node.parent < 0 ? local : playback_test_product(worlds[node.parent], local);
    }
}

fn double[<4>] playback_test_quaternion_product(double[<4>] left, double[<4>] right) @local {
    return {
        left.w*right.x + left.x*right.w + left.y*right.z - left.z*right.y,
        left.w*right.y - left.x*right.z + left.y*right.w + left.z*right.x,
        left.w*right.z + left.x*right.y - left.y*right.x + left.z*right.w,
        left.w*right.w - left.x*right.x - left.y*right.y - left.z*right.z,
    };
}

fn double[<4>] playback_test_chain_rotation(Transform[] pose) @local {
    double[<4>] result = { 0, 0, 0, 1 };
    for (uint index = 0; index < 3; index++) {
        Quat rotation = pose[index].rotation;
        double[<4>] value = { rotation.v.x, rotation.v.y, rotation.v.z, rotation.v.w };
        result = playback_test_quaternion_product(result, value / value.length());
    }
    return result;
}

fn double[<3>] playback_test_up(GeneralizedPlaybackFixture* fixture) @local {
    Vec3 value = fixture.state.extraction.up;
    double[<3>] up = { value.x, value.y, value.z };
    return up / up.length();
}

fn GeneralizedMotion playback_test_expected_endpoint(
    GeneralizedPlaybackFixture* fixture,
    Transform[] pose,
) @local {
    PlaybackTestMatrix[5] reference;
    PlaybackTestMatrix[5] current;
    playback_test_worlds(fixture, fixture.reference_pose[..], reference[..]);
    playback_test_worlds(fixture, pose, current[..]);
    double[<3>] pivot = playback_test_point(reference[2], {});
    double[<3>] translation = playback_test_point(current[2], {}) - pivot;
    for (uint axis = 0; axis < 3; axis++) {
        if (!fixture.state.extraction.translation_axes[axis]) translation[axis] = 0;
    }
    double[<3>] up = playback_test_up(fixture);
    double twist;
    if (fixture.state.extraction.twist) {
        double[<4>] begin = playback_test_chain_rotation(fixture.reference_pose[..]);
        double[<4>] end = playback_test_chain_rotation(pose);
        double initial = 2 * math::atan2(begin.x*up.x + begin.y*up.y + begin.z*up.z, begin.w);
        double final = 2 * math::atan2(end.x*up.x + end.y*up.y + end.z*up.z, end.w);
        twist = math::atan2(math::sin(final - initial), math::cos(final - initial));
    }
    PlaybackTestMatrix rotation = playback_test_rodrigues(up, twist);
    return { .translation = translation + pivot - playback_test_point(rotation, pivot), .twist = twist };
}

fn void playback_test_raw_pose(GeneralizedPlaybackFixture* fixture, float time, Transform[] output) @local {
    Action* action = fixture.actions.get(fixture.order[0]);
    float saved = action.time;
    action.time = time;
    anim::blend_pose(
        playback: &fixture.view,
        assets: &fixture.assets,
        destination: fixture.pose.destination,
        scratch: fixture.pose.scratch,
    );
    output[..] = fixture.pose.destination.pose[..];
    action.time = saved;
}

fn void create_generalized_playback_fixture(
    GeneralizedPlaybackFixture* fixture,
    RootExtractionDesc extraction,
) @local {
    int[5] parents = { -1, 0, 1, 0, -1 };
    String[5] names = { "base", "ancestor", "motion", "sibling", "rigid_branch" };
    foreach (index, &node : fixture.nodes) {
        *node = { .parent = parents[index], .name = names[index], .local = maths::TRANSFORM_IDENTITY };
        node.local.position = { 0.1f * (float)index, 0.05f * (float)index, -0.15f * (float)index };
    }
    fixture.nodes[0].local.position = { 1, 0.5f, -0.25f };
    fixture.nodes[0].local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.15f);
    fixture.nodes[0].local.scale = { 1.25f, 1.25f, 1.25f };
    fixture.nodes[4].local.scale = { -1, 2, 1 };
    foreach (index, node : fixture.nodes) fixture.base_pose[index] = node.local;
    fixture.times = { 0, 1 };
    fixture.targets = { 1, 1, 1, 2, 2 };
    fixture.ancestor_positions = { 0.1f, 0.2f, -0.1f, 0.4f, 0.5f, 0.2f };
    fixture.ancestor_scales = { 0.5f, 0.5f, 0.5f, 2, 2, 2 };
    fixture.motion_positions = { 2, 1, -0.5f, 2.8f, 1.2f, -0.2f };
    Quat ancestor_end = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.4f);
    Quat motion_end = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.3f)
      .mul(quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.2f));
    fixture.ancestor_rotations = {
        0, 0, 0, 1, ancestor_end.v.x, ancestor_end.v.y, ancestor_end.v.z, ancestor_end.v.w,
    };
    fixture.motion_rotations = { 0, 0, 0, 1, motion_end.v.x, motion_end.v.y, motion_end.v.z, motion_end.v.w };
    fixture.tracks = {
        { .target = 0, .path = TargetPath.TRANSLATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.ancestor_positions[..] },
        { .target = 1, .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.ancestor_rotations[..] },
        { .target = 2, .path = TargetPath.SCALE, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.ancestor_scales[..] },
        { .target = 3, .path = TargetPath.TRANSLATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.motion_positions[..] },
        { .target = 4, .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.motion_rotations[..] },
    };
    ModelTemplate model = { .nodes = fixture.nodes[..] };
    AnimationClip clip = { .duration = 1, .tracks = fixture.tracks[..], .targets = fixture.targets[..] };
    fixture.chain = anim::create_captured_motion_chain(
        allocator: mem,
        template: &model,
        clip: &clip,
        root: 2,
        extraction: extraction,
    )!!;
    fixture.chain.instance_scale = { 1, 1, 1 };
    fixture.assets.clips = pool::create_pool{ClipAsset, ClipId}(mem, 1);
    ClipId clip_id = fixture.assets.clips.add({ .data = clip })!!;
    fixture.actions = pool::create_pool{Action, AnimationActionId}(mem, 2);
    fixture.mask[..] = true;
    fixture.order[0] = fixture.actions.add({
        .clip = clip_id,
        .cursors = fixture.cursors[..],
        .mask = fixture.mask[..],
        .speed = 1,
        .weight = 1,
        .fade_target = 1,
        .playing = true,
        .loop = true,
        .root_motion = RootMotion.EXTRACT,
        .extraction = extraction,
        .motion_chain = &fixture.chain,
        .motion_reference = anim::capture_generalized_motion_reference(&fixture.chain, &clip),
        .translation_track = anim::NO_MOTION_TRACK,
        .rotation_track = anim::NO_MOTION_TRACK,
    })!!;
    fixture.action_count = 1;
    fixture.view = {
        .allocator = mem,
        .actions = &fixture.actions,
        .order = fixture.order[..],
        .action_count = &fixture.action_count,
        .root_node = 2,
    };
    fixture.pose = anim::create_pose_storage(
        allocator: mem,
        base_pose: fixture.base_pose[..],
        mesh_nodes: {},
        base_morph_weights: {},
        event_capacity: 0,
    );
    anim::initialize_generalized_playback(&fixture.state, &fixture.view);
    playback_test_raw_pose(fixture, 0, fixture.reference_pose[..]);
}

fn void destroy_generalized_playback_fixture(GeneralizedPlaybackFixture* fixture) @local {
    anim::destroy_pose_storage(mem, fixture.pose);
    pool::destroy_pool{Action, AnimationActionId}(&fixture.actions);
    pool::destroy_pool{ClipAsset, ClipId}(&fixture.assets.clips);
    anim::destroy_captured_motion_chain(&fixture.chain);
}

fn void playback_test_compare_worlds(
    GeneralizedPlaybackFixture* fixture,
    PlaybackTestMatrix consumed,
    PlaybackTestMatrix anchor,
    Transform[] keep,
) @local {
    PlaybackTestMatrix[5] expected;
    PlaybackTestMatrix[5] actual;
    playback_test_worlds(fixture, keep, expected[..]);
    playback_test_worlds(fixture, fixture.pose.destination.pose, actual[..]);
    double[<3>][4] corners = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
    for (uint node = 0; node < 5; node++) {
        PlaybackTestMatrix reference = playback_test_product(anchor, expected[node]);
        PlaybackTestMatrix reconstructed = playback_test_product(consumed, actual[node]);
        foreach (corner : corners) {
            assert((playback_test_point(reconstructed, corner) - playback_test_point(reference, corner)).length()
              <= PLAYBACK_TEST_POINT_EPSILON);
        }
    }
}

fn void test_animation_generalized_playback_animated_ancestors_and_all_branches_match_keep() @test {
    GeneralizedPlaybackFixture fixture;
    create_generalized_playback_fixture(&fixture, {
        .generalized = true,
        .translation_axes = { true, true, true },
        .up = (Vec3){ 1, 2, 3 }.normalize(),
        .twist = true,
    });
    defer destroy_generalized_playback_fixture(&fixture);
    usz state_bytes = GeneralizedPlaybackState::size;
    usz crowd_bytes = (usz)PLAYBACK_TEST_CROWD_CAPACITY * state_bytes;
    io::printfn("Generalized state=%s bytes; 4096 rows=%s bytes", state_bytes, crowd_bytes);
    Action* action = fixture.actions.get(fixture.order[0]);
    action.loop = false;
    PlaybackTestMatrix consumed = playback_test_identity();
    for (uint frame = 0; frame < 4; frame++) {
        anim::advance_clock(action, 1, 0.25);
        anim::blend_pose(
            playback: &fixture.view,
            assets: &fixture.assets,
            destination: fixture.pose.destination,
            scratch: fixture.pose.scratch,
        );
        Transform[5] keep;
        keep[..] = fixture.pose.destination.pose[..];
        GeneralizedMotion delta = anim::evaluate_generalized_playback_motion(
            playback: &fixture.view,
            assets: &fixture.assets,
            destination: fixture.pose.destination,
            state: &fixture.state,
            dt: 0.25,
        );
        consumed = playback_test_product(consumed, playback_test_motion(delta, playback_test_up(&fixture)));
        anim::finish_generalized_playback(
            state: &fixture.state,
            playback: &fixture.view,
            destination: fixture.pose.destination,
            final_motion: delta,
        );
        playback_test_compare_worlds(
            fixture: &fixture,
            consumed: consumed,
            anchor: playback_test_identity(),
            keep: keep[..],
        );
        GeneralizedMotion expected = playback_test_expected_endpoint(&fixture, keep[..]);
        PlaybackTestMatrix endpoint = playback_test_motion(expected, playback_test_up(&fixture));
        for (uint row = 0; row < 3; row++) for (uint column = 0; column < 4; column++) {
            assert(math::abs(consumed.cells[row][column] - endpoint.cells[row][column])
              < PLAYBACK_TEST_MOTION_EPSILON);
        }
        assert(fixture.pose.destination.pose[2].position == keep[2].position);
        assert(fixture.pose.destination.pose[3].position == keep[3].position);
        assert(fixture.pose.destination.pose[4].scale == (Vec3){ -1, 2, 1 });
    }
}

fn void test_animation_generalized_playback_loop_and_reverse_cycle_anchor_reconstruct_keep() @test {
    foreach (double direction : { 1.0, -1.0 }) {
        GeneralizedPlaybackFixture fixture;
        create_generalized_playback_fixture(&fixture, {
            .generalized = true,
            .translation_axes = { true, true, true },
            .up = { 0, 1, 0 },
            .twist = true,
        });
        defer destroy_generalized_playback_fixture(&fixture);
        Transform[5] end_pose;
        playback_test_raw_pose(&fixture, 1, end_pose[..]);
        GeneralizedMotion cycle_motion = playback_test_expected_endpoint(&fixture, end_pose[..]);
        PlaybackTestMatrix cycle = playback_test_motion(cycle_motion, playback_test_up(&fixture));
        PlaybackTestMatrix inverse_cycle = playback_test_rigid_inverse(cycle);
        PlaybackTestMatrix consumed = playback_test_identity();
        Action* action = fixture.actions.get(fixture.order[0]);
        for (uint frame = 0; frame < 10; frame++) {
            anim::advance_clock(action, 1, direction * 0.25);
            anim::blend_pose(
                playback: &fixture.view,
                assets: &fixture.assets,
                destination: fixture.pose.destination,
                scratch: fixture.pose.scratch,
            );
            Transform[5] keep;
            keep[..] = fixture.pose.destination.pose[..];
            GeneralizedMotion delta = anim::evaluate_generalized_playback_motion(
                playback: &fixture.view,
                assets: &fixture.assets,
                destination: fixture.pose.destination,
                state: &fixture.state,
                dt: 0.25,
            );
            consumed = playback_test_product(consumed, playback_test_motion(delta, playback_test_up(&fixture)));
            anim::finish_generalized_playback(
                state: &fixture.state,
                playback: &fixture.view,
                destination: fixture.pose.destination,
                final_motion: delta,
            );
            int cycles = (int)math::floor(direction * (double)(frame + 1) * 0.25);
            PlaybackTestMatrix anchor = playback_test_identity();
            for (int index = 0; index < math::abs(cycles); index++) {
                anchor = playback_test_product(anchor, cycles < 0 ? inverse_cycle : cycle);
            }
            playback_test_compare_worlds(
                fixture: &fixture,
                consumed: consumed,
                anchor: anchor,
                keep: keep[..],
            );
            PlaybackTestMatrix phase = playback_test_motion(
                playback_test_expected_endpoint(&fixture, keep[..]), playback_test_up(&fixture));
            PlaybackTestMatrix expected = playback_test_product(anchor, phase);
            for (uint row = 0; row < 3; row++) for (uint column = 0; column < 4; column++) {
                assert(math::abs(consumed.cells[row][column] - expected.cells[row][column])
                  < PLAYBACK_TEST_MOTION_EPSILON);
            }
        }
    }
}

fn void test_animation_generalized_playback_axes_weighted_layers_and_exact_emitted_motion() @test {
    for (uint selected = 0; selected < 4; selected++) {
        GeneralizedPlaybackFixture fixture;
        RootExtractionDesc extraction = { .generalized = true, .up = { 0, 0, 1 } };
        for (uint axis = 0; axis < 3; axis++) extraction.translation_axes[axis] = selected == 3 || selected == axis;
        create_generalized_playback_fixture(&fixture, extraction);
        defer destroy_generalized_playback_fixture(&fixture);
        Action* first = fixture.actions.get(fixture.order[0]);
        first.weight = selected == 3 ? 1 : 0.25f;
        Action second = *first;
        second.weight = 0.75f;
        second.layer = selected == 3 ? 1 : 0;
        second.cursors = fixture.second_cursors[..];
        fixture.order[1] = fixture.actions.add(second)!!;
        fixture.action_count = 2;
        Action* last = fixture.actions.get(fixture.order[1]);
        anim::advance_clock(first, 1, 0.25);
        anim::advance_clock(last, 1, 0.25);
        anim::blend_pose(
            playback: &fixture.view,
            assets: &fixture.assets,
            destination: fixture.pose.destination,
            scratch: fixture.pose.scratch,
        );
        Transform[5] keep;
        keep[..] = fixture.pose.destination.pose[..];
        GeneralizedMotion expected = playback_test_expected_endpoint(&fixture, keep[..]);
        GeneralizedMotion delta = anim::evaluate_generalized_playback_motion(
            playback: &fixture.view,
            assets: &fixture.assets,
            destination: fixture.pose.destination,
            state: &fixture.state,
            dt: 0.25,
        );
        assert(delta.twist == 0);
        for (uint axis = 0; axis < 3; axis++) {
            assert(math::abs(delta.translation[axis] - expected.translation[axis]) < PLAYBACK_TEST_MOTION_EPSILON);
            if (!extraction.translation_axes[axis]) assert(delta.translation[axis] == 0);
        }
        GeneralizedMotion supplied = {
            .translation = delta.translation + (double[<3>]){ 0.1, -0.2, 0.3 },
            .twist = 0.2,
        };
        RootMotionDelta emitted = {
            .translation = {
                (float)supplied.translation.x, (float)supplied.translation.y, (float)supplied.translation.z,
            },
            .rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.2f),
        };
        PlaybackTestMatrix external = playback_test_local({
            .position = emitted.translation,
            .rotation = emitted.rotation,
            .scale = { 1, 1, 1 },
        });
        anim::finish_generalized_playback(
            state: &fixture.state,
            playback: &fixture.view,
            destination: fixture.pose.destination,
            final_motion: supplied,
            published: &emitted,
        );
        playback_test_compare_worlds(
            fixture: &fixture,
            consumed: external,
            anchor: playback_test_identity(),
            keep: keep[..],
        );
    }
}
fn AnimationClip playback_test_owned_clip(GeneralizedPlaybackFixture* fixture) @local {
    AnimationClip clip = {
        .duration = 1,
        .tracks = alloc::new_array(mem, Track, fixture.tracks.len),
        .targets = alloc::new_array(mem, uint, fixture.targets.len),
    };
    clip.targets[..] = fixture.targets[..];
    foreach (index, track : fixture.tracks) {
        clip.tracks[index] = track;
        clip.tracks[index].times = alloc::new_array(mem, float, track.times.len);
        clip.tracks[index].times[..] = track.times[..];
        clip.tracks[index].values = alloc::new_array(mem, float, track.values.len);
        clip.tracks[index].values[..] = track.values[..];
    }
    return clip;
}

fn void test_animation_generalized_playback_animator_consumption_matches_keep_without_history_allocation() @test {
    for (uint mode = 0; mode < 3; mode++) {
        GeneralizedPlaybackFixture fixture;
        create_generalized_playback_fixture(&fixture, {
            .generalized = true,
            .translation_axes = { true, true, true },
            .up = (Vec3){ 1, 2, 3 }.normalize(),
            .twist = true,
        });
        defer destroy_generalized_playback_fixture(&fixture);
        AssetStore assets = asset::create_asset_store(mem, {
            .max_geometries = 1,
            .max_textures = 8,
            .max_materials = 1,
            .max_samplers = 8,
            .max_models = 1,
            .max_skeletons = 1,
            .max_clips = 1,
        });
        defer asset::destroy_asset_store(&assets);
        ModelTemplate template = { .nodes = alloc::new_array(mem, NodeTemplate, fixture.nodes.len) };
        template.nodes[..] = fixture.nodes[..];
        foreach (&node : template.nodes) node.name = node.name.copy(mem);
        ModelId model_id = assets.add_model_owned(&template)!!;
        AnimationClip clip = playback_test_owned_clip(&fixture);
        ClipId clip_id = assets.add_clip_owned(&clip)!!;
        PlaybackOwnerAllocationProbe allocator = { .backing = mem };
        Scene scene = scene::create_scene(&allocator, { .max_nodes = 20 });
        defer scene::destroy_scene(&scene);
        Node* kept_root = model::instantiate(&assets, &scene, model_id)!!;
        Node* extracted_root = model::instantiate(&assets, &scene, model_id)!!;
        Animator* kept = anim::add_animator(&scene, kept_root);
        Animator* extracted = anim::add_animator(&scene, extracted_root);
        extracted.root_node = 2;
        AnimationActionId kept_id = kept.play(&assets, clip_id)!!;
        AnimationActionId extracted_id = extracted.play(
            assets: &assets,
            clip: clip_id,
            desc: { .root_motion = RootMotion.EXTRACT, .extraction = fixture.state.extraction },
        )!!;
        kept.action(kept_id).loop = mode != 0;
        extracted.action(extracted_id).loop = mode != 0;
        kept.action(kept_id).speed = mode == 2 ? -1 : 1;
        extracted.action(extracted_id).speed = mode == 2 ? -1 : 1;
        assert(extracted.inertial_storage == null && extracted.pose_storage.scratch.derivative == null);
        Transform[5] endpoint;
        playback_test_raw_pose(&fixture, 1, endpoint[..]);
        PlaybackTestMatrix cycle = playback_test_motion(
            playback_test_expected_endpoint(&fixture, endpoint[..]), playback_test_up(&fixture));
        PlaybackTestMatrix reverse_cycle = playback_test_rigid_inverse(cycle);
        uint frames = mode == 0 ? 8 : 20;
        uint acquisitions = allocator.acquisitions;
        uint resizes = allocator.resizes;
        for (uint frame = 0; frame < frames; frame++) {
            anim::update(&assets, &scene, 0.125f);
            anim::apply_root_motion(extracted_root, extracted.root_motion);
            scene.update_world();
            int cycles = mode == 0 ? 0 : (int)math::floor((mode == 2 ? -1.0 : 1.0) * (double)(frame + 1) * 0.125);
            PlaybackTestMatrix anchor = playback_test_identity();
            for (int index = 0; index < math::abs(cycles); index++) {
                anchor = playback_test_product(anchor, cycles < 0 ? reverse_cycle : cycle);
            }
            ModelInstance* kept_instance = scene.get(kept_root, ModelInstance);
            ModelInstance* extracted_instance = scene.get(extracted_root, ModelInstance);
            Transform[5] keep;
            foreach (index, &local : keep) *local = kept_instance.present_node((uint)index).local;
            PlaybackTestMatrix[5] expected_worlds;
            playback_test_worlds(&fixture, keep[..], expected_worlds[..]);
            double[<3>][4] corners = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
            for (uint node = 0; node < 5; node++) {
                PlaybackTestMatrix expected = playback_test_product(anchor, expected_worlds[node]);
                Mat4 actual = extracted_instance.present_node(node).world;
                foreach (corner : corners) {
                    Vec3 point = { (float)corner.x, (float)corner.y, (float)corner.z };
                    Vec3 actual_point = maths::transform_point(actual, point);
                    double[<3>] observed = { actual_point.x, actual_point.y, actual_point.z };
                    assert((observed - playback_test_point(expected, corner)).length() <= PLAYBACK_TEST_POINT_EPSILON,
                        "mode=%s frame=%s node=%s", mode, frame, node);
                }
            }
            assert(extracted.inertial_storage == null && extracted.pose_storage.scratch.derivative == null);
            assert(allocator.acquisitions == acquisitions && allocator.resizes == resizes);
        }
        RootMotionDelta previous = extracted.root_motion;
        anim::update(&assets, &scene, 0);
        assert(extracted.root_motion.translation == (Vec3){});
        assert(extracted.root_motion.rotation.v == (Vec4){ 0, 0, 0, 1 });
        assert(previous.translation.length() > 0 || previous.rotation.v != (Vec4){ 0, 0, 0, 1 });
    }
}
fn void playback_test_owner_world_snapshot(Scene* scene, Node* owner, Mat4[] snapshot) @local {
    scene.update_world();
    ModelInstance* instance = scene.get(owner, ModelInstance);
    foreach (index, &world : snapshot) *world = instance.present_node((uint)index).world;
}

fn void playback_test_owner_world_unchanged(Scene* scene, Node* owner, Mat4[] expected) @local {
    scene.update_world();
    ModelInstance* instance = scene.get(owner, ModelInstance);
    Vec3[4] corners = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
    foreach (index, reference : expected) {
        Mat4 actual = instance.present_node((uint)index).world;
        foreach (corner : corners) {
            assert((maths::transform_point(actual, corner) - maths::transform_point(reference, corner)).length()
              <= (float)PLAYBACK_TEST_POINT_EPSILON);
        }
    }
}

fn void test_animation_generalized_playback_request_onset_after_consumption_preserves_displayed_worlds() @test {
    GeneralizedPlaybackFixture fixture;
    create_generalized_playback_fixture(&fixture, {
        .generalized = true,
        .translation_axes = { true, true, true },
        .up = (Vec3){ 1, 2, 3 }.normalize(),
        .twist = true,
    });
    defer destroy_generalized_playback_fixture(&fixture);
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 1,
        .max_textures = 8,
        .max_materials = 1,
        .max_samplers = 8,
        .max_models = 1,
        .max_skeletons = 1,
        .max_clips = 2,
    });
    defer asset::destroy_asset_store(&assets);
    ModelTemplate template = { .nodes = alloc::new_array(mem, NodeTemplate, fixture.nodes.len) };
    template.nodes[..] = fixture.nodes[..];
    foreach (&node : template.nodes) node.name = node.name.copy(mem);
    ModelId model_id = assets.add_model_owned(&template)!!;
    AnimationClip source_clip = playback_test_owned_clip(&fixture);
    AnimationClip target_clip = playback_test_owned_clip(&fixture);
    target_clip.tracks[0].values[..] = ((float[6]){ -0.2f, 0.4f, 0.3f, 0.1f, 0.7f, 0.6f })[..];
    target_clip.tracks[3].values[..] = ((float[6]){ -1, 0.5f, 1, -0.2f, 0.7f, 1.3f })[..];
    Quat initial = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.25f)
      .mul(quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.1f));
    Quat final = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.7f)
      .mul(quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.1f));
    target_clip.tracks[4].values[..] = ((float[8]){
        initial.v.x, initial.v.y, initial.v.z, initial.v.w, final.v.x, final.v.y, final.v.z, final.v.w,
    })[..];
    ClipId source_id = assets.add_clip_owned(&source_clip)!!;
    ClipId target_id = assets.add_clip_owned(&target_clip)!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = 12 });
    defer scene::destroy_scene(&scene);
    Node* owner = model::instantiate(&assets, &scene, model_id)!!;
    Animator* animator = anim::add_animator(&scene, owner, { .inertia_enabled = true });
    animator.root_node = 2;
    animator.play(
        assets: &assets,
        clip: source_id,
        desc: { .root_motion = RootMotion.EXTRACT, .extraction = fixture.state.extraction },
    )!!;
    for (uint frame = 0; frame < 3; frame++) {
        anim::update(&assets, &scene, 0.125f);
        anim::apply_root_motion(owner, animator.root_motion);
    }
    assert(owner.local.position.length() > 0.1f);
    Mat4[5] source_worlds;
    playback_test_owner_world_snapshot(&scene, owner, source_worlds[..]);
    double previous_dt = animator.inertial_storage.rows[0].control.previous_dt;
    AnimationTargetDesc[1] targets = { {
        .clip = target_id,
        .play = { .root_motion = RootMotion.EXTRACT, .extraction = fixture.state.extraction },
        .start_time = 0.375f,
        .speed = 1,
        .weight = 1,
        .loop = true,
        .playing = true,
    } };
    animator.inertialize(&assets, { .duration = 0.5f, .actions = targets[..] })!!;
    playback_test_owner_world_unchanged(&scene, owner, source_worlds[..]);
    for (uint zero_step = 0; zero_step < 3; zero_step++) {
        anim::update(&assets, &scene, 0);
        assert(animator.root_motion.translation == (Vec3){});
        assert(animator.root_motion.rotation.v == (Vec4){ 0, 0, 0, 1 });
        playback_test_owner_world_unchanged(&scene, owner, source_worlds[..]);
        assert(animator.inertial_storage.rows[0].control.previous_dt == previous_dt);
        assert(animator.inertial_storage.rows[0].control.elapsed == 0);
    }
    for (uint frame = 0; frame < 3; frame++) {
        anim::update(&assets, &scene, 0.0625f);
        anim::apply_root_motion(owner, animator.root_motion);
    }
    playback_test_owner_world_snapshot(&scene, owner, source_worlds[..]);
    targets[0].start_time = 0.625f;
    targets[0].speed = -1;
    animator.inertialize(&assets, { .duration = 0.25f, .actions = targets[..] })!!;
    playback_test_owner_world_unchanged(&scene, owner, source_worlds[..]);
    anim::update(&assets, &scene, 0);
    playback_test_owner_world_unchanged(&scene, owner, source_worlds[..]);
}
