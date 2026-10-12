module c3d::anim;

import c3d;
import c3d::asset;
import c3d::maths;
import std::math;

const double MOTION_UNIT_TOLERANCE @local = 1e-5; // Bounds squared-length error of the twist axis and baseline rotations.
const double MOTION_FRAME_SCALE_TOLERANCE @local = 1e-5; // Bounds relative spread of positive baseline scale.
const uint MOTION_TRANSLATION_SLOT @local = 0;
const uint MOTION_ROTATION_SLOT @local = 1;
const uint MOTION_SCALE_SLOT @local = 2;

const double MOTION_SCALE_EPSILON @local = 1e-5; // Relative component tolerance of a uniform scale.

struct CapturedMotionNode @private {
    uint model_node;
    uint translation_track;
    uint rotation_track;
    uint scale_track;
    Transform baseline;
}

struct CapturedMotionChain @private {
    Allocator allocator;
    RootExtractionDesc extraction;
    CapturedMotionNode[] nodes;
    double[<3>][] pose_scale_sums;
    uint[] top_level_nodes;
}

fn bool? validate_generalized_motion(
    ModelTemplate* template,
    AnimationClip* clip,
    uint root,
    RootExtractionDesc extraction,
    MotionBasis motion_basis,
    bool additive,
) @private {
    if (root >= template.nodes.len) return c3d::INVALID_ARGUMENT~;
    validate_motion_up(extraction.up)!;

    if (!motion_basis.root_present || !motion_basis.parent_space || !motion_basis.ancestors_parent_space) {
        return c3d::INVALID_ARGUMENT~;
    }

    validate_motion_baseline_scale(motion_basis.instance_scale)!;

    bool unsupported;
    for (int model_node = (int)root; model_node >= 0; model_node = template.nodes[model_node].parent) {
        validate_motion_baseline(template.nodes[model_node].local)!;

        uint[3] track_indices = { NO_MOTION_TRACK, NO_MOTION_TRACK, NO_MOTION_TRACK };

        foreach (track_index, &track : clip.tracks) {
            if (clip.targets[track.target] != (uint)model_node || track.path == TargetPath.MORPH_WEIGHTS) continue;
            uint slot = motion_chain_track_slot(track.path);
            if (track_indices[slot] != NO_MOTION_TRACK) return c3d::INVALID_ARGUMENT~;
            track_indices[slot] = (uint)track_index;

            switch (track.path) {
                case TRANSLATION:
                case MORPH_WEIGHTS:
                    continue;
                case ROTATION:
                    validate_motion_rotation_track(track)!;
                case SCALE:
                    unsupported |= validate_consumed_scale_track(track, additive)!;
            }
        }
    }

    return unsupported;
}

