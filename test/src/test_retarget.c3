module c3d::test::retarget;

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;
import std::math::quaternion;

const float TOLERANCE @local = 0.0005f;
const float PROFILE_POSITION_EPSILON @local = 1e-5f;
const float PROFILE_SUBKEY_EPSILON @local = 0.0005f;

struct Rig @local {
    NodeTemplate[] source_nodes;
    ModelTemplate  target;
    AnimationClip  clip;
}

struct ProfileRig @local {
    NodeTemplate[] source;
    ModelTemplate target;
    RetargetProfileDesc desc;
    AnimationClip clip;
}

fn bool close(float first, float second) @local {
    return math::abs(first - second) <= TOLERANCE;
}

fn Track make_track(uint target, TargetPath path, float[] times, float[] values) @local {
    Track track = {
        .target        = target,
        .path          = path,
        .interpolation = Interpolation.LINEAR,
        .times         = alloc::new_array(mem, float, times.len),
        .values        = alloc::new_array(mem, float, values.len),
    };
    track.times[..] = times[..];
    track.values[..] = values[..];
    return track;
}

fn NodeTemplate make_node(String name, int parent, Vec3 position) @local {
    return {
        .parent  = parent,
        .name    = name.copy(mem),
        .local   = { .position = position, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
        .visible = true,
        .layers  = 1,
    };
}

fn Rig make_rig() @local {
    Rig rig;
    rig.source_nodes = alloc::new_array(mem, NodeTemplate, 3);
    rig.source_nodes[0] = make_node("mixamorig:Hips", -1, { 0, 0.8f, 0 });
    rig.source_nodes[1] = make_node("mixamorig:Spine", 0, { 0, 0.1f, 0 });
    rig.source_nodes[2] = make_node("Prop", -1, { 0, 0, 0 });

    rig.target.nodes = alloc::new_array(mem, NodeTemplate, 4);
    rig.target.nodes[0] = make_node("Mesh", -1, { 0, 0, 0 });
    rig.target.nodes[1] = make_node("Hips", -1, { 0, 0.81f, 0 });
    rig.target.nodes[2] = make_node("Spine", 1, { 0, 0.1f, 0 });
    rig.target.nodes[3] = make_node("HeadTop_End", 2, { 0, 0.5f, 0 });

    float[3] three_times = { 0, 0.5f, 1 };
    float[2] two_times = { 0, 1 };
    float[9] hips_translation = { 0, 0.8f, 0, 0.5f, 0.85f, 0.2f, 1, 0.8f, 0.4f };
    float[8] rotations = { 0, 0, 0, 1, 0, 0.7071f, 0, 0.7071f };
    float[6] unit_scale = { 1, 1, 1, 1, 1, 1 };
    float[6] spine_translation = { 0, 0.1f, 0, 0, 0.1f, 0 };
    rig.clip = {
        .name     = "walk".copy(mem),
        .duration = 1,
        .tracks   = alloc::new_array(mem, Track, 5),
        .targets  = alloc::new_array(mem, uint, 2),
    };
    rig.clip.targets[0] = 0;
    rig.clip.targets[1] = 1;
    rig.clip.tracks[0] = make_track(0, TargetPath.TRANSLATION, three_times[..], hips_translation[..]);
    rig.clip.tracks[1] = make_track(0, TargetPath.ROTATION, two_times[..], rotations[..]);
    rig.clip.tracks[2] = make_track(0, TargetPath.SCALE, two_times[..], unit_scale[..]);
    rig.clip.tracks[3] = make_track(1, TargetPath.TRANSLATION, two_times[..], spine_translation[..]);
    rig.clip.tracks[4] = make_track(1, TargetPath.ROTATION, two_times[..], rotations[..]);
    return rig;
}

fn void destroy_rig(Rig* rig) @local {
    asset::free_clip(mem, &rig.clip);
    asset::free_model_template(mem, &rig.target);
    foreach (&node : rig.source_nodes) alloc::free(mem, node.name.ptr);
    alloc::free(mem, rig.source_nodes.ptr);
}

fn Track* track_of(AnimationClip* clip, uint template_index, TargetPath path) @local {
    foreach (&track : clip.tracks) {
        if (track.path == path && clip.targets[track.target] == template_index) return track;
    }
    return null;
}

fn void test_retarget_matches_prefixed_names_case_insensitively() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    AnimationClip result = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target)!!;
    defer asset::free_clip(mem, &result);
    assert(result.name == "walk" && result.duration == 1);
    assert(result.targets.len == 2 && result.targets[0] == 1 && result.targets[1] == 2);
    assert(track_of(&result, 1, TargetPath.ROTATION) != null && track_of(&result, 2, TargetPath.ROTATION) != null);
    Track* rotation = track_of(&result, 2, TargetPath.ROTATION);
    assert(rotation.times.len == 2 && close(rotation.values[5], 0.7071f));
}

fn void test_retarget_keeps_root_translation_only() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    AnimationClip result = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target)!!;
    defer asset::free_clip(mem, &result);
    assert(result.tracks.len == 4);
    assert(track_of(&result, 1, TargetPath.TRANSLATION) != null && track_of(&result, 1, TargetPath.SCALE) != null);
    assert(track_of(&result, 2, TargetPath.TRANSLATION) == null);

    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.copy_translations = true;
    AnimationClip full = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
    defer asset::free_clip(mem, &full);
    assert(full.tracks.len == 5 && track_of(&full, 2, TargetPath.TRANSLATION) != null);
}

fn void test_retarget_unmatched_source_faults_unless_partial() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    float[2] times = { 0, 1 };
    float[8] rotations = { 0, 0, 0, 1, 0, 0, 0, 1 };
    Track[] tracks = alloc::new_array(mem, Track, 6);
    tracks[:5] = rig.clip.tracks[..];
    tracks[5] = make_track(2, TargetPath.ROTATION, times[..], rotations[..]);
    alloc::free(mem, rig.clip.tracks.ptr);
    rig.clip.tracks = tracks;
    uint[] targets = alloc::new_array(mem, uint, 3);
    targets[0] = 0;
    targets[1] = 1;
    targets[2] = 2;
    alloc::free(mem, rig.clip.targets.ptr);
    rig.clip.targets = targets;

    if (catch excuse = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target)) {
        assert(excuse == c3d::ASSET_FORMAT_ERROR);
    } else {
        assert(false, "expected a fault");
    }
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.allow_partial = true;
    AnimationClip partial = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
    defer asset::free_clip(mem, &partial);
    assert(partial.tracks.len == 4 && partial.targets.len == 2);
}

fn void test_retarget_name_map_overrides_matching() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    float[2] times = { 0, 1 };
    float[8] rotations = { 0, 0, 0, 1, 0, 0, 0, 1 };
    Track[] tracks = alloc::new_array(mem, Track, 6);
    tracks[:5] = rig.clip.tracks[..];
    tracks[5] = make_track(2, TargetPath.ROTATION, times[..], rotations[..]);
    alloc::free(mem, rig.clip.tracks.ptr);
    rig.clip.tracks = tracks;
    uint[] targets = alloc::new_array(mem, uint, 3);
    targets[0] = 0;
    targets[1] = 1;
    targets[2] = 2;
    alloc::free(mem, rig.clip.targets.ptr);
    rig.clip.targets = targets;

    NameMapping[1] mapping = { { .source = "Prop", .target = "HeadTop_End" } };
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.name_map = mapping[..];
    AnimationClip result = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
    defer asset::free_clip(mem, &result);
    assert(result.tracks.len == 5 && track_of(&result, 3, TargetPath.ROTATION) != null);

    NameMapping[1] missing = { { .source = "Prop", .target = "Nowhere" } };
    options.name_map = missing[..];
    if (catch excuse = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)) {
        assert(excuse == c3d::ASSET_FORMAT_ERROR);
    } else {
        assert(false, "expected a fault");
    }
}

fn void test_retarget_strip_xz_pins_root_to_first_key() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.root_motion = RootMotion.STRIP_XZ;
    AnimationClip result = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
    defer asset::free_clip(mem, &result);
    Track* hips = track_of(&result, 1, TargetPath.TRANSLATION);
    assert(hips != null && hips.times.len == 3);
    float[9] expected = { 0, 0.8f, 0, 0, 0.85f, 0, 0, 0.8f, 0 };
    foreach (index, value : expected) assert(close(hips.values[index], value));
    assert(close(rig.clip.tracks[0].values[3], 0.5f));
}

fn void test_retarget_extract_moves_displacement_to_root_node() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.root_motion = RootMotion.EXTRACT;
    options.root_node = 0;
    AnimationClip result = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
    defer asset::free_clip(mem, &result);
    assert(result.tracks.len == 5);
    assert(result.targets.len == 3 && result.targets[0] == 1 && result.targets[1] == 0 && result.targets[2] == 2);
    Track* root = track_of(&result, 0, TargetPath.TRANSLATION);
    assert(root != null && root.interpolation == Interpolation.LINEAR && root.times.len == 3);
    float[9] expected_root = { 0, 0, 0, 0.5f, 0, 0.2f, 1, 0, 0.4f };
    foreach (index, value : expected_root) assert(close(root.values[index], value));
    Track* hips = track_of(&result, 1, TargetPath.TRANSLATION);
    assert(close(hips.values[3], 0) && close(hips.values[5], 0) && close(hips.values[4], 0.85f));
}

fn void test_retarget_extract_without_root_node_is_invalid_argument() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.root_motion = RootMotion.EXTRACT;
    if (catch excuse = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "expected a fault");
    }
}

fn void test_retarget_ambiguous_destination_name_faults() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    alloc::free(mem, rig.target.nodes[3].name.ptr);
    rig.target.nodes[3].name = "spine".copy(mem);
    if (catch excuse = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target)) {
        assert(excuse == c3d::ASSET_FORMAT_ERROR);
    } else {
        assert(false, "expected a fault");
    }
}

fn Track make_cubic_track(uint target, float[] times, float[] slots) @local {
    Track track = make_track(target, TargetPath.TRANSLATION, times, slots);
    track.interpolation = Interpolation.CUBIC_SPLINE;
    return track;
}

fn Vec3 sample_translation(Track* track, float time) @local {
    float[3] out;
    uint cursor;
    anim::sample_track(track, time, &cursor, out[..]);
    return { out[0], out[1], out[2] };
}

fn void test_retarget_step_hips_keep_step_and_pin_to_the_first_key() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    rig.clip.tracks[0].interpolation = Interpolation.STEP;
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.root_motion = RootMotion.EXTRACT;
    options.root_node = 0;
    AnimationClip result = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
    defer asset::free_clip(mem, &result);
    Track* hips = track_of(&result, 1, TargetPath.TRANSLATION);
    Track* root = track_of(&result, 0, TargetPath.TRANSLATION);
    assert(hips.interpolation == Interpolation.STEP && root.interpolation == Interpolation.STEP);
    Vec3 mid = sample_translation(hips, 0.75f);
    assert(close(mid.x, 0) && close(mid.z, 0) && close(mid.y, 0.85f));
    Vec3 root_mid = sample_translation(root, 0.75f);
    assert(close(root_mid.x, 0.5f) && close(root_mid.z, 0.2f) && close(root_mid.y, 0));
}

