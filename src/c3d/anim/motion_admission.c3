module c3d::anim;

import c3d;
import c3d::asset;
import c3d::maths;
import std::math;

const double MOTION_UP_UNIT_TOLERANCE @local = 1e-5; // Bounds squared-length error of the captured twist axis.
const double MOTION_FRAME_ORTHONORMAL_TOLERANCE @local = 1e-5; // Bounds axis length, dot and handedness error.
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
    Transform reference;
    double reference_scale;
}

struct CapturedMotionChain @private {
    Allocator allocator;
    ModelId model;
    uint root_node;
    uint clip_track_count;
    RootExtractionDesc extraction;
    CapturedMotionNode[] nodes;
    double[<3>][] pose_scale_sums;
    uint[] top_level_nodes;
    String[] model_names;
    int[] model_parents;
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
    validate_motion_model_layout(template, clip, root)!;
    validate_motion_up(extraction)!;

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
                    if (catch excuse = validate_motion_rotation_track(track)) {
                        if (excuse != c3d::UNSUPPORTED) return excuse~;
                        unsupported = true;
                    }
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
    validate_motion_model_layout(template, clip, root)!;
    validate_motion_up(extraction)!;

    sz chain_count;
    for (int node = (int)root; node >= 0; node = template.nodes[node].parent) chain_count++;
    sz top_level_count;
    foreach (node : template.nodes) if (node.parent < 0) top_level_count++;

    CapturedMotionChain captured = {
        .allocator = allocator,
        .root_node = root,
        .clip_track_count = (uint)clip.tracks.len,
        .extraction = extraction,
    };
    defer catch destroy_captured_motion_chain(&captured);

