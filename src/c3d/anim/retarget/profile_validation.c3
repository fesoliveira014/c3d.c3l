module c3d::anim::retarget;

import c3d;
import c3d::asset;
import c3d::maths;
import std::math;

fn void? validate_profile_templates(NodeTemplate[] source, NodeTemplate[] target) @private {
    if (source.len > uint::max || target.len > uint::max || !source.len || !target.len) {
        return c3d::INVALID_ARGUMENT~;
    }

    foreach (uint index, &node : source) {
        if (node.parent < -1 || (node.parent >= 0 && (uint)node.parent >= index)) return c3d::INVALID_ARGUMENT~;
        if (!profile_valid_transform(node.local)) return c3d::INVALID_ARGUMENT~;
    }

    foreach (uint index, &node : target) {
        if (node.parent < -1 || (node.parent >= 0 && (uint)node.parent >= index)) return c3d::INVALID_ARGUMENT~;
        if (!profile_valid_transform(node.local)) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? validate_profile_calibration(
    NodeTemplate[] source,
    NodeTemplate[] target,
    RetargetProfileDesc* desc,
) @private {
    if (desc.source_calibration.len != source.len || desc.target_calibration.len != target.len) {
        return c3d::INVALID_ARGUMENT~;
    }

    foreach (rotation : desc.source_calibration) {
        if (!profile_unit_rotation(rotation)) return c3d::INVALID_ARGUMENT~;
    }

    foreach (rotation : desc.target_calibration) {
        if (!profile_unit_rotation(rotation)) return c3d::INVALID_ARGUMENT~;
    }
}

fn Quat? profile_facing_rotation(Mat4 facing) @private {
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
    if (!valid) return c3d::INVALID_ARGUMENT~;

    return maths::transform_from_mat4(facing).rotation.normalize();
}

fn void? profile_bind(
    ProfileNode[] source,
    ProfileNode[] target,
    uint source_node,
    uint target_node,
) @private {
    if (source[source_node].mapped != RETARGET_NO_NODE || target[target_node].mapped != RETARGET_NO_NODE) {
        return c3d::ASSET_FORMAT_ERROR~;
    }

    source[source_node].mapped = target_node;
    target[target_node].mapped = source_node;
}

fn uint? profile_exact_node(ProfileNode[] nodes, String name) @private {
    uint found = RETARGET_NO_NODE;

    foreach (uint index, &node : nodes) {
        if (node.name != name) continue;
        if (found != RETARGET_NO_NODE) return c3d::ASSET_FORMAT_ERROR~;

        found = index;
    }

    if (found == RETARGET_NO_NODE) return c3d::ASSET_FORMAT_ERROR~;

    return found;
}

fn void? prepare_profile_bindings(
    ProfileNode[] source,
    ProfileNode[] target,
    RetargetProfileDesc* desc,
) @private {
    switch (desc.mapping_mode) {
        case BY_INDEX:
            if (desc.name_map.len) return c3d::ASSET_FORMAT_ERROR~;

            foreach (mapping : desc.index_map) {
                if (mapping.source_node >= source.len || mapping.target_node >= target.len) {
                    return c3d::ASSET_FORMAT_ERROR~;
                }

                profile_bind(
                    source: source,
                    target: target,
                    source_node: mapping.source_node,
                    target_node: mapping.target_node,
                )!;
            }
        case BY_NAME:
            if (desc.index_map.len) return c3d::ASSET_FORMAT_ERROR~;

            foreach (mapping : desc.name_map) {
                profile_bind(
                    source: source,
                    target: target,
                    source_node: profile_exact_node(source, mapping.source)!,
                    target_node: profile_exact_node(target, mapping.target)!,
                )!;
            }

            foreach (uint source_node, &node : source) {
                if (node.mapped != RETARGET_NO_NODE) continue;
                String key = canonical(node.name);
                uint target_node = RETARGET_NO_NODE;

                foreach (uint index, &candidate : target) {
                    if (canonical(candidate.name) != key) continue;
                    if (target_node != RETARGET_NO_NODE) return c3d::ASSET_FORMAT_ERROR~;

                    target_node = index;
                }

                if (target_node == RETARGET_NO_NODE) continue;

                for (usz index = (usz)source_node + 1; index < source.len; index++) {
                    if (source[index].mapped == RETARGET_NO_NODE && canonical(source[index].name) == key) {
                        return c3d::ASSET_FORMAT_ERROR~;
                    }
                }

                profile_bind(
                    source: source,
                    target: target,
                    source_node: source_node,
                    target_node: target_node,
                )!;
            }
    }
}

fn void? prepare_profile_motion(
    ProfileNode[] source,
    ProfileNode[] target,
    RetargetProfileDesc* desc,
) @private {
    if (desc.source_motion_node == RETARGET_NO_NODE && desc.target_motion_node == RETARGET_NO_NODE) return;
    if (desc.source_motion_node >= source.len || desc.target_motion_node >= target.len
        || source[desc.source_motion_node].mapped != desc.target_motion_node) {
        return c3d::INVALID_ARGUMENT~;
    }

    for (int ancestor = (int)desc.source_motion_node; ancestor >= 0; ancestor = source[ancestor].parent) {
        source[ancestor].motion = true;
        uint destination = source[ancestor].mapped;
        if (destination != RETARGET_NO_NODE) target[destination].motion = true;
    }
}

fn void? validate_profile_carrier(ProfileNode[] nodes, ModelTemplate* target, uint carrier) @private {
    if (carrier == RETARGET_NO_NODE) return;
    if (carrier >= nodes.len) return c3d::INVALID_ARGUMENT~;

    foreach (uint index, &node : nodes) {
        if (node.mapped != RETARGET_NO_NODE && !profile_descendant(nodes, index, carrier)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }

    for (int ancestor = (int)carrier; ancestor >= 0; ancestor = nodes[ancestor].parent) {
        Vec3 up = nodes[ancestor].authored.rotation.rotate_vec3({ 0, 1, 0 });
        if ((up - (Vec3){ 0, 1, 0 }).length() > PROFILE_FRAME_TOLERANCE) return c3d::INVALID_ARGUMENT~;
    }

    foreach (&mesh : target.meshes) validate_carrier_member(nodes, carrier, mesh.node)!;

    foreach (&group : target.lod_groups) validate_carrier_member(nodes, carrier, group.node)!;

    foreach (&skin : target.skins) {
        validate_carrier_member(nodes, carrier, skin.mesh_node)!;

        foreach (joint : skin.joint_nodes) validate_carrier_member(nodes, carrier, joint)!;
    }
}

fn void? validate_carrier_member(ProfileNode[] nodes, uint carrier, uint member) @private {
    if (member >= nodes.len || !profile_descendant(nodes, member, carrier)) return c3d::INVALID_ARGUMENT~;
}

fn void? validate_profile_snapshot(ProfileNode[] snapshot, NodeTemplate[] nodes) @private {
    if (snapshot.len != nodes.len) return c3d::INVALID_ARGUMENT~;

    foreach (uint index, &node : nodes) {
        Transform captured = snapshot[index].authored;
        if (node.name != snapshot[index].name || node.parent != snapshot[index].parent
            || node.local.position != captured.position || node.local.rotation.v != captured.rotation.v
            || node.local.scale != captured.scale) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}
