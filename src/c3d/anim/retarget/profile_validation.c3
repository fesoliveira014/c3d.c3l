module c3d::anim::retarget;

import c3d;
import c3d::asset;
import c3d::maths;
import std::math;

fn void? validate_profile_templates(
    NodeTemplate[] source,
    NodeTemplate[] target,
    RetargetDiagnostic* diagnostic,
) @private {
    if (source.len > uint::max || target.len > uint::max || !source.len || !target.len) {
        return profile_failure(diagnostic, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_TEMPLATE)~;
    }
    foreach (uint index, &node : source) {
        if (node.parent < -1 || (node.parent >= 0 && (uint)node.parent >= index)) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.INVALID_TEMPLATE,
                source_node: index,
            )~;
        }
        if (!profile_valid_transform(node.local)) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.INVALID_STATIC_TRANSFORM,
                source_node: index,
            )~;
        }
    }
    foreach (uint index, &node : target) {
        if (node.parent < -1 || (node.parent >= 0 && (uint)node.parent >= index)) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.INVALID_TEMPLATE,
                target_node: index,
            )~;
        }
        if (!profile_valid_transform(node.local)) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.INVALID_STATIC_TRANSFORM,
                target_node: index,
            )~;
        }
    }
}

fn void? validate_profile_calibration(
    NodeTemplate[] source,
    NodeTemplate[] target,
    RetargetProfileDesc* desc,
    RetargetDiagnostic* diagnostic,
) @private {
    if (desc.source_calibration.len != source.len || desc.target_calibration.len != target.len) {
        return profile_failure(diagnostic, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_CALIBRATION)~;
    }
    foreach (uint index, rotation : desc.source_calibration) {
        if (!profile_unit_rotation(rotation)) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.INVALID_CALIBRATION,
                source_node: index,
            )~;
        }
    }
    foreach (uint index, rotation : desc.target_calibration) {
        if (!profile_unit_rotation(rotation)) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.INVALID_CALIBRATION,
                target_node: index,
            )~;
        }
    }
}

fn Quat? profile_facing_rotation(Mat4 facing, RetargetDiagnostic* diagnostic) @private {
    Vec3 axis_x = { facing.m00, facing.m10, facing.m20 };
    Vec3 axis_y = { facing.m01, facing.m11, facing.m21 };
    Vec3 axis_z = { facing.m02, facing.m12, facing.m22 };
    bool valid = profile_finite_vec(axis_x) && profile_finite_vec(axis_y) && profile_finite_vec(axis_z)
      && facing.m03 == 0 && facing.m13 == 0 && facing.m23 == 0
      && facing.m30 == 0 && facing.m31 == 0 && facing.m32 == 0 && facing.m33 == 1
      && math::abs(axis_x.length() - 1) <= PROFILE_FRAME_TOLERANCE
      && math::abs(axis_z.length() - 1) <= PROFILE_FRAME_TOLERANCE
      && (axis_y - (Vec3){ 0, 1, 0 }).length() <= PROFILE_FRAME_TOLERANCE
      && math::abs(axis_x.y) <= PROFILE_FRAME_TOLERANCE
      && math::abs(axis_z.y) <= PROFILE_FRAME_TOLERANCE
      && math::abs(axis_x.dot(axis_z)) <= PROFILE_FRAME_TOLERANCE
      && math::abs(axis_x.dot(axis_y.cross(axis_z)) - 1) <= PROFILE_FRAME_TOLERANCE;
    if (!valid) {
        return profile_failure(diagnostic, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_FACING_BASIS)~;
    }
    return maths::transform_from_mat4(facing).rotation.normalize();
}

fn void? profile_bind(
    ProfileNode[] source,
    ProfileNode[] target,
    uint source_node,
    uint target_node,
    uint row,
    RetargetDiagnostic* diagnostic,
) @private {
    if (source[source_node].mapped != RETARGET_NO_NODE || target[target_node].mapped != RETARGET_NO_NODE) {
        return profile_failure(
            diagnostic: diagnostic,
            excuse: c3d::ASSET_FORMAT_ERROR,
            reason: RetargetReason.CONFLICTING_MAPPING,
            source_node: source_node,
            target_node: target_node,
            mapping_row: row,
        )~;
    }
    source[source_node].mapped = target_node;
    source[source_node].mapping_row = row;
    target[target_node].mapped = source_node;
    target[target_node].mapping_row = row;
}