    captured.nodes = alloc::new_array_try(allocator, CapturedMotionNode, chain_count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    captured.top_level_nodes = alloc::new_array_try(allocator, uint, top_level_count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    captured.model_names = alloc::new_array_try(allocator, String, template.nodes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    captured.model_parents = alloc::new_array_try(allocator, int, template.nodes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;

    // This temporary node-to-chain map shares the final parent array during capture.
    captured.model_parents[..] = -1;
    uint chain_index;
    for (int node = (int)root; node >= 0; node = template.nodes[node].parent) {
        captured.nodes[chain_index] = {
            .model_node = (uint)node,
            .translation_track = NO_MOTION_TRACK,
            .rotation_track = NO_MOTION_TRACK,
            .scale_track = NO_MOTION_TRACK,
            .baseline = template.nodes[node].local,
            .reference = template.nodes[node].local,
        };
        captured.model_parents[node] = (int)chain_index++;
    }

    foreach (track_index, track : clip.tracks) {
        int index = captured.model_parents[clip.targets[track.target]];
        if (index < 0) continue;
        CapturedMotionNode* node = &captured.nodes[index];

        switch (track.path) {
            case TRANSLATION:
                node.translation_track = (uint)track_index;
            case ROTATION:
                node.rotation_track = (uint)track_index;
            case SCALE:
                node.scale_track = (uint)track_index;
            case MORPH_WEIGHTS:
                continue;
        }
    }

    uint top_level_index;
    foreach (index, node : template.nodes) {
        char[] name = alloc::new_array_try(allocator, char, node.name.len) ?? c3d::CAPACITY_EXCEEDED~!;
        name[..] = node.name[..];
        captured.model_names[index] = (String)name;
        captured.model_parents[index] = node.parent;
        if (node.parent < 0) captured.top_level_nodes[top_level_index++] = (uint)index;
    }

    foreach (&node : captured.nodes) capture_motion_reference(node, clip);

    return captured;
}

fn void destroy_captured_motion_chain(CapturedMotionChain* captured) @private {
    foreach (name : captured.model_names) alloc::free(captured.allocator, name.ptr);
    alloc::free(captured.allocator, captured.nodes.ptr);
    alloc::free(captured.allocator, captured.pose_scale_sums.ptr);
    alloc::free(captured.allocator, captured.top_level_nodes.ptr);
    alloc::free(captured.allocator, captured.model_names.ptr);
    alloc::free(captured.allocator, captured.model_parents.ptr);

    *captured = {};
}

fn void? validate_motion_model_layout(ModelTemplate* template, AnimationClip* clip, uint root) @local {
    if (root >= template.nodes.len || template.nodes.len > int::max || clip.tracks.len > uint::max) {
        return c3d::INVALID_ARGUMENT~;
    }

    foreach (index, node : template.nodes) {
        if (node.parent < -1 || node.parent >= index) return c3d::INVALID_ARGUMENT~;
    }

    foreach (target : clip.targets) {
        if (target >= template.nodes.len) return c3d::INVALID_ARGUMENT~;
    }

    foreach (track : clip.tracks) {
        if (track.target >= clip.targets.len) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? validate_motion_up(RootExtractionDesc extraction) @local {
    Vec3 up = extraction.up;
    double squared = (double)up.x * (double)up.x + (double)up.y * (double)up.y + (double)up.z * (double)up.z;
    if (!extraction.generalized || !math::is_finite(up.x) || !math::is_finite(up.y)
        || !math::is_finite(up.z) || math::abs(squared - 1) > MOTION_UP_UNIT_TOLERANCE) {
        return c3d::INVALID_ARGUMENT~;
    }
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

    bool nonzero;
    foreach (component : baseline.rotation.v) {
        if (!math::is_finite(component)) return c3d::INVALID_ARGUMENT~;
        nonzero |= component != 0;
    }
    if (!nonzero) return c3d::INVALID_ARGUMENT~;

    double quaternion_x = baseline.rotation.v.x;
    double quaternion_y = baseline.rotation.v.y;
    double quaternion_z = baseline.rotation.v.z;
    double quaternion_w = baseline.rotation.v.w;
    double square_x = quaternion_x * quaternion_x;
    double square_y = quaternion_y * quaternion_y;
    double square_z = quaternion_z * quaternion_z;
    double product_xy = quaternion_x * quaternion_y;
    double product_xz = quaternion_x * quaternion_z;
    double product_yz = quaternion_y * quaternion_z;
    double product_xw = quaternion_x * quaternion_w;
    double product_yw = quaternion_y * quaternion_w;
    double product_zw = quaternion_z * quaternion_w;

    // The standard conversion normalizes first, which would conceal a malformed authored frame.
    double[3][3] columns = {
        { 1 - 2 * square_y - 2 * square_z, 2 * (product_xy + product_zw), 2 * (product_xz - product_yw) },
        { 2 * (product_xy - product_zw), 1 - 2 * square_x - 2 * square_z, 2 * (product_yz + product_xw) },
        { 2 * (product_xz + product_yw), 2 * (product_yz - product_xw), 1 - 2 * square_x - 2 * square_y },
    };

    foreach (&column : columns) {
        double squared;
        foreach (component : *column) {
            if (!math::is_finite(component)) return c3d::INVALID_ARGUMENT~;
            squared += component * component;
        }
        double length = math::sqrt(squared);
        if (!(length > 0) || math::abs(length - 1) > MOTION_FRAME_ORTHONORMAL_TOLERANCE) {
            return c3d::INVALID_ARGUMENT~;
        }
        foreach (&component : *column) *component /= length;
    }

    for (uint left = 0; left < 3; left++) {
        for (uint right = left + 1; right < 3; right++) {
            double product;
            for (uint component = 0; component < 3; component++) {
                product += columns[left][component] * columns[right][component];
            }
            if (math::abs(product) > MOTION_FRAME_ORTHONORMAL_TOLERANCE) return c3d::INVALID_ARGUMENT~;
        }
    }

    double determinant = columns[0][0] * (columns[1][1] * columns[2][2] - columns[1][2] * columns[2][1])
      - columns[0][1] * (columns[1][0] * columns[2][2] - columns[1][2] * columns[2][0])
      + columns[0][2] * (columns[1][0] * columns[2][1] - columns[1][1] * columns[2][0]);
    if (determinant < 1 - MOTION_FRAME_ORTHONORMAL_TOLERANCE) return c3d::INVALID_ARGUMENT~;
}

fn void capture_motion_reference(CapturedMotionNode* node, AnimationClip* clip) @local {
    double[4] values;
    double[4] rates;
    uint cursor;

    if (node.translation_track != NO_MOTION_TRACK) {
        sample_track_analytic(
            track: &clip.tracks[node.translation_track],
            time: 0,
            cursor: &cursor,
            value: values[:3],
            rate: rates[:3],
        );
        node.reference.position = { (float)values[0], (float)values[1], (float)values[2] };
    }

    if (node.rotation_track != NO_MOTION_TRACK) {
        cursor = 0;
        sample_track_analytic(
            track: &clip.tracks[node.rotation_track],
            time: 0,
            cursor: &cursor,
            value: values[..],
            rate: rates[..],
        );
        node.reference.rotation = { .v = { (float)values[0], (float)values[1], (float)values[2], (float)values[3] } };
    }

    if (node.scale_track != NO_MOTION_TRACK) {
        cursor = 0;
        sample_track_analytic(
            track: &clip.tracks[node.scale_track],
            time: 0,
            cursor: &cursor,
            value: values[:3],
            rate: rates[:3],
        );
        node.reference.scale = { (float)values[0], (float)values[1], (float)values[2] };
        node.reference_scale = (values[0] + values[1] + values[2]) / 3;
    } else {
        Vec3 scale = node.reference.scale;
        node.reference_scale = ((double)scale.x + (double)scale.y + (double)scale.z) / 3;
    }
}
