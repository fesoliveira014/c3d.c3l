module c3d::test::retarget;

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::maths;
import std::math;

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