fn void test_retarget_cubic_hips_keep_values_and_zero_stripped_tangents() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    float[2] times = { 0, 2 };
    float[18] slots = {
        0, 0, 0,  0, 0.8f, 0,  1, 0.5f, 1,
        1, 0, 1,  2, 0.8f, 2,  0, 0, 0,
    };
    asset::free_clip(mem, &rig.clip);
    rig.clip = {
        .name     = "run".copy(mem),
        .duration = 2,
        .tracks   = alloc::new_array(mem, Track, 1),
        .targets  = alloc::new_array(mem, uint, 1),
    };
    rig.clip.targets[0] = 0;
    rig.clip.tracks[0] = make_cubic_track(0, times[..], slots[..]);
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.root_motion = RootMotion.EXTRACT;
    options.root_node = 0;
    AnimationClip result = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
    defer asset::free_clip(mem, &result);

    Track* hips = track_of(&result, 1, TargetPath.TRANSLATION);
    Track* root = track_of(&result, 0, TargetPath.TRANSLATION);
    assert(hips.interpolation == Interpolation.CUBIC_SPLINE && root.interpolation == Interpolation.CUBIC_SPLINE);
    assert(hips.values.len == 18 && root.values.len == 18);
    foreach (time : (float[3]){ 0.5f, 1, 1.5f }) {
        Vec3 pinned = sample_translation(hips, time);
        assert(close(pinned.x, 0) && close(pinned.z, 0));
        Vec3 moved = sample_translation(root, time);
        assert(close(moved.y, 0));
    }
    Vec3 end = sample_translation(root, 2);
    assert(close(end.x, 2) && close(end.z, 2));
    Vec3 hips_mid = sample_translation(hips, 1);
    Vec3 original_mid = sample_translation(&rig.clip.tracks[0], 1);
    assert(close(hips_mid.y, original_mid.y));
}

const float STRICT @local = 1e-5f;

fn Quat about(Vec3 axis, float degrees) @local {
    return quaternion::from_axis_angle{float}(axis, degrees * (float)math::PI / 180);
}

fn NodeTemplate make_rotated_node(String name, int parent, Vec3 position, Quat rotation) @local {
    NodeTemplate node = make_node(name, parent, position);
    node.local.rotation = rotation;
    return node;
}

fn Rig make_rotated_rig() @local {
    Quat rx = about({ 1, 0, 0 }, -90);
    Quat ry = about({ 0, 1, 0 }, 90);
    Quat ry30 = about({ 0, 1, 0 }, 30);
    Rig rig;
    rig.source_nodes = alloc::new_array(mem, NodeTemplate, 3);
    rig.source_nodes[0] = make_node("Hips", -1, { 0, 1, 0 });
    rig.source_nodes[1] = make_node("Spine", 0, { 0, 0.2f, 0 });
    rig.source_nodes[2] = make_node("Head", 1, { 0, 0.3f, 0 });

    rig.target.nodes = alloc::new_array(mem, NodeTemplate, 5);
    rig.target.nodes[0] = make_rotated_node("Root", -1, { 0, 0, 0 }, rx);
    rig.target.nodes[1] = make_rotated_node("Hips", 0, { 0, 0, 0.9f }, ry);
    rig.target.nodes[2] = make_rotated_node("Pelvis", 1, { 0, 0.1f, 0 }, rx);
    rig.target.nodes[3] = make_rotated_node("Spine", 2, { 0, 0.2f, 0 }, ry);
    rig.target.nodes[4] = make_rotated_node("Head", 3, { 0, 0.3f, 0 }, ry);

    float[2] times = { 0, 1 };
    float[8] spine_rotation = { 0, 0, 0, 1, ry30.i, ry30.j, ry30.k, ry30.l };
    float[6] hips_translation = { 0, 1, 0, 0.3f, 1.2f, 1 };
    float[6] spine_translation = { 0, 0.2f, 0, 0, 0.25f, 0 };
    rig.clip = {
        .name     = "sway".copy(mem),
        .duration = 1,
        .tracks   = alloc::new_array(mem, Track, 3),
        .targets  = alloc::new_array(mem, uint, 2),
    };
    rig.clip.targets[0] = 0;
    rig.clip.targets[1] = 1;
    rig.clip.tracks[0] = make_track(1, TargetPath.ROTATION, times[..], spine_rotation[..]);
    rig.clip.tracks[1] = make_track(0, TargetPath.TRANSLATION, times[..], hips_translation[..]);
    rig.clip.tracks[2] = make_track(1, TargetPath.TRANSLATION, times[..], spine_translation[..]);
    return rig;
}

fn RetargetOptions corrected(RootMotion root_motion = RootMotion.KEEP) @local {
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.rest_pose = RestPose.CORRECT;
    options.allow_partial = true;
    options.root_motion = root_motion;
    return options;
}

fn Quat sampled_rotation(AnimationClip* clip, ModelTemplate* target, uint node, float time) @local {
    Track* track = track_of(clip, node, TargetPath.ROTATION);
    if (!track) return target.nodes[node].local.rotation;
    float[4] out;
    uint cursor;
    anim::sample_track(track, time, &cursor, out[..]);
    return { .v = { out[0], out[1], out[2], out[3] } };
}

fn Vec3 sampled_position(AnimationClip* clip, ModelTemplate* target, uint node, float time) @local {
    Track* track = track_of(clip, node, TargetPath.TRANSLATION);
    if (!track) return target.nodes[node].local.position;
    return sample_translation(track, time);
}

fn Quat model_rotation(AnimationClip* clip, ModelTemplate* target, uint node, float time) @local {
    Quat rotation = sampled_rotation(clip, target, node, time);
    for (int parent = target.nodes[node].parent; parent >= 0; parent = target.nodes[parent].parent) {
        rotation = sampled_rotation(clip, target, (uint)parent, time).mul(rotation);
    }
    return rotation;
}

fn Vec3 model_position(AnimationClip* clip, ModelTemplate* target, uint node, float time) @local {
    Vec3 position = sampled_position(clip, target, node, time);
    for (int parent = target.nodes[node].parent; parent >= 0; parent = target.nodes[parent].parent) {
        position = sampled_rotation(clip, target, (uint)parent, time).rotate_vec3(position)
            + sampled_position(clip, target, (uint)parent, time);
    }
    return position;
}

fn Vec4 rotation_key(Track* track, usz key) @local {
    float[] value = track.values[key * 4:4];
    return { value[0], value[1], value[2], value[3] };
}

fn bool same_rotation(Quat first, Quat second) @local => math::abs(first.v.dot(second.v)) >= 1 - STRICT;

fn bool near_position(Vec3 first, Vec3 second) @local => (first - second).length() <= STRICT * 10;

fn AnimationClip retarget_rotated(Rig* rig, RetargetOptions options) @local {
    return retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
}

fn void test_rest_correction_reproduces_the_target_rest_from_a_source_rest_key() @test {
    Rig rig = make_rotated_rig();
    defer destroy_rig(&rig);
    AnimationClip result = retarget_rotated(&rig, corrected());
    defer asset::free_clip(mem, &result);

    foreach (uint node : (uint[3]){ 1, 3, 4 }) {
        assert(same_rotation(sampled_rotation(&result, &rig.target, node, 0), rig.target.nodes[node].local.rotation));
    }
    assert(near_position(sampled_position(&result, &rig.target, 1, 0), rig.target.nodes[1].local.position));
}

fn void test_rest_correction_transfers_the_model_space_delta() @test {
    Rig rig = make_rotated_rig();
    defer destroy_rig(&rig);
    AnimationClip result = retarget_rotated(&rig, corrected());
    defer asset::free_clip(mem, &result);

    Quat expected = about({ 0, 1, 0 }, 30).mul(retarget::rest_world_rotation(rig.target.nodes, 3));
    assert(same_rotation(model_rotation(&result, &rig.target, 3, 1), expected));
    foreach (&track : result.tracks) {
        if (track.path != TargetPath.ROTATION) continue;
        for (usz key = 1; key < track.times.len; key++) {
            assert(rotation_key(track, key - 1).dot(rotation_key(track, key)) >= 0);
        }
    }
}

fn void test_rest_correction_keeps_unmapped_joints_at_rest() @test {
    Rig rig = make_rotated_rig();
    defer destroy_rig(&rig);
    AnimationClip result = retarget_rotated(&rig, corrected());
    defer asset::free_clip(mem, &result);

    foreach (target : result.targets) assert(target != 0 && target != 2);
}

fn void test_rest_correction_bakes_linear_keys_at_the_rate() @test {
    Rig rig = make_rotated_rig();
    defer destroy_rig(&rig);
    RetargetOptions options = corrected();

    AnimationClip thirty = retarget_rotated(&rig, options);
    defer asset::free_clip(mem, &thirty);
    Track* spine = track_of(&thirty, 3, TargetPath.ROTATION);
    assert(spine.times.len == 31);
    foreach (&track : thirty.tracks) assert(track.interpolation == Interpolation.LINEAR);

    options.bake_rate = 10;
    AnimationClip ten = retarget_rotated(&rig, options);
    defer asset::free_clip(mem, &ten);
    assert(track_of(&ten, 3, TargetPath.ROTATION).times.len == 11);

    options.bake_rate = 30;
    float duration = 31.0f / 30.0f + 1e-6f;
    rig.clip.duration = duration;
    AnimationClip odd = retarget_rotated(&rig, options);
    defer asset::free_clip(mem, &odd);
    float[] times = track_of(&odd, 3, TargetPath.ROTATION).times;
    assert(times.len == 32);
    for (usz key = 1; key < times.len; key++) assert(times[key] > times[key - 1]);
    assert(times[^1] == duration);

    rig.clip.duration = 0;
    AnimationClip still = retarget_rotated(&rig, options);
    defer asset::free_clip(mem, &still);
    Track* single = track_of(&still, 3, TargetPath.ROTATION);
    assert(single.times.len == 1 && single.times[0] == 0);
}

fn void test_rest_correction_never_emits_non_root_translations() @test {
    Rig rig = make_rotated_rig();
    defer destroy_rig(&rig);
    AnimationClip result = retarget_rotated(&rig, corrected());
    defer asset::free_clip(mem, &result);

    assert(track_of(&result, 3, TargetPath.TRANSLATION) == null);
    assert(track_of(&result, 1, TargetPath.TRANSLATION) != null);
}

fn void test_rest_correction_moves_the_root_in_model_space() @test {
    Rig rig = make_rotated_rig();
    defer destroy_rig(&rig);
    RetargetOptions options = corrected();
    options.root_translation_scale = 0.5f;
    AnimationClip result = retarget_rotated(&rig, options);
    defer asset::free_clip(mem, &result);

    Vec3 moved = model_position(&result, &rig.target, 1, 1) - retarget::rest_world_position(rig.target.nodes, 1);
    assert(near_position(moved, { 0.15f, 0.1f, 0.5f }));
}