fn CapturedMotionChain? create_captured_motion_chain(
    Allocator allocator,
    ModelTemplate* template,
    AnimationClip* clip,
    uint root,
    RootExtractionDesc extraction,
) @private {
    sz chain_count;
    for (int node = (int)root; node >= 0; node = template.nodes[node].parent) chain_count++;
    sz top_level_count;
    foreach (node : template.nodes) if (node.parent < 0) top_level_count++;

    CapturedMotionChain captured = {
        .allocator = allocator,
        .extraction = extraction,
    };
    defer catch destroy_captured_motion_chain(&captured);

    captured.nodes = alloc::new_array_try(allocator, CapturedMotionNode, chain_count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    captured.top_level_nodes = alloc::new_array_try(allocator, uint, top_level_count)
      ?? c3d::CAPACITY_EXCEEDED~!;

    uint chain_index;
    for (int node = (int)root; node >= 0; node = template.nodes[node].parent) {
        captured.nodes[chain_index++] = {
            .model_node = (uint)node,
            .translation_track = NO_MOTION_TRACK,
            .rotation_track = NO_MOTION_TRACK,
            .scale_track = NO_MOTION_TRACK,
            .baseline = template.nodes[node].local,
        };
    }

    foreach (track_index, track : clip.tracks) {
        foreach (&node : captured.nodes) {
            if (node.model_node != clip.targets[track.target]) continue;

            switch (track.path) {
                case TRANSLATION:
                    node.translation_track = (uint)track_index;
                case ROTATION:
                    node.rotation_track = (uint)track_index;
                case SCALE:
                    node.scale_track = (uint)track_index;
                case MORPH_WEIGHTS:
                    break;
            }
        }
    }

    uint top_level_index;
    foreach (index, node : template.nodes) {
        if (node.parent < 0) captured.top_level_nodes[top_level_index++] = (uint)index;
    }

    return captured;
}

fn void destroy_captured_motion_chain(CapturedMotionChain* captured) @private {
    alloc::free(captured.allocator, captured.nodes.ptr);
    alloc::free(captured.allocator, captured.pose_scale_sums.ptr);
    alloc::free(captured.allocator, captured.top_level_nodes.ptr);

    *captured = {};
}

fn void? validate_motion_up(Vec3 up) @local {
    double squared = (double)up.x * up.x + (double)up.y * up.y + (double)up.z * up.z;
    if (!motion_unit_length(squared)) return c3d::INVALID_ARGUMENT~;
}

fn uint motion_chain_track_slot(TargetPath path) @local {
    switch (path) {
        case TRANSLATION:
            return MOTION_TRANSLATION_SLOT;
        case ROTATION:
            return MOTION_ROTATION_SLOT;
        case SCALE:
            return MOTION_SCALE_SLOT;
        case MORPH_WEIGHTS:
            return 3;
    }
}

fn void? validate_motion_baseline_scale(Vec3 scale) @local {
    if (!math::is_finite(scale.x) || !math::is_finite(scale.y) || !math::is_finite(scale.z)
        || !(scale.x > 0) || !(scale.y > 0) || !(scale.z > 0)) return c3d::INVALID_ARGUMENT~;

    double maximum = math::max((double)scale.x, math::max((double)scale.y, (double)scale.z));
    double minimum = math::min((double)scale.x, math::min((double)scale.y, (double)scale.z));
    if (minimum < maximum * (1 - MOTION_FRAME_SCALE_TOLERANCE)) return c3d::INVALID_ARGUMENT~;
}

fn void? validate_motion_baseline(Transform baseline) @local {
    if (!math::is_finite(baseline.position.x) || !math::is_finite(baseline.position.y)
        || !math::is_finite(baseline.position.z)) return c3d::INVALID_ARGUMENT~;

    validate_motion_baseline_scale(baseline.scale)!;

    // Matrix conversion normalizes the rotation, which would conceal a malformed authored frame.
    Quat rotation = baseline.rotation;
    double squared = (double)rotation.v.x * rotation.v.x + (double)rotation.v.y * rotation.v.y
      + (double)rotation.v.z * rotation.v.z + (double)rotation.v.w * rotation.v.w;
    if (!motion_unit_length(squared)) return c3d::INVALID_ARGUMENT~;
}

fn bool motion_unit_length(double squared) @local => math::abs(squared - 1) <= MOTION_UNIT_TOLERANCE;

// Admission returns UNSUPPORTED as true, so a request reports every other fault of its actions first.
fn bool? validate_playback_addition(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationClip* clip,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis basis,
) @private {
    CapturedMotionChain* chain = generalized_playback_chain(playback);
    bool unsupported = validate_action_desc(
        playback: playback,
        assets: assets,
        clip: clip,
        desc: desc,
        destination: destination,
        motion_basis: basis,
        consumed_extraction: chain ? &chain.extraction : null,
    )!;

    validate_live_extraction(playback, desc)!;
    if (chain || !desc.extraction.generalized) return unsupported;

    ModelTemplate* template = &assets.models.try_get(playback.model)!.data;
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        unsupported |= validate_generalized_motion(
            template: template,
            clip: &assets.clips.try_get(action.clip)!.data,
            root: playback.root_node,
            extraction: desc.extraction,
            motion_basis: basis,
            additive: action.additive,
        )!;
    }

    return unsupported;
}

fn bool? validate_action_desc(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationClip* clip,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
    RootExtractionDesc* consumed_extraction,
) @private {
    validate_playback_action(clip, desc, destination)!;

    Action motion;
    configure_motion(
        playback: playback,
        action: &motion,
        clip: clip,
        desc: desc,
        motion_basis: motion_basis,
        node_count: destination.base_pose.len,
    )!;

    bool unsupported;
    if (desc.additive && desc.additive_scale == AdditiveScaleMode.MULTIPLICATIVE) {
        unsupported = validate_multiplicative_scale(clip)!;
    }

    RootExtractionDesc* extraction = desc.extraction.generalized ? &desc.extraction : consumed_extraction;
    if (!extraction) return unsupported;

    unsupported |= validate_generalized_motion(
        template: &assets.models.try_get(playback.model)!.data,
        clip: clip,
        root: playback.root_node,
        extraction: *extraction,
        motion_basis: motion_basis,
        additive: desc.additive,
    )!;

    return unsupported;
}