fn uint? profile_exact_node(
    ProfileNode[] nodes,
    String name,
    bool source,
    uint row,
    RetargetDiagnostic* diagnostic,
) @private {
    uint found = RETARGET_NO_NODE;
    foreach (uint index, &node : nodes) {
        if (node.name != name) continue;
        if (found != RETARGET_NO_NODE) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::ASSET_FORMAT_ERROR,
                reason: source ? RetargetReason.AMBIGUOUS_SOURCE : RetargetReason.AMBIGUOUS_TARGET,
                source_node: source ? found : RETARGET_NO_NODE,
                target_node: source ? RETARGET_NO_NODE : found,
                mapping_row: row,
            )~;
        }
        found = index;
    }
    if (found == RETARGET_NO_NODE) {
        return profile_failure(
            diagnostic: diagnostic,
            excuse: c3d::ASSET_FORMAT_ERROR,
            reason: source ? RetargetReason.MISSING_SOURCE : RetargetReason.MISSING_TARGET,
            mapping_row: row,
        )~;
    }
    return found;
}

fn void? prepare_profile_bindings(
    ProfileNode[] source,
    ProfileNode[] target,
    RetargetProfileDesc* desc,
    RetargetDiagnostic* diagnostic,
) @private {
    switch (desc.mapping_mode) {
        case BY_INDEX:
            if (desc.name_map.len) {
                return profile_failure(
                    diagnostic: diagnostic,
                    excuse: c3d::ASSET_FORMAT_ERROR,
                    reason: RetargetReason.CONFLICTING_MAPPING,
                    mapping_row: 0,
                )~;
            }
            foreach (uint row, mapping : desc.index_map) {
                if (mapping.source_node >= source.len || mapping.target_node >= target.len) {
                    return profile_failure(
                        diagnostic: diagnostic,
                        excuse: c3d::ASSET_FORMAT_ERROR,
                        reason: RetargetReason.INVALID_MAPPING_INDEX,
                        source_node: mapping.source_node,
                        target_node: mapping.target_node,
                        mapping_row: row,
                    )~;
                }
                profile_bind(
                    source: source,
                    target: target,
                    source_node: mapping.source_node,
                    target_node: mapping.target_node,
                    row: row,
                    diagnostic: diagnostic,
                )!;
            }
        case BY_NAME:
            if (desc.index_map.len) {
                return profile_failure(
                    diagnostic: diagnostic,
                    excuse: c3d::ASSET_FORMAT_ERROR,
                    reason: RetargetReason.CONFLICTING_MAPPING,
                    source_node: desc.index_map[0].source_node,
                    target_node: desc.index_map[0].target_node,
                    mapping_row: 0,
                )~;
            }
            foreach (uint row, mapping : desc.name_map) {
                uint source_node = profile_exact_node(
                    nodes: source,
                    name: mapping.source,
                    source: true,
                    row: row,
                    diagnostic: diagnostic,
                )!;
                uint target_node = profile_exact_node(
                    nodes: target,
                    name: mapping.target,
                    source: false,
                    row: row,
                    diagnostic: diagnostic,
                )!;
                profile_bind(
                    source: source,
                    target: target,
                    source_node: source_node,
                    target_node: target_node,
                    row: row,
                    diagnostic: diagnostic,
                )!;
            }
            foreach (uint source_node, &node : source) {
                if (node.mapped != RETARGET_NO_NODE) continue;
                String key = canonical(node.name);
                uint target_node = RETARGET_NO_NODE;
                foreach (uint index, &candidate : target) {
                    if (canonical(candidate.name) != key) continue;
                    if (target_node != RETARGET_NO_NODE) {
                        return profile_failure(
                            diagnostic: diagnostic,
                            excuse: c3d::ASSET_FORMAT_ERROR,
                            reason: RetargetReason.AMBIGUOUS_TARGET,
                            source_node: source_node,
                            target_node: target_node,
                        )~;
                    }
                    target_node = index;
                }
                if (target_node == RETARGET_NO_NODE) continue;
                for (usz index = (usz)source_node + 1; index < source.len; index++) {
                    if (source[index].mapped == RETARGET_NO_NODE && canonical(source[index].name) == key) {
                        return profile_failure(
                            diagnostic: diagnostic,
                            excuse: c3d::ASSET_FORMAT_ERROR,
                            reason: RetargetReason.AMBIGUOUS_SOURCE,
                            source_node: source_node,
                            target_node: target_node,
                        )~;
                    }
                }
                profile_bind(
                    source: source,
                    target: target,
                    source_node: source_node,
                    target_node: target_node,
                    row: RETARGET_NO_NODE,
                    diagnostic: diagnostic,
                )!;
            }
    }
}