fn void test_rest_correction_strip_xz_holds_the_horizontal_model_position() @test {
    Rig rig = make_rotated_rig();
    defer destroy_rig(&rig);
    AnimationClip result = retarget_rotated(&rig, corrected(RootMotion.STRIP_XZ));
    defer asset::free_clip(mem, &result);

    Vec3 start = model_position(&result, &rig.target, 1, 0);
    Vec3 end = model_position(&result, &rig.target, 1, 1);
    assert(near_position({ end.x, 0, end.z }, { start.x, 0, start.z }));
    assert(math::abs(end.y - start.y - 0.2f) <= STRICT * 10);
}

fn void test_rest_correction_extract_moves_the_horizontal_to_the_root_node() @test {
    Rig rig = make_rotated_rig();
    defer destroy_rig(&rig);
    RetargetOptions options = corrected(RootMotion.EXTRACT);
    options.root_node = 0;
    AnimationClip result = retarget_rotated(&rig, options);
    defer asset::free_clip(mem, &result);

    Vec3 root_moved = model_position(&result, &rig.target, 0, 1) - model_position(&result, &rig.target, 0, 0);
    assert(near_position(root_moved, { 0.3f, 0, 1 }));
    Vec3 hips_start = model_position(&result, &rig.target, 1, 0) - model_position(&result, &rig.target, 0, 0);
    Vec3 hips_end = model_position(&result, &rig.target, 1, 1) - model_position(&result, &rig.target, 0, 1);
    assert(near_position(hips_end - hips_start, { 0, 0.2f, 0 }));
}

fn void test_rest_correction_faults_on_an_unresolved_tracked_node() @test {
    Rig rig = make_rotated_rig();
    defer destroy_rig(&rig);
    NodeTemplate[] nodes = alloc::new_array(mem, NodeTemplate, 4);
    nodes[:3] = rig.source_nodes[..];
    nodes[3] = make_node("Tail", 0, { 0, -0.1f, 0 });
    alloc::free(mem, rig.source_nodes.ptr);
    rig.source_nodes = nodes;
    uint[] targets = alloc::new_array(mem, uint, 3);
    targets[:2] = rig.clip.targets[..];
    targets[2] = 3;
    alloc::free(mem, rig.clip.targets.ptr);
    rig.clip.targets = targets;
    rig.clip.tracks[2].target = 2;

    RetargetOptions options = corrected();
    options.allow_partial = false;
    if (catch excuse = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)) {
        assert(excuse == c3d::ASSET_FORMAT_ERROR);
    } else {
        assert(false);
    }
    AnimationClip partial = retarget_rotated(&rig, corrected());
    defer asset::free_clip(mem, &partial);
    foreach (target : partial.targets) assert(target < rig.target.nodes.len);
    assert(partial.tracks.len == 4);
}

fn void test_rest_correction_faults_on_two_animated_roots() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    alloc::free(mem, rig.source_nodes[2].name.ptr);
    rig.source_nodes[2].name = "Mesh".copy(mem);
    rig.clip.targets[1] = 2;
    RetargetOptions options = corrected();
    if (catch excuse = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)) {
        assert(excuse == c3d::ASSET_FORMAT_ERROR);
        return;
    }
    assert(false);
}

fn void test_root_translation_scale_scales_hip_keys() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    AnimationClip full = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
    defer asset::free_clip(mem, &full);
    options.root_translation_scale = 0.5f;
    AnimationClip half = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
    defer asset::free_clip(mem, &half);
    Track* full_hips = track_of(&full, 1, TargetPath.TRANSLATION);
    Track* half_hips = track_of(&half, 1, TargetPath.TRANSLATION);
    foreach (index, value : full_hips.values) assert(close(half_hips.values[index], value * 0.5f));

    options.root_motion = RootMotion.EXTRACT;
    options.root_node = 0;
    AnimationClip extracted = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, options)!!;
    defer asset::free_clip(mem, &extracted);
    Vec3 travel = sample_translation(track_of(&extracted, 0, TargetPath.TRANSLATION), 1);
    assert(close(travel.x, 0.5f) && close(travel.z, 0.2f));
}

fn void test_default_fields_at_zero_keep_copy_output() @test {
    Rig rig = make_rig();
    defer destroy_rig(&rig);
    RetargetOptions literal = { .root_motion = RootMotion.STRIP_XZ, .root_node = anim::NO_ROOT_NODE };
    RetargetOptions defaults = retarget::RETARGET_OPTIONS_DEFAULT;
    defaults.root_motion = RootMotion.STRIP_XZ;
    AnimationClip first = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, literal)!!;
    defer asset::free_clip(mem, &first);
    AnimationClip second = retarget::retarget_by_name(mem, &rig.clip, rig.source_nodes, &rig.target, defaults)!!;
    defer asset::free_clip(mem, &second);
    assert(first.tracks.len == second.tracks.len);
    foreach (index, &track : first.tracks) {
        assert(track.values.len == second.tracks[index].values.len);
        foreach (value_index, value : track.values) assert(value == second.tracks[index].values[value_index]);
    }
}

fn void test_rest_world_helpers_compose_parents_first() @test {
    Rig rig = make_rotated_rig();
    defer destroy_rig(&rig);
    Quat rx = about({ 1, 0, 0 }, -90);
    Quat ry = about({ 0, 1, 0 }, 90);
    assert(same_rotation(retarget::rest_world_rotation(rig.target.nodes, 3), rx.mul(ry).mul(rx).mul(ry)));
    assert(near_position(retarget::rest_world_position(rig.target.nodes, 1), { 0, 0.9f, 0 }));
}

fn Quat profile_turn(Vec3 axis, float degrees) @local {
    return quaternion::from_axis_angle{float}(axis, degrees * (float)math::PI / 180);
}

fn Transform profile_transform(
    Vec3 position = {},
    Quat rotation = quaternion::IDENTITY,
    float scale = 1,
) @local {
    return { .position = position, .rotation = rotation, .scale = { scale, scale, scale } };
}

fn ProfileRig profile_rig(uint source_count, uint target_count) @local {
    ProfileRig rig = {
        .source = alloc::new_array(tmem, NodeTemplate, source_count),
        .target = { .nodes = alloc::new_array(tmem, NodeTemplate, target_count) },
        .desc = retarget::RETARGET_PROFILE_DESC_DEFAULT,
        .clip = { .name = "authored_motion", .duration = 1 },
    };

    rig.desc.mapping_mode = ProfileMappingMode.BY_INDEX;
    rig.desc.source_calibration = alloc::new_array(tmem, Quat, source_count);
    rig.desc.target_calibration = alloc::new_array(tmem, Quat, target_count);
    rig.desc.source_calibration[..] = maths::TRANSFORM_IDENTITY.rotation;
    rig.desc.target_calibration[..] = maths::TRANSFORM_IDENTITY.rotation;

    foreach (&node : rig.source) *node = {
        .parent = -1, .name = "joint", .local = maths::TRANSFORM_IDENTITY, .visible = true,
    };

    foreach (&node : rig.target.nodes) *node = {
        .parent = -1, .name = "joint", .local = maths::TRANSFORM_IDENTITY, .visible = true,
    };

    return rig;
}

fn void profile_map(ProfileRig* rig, NodeIndexMapping[] mappings) @local {
    rig.desc.index_map = alloc::new_array(tmem, NodeIndexMapping, mappings.len);
    rig.desc.index_map[..] = mappings[..];
}

fn Track profile_input_track(
    uint target,
    TargetPath path,
    float[] times,
    float[] values,
    Interpolation interpolation = Interpolation.LINEAR,
) @local {
    Track track = {
        .target = target,
        .path = path,
        .interpolation = interpolation,
        .times = alloc::new_array(tmem, float, times.len),
        .values = alloc::new_array(tmem, float, values.len),
    };

    track.times[..] = times[..];
    track.values[..] = values[..];

    return track;
}

fn void profile_clip(ProfileRig* rig, uint[] targets, Track[] tracks) @local {
    rig.clip.targets = alloc::new_array(tmem, uint, targets.len);
    rig.clip.targets[..] = targets[..];
    rig.clip.tracks = alloc::new_array(tmem, Track, tracks.len);
    rig.clip.tracks[..] = tracks[..];
}

fn RetargetProfile profile_prepare(ProfileRig* rig) @local {
    return retarget::create_retarget_profile(
        allocator: mem,
        source_nodes: rig.source,
        target: &rig.target,
        desc: rig.desc,
    )!!;
}

fn AnimationClip profile_bake(
    ProfileRig* rig,
    RetargetProfile* profile,
    RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT,
) @local {
    return retarget::retarget_with_profile(
        allocator: mem,
        source: &rig.clip,
        source_nodes: rig.source,
        target: &rig.target,
        profile: profile,
        options: options,
    )!!;
}

fn void profile_expect_creation_fault(ProfileRig* rig, fault expected) @local {
    assert(@catch(retarget::create_retarget_profile(
        allocator: mem,
        source_nodes: rig.source,
        target: &rig.target,
        desc: rig.desc,
    )) == expected);
}

fn void profile_expect_bake_fault(
    ProfileRig* rig,
    RetargetProfile* profile,
    fault expected,
    RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT,
) @local {
    assert(@catch(retarget::retarget_with_profile(
        allocator: mem,
        source: &rig.clip,
        source_nodes: rig.source,
        target: &rig.target,
        profile: profile,
        options: options,
    )) == expected);
}

fn Track* profile_output_track(AnimationClip* clip, uint node, TargetPath path) @local {
    foreach (&track : clip.tracks) {
        if (clip.targets[track.target] == node && track.path == path) return track;
    }

    return null;
}

fn Transform profile_sample_node(
    AnimationClip* clip,
    ModelTemplate* target,
    uint node,
    float time,
) @local {
    Transform local = target.nodes[node].local;

    foreach (&track : clip.tracks) {
        if (clip.targets[track.target] != node || track.path == TargetPath.MORPH_WEIGHTS) continue;
        float[4] sample;
        uint cursor;
        anim::sample_track(
            track: track,
            time: time,
            cursor: &cursor,
            out: sample[:track.stride()],
        );

        switch (track.path) {
            case TRANSLATION: local.position = { sample[0], sample[1], sample[2] };
            case ROTATION: local.rotation = { .v = { sample[0], sample[1], sample[2], sample[3] } };
            case SCALE: local.scale = { sample[0], sample[1], sample[2] };
            case MORPH_WEIGHTS: break;
        }
    }

    return local;
}

fn Mat4 profile_sample_world(
    AnimationClip* clip,
    ModelTemplate* target,
    uint node,
    float time,
) @local {
    Mat4 matrix = profile_sample_node(
        clip: clip,
        target: target,
        node: node,
        time: time,
    ).to_mat4();

    for (int parent = target.nodes[node].parent; parent >= 0; parent = target.nodes[parent].parent) {
        matrix = profile_sample_node(
            clip: clip,
            target: target,
            node: (uint)parent,
            time: time,
        ).to_mat4().mul(matrix);
    }

    return matrix;
}

