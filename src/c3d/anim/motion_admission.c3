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

fn void? validate_generalized_motion(
    ModelTemplate* template,
    AnimationClip* clip,
    uint root,
    RootExtractionDesc extraction,
    MotionBasis motion_basis,
    bool additive,
    AdditiveScaleMode additive_scale,
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
                    ConsumedScaleDomain domain = classify_consumed_scale_track(track, additive)!;
                    unsupported |= domain == ConsumedScaleDomain.SAMPLING_UNPROVEN;
            }
        }
    }

    if (unsupported) return c3d::UNSUPPORTED~;
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