fn void? prepare_profile_motion(
    ProfileNode[] source,
    ProfileNode[] target,
    RetargetProfileDesc* desc,
    RetargetDiagnostic* diagnostic,
) @private {
    if (desc.source_motion_node == RETARGET_NO_NODE && desc.target_motion_node == RETARGET_NO_NODE) return;
    if (desc.source_motion_node >= source.len || desc.target_motion_node >= target.len
        || source[desc.source_motion_node].mapped != desc.target_motion_node) {
        return profile_failure(
            diagnostic: diagnostic,
            excuse: c3d::INVALID_ARGUMENT,
            reason: RetargetReason.INVALID_MOTION_PAIR,
            source_node: desc.source_motion_node,
            target_node: desc.target_motion_node,
        )~;
    }
    for (int ancestor = (int)desc.source_motion_node; ancestor >= 0; ancestor = source[ancestor].parent) {
        source[ancestor].motion = true;
        uint destination = source[ancestor].mapped;
        if (destination != RETARGET_NO_NODE) target[destination].motion = true;
    }
}

fn void? validate_profile_carrier(
    ProfileNode[] nodes,
    ModelTemplate* target,
    uint carrier,
    RetargetDiagnostic* diagnostic,
) @private {
    if (carrier == RETARGET_NO_NODE) return;
    if (carrier >= nodes.len) {
        return profile_failure(
            diagnostic: diagnostic,
            excuse: c3d::INVALID_ARGUMENT,
            reason: RetargetReason.INVALID_MOTION_CARRIER,
            target_node: carrier,
        )~;
    }
    foreach (uint index, &node : nodes) {
        if (node.mapped != RETARGET_NO_NODE && !profile_descendant(nodes, index, carrier)) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.INVALID_MOTION_CARRIER,
                source_node: node.mapped,
                target_node: index,
                mapping_row: node.mapping_row,
            )~;
        }
    }
    for (int ancestor = (int)carrier; ancestor >= 0; ancestor = nodes[ancestor].parent) {
        Vec3 up = nodes[ancestor].authored.rotation.rotate_vec3({ 0, 1, 0 });
        if ((up - (Vec3){ 0, 1, 0 }).length() > PROFILE_FRAME_TOLERANCE) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.INVALID_MOTION_CARRIER,
                target_node: (uint)ancestor,
            )~;
        }
    }
    foreach (&mesh : target.meshes) {
        validate_carrier_member(
            nodes: nodes,
            carrier: carrier,
            member: mesh.node,
            diagnostic: diagnostic,
        )!;
    }
    foreach (&group : target.lod_groups) {
        validate_carrier_member(
            nodes: nodes,
            carrier: carrier,
            member: group.node,
            diagnostic: diagnostic,
        )!;
    }
    foreach (&skin : target.skins) {
        validate_carrier_member(
            nodes: nodes,
            carrier: carrier,
            member: skin.mesh_node,
            diagnostic: diagnostic,
        )!;
        foreach (joint : skin.joint_nodes) validate_carrier_member(
            nodes: nodes,
            carrier: carrier,
            member: joint,
            diagnostic: diagnostic,
        )!;
    }
}

fn void? validate_carrier_member(
    ProfileNode[] nodes,
    uint carrier,
    uint member,
    RetargetDiagnostic* diagnostic,
) @private {
    if (member >= nodes.len || !profile_descendant(nodes, member, carrier)) {
        return profile_failure(
            diagnostic: diagnostic,
            excuse: c3d::INVALID_ARGUMENT,
            reason: RetargetReason.INVALID_MOTION_CARRIER,
            target_node: member,
        )~;
    }
}

fn void? validate_profile_snapshot(
    ProfileNode[] snapshot,
    NodeTemplate[] nodes,
    bool source,
    RetargetDiagnostic* diagnostic,
) @private {
    if (snapshot.len != nodes.len) {
        return profile_failure(diagnostic, c3d::INVALID_ARGUMENT, RetargetReason.TEMPLATE_LAYOUT_MISMATCH)~;
    }
    foreach (uint index, &node : nodes) {
        if (node.name != snapshot[index].name) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.TEMPLATE_LAYOUT_MISMATCH,
                source_node: source ? index : RETARGET_NO_NODE,
                target_node: source ? RETARGET_NO_NODE : index,
            )~;
        }
        Transform captured = snapshot[index].authored;
        if (node.parent != snapshot[index].parent || node.local.position != captured.position
            || node.local.rotation.v != captured.rotation.v || node.local.scale != captured.scale) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.TEMPLATE_REFERENCE_MISMATCH,
                source_node: source ? index : RETARGET_NO_NODE,
                target_node: source ? RETARGET_NO_NODE : index,
            )~;
        }
    }
}