fn void profile_expect_position(Mat4 world, Vec3 expected, float epsilon = PROFILE_POSITION_EPSILON) @local {
    assert((maths::translation(world) - expected).length() <= epsilon);
}

fn void profile_expect_rotation(Mat4 world, Quat expected, float radians = 0.0001f) @local {
    Quat actual = maths::transform_from_mat4(world).rotation.normalize();
    double dot;
    double actual_length;
    double expected_length;

    foreach (index, component : actual.v) {
        dot += (double)component * expected.v[index];
        actual_length += (double)component * component;
        expected_length += (double)expected.v[index] * expected.v[index];
    }

    dot = math::abs(dot) / math::sqrt(actual_length * expected_length);
    double angle = 2 * math::acos(math::clamp(dot, 0.0, 1.0));
    assert(angle <= radians);
}

fn void profile_expect_scale(Mat4 world, float expected) @local {
    Transform transform = maths::transform_from_mat4(world);
    assert((transform.scale - (Vec3){ expected, expected, expected }).length() <= PROFILE_POSITION_EPSILON);
}

fn double profile_source_angle(float degrees, double fraction) @local {
    double half_angle = (double)degrees * math::PI / 360;
    double sine = fraction * math::sin(half_angle);
    double cosine = 1 - fraction + fraction * math::cos(half_angle);

    return 360 * math::atan2(sine, cosine) / math::PI;
}

fn void profile_expect_anatomical_pose(AnimationClip* clip, ProfileRig* rig, float time) @local {
    float degrees = (float)profile_source_angle(30, (double)time);
    Quat expected = profile_turn({ 0, 0, 1 }, degrees);
    double angle = (double)degrees * math::PI / 180;

    Mat4 forearm = profile_sample_world(
        clip: clip,
        target: &rig.target,
        node: 1,
        time: time,
    );
    Mat4 wrist = profile_sample_world(
        clip: clip,
        target: &rig.target,
        node: 2,
        time: time,
    );

    profile_expect_position(forearm, { 2, 0, 0 });
    profile_expect_rotation(forearm, expected);
    profile_expect_position(wrist, { 2 + (float)(2 * math::cos(angle)), (float)(2 * math::sin(angle)), 0 });
    profile_expect_rotation(wrist, expected);
    profile_expect_scale(forearm, 1);
    profile_expect_scale(wrist, 1);
}

fn void profile_expect_facing_pose(
    AnimationClip* clip,
    ProfileRig* rig,
    float yaw,
    float time,
) @local {
    float degrees = (float)profile_source_angle(30, (double)time);
    double facing = ((double)yaw + 20) * math::PI / 180;
    double facing_sine = math::sin(facing);
    double facing_cosine = math::cos(facing);
    Quat target_calibration = profile_turn({ 0, 1, 0 }, 90).mul(profile_turn({ 0, 0, 1 }, -45));
    Quat expected = profile_turn({ (float)facing_cosine, 0, -(float)facing_sine }, degrees)
      .mul(target_calibration);
    double angle = (double)degrees * math::PI / 180;
    double sine = math::sin(angle);
    double cosine = math::cos(angle);
    double length = math::sqrt(2.0);

    Mat4 child = profile_sample_world(
        clip: clip,
        target: &rig.target,
        node: 1,
        time: time,
    );
    Mat4 tip = profile_sample_world(
        clip: clip,
        target: &rig.target,
        node: 2,
        time: time,
    );

    profile_expect_position(child, { 3, 2, -1 });
    profile_expect_rotation(child, expected);
    profile_expect_position(tip, {
        3 + (float)(length * facing_sine * (-sine + facing_cosine * (1 - cosine))),
        2 + (float)(length * (-cosine + facing_cosine * sine)),
        -1 + (float)(length * (-cosine - facing_cosine * sine - facing_sine * facing_sine * (1 - cosine))),
    });
    profile_expect_rotation(tip, expected);
    profile_expect_scale(child, 1);
    profile_expect_scale(tip, 1);
}

fn ProfileRig profile_ancestor_rig() @local {
    ProfileRig rig = profile_rig(3, 3);
    rig.source[0].local = profile_transform({ 1, 2, 3 }, quaternion::IDENTITY, 2);

    rig.source[1].parent = 0;
    rig.source[1].local = profile_transform({ 1, 0, 0 }, quaternion::IDENTITY, 0.5f);

    rig.source[2].parent = 1;
    rig.source[2].local = profile_transform({ 0, 1, 0 }, quaternion::IDENTITY, 3);

    rig.target.nodes[0].local = profile_transform({ -2, 1, 4 }, profile_turn({ 0, 0, 1 }, 90), 2);

    rig.target.nodes[1].parent = 0;
    rig.target.nodes[1].local = profile_transform({ 1, -2.5f, -0.5f }, profile_turn({ 0, 0, 1 }, -90), 1.5f);

    rig.target.nodes[2].parent = 1;
    rig.target.nodes[2].local.position = { 0, 0, 1 };
    rig.desc.target_calibration[0] = rig.target.nodes[0].local.rotation;
    rig.desc.target_calibration[1] = rig.target.nodes[1].local.rotation;
    profile_map(&rig, (NodeIndexMapping[2]){
        { .source_node = 1, .target_node = 0 }, { .source_node = 2, .target_node = 1 },
    }[..]);
    rig.desc.source_motion_node = 2;
    rig.desc.target_motion_node = 1;
    rig.clip.duration = 3;
    rig.clip.targets = alloc::new_array(tmem, uint, 3);
    rig.clip.targets[..] = (uint[3]){ 0, 1, 2 }[..];
    rig.clip.tracks = alloc::new_array(tmem, Track, 5);
    Quat yaw = profile_turn({ 0, 1, 0 }, 90);
    Quat pitch = profile_turn({ 1, 0, 0 }, 90);
    Quat roll = profile_turn({ 0, 0, 1 }, 90);
    Quat[3] turns = { yaw, pitch, roll };

    foreach (uint index, turn : turns) rig.clip.tracks[index] = profile_input_track(
        target: index,
        path: TargetPath.ROTATION,
        times: (float[2]){ 0, 3 }[..],
        values: (float[8]){ 0, 0, 0, 1, turn.v.x, turn.v.y, turn.v.z, turn.v.w }[..],
    );
    rig.clip.tracks[3] = profile_input_track(
        target: 0,
        path: TargetPath.SCALE,
        times: (float[2]){ 0, 3 }[..],
        values: (float[6]){ 2, 2, 2, 4, 4, 4 }[..],
    );
    rig.clip.tracks[4] = profile_input_track(
        target: 1,
        path: TargetPath.SCALE,
        times: (float[2]){ 0, 3 }[..],
        values: (float[6]){ 0.5f, 0.5f, 0.5f, 0.25f, 0.25f, 0.25f }[..],
    );

    return rig;
}

fn ProfileRig profile_carrier_rig() @local {
    ProfileRig rig = profile_rig(2, 5);
    rig.source[1].parent = 0;

    rig.target.nodes[0].local = profile_transform({ 1, 0, 2 }, profile_turn({ 0, 1, 0 }, 90), 2);

    rig.target.nodes[1].parent = 0;
    rig.target.nodes[1].local = profile_transform({ 1, 2, 0 }, profile_turn({ 0, 0, 1 }, 90), 0.5f);

    rig.target.nodes[2].parent = 0;
    rig.target.nodes[2].local.position = { -1, 0, 2 };

    rig.target.nodes[3].parent = 1;
    rig.target.nodes[3].local.position = { 0, 1, 0 };

    rig.target.nodes[4].parent = 1;

    foreach (index, &node : rig.target.nodes) rig.desc.target_calibration[index] = node.local.rotation;
    profile_map(&rig, (NodeIndexMapping[2]){
        { .source_node = 0, .target_node = 1 }, { .source_node = 1, .target_node = 4 },
    }[..]);
    rig.desc.source_motion_node = 1;
    rig.desc.target_motion_node = 4;
    rig.desc.target_carrier = 0;
    rig.target.meshes = alloc::new_array(tmem, ModelMesh, 1);
    rig.target.meshes[0].node = 2;
    rig.target.skins = alloc::new_array(tmem, ModelSkin, 1);
    uint[] joints = alloc::new_array(tmem, uint, 2);
    joints[..] = (uint[2]){ 1, 4 }[..];
    rig.target.skins[0] = { .mesh_node = 2, .joint_nodes = joints };
    profile_clip(&rig, (uint[1]){ 1 }[..], (Track[1]){
        profile_input_track(
            target: 0,
            path: TargetPath.TRANSLATION,
            times: (float[2]){ 0, 1 }[..],
            values: (float[6]){ 0, 0, 0, 0.5f, 0, -0.25f }[..],
        ),
    }[..]);

    return rig;
}

fn ProfileRig profile_forest_rig() @local {
    ProfileRig rig = profile_rig(1, 2);
    rig.source[0].local.position = { 0, 2, 0 };

    rig.target.nodes[0].local = profile_transform({ 2, 1, -3 }, profile_turn({ 1, 0, 0 }, 30));

    rig.target.nodes[1].local = profile_transform({ -1, 1, 2 }, profile_turn({ 0, 1, 0 }, 37), 0.5f);
    rig.desc.target_calibration[0] = rig.target.nodes[0].local.rotation;
    rig.desc.facing = profile_turn({ 0, 1, 0 }, 90).to_matrix();
    rig.desc.source_motion_node = 0;
    rig.desc.target_motion_node = 0;
    profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
    Quat turn = profile_turn({ 0, 1, 0 }, 90);
    profile_clip(&rig, (uint[1]){ 0 }[..], (Track[2]){
        profile_input_track(
            target: 0,
            path: TargetPath.TRANSLATION,
            times: (float[2]){ 0, 1 }[..],
            values: (float[6]){ 0, 2, 0, 1, 2.5f, 3 }[..],
        ),
        profile_input_track(
            target: 0,
            path: TargetPath.ROTATION,
            times: (float[2]){ 0, 1 }[..],
            values: (float[8]){ 0, 0, 0, 1, turn.v.x, turn.v.y, turn.v.z, turn.v.w }[..],
        ),
    }[..]);

    return rig;
}

