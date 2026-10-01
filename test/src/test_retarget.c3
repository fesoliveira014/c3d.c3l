module c3d::test::retarget;

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::maths;
import std::math;
import std::math::quaternion;

const float TOLERANCE @local = 0.0005f;

struct Rig @local {
    NodeTemplate[] source_nodes;
    ModelTemplate  target;
    AnimationClip  clip;
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