fn void? validate_live_extraction(PlaybackView* playback, PlayDesc desc) @private {
    if (desc.root_motion != RootMotion.EXTRACT) return;

    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (action.root_motion == RootMotion.EXTRACT && !same_extraction(action.extraction, desc.extraction)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

// Planar extraction has one fixed frame; generalized frames must match exactly.
fn bool same_extraction(RootExtractionDesc first, RootExtractionDesc second) @private {
    if (!first.generalized && !second.generalized) return true;

    return first.generalized == second.generalized && first.up == second.up && first.twist == second.twist
      && first.translation_axes == second.translation_axes;
}

fn void? prepare_action_motion_capture(
    Allocator allocator,
    AssetStore* assets,
    ModelId model,
    Action* action,
    uint root_node,
) @private {
    if (!action.extraction.generalized) return;

    ModelTemplate* template = &assets.model(model).data;
    AnimationClip* clip = &assets.clip(action.clip).data;

    CapturedMotionChain* captured = alloc::new_try(allocator, CapturedMotionChain)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, captured);

    *captured = create_captured_motion_chain(
        allocator: allocator,
        template: template,
        clip: clip,
        root: root_node,
        extraction: action.extraction,
    )!;
    defer catch destroy_captured_motion_chain(captured);

    captured.pose_scale_sums = alloc::new_array_try(allocator, double[<3>], template.nodes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;

    action.motion_chain = captured;
    action.motion_reference = capture_generalized_motion_reference(captured, clip);
}

fn void? validate_motion_rotation_track(Track* track) @private {
    validate_motion_track_storage(track, TargetPath.ROTATION)!;

    uint key_count = (uint)track.times.len;
    for (uint key = 0; key < key_count; key++) {
        float[] value = motion_domain_key(track, (uint)key, CUBIC_SLOT_VALUE);
        bool nonzero;
        foreach (component : value) nonzero |= component != 0;
        if (!nonzero) return c3d::INVALID_ARGUMENT~;
    }
}

fn bool? validate_consumed_scale_track(Track* track, bool additive) @private {
    validate_motion_track_storage(track, TargetPath.SCALE)!;

    float[] reference = motion_domain_key(track, 0, CUBIC_SLOT_VALUE);

    uint key_count = (uint)track.times.len;
    for (uint key = 0; key < key_count; key++) {
        float[] value = motion_domain_key(track, (uint)key, CUBIC_SLOT_VALUE);
        if (additive) {
            for (uint component = 0; component < 3; component++) {
                if (value[component] != reference[component]) return c3d::INVALID_ARGUMENT~;
            }
        } else {
            for (uint component = 0; component < 3; component++) {
                if (!(value[component] > 0)) return c3d::INVALID_ARGUMENT~;
            }

            if (!motion_scale_uniform(value)) return c3d::INVALID_ARGUMENT~;
        }
    }

    return track.interpolation == Interpolation.CUBIC_SPLINE;
}

fn void? validate_motion_track_storage(Track* track, TargetPath path) @local {
    usz stride = path == TargetPath.ROTATION ? 4 : 3;
    usz slots = track.interpolation == Interpolation.CUBIC_SPLINE ? CUBIC_SLOTS_PER_KEY : 1;
    if (track.path != path || track.times.len == 0 || track.times.len > uint::max
        || track.times.len > usz::max / (slots * stride)
        || track.values.len != track.times.len * slots * stride) return c3d::INVALID_ARGUMENT~;

    foreach (key, time : track.times) {
        if (!math::is_finite(time) || (key && time <= track.times[key - 1])) return c3d::INVALID_ARGUMENT~;
    }

    foreach (value : track.values) {
        if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
    }
}

fn float[] motion_domain_key(Track* track, uint key, uint slot) @local {
    usz stride = track.stride();
    usz offset = track.interpolation == Interpolation.CUBIC_SPLINE
      ? ((usz)key * CUBIC_SLOTS_PER_KEY + slot) * stride : (usz)key * stride;

    return track.values[offset : stride];
}

fn bool motion_scale_uniform(float[] value) @local {
    foreach (smaller : value) foreach (larger : value) {
        if (smaller >= larger) continue;
        if ((double)smaller < (double)larger * 0.5) return false;

        // Within a factor of two the difference is exact, and the single fma rounding keeps its sign.
        if (math::fma((double)larger, MOTION_SCALE_EPSILON, (double)smaller - (double)larger) < 0) return false;
    }

    return true;
}