fn ProfileRig profile_turning_carrier_rig(float degrees, float facing) @local {
    ProfileRig rig = profile_rig(3, 7);
    rig.source[0].name = "source_hips";
    rig.source[0].local.rotation = profile_turn({ 0, 1, 0 }, 20);
    rig.desc.source_calibration[0] = rig.source[0].local.rotation;
    rig.source[1].parent = 0;
    rig.source[1].name = "source_leaf";
    rig.source[1].local.position = { 1, 0, 0 };
    rig.source[2].name = "source_prop";

    rig.target.nodes[0].name = "static_ancestor";
    rig.target.nodes[0].local = profile_transform({}, profile_turn({ 0, 1, 0 }, 30), 3);

    rig.target.nodes[1].parent = 0;
    rig.target.nodes[1].name = "carrier";
    rig.target.nodes[1].local = profile_transform({ 1, 0, 2 }, profile_turn({ 0, 1, 0 }, 90), 2);

    rig.target.nodes[2].parent = 1;
    rig.target.nodes[2].name = "hips";
    rig.target.nodes[2].local = profile_transform({ 0.5f, 1, 0 }, profile_turn({ 0, 0, 1 }, 90), 0.5f);

    rig.target.nodes[3].parent = 1;
    rig.target.nodes[3].name = "unmapped_branch";
    rig.target.nodes[3].local.position = { -0.25f, 0, 0.25f };

    rig.target.nodes[4].parent = 2;
    rig.target.nodes[4].name = "unmapped_tip";
    rig.target.nodes[4].local.position = { 0, 0.5f, 0 };

    rig.target.nodes[5].parent = 2;
    rig.target.nodes[5].name = "mapped_leaf";
    rig.target.nodes[5].local.position = { 0, 1, 0 };

    rig.target.nodes[6].parent = 1;
    rig.target.nodes[6].name = "mapped_sibling";
    rig.target.nodes[6].local.position = { 0.25f, 0, 0 };

    foreach (index, &node : rig.target.nodes) rig.desc.target_calibration[index] = node.local.rotation;

    profile_map(&rig, (NodeIndexMapping[3]){
        { .source_node = 0, .target_node = 2 }, { .source_node = 1, .target_node = 5 },
        { .source_node = 2, .target_node = 6 },
    }[..]);

    rig.desc.source_motion_node = 0;
    rig.desc.target_motion_node = 2;
    rig.desc.target_carrier = 1;
    rig.desc.facing = profile_turn({ 0, 1, 0 }, facing).to_matrix();

    rig.clip.duration = degrees / 90;
    uint keys = (uint)rig.clip.duration + 1;
    float[] times = alloc::new_array(tmem, float, keys);
    float[] translations = alloc::new_array(tmem, float, (sz)keys * 3);
    float[] rotations = alloc::new_array(tmem, float, (sz)keys * 4);

    for (uint key = 0; key < keys; key++) {
        times[key] = (float)key;
        float phase = (float)key / rig.clip.duration;
        translations[(usz)key * 3] = 0.5f * phase;
        translations[(usz)key * 3 + 2] = -0.25f * phase;
        Quat rotation = profile_turn({ 0, 1, 0 }, 20 + 90.0f * key);

        foreach (usz component, value : rotation.v) rotations[(usz)key * 4 + component] = value;
    }

    profile_clip(&rig, (uint[1]){ 0 }[..], (Track[2]){
        profile_input_track(
            target: 0,
            path: TargetPath.TRANSLATION,
            times: times,
            values: translations,
        ),
        profile_input_track(
            target: 0,
            path: TargetPath.ROTATION,
            times: times,
            values: rotations,
        ),
    }[..]);

    return rig;
}

fn Vec3 profile_yaw_vector(Vec3 value, double degrees) @local {
    double angle = degrees * math::PI / 180;
    double sine = math::sin(angle);
    double cosine = math::cos(angle);

    return {
        (float)(cosine * value.x + sine * value.z),
        value.y,
        (float)(-sine * value.x + cosine * value.z),
    };
}

fn void profile_expect_turning_pose(
    AnimationClip* clip,
    ProfileRig* rig,
    float facing,
    float time,
    RootMotion mode,
) @local {
    Vec3 reference = profile_yaw_vector({ 3, 0, 6 }, 30);
    double phase = (double)time / rig.clip.duration;
    Vec3 horizontal = profile_yaw_vector({ (float)(0.5 * phase), 0, (float)(-0.25 * phase) }, facing);
    float degrees = 90 * time;
    Quat carrier_rotation = profile_turn({ 0, 1, 0 }, 120);
    Quat motion_rotation = profile_turn({ 0, 1, 0 }, degrees).mul(carrier_rotation)
      .mul(profile_turn({ 0, 0, 1 }, 90));
    Vec3 motion_reference = reference + profile_yaw_vector({ 3, 6, 0 }, 120);
    bool extract = mode == RootMotion.EXTRACT;
    Vec3 carrier_position = extract ? reference + horizontal : reference;
    Quat carrier_facing = extract ? profile_turn({ 0, 1, 0 }, degrees).mul(carrier_rotation) : carrier_rotation;
    double carried_yaw = extract ? 120 + (double)degrees : 120;
    Vec3[5] positions = {
        motion_reference + horizontal,
        carrier_position + profile_yaw_vector({ -1.5f, 0, 1.5f }, carried_yaw),
        motion_reference + horizontal + profile_yaw_vector({ -1.5f, 0, 0 }, 120 + (double)degrees),
        motion_reference + horizontal + profile_yaw_vector({ -3, 0, 0 }, 120 + (double)degrees),
        carrier_position + profile_yaw_vector({ 1.5f, 0, 0 }, carried_yaw),
    };

    foreach (uint offset, position : positions) {
        uint node = offset + 2;
        bool carried = node == 3 || node == 6;
        if (mode == RootMotion.STRIP_XZ && !carried) position -= horizontal;
        Mat4 world = profile_sample_world(
            clip: clip,
            target: &rig.target,
            node: node,
            time: time,
        );
        profile_expect_position(world, position);
        profile_expect_rotation(world, carried ? carrier_facing : motion_rotation);
        profile_expect_scale(world, carried ? 6 : 3);
    }

    Mat4 carrier = profile_sample_world(
        clip: clip,
        target: &rig.target,
        node: 1,
        time: time,
    );
    profile_expect_position(carrier, carrier_position);
    profile_expect_rotation(carrier, carrier_facing);
    profile_expect_scale(carrier, 6);
}

fn void profile_check_turning_carrier_runtime(bool root_yaw) @local {
    ProfileRig rig = profile_turning_carrier_rig(90, 37);
    RetargetProfile profile = profile_prepare(&rig);

    RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
    AnimationClip keep = profile_bake(&rig, &profile, options);
    options.root_motion = RootMotion.EXTRACT;
    AnimationClip extract = profile_bake(&rig, &profile, options);
    retarget::destroy_retarget_profile(&profile);

    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 1, .max_textures = 8, .max_materials = 1, .max_samplers = 8,
        .max_models = 1, .max_skeletons = 1, .max_clips = 2,
    });
    defer asset::destroy_asset_store(&assets);

    ModelTemplate template = { .nodes = alloc::new_array(mem, NodeTemplate, rig.target.nodes.len) };
    template.nodes[..] = rig.target.nodes[..];
    foreach (&node : template.nodes) node.name = node.name.copy(mem);

    ModelId model_id = assets.add_model_owned(&template)!!;
    ClipId kept_clip = assets.add_clip_owned(&keep)!!;
    ClipId extracted_clip = assets.add_clip_owned(&extract)!!;

    Scene scene = scene::create_scene(mem, { .max_nodes = 20 });
    defer scene::destroy_scene(&scene);

    Node* kept_root = model::instantiate(&assets, &scene, model_id)!!;
    Node* extracted_root = model::instantiate(&assets, &scene, model_id)!!;
    Animator* kept = anim::add_animator(&scene, kept_root);
    Animator* extracted = anim::add_animator(&scene, extracted_root);
    extracted.root_node = 1;

    AnimationActionId kept_action = kept.play(&assets, kept_clip)!!;
    AnimationActionId extracted_action = extracted.play(
        assets: &assets,
        clip: extracted_clip,
        desc: { .root_motion = RootMotion.EXTRACT, .root_yaw = root_yaw },
    )!!;
    kept.action(kept_action).loop = false;
    extracted.action(extracted_action).loop = false;

    float key_error;
    float subkey_error;

    for (uint frame = 1; frame <= 240; frame++) {
        anim::update(&assets, &scene, 1.0f / 240);
        anim::apply_root_motion(extracted_root, extracted.root_motion);
        scene.update_world();

        bool key_sample = frame % 4 == 0;
        ModelInstance* kept_instance = scene.get(kept_root, ModelInstance);
        ModelInstance* extracted_instance = scene.get(extracted_root, ModelInstance);
        foreach (node : (uint[3]){ 2, 4, 5 }) {
            Node* expected = kept_instance.present_node(node);
            Node* actual = extracted_instance.present_node(node);
            float error = (maths::translation(expected.world) - maths::translation(actual.world)).length();
            if (key_sample) {
                key_error = math::max(key_error, error);
            } else {
                subkey_error = math::max(subkey_error, error);
            }

            profile_expect_rotation(actual.world, maths::transform_from_mat4(expected.world).rotation,
                key_sample ? 0.0001f : 0.25f * (float)math::PI / 180);
            profile_expect_scale(actual.world, 3);
        }

        if (!root_yaw) {
            assert(extracted_root.local.rotation.v == (Vec4){ 0, 0, 0, 1 });
            assert(extracted.root_motion.rotation.v == (Vec4){ 0, 0, 0, 1 });
        }
    }

    assert(key_error <= PROFILE_POSITION_EPSILON);
    assert(subkey_error <= PROFILE_SUBKEY_EPSILON);

    Quat mesh_rotation = profile_turn({ 0, 1, 0 }, 90)
      .mul(profile_turn({ 0, 1, 0 }, 120)).mul(profile_turn({ 0, 0, 1 }, 90));
    Node* mesh = scene.get(extracted_root, ModelInstance).present_node(2);
    profile_expect_rotation(mesh.world, mesh_rotation);
}

fn void test_profile_anatomical_calibration_preserves_target_bone_proportions() @test {
    @pool() {
        ProfileRig rig = profile_rig(3, 3);
        rig.source[1].parent = 0;
        rig.source[1].local.position = { 1, 0, 0 };

        rig.source[2].parent = 1;
        rig.source[2].local.position = { 1, 0, 0 };

        rig.target.nodes[1].parent = 0;
        rig.target.nodes[1].local = profile_transform({ 2, 0, 0 }, profile_turn({ 0, 0, 1 }, -45));

        rig.target.nodes[2].parent = 1;
        rig.target.nodes[2].local.position = { 2, 0, 0 };

        profile_map(&rig, (NodeIndexMapping[2]){
            { .source_node = 0, .target_node = 0 }, { .source_node = 1, .target_node = 1 },
        }[..]);

        Quat end = profile_turn({ 0, 0, 1 }, 30);
        profile_clip(&rig, (uint[1]){ 1 }[..], (Track[1]){
            profile_input_track(
                target: 0,
                path: TargetPath.ROTATION,
                times: (float[2]){ 0, 1 }[..],
                values: (float[8]){ 0, 0, 0, 1, end.v.x, end.v.y, end.v.z, end.v.w }[..],
            ),
        }[..]);

        Transform source_rest = rig.source[1].local;
        Transform target_rest = rig.target.nodes[1].local;

        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);

        Track* rotation = profile_output_track(&result, 1, TargetPath.ROTATION);
        assert(rotation != null && rotation.times.len == 61);

        foreach (time : (float[5]){ 0, 0.25f, 0.5f, 0.75f, 1 }) profile_expect_anatomical_pose(&result, &rig, time);
        profile_expect_position(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 2,
            time: 1,
        ), { 2 + math::sqrt(3.0f), 1, 0 });
        profile_expect_position(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 2,
            time: 0.5f,
        ), {
            2 + (math::sqrt(6.0f) + math::sqrt(2.0f)) / 2,
            (math::sqrt(6.0f) - math::sqrt(2.0f)) / 2,
            0,
        });

        assert(profile_output_track(&result, 2, TargetPath.ROTATION) == null);
        assert(profile_output_track(&result, 1, TargetPath.TRANSLATION) == null);
        assert(rig.source[1].local.rotation.v == source_rest.rotation.v);
        assert(rig.target.nodes[1].local.rotation.v == target_rest.rotation.v);
        assert(rig.target.nodes[2].local.position == (Vec3){ 2, 0, 0 });
    };
}

fn void test_profile_facing_calibration_and_noncommuting_target_parents() @test {
    @pool() {
        const float YAW = 37;
        ProfileRig rig = profile_rig(2, 3);
        rig.source[0].local.rotation = profile_turn({ 0, 1, 0 }, 20);

        rig.source[1].parent = 0;
        rig.source[1].local.rotation = profile_turn({ 0, 0, 1 }, -10);

        rig.target.nodes[0].local.rotation = profile_turn({ 0, 1, 0 }, 90);

        rig.target.nodes[1].parent = 0;
        rig.target.nodes[1].local = profile_transform({ 1, 2, 3 }, profile_turn({ 0, 0, 1 }, 10));

        rig.target.nodes[2].parent = 1;
        rig.target.nodes[2].local.position = { 2, 0, 0 };

        rig.desc.source_calibration[0] = rig.source[0].local.rotation;
        rig.desc.source_calibration[1] = profile_turn({ 0, 0, 1 }, 45);
        rig.desc.target_calibration[0] = profile_turn({ 1, 0, 0 }, 80);
        rig.desc.target_calibration[1] = profile_turn({ 0, 0, 1 }, -45);
        rig.desc.target_calibration[2] = profile_turn({ 0, 1, 0 }, 70);
        rig.desc.facing = profile_turn({ 0, 1, 0 }, YAW).to_matrix();

        profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 1, .target_node = 1 } }[..]);

        Quat start = rig.desc.source_calibration[1];
        Quat end = profile_turn({ 1, 0, 0 }, 30).mul(start);

        profile_clip(&rig, (uint[1]){ 1 }[..], (Track[1]){
            profile_input_track(
                target: 0,
                path: TargetPath.ROTATION,
                times: (float[2]){ 0, 1 }[..],
                values: (float[8]){
                    start.v.x, start.v.y, start.v.z, start.v.w,
                    end.v.x, end.v.y, end.v.z, end.v.w,
                }[..],
            ),
        }[..]);

        Transform source_rest = rig.source[1].local;
        Transform target_rest = rig.target.nodes[1].local;

        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);

        Track* rotation = profile_output_track(&result, 1, TargetPath.ROTATION);
        assert(rotation != null && rotation.times.len == 61);

        foreach (time : (float[5]){ 0, 0.25f, 0.5f, 0.75f, 1 }) {
            profile_expect_facing_pose(
                clip: &result,
                rig: &rig,
                yaw: YAW,
                time: time,
            );
        }

        profile_expect_rotation(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 0,
            time: 0.5f,
        ), profile_turn({ 0, 1, 0 }, 90));
        assert(profile_output_track(&result, 0, TargetPath.ROTATION) == null);
        assert(profile_output_track(&result, 2, TargetPath.ROTATION) == null);
        assert(profile_output_track(&result, 1, TargetPath.TRANSLATION) == null);
        assert(profile_output_track(&result, 2, TargetPath.TRANSLATION) == null);
        assert(rig.source[1].local.rotation.v == source_rest.rotation.v);
        assert(rig.target.nodes[1].local.rotation.v == target_rest.rotation.v);
        assert(rig.target.nodes[2].local.position == (Vec3){ 2, 0, 0 });
    };
}

fn void test_profile_composes_unmapped_animated_ancestors_and_affine_motion_chain() @test {
    @pool() {
        ProfileRig rig = profile_ancestor_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);

        Mat4 parent = profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 0,
            time: 3,
        );
        Mat4 motion = profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 3,
        );
        profile_expect_position(parent, { -4, 1, 0 });
        profile_expect_position(motion, { 2, 2, -1 });
        profile_expect_rotation(parent, profile_turn({ 1, 0, 0 }, 90));
        profile_expect_rotation(motion, profile_turn({ 1, 0, 0 }, 90));
        profile_expect_scale(parent, 2);
        profile_expect_scale(motion, 3);
        Transform local = profile_sample_node(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 3,
        );
        assert((local.position - (Vec3){ 3, -0.5f, -0.5f }).length() <= PROFILE_POSITION_EPSILON);
        assert((local.scale - (Vec3){ 1.5f, 1.5f, 1.5f }).length() <= PROFILE_POSITION_EPSILON);
        assert(profile_output_track(&result, 2, TargetPath.TRANSLATION) == null);
        float half = math::sqrt(0.5f);
        profile_expect_position(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 0,
            time: 1.5f,
        ), {
            -4 + 3 * half, 1, 4 - 3 * half,
        });
        profile_expect_position(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 1.5f,
        ), {
            1.5625f + 3 * half, 2 + 1.125f * half, 3.5625f - 3 * half,
        });
        profile_expect_scale(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 0,
            time: 1.5f,
        ), 2.25f);
        profile_expect_scale(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 1.5f,
        ), 3.375f);

        Track[] tracks = alloc::new_array(tmem, Track, 6);
        tracks[:5] = rig.clip.tracks[..];
        tracks[5] = profile_input_track(
            target: 0,
            path: TargetPath.TRANSLATION,
            times: (float[2]){ 0, 3 }[..],
            values: (float[6]){ 1, 2, 3, 1.6f, 2.3f, 2.7f }[..],
        );
        rig.clip.tracks = tracks;
        AnimationClip translated = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &translated);

        profile_expect_position(profile_sample_world(
            clip: &translated,
            target: &rig.target,
            node: 0,
            time: 3,
        ), { -3.4f, 1.3f, -0.3f });
        profile_expect_position(profile_sample_world(
            clip: &translated,
            target: &rig.target,
            node: 1,
            time: 3,
        ), { 2.6f, 2.3f, -1.3f });
        local = profile_sample_node(
            clip: &translated,
            target: &rig.target,
            node: 1,
            time: 3,
        );
        assert((local.position - (Vec3){ 3, -0.5f, -0.5f }).length() <= PROFILE_POSITION_EPSILON);
    };
}

fn void test_profile_carrier_compensates_only_the_motion_branch() @test {
    @pool() {
        ProfileRig rig = profile_carrier_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        AnimationClip keep = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &keep);

        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.root_motion = RootMotion.EXTRACT;
        AnimationClip extract = profile_bake(&rig, &profile, options);
        defer asset::free_clip(mem, &extract);

        options.root_motion = RootMotion.STRIP_XZ;
        AnimationClip strip = profile_bake(&rig, &profile, options);
        defer asset::free_clip(mem, &strip);

        Vec3 horizontal = { 0.5f, 0, -0.25f };
        Vec3[4] expected = { { 1, 4, 0 }, { 5, 0, 4 }, { 1, 4, 1 }, { 1.5f, 4, -0.25f } };

        foreach (uint index, position : expected) {
            uint node = index + 1;
            bool rigid = node == 2;
            profile_expect_position(profile_sample_world(
                clip: &keep,
                target: &rig.target,
                node: node,
                time: 1,
            ), position);
            profile_expect_position(profile_sample_world(
                clip: &extract,
                target: &rig.target,
                node: node,
                time: 1,
            ), rigid ? position + horizontal : position);
            profile_expect_position(profile_sample_world(
                clip: &strip,
                target: &rig.target,
                node: node,
                time: 1,
            ), rigid ? position : position - horizontal);
        }

        assert((profile_sample_node(
            clip: &extract,
            target: &rig.target,
            node: 0,
            time: 1,
        ).position - (Vec3){ 1.5f, 0, 1.75f }).length()
            <= PROFILE_POSITION_EPSILON);
        assert((profile_sample_node(
            clip: &extract,
            target: &rig.target,
            node: 1,
            time: 1,
        ).position - (Vec3){ 0.875f, 2, -0.25f }).length()
            <= PROFILE_POSITION_EPSILON);
        assert(profile_output_track(&extract, 2, TargetPath.TRANSLATION) == null);
        assert(profile_output_track(&strip, 2, TargetPath.TRANSLATION) == null);
        assert(profile_output_track(&extract, 3, TargetPath.TRANSLATION) == null);

        foreach (&track : extract.tracks) assert(track.times.len == 61 && track.interpolation == Interpolation.LINEAR);
    };
}

fn void test_profile_virtual_forest_strips_only_the_motion_root() @test {
    @pool() {
        ProfileRig rig = profile_forest_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.root_translation_scale = 0.5f;
        AnimationClip keep = profile_bake(&rig, &profile, options);
        defer asset::free_clip(mem, &keep);

        options.root_motion = RootMotion.STRIP_XZ;
        AnimationClip strip = profile_bake(&rig, &profile, options);
        defer asset::free_clip(mem, &strip);

        Vec3 horizontal = { 1.5f, 0, -0.5f };
        profile_expect_position(profile_sample_world(
            clip: &keep,
            target: &rig.target,
            node: 0,
            time: 1,
        ), (Vec3){ 2, 1.25f, -3 } + horizontal);
        profile_expect_position(profile_sample_world(
            clip: &strip,
            target: &rig.target,
            node: 0,
            time: 1,
        ), { 2, 1.25f, -3 });
        profile_expect_position(profile_sample_world(
            clip: &strip,
            target: &rig.target,
            node: 1,
            time: 1,
        ), { -1, 1, 2 });
        assert(profile_output_track(&strip, 1, TargetPath.TRANSLATION) == null);
        profile_expect_position(profile_sample_world(
            clip: &keep,
            target: &rig.target,
            node: 0,
            time: 1.0f / 120,
        ), {
            2.0125f, 1.002083333333f, -3.004166666667f,
        });
        options.root_motion = RootMotion.EXTRACT;
        profile_expect_bake_fault(
            rig: &rig,
            profile: &profile,
            expected: c3d::INVALID_ARGUMENT,
            options: options,
        );

        ProfileRig offset = profile_forest_rig();
        offset.clip.tracks[0].values[0] = 1;
        offset.clip.tracks[0].values[2] = 3;
        offset.clip.tracks[0].values[3] = 2;
        offset.clip.tracks[0].values[5] = 6;
        RetargetProfile offset_profile = profile_prepare(&offset);
        defer retarget::destroy_retarget_profile(&offset_profile);

        options.root_motion = RootMotion.STRIP_XZ;
        options.root_translation_scale = 1;
        AnimationClip offset_strip = profile_bake(&offset, &offset_profile, options);
        defer asset::free_clip(mem, &offset_strip);

        profile_expect_position(profile_sample_world(
            clip: &offset_strip,
            target: &offset.target,
            node: 0,
            time: 1,
        ), { 5, 1.5f, -4 });
    };
}

fn void test_profile_mapping_selects_nodes_and_rejects_conflicts() @test {
    @pool() {
        ProfileRig rig = profile_rig(3, 3);
        profile_map(&rig, (NodeIndexMapping[2]){
            { .source_node = 0, .target_node = 2 }, { .source_node = 1, .target_node = 0 },
        }[..]);
        RetargetProfile by_index = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&by_index);

        AnimationClip indexed = profile_bake(&rig, &by_index);
        defer asset::free_clip(mem, &indexed);

        assert(profile_output_track(&indexed, 0, TargetPath.ROTATION) != null);
        assert(profile_output_track(&indexed, 2, TargetPath.ROTATION) != null);
        assert(profile_output_track(&indexed, 1, TargetPath.ROTATION) == null);

        rig.desc.index_map[1].target_node = 2;
        profile_expect_creation_fault(&rig, c3d::ASSET_FORMAT_ERROR);
        rig.desc.index_map[1] = { .source_node = 99, .target_node = 1 };
        profile_expect_creation_fault(&rig, c3d::ASSET_FORMAT_ERROR);
        rig.desc.index_map[1] = { .source_node = 1, .target_node = 0 };
        rig.desc.name_map = (NameMapping[1]){ { .source = "joint", .target = "joint" } }[..];
        profile_expect_creation_fault(&rig, c3d::ASSET_FORMAT_ERROR);

        rig.desc.mapping_mode = ProfileMappingMode.BY_NAME;
        profile_expect_creation_fault(&rig, c3d::ASSET_FORMAT_ERROR);
        rig.desc.index_map = {};
        profile_expect_creation_fault(&rig, c3d::ASSET_FORMAT_ERROR);
        rig.desc.name_map[0].source = "absent";
        profile_expect_creation_fault(&rig, c3d::ASSET_FORMAT_ERROR);
        rig.desc.name_map = {};
        profile_expect_creation_fault(&rig, c3d::ASSET_FORMAT_ERROR);
        rig.target.nodes = rig.target.nodes[:1];
        rig.desc.target_calibration = rig.desc.target_calibration[:1];
        profile_expect_creation_fault(&rig, c3d::ASSET_FORMAT_ERROR);

        ProfileRig named = profile_rig(3, 3);
        named.source[0].name = "source:Hips";
        named.source[1].name = "source:Arm";
        named.source[2].name = "helper";
        named.target.nodes[0].name = "hips";
        named.target.nodes[1].name = "Elbow";
        named.target.nodes[2].name = "unused";
        named.desc.mapping_mode = ProfileMappingMode.BY_NAME;
        named.desc.name_map = (NameMapping[1]){ { .source = "source:Arm", .target = "Elbow" } }[..];
        RetargetProfile by_name = profile_prepare(&named);
        defer retarget::destroy_retarget_profile(&by_name);

        AnimationClip result = profile_bake(&named, &by_name);
        defer asset::free_clip(mem, &result);

        assert(result.tracks.len == 2);
    };
}

fn void test_profile_exact_fingerprint_rejects_template_changes() @test {
    @pool() {
        ProfileRig rig = profile_forest_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        String source_name = rig.source[0].name;
        rig.source[0].name = "renamed";
        profile_expect_bake_fault(&rig, &profile, c3d::INVALID_ARGUMENT);
        rig.source[0].name = source_name;

        NodeTemplate[] original = rig.target.nodes;
        rig.target.nodes = rig.target.nodes[:1];
        profile_expect_bake_fault(&rig, &profile, c3d::INVALID_ARGUMENT);
        rig.target.nodes = original;

        rig.target.nodes[1].local.position.x += 1;
        profile_expect_bake_fault(&rig, &profile, c3d::INVALID_ARGUMENT);
        rig.target.nodes[1].local.position.x -= 1;

        rig.target.meshes = (ModelMesh[1]){ { .node = 0, .material = { .index = 2 } } }[..];
        AnimationClip compatible = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &compatible);

        assert(compatible.duration == rig.clip.duration);
    };
}

fn void test_profile_rejects_invalid_descriptors_carriers_and_reference_range() @test {
    @pool() {
        ProfileRig rig = profile_carrier_rig();
        Quat[] original_calibration = rig.desc.source_calibration;
        rig.desc.source_calibration = original_calibration[:1];
        profile_expect_creation_fault(&rig, c3d::INVALID_ARGUMENT);
        rig.desc.source_calibration = original_calibration;
        rig.desc.source_calibration[1] = {};
        profile_expect_creation_fault(&rig, c3d::INVALID_ARGUMENT);
        rig.desc.source_calibration[1] = quaternion::IDENTITY;

        rig.desc.facing = profile_turn({ 1, 0, 0 }, 90).to_matrix();
        profile_expect_creation_fault(&rig, c3d::INVALID_ARGUMENT);
        rig.desc.facing = matrix::IDENTITY4;

        rig.source[0].local.scale = { 1, 2, 1 };
        profile_expect_creation_fault(&rig, c3d::INVALID_ARGUMENT);
        rig.source[0].local.scale = { 1, 1, 1 };

        rig.target.nodes[0].local.rotation = profile_turn({ 1, 0, 0 }, 10);
        profile_expect_creation_fault(&rig, c3d::INVALID_ARGUMENT);
        rig.target.nodes[0].local.rotation = profile_turn({ 0, 1, 0 }, 90);
        rig.target.meshes[0].node = 0;
        profile_expect_creation_fault(&rig, c3d::INVALID_ARGUMENT);
        rig.target.meshes[0].node = 2;
        rig.desc.index_map[0].target_node = 0;
        profile_expect_creation_fault(&rig, c3d::INVALID_ARGUMENT);

        ProfileRig extreme = profile_rig(2, 1);
        extreme.source[0].local.scale = { 1e30f, 1e30f, 1e30f };
        extreme.source[1].parent = 0;
        extreme.source[1].local.scale = { 1e30f, 1e30f, 1e30f };
        profile_map(&extreme, (NodeIndexMapping[1]){ { .source_node = 1, .target_node = 0 } }[..]);
        profile_expect_creation_fault(&extreme, c3d::INVALID_ARGUMENT);
    };
}

fn void test_profile_rejects_nonuniform_ancestor_scale_and_unmatched_tracks() @test {
    @pool() {
        ProfileRig rig = profile_ancestor_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        rig.clip.tracks[3].values[4] = 8;
        profile_expect_bake_fault(&rig, &profile, c3d::UNSUPPORTED);

        ProfileRig partial = profile_rig(2, 1);
        profile_map(&partial, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
        profile_clip(&partial, (uint[1]){ 1 }[..], (Track[1]){
            profile_input_track(
                target: 0,
                path: TargetPath.TRANSLATION,
                times: (float[2]){ 0, 1 }[..],
                values: (float[6]){ 0, 0, 0, 1, 0, 0 }[..],
            ),
        }[..]);
        RetargetProfile partial_profile = profile_prepare(&partial);
        defer retarget::destroy_retarget_profile(&partial_profile);

        profile_expect_bake_fault(&partial, &partial_profile, c3d::ASSET_FORMAT_ERROR);
        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.allow_partial = true;
        AnimationClip accepted = profile_bake(&partial, &partial_profile, options);
        defer asset::free_clip(mem, &accepted);

        assert(accepted.tracks.len == 1);
    };
}

fn void test_profile_cadence_includes_zero_tiny_and_nonintegral_endpoints() @test {
    @pool() {
        ProfileRig rig = profile_rig(1, 1);
        profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        foreach (duration : (float[3]){ 0, 0.000001f, 1.013f }) {
            rig.clip.duration = duration;
            uint count = duration == 0 ? 1 : 2;
            float[] times = alloc::new_array(tmem, float, count);
            times[count - 1] = duration;
            float[] values = alloc::new_array(tmem, float, (sz)count * 4);
            values[3] = 1;
            if (count > 1) values[7] = -1;
            profile_clip(&rig, (uint[1]){ 0 }[..], (Track[1]){
                profile_input_track(
                    target: 0,
                    path: TargetPath.ROTATION,
                    times: times,
                    values: values,
                ),
            }[..]);
            AnimationClip result = profile_bake(&rig, &profile);
            defer asset::free_clip(mem, &result);

            Track* rotation = profile_output_track(&result, 0, TargetPath.ROTATION);
            uint intervals = duration == 0 ? 0 : (uint)math::max(1.0, math::ceil((double)duration * 60 - 0.001));
            assert(rotation.times.len == (usz)intervals + 1);
            assert(rotation.times[0] == 0 && rotation.times[^1] == duration);

            for (usz key = 1; key < rotation.times.len; key++) {
                assert(rotation.times[key] > rotation.times[key - 1]);
                float[] before = rotation.values[(key - 1) * 4:4];
                float[] after = rotation.values[key * 4:4];
                Vec4 first = { before[0], before[1], before[2], before[3] };
                Vec4 second = { after[0], after[1], after[2], after[3] };
                assert(first.dot(second) >= 0);
                assert(math::abs(second.dot(second) - 1) <= 1e-5f);
            }
        }

        RetargetBakeOptions invalid = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        invalid.bake_rate = 0;
        profile_expect_bake_fault(
            rig: &rig,
            profile: &profile,
            expected: c3d::INVALID_ARGUMENT,
            options: invalid,
        );
        invalid.bake_rate = float::max;
        profile_expect_bake_fault(
            rig: &rig,
            profile: &profile,
            expected: c3d::CAPACITY_EXCEEDED,
            options: invalid,
        );
    };
}

fn void test_profile_copied_scale_morph_and_events_keep_interpolation_and_ownership() @test {
    @pool() {
        ProfileRig rig = profile_rig(1, 1);
        profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
        rig.target.meshes = alloc::new_array(tmem, ModelMesh, 1);
        rig.target.meshes[0] = { .node = 0, .default_morph_weights = (float[2]){ 0, 0 }[..] };
        profile_clip(&rig, (uint[1]){ 0 }[..], (Track[2]){
            profile_input_track(
                target: 0,
                path: TargetPath.SCALE,
                times: (float[2]){ 0, 1 }[..],
                values: (float[6]){ 1, 1, 1, 2, 2, 2 }[..],
                interpolation: Interpolation.STEP,
            ),
            profile_input_track(
                target: 0,
                path: TargetPath.MORPH_WEIGHTS,
                times: (float[2]){ 0, 1 }[..],
                values: (float[12]){ 0, 0, 0.2f, 0.4f, 1, 1, 1, 1, 0.8f, 0.6f, 0, 0 }[..],
                interpolation: Interpolation.CUBIC_SPLINE,
            ),
        }[..]);
        rig.clip.events = (ClipEvent[2]){ { .time = 0, .id = 7 }, { .time = 0.5f, .id = 9 } }[..];
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);

        Track* scale = profile_output_track(&result, 0, TargetPath.SCALE);
        Track* morph = profile_output_track(&result, 0, TargetPath.MORPH_WEIGHTS);
        assert(scale.interpolation == Interpolation.STEP && scale.times.len == 2);
        assert(morph.interpolation == Interpolation.CUBIC_SPLINE && morph.values.len == 12);
        assert(scale.values.ptr != rig.clip.tracks[0].values.ptr && morph.values.ptr != rig.clip.tracks[1].values.ptr);

        foreach (index, value : morph.values) assert(value == rig.clip.tracks[1].values[index]);
        rig.clip.tracks[0].values[0] = 99;
        rig.clip.tracks[1].values[0] = 99;
        rig.clip.events[0].id = 99;
        assert(scale.values[0] == 1 && morph.values[0] == 0 && result.events[0].id == 7);
        rig.clip.tracks[0].values[0] = 1;
        rig.clip.tracks[1].values[0] = 0;
        rig.target.meshes[0].default_morph_weights = (float[1]){ 0 }[..];
        profile_expect_bake_fault(&rig, &profile, c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_profile_owns_preparation_and_failure_preserves_existing_resource_bytes() @test {
    @pool() {
        ProfileRig rig = profile_forest_rig();
        NodeIndexMapping[] mapping = alloc::new_array(mem, NodeIndexMapping, rig.desc.index_map.len);
        mapping[..] = rig.desc.index_map[..];
        Quat[] source_calibration = alloc::new_array(mem, Quat, rig.desc.source_calibration.len);
        source_calibration[..] = rig.desc.source_calibration[..];
        Quat[] target_calibration = alloc::new_array(mem, Quat, rig.desc.target_calibration.len);
        target_calibration[..] = rig.desc.target_calibration[..];
        rig.desc.index_map = mapping;
        rig.desc.source_calibration = source_calibration;
        rig.desc.target_calibration = target_calibration;
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();

        RetargetProfile profile = retarget::create_retarget_profile(
            allocator: &tracker,
            source_nodes: rig.source,
            target: &rig.target,
            desc: rig.desc,
        )!!;
        assert(tracker.allocation_count() == 1);
        sz bytes = tracker.allocated();
        char[] captured = alloc::new_array(tmem, char, bytes);
        captured[..] = ((char*)profile.data)[:bytes];
        mapping[0].target_node = 99;
        source_calibration[0] = {};
        target_calibration[0] = {};

        alloc::free(mem, mapping.ptr);
        alloc::free(mem, source_calibration.ptr);
        alloc::free(mem, target_calibration.ptr);
        rig.desc.index_map = {};
        rig.desc.source_calibration = {};
        rig.desc.target_calibration = {};
        profile_expect_creation_fault(&rig, c3d::INVALID_ARGUMENT);

        foreach (index, value : captured) assert(((char*)profile.data)[index] == value);
        AnimationClip first = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &first);

        AnimationClip second = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &second);

        foreach (index, value : captured) assert(((char*)profile.data)[index] == value);
        retarget::destroy_retarget_profile(&profile);
        assert(!profile.data && tracker.allocation_count() == 0 && tracker.allocated() == 0);
        rig.clip.tracks[0].values[3] = 99;
        assert(first.name == "authored_motion" && second.name == "authored_motion");
        assert(first.tracks[0].times.ptr != second.tracks[0].times.ptr);
        profile_expect_position(profile_sample_world(
            clip: &first,
            target: &rig.target,
            node: 0,
            time: 1,
        ), { 5, 1.5f, -4 });
        profile_expect_position(profile_sample_world(
            clip: &second,
            target: &rig.target,
            node: 0,
            time: 1,
        ), { 5, 1.5f, -4 });
    };
}

fn void test_profile_failed_sample_frees_every_partial_clip_allocation() @test {
    @pool() {
        ProfileRig rig = profile_rig(1, 1);
        rig.desc.source_motion_node = 0;
        rig.desc.target_motion_node = 0;
        profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
        profile_clip(&rig, (uint[1]){ 0 }[..], (Track[1]){
            profile_input_track(
                target: 0,
                path: TargetPath.SCALE,
                times: (float[2]){ 0, 1 }[..],
                values: (float[18]){
                    0, 0, 0, 1, 1, 1, -10, -10, -10,
                    10, 10, 10, 1, 1, 1, 0, 0, 0,
                }[..],
                interpolation: Interpolation.CUBIC_SPLINE,
            ),
        }[..]);
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();

        assert(@catch(retarget::retarget_with_profile(
            allocator: &tracker,
            source: &rig.clip,
            source_nodes: rig.source,
            target: &rig.target,
            profile: &profile,
        )) == c3d::UNSUPPORTED);
        assert(tracker.allocation_count() == 0 && tracker.allocated() == 0);
        assert(rig.clip.tracks[0].values[6] == -10 && rig.source[0].local.scale == (Vec3){ 1, 1, 1 });
    };
}

fn void test_profile_mapped_leaf_copies_nonuniform_nonmotion_scale_exactly() @test {
    @pool() {
        ProfileRig rig = profile_rig(2, 2);
        rig.source[1].parent = 0;

        rig.target.nodes[1].parent = 0;
        rig.target.nodes[1].local.position = { 0, 1, 0 };
        profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 1, .target_node = 1 } }[..]);
        profile_clip(&rig, (uint[1]){ 1 }[..], (Track[1]){
            profile_input_track(
                target: 0,
                path: TargetPath.SCALE,
                times: (float[2]){ 0, 1 }[..],
                values: (float[6]){ 1, 1, 1, 1, 2, 1 }[..],
                interpolation: Interpolation.STEP,
            ),
        }[..]);
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);

        Track* copied = profile_output_track(&result, 1, TargetPath.SCALE);
        assert(copied != null && copied.interpolation == Interpolation.STEP);
        assert(copied.times == rig.clip.tracks[0].times && copied.values == rig.clip.tracks[0].values);
        assert(copied.times.ptr != rig.clip.tracks[0].times.ptr && copied.values.ptr != rig.clip.tracks[0].values.ptr);
        assert(profile_sample_node(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 1,
        ).scale == (Vec3){ 1, 2, 1 });
        profile_expect_rotation(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 1,
        ), maths::TRANSFORM_IDENTITY.rotation);
        assert(rig.source[1].local.scale == (Vec3){ 1, 1, 1 });
        assert(rig.target.nodes[1].local.scale == (Vec3){ 1, 1, 1 });
    };
}

fn void test_profile_copied_scale_remains_uniform_when_target_consumes_descendants() @test {
    @pool() {
        ProfileRig rig = profile_rig(2, 3);
        rig.source[1].parent = 0;

        rig.target.nodes[1].parent = 0;

        rig.target.nodes[2].parent = 1;
        profile_map(&rig, (NodeIndexMapping[2]){
            { .source_node = 1, .target_node = 1 },
            { .source_node = 0, .target_node = 2 },
        }[..]);
        profile_clip(&rig, (uint[1]){ 1 }[..], (Track[1]){
            profile_input_track(
                target: 0,
                path: TargetPath.SCALE,
                times: (float[2]){ 0, 1 }[..],
                values: (float[6]){ 1, 1, 1, 1, 2, 1 }[..],
            ),
        }[..]);
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        profile_expect_bake_fault(&rig, &profile, c3d::UNSUPPORTED);
    };
}

fn void test_profile_long_cadence_grid_emits_rounded_endpoint_once() @test {
    @pool() {
        const float DURATION = 512.16668701171875f;
        const usz EXPECTED_KEYS = 30731;
        ProfileRig rig = profile_rig(1, 1);
        rig.clip.duration = DURATION;
        profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);

        Track* rotation = profile_output_track(&result, 0, TargetPath.ROTATION);
        assert(rotation != null && rotation.times.len == EXPECTED_KEYS);
        assert(rotation.times[0] == 0 && rotation.times[^1] == DURATION);
        usz endpoints;

        foreach (index, time : rotation.times) {
            if (time == DURATION) endpoints++;
            if (index > 0) assert(time > rotation.times[index - 1]);
        }

        assert(endpoints == 1 && rotation.times[^2] == 30729.0f / 60);
    };
}

fn void test_profile_extract_yaw_preserves_turning_worlds_and_carries_unmapped_branches() @test {
    @pool() {
        const float FACING = 37;
        ProfileRig rig = profile_turning_carrier_rig(360, FACING);
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);

        AnimationClip keep = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &keep);

        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.root_motion = RootMotion.EXTRACT;
        AnimationClip extract = profile_bake(&rig, &profile, options);
        defer asset::free_clip(mem, &extract);

        options.root_motion = RootMotion.STRIP_XZ;
        AnimationClip strip = profile_bake(&rig, &profile, options);
        defer asset::free_clip(mem, &strip);

        Track* carrier_rotation = profile_output_track(&extract, 1, TargetPath.ROTATION);

        assert(carrier_rotation != null && carrier_rotation.interpolation == Interpolation.LINEAR);
        assert(profile_output_track(&extract, 1, TargetPath.SCALE) == null);
        assert(profile_output_track(&extract, 3, TargetPath.ROTATION) == null);
        assert(profile_output_track(&keep, 1, TargetPath.ROTATION) == null);
        assert(profile_output_track(&strip, 1, TargetPath.ROTATION) == null);

        double previous_angle = 90 * math::PI / 180;
        double total;

        foreach (usz key, time : carrier_rotation.times) {
            float[] values = carrier_rotation.values[key * 4:4];
            assert(values[0] == 0 && values[2] == 0);
            double current = 2 * math::atan2((double)values[1], (double)values[3]);
            if (key > 0) total += math::atan2(math::sin(current - previous_angle), math::cos(current - previous_angle));
            previous_angle = current;
        }

        assert(math::abs(total - 2 * math::PI) < 0.0001);

        for (uint key = 0; key <= (uint)(rig.clip.duration * 60); key++) {
            float time = (float)key / 60;
            profile_expect_turning_pose(
                clip: &keep,
                rig: &rig,
                facing: FACING,
                time: time,
                mode: RootMotion.KEEP,
            );
            profile_expect_turning_pose(
                clip: &extract,
                rig: &rig,
                facing: FACING,
                time: time,
                mode: RootMotion.EXTRACT,
            );
            profile_expect_turning_pose(
                clip: &strip,
                rig: &rig,
                facing: FACING,
                time: time,
                mode: RootMotion.STRIP_XZ,
            );
        }
    };
}

fn void test_profile_runtime_turning_scaled_faced_subkeys_matches_keep() @test {
    @pool() {
        foreach (root_yaw : (bool[2]){ false, true }) profile_check_turning_carrier_runtime(root_yaw);
    };
}
