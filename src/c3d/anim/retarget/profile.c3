module c3d::anim::retarget;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import std::math;

<* Absent node or mapping-row context, never an error result. *>
const uint RETARGET_NO_NODE = uint::max;

<* Generated keys per second in a calibrated clip. *>
const float PROFILE_BAKE_RATE_DEFAULT = 60; // 60 intervals/s per generated track balance interpolation error and clip size

<* Name matching with a virtual boundary and identity facing. *>
const RetargetProfileDesc RETARGET_PROFILE_DESC_DEFAULT = {
    .mapping_mode = ProfileMappingMode.BY_NAME,
    .source_motion_node = RETARGET_NO_NODE,
    .target_motion_node = RETARGET_NO_NODE,
    .target_carrier = RETARGET_NO_NODE,
    .facing = matrix::IDENTITY4,
};

<* Preserve full motion with endpoint-inclusive sixty-hertz keys. *>
const RetargetBakeOptions RETARGET_BAKE_OPTIONS_DEFAULT = {
    .root_motion = RootMotion.KEEP,
    .bake_rate = PROFILE_BAKE_RATE_DEFAULT,
    .root_translation_scale = 1,
};

const float PROFILE_FRAME_TOLERANCE @private = 1e-5f; // bounds accepted frame roundoff in rotations, facing and uniform scale
const float PROFILE_KEY_SNAP @private = 0.001f; // avoids an extra interval from roundoff at intended grid endpoints
const uint PROFILE_MAX_INTERVALS @private = 1u << 24; // float key indices cease representing every integer above this bound

<* Authoritative indices or unique names select node correspondences. *>
enum ProfileMappingMode {
    BY_NAME,
    BY_INDEX,
}

<* Precise context accompanying an existing root fault. *>
enum RetargetReason {
    NONE,
    INVALID_PROFILE,
    INVALID_TEMPLATE,
    INVALID_CALIBRATION,
    INVALID_FACING_BASIS,
    INVALID_STATIC_TRANSFORM,
    INVALID_MOTION_PAIR,
    INVALID_MOTION_CARRIER,
    INVALID_BAKE_OPTIONS,
    MISSING_SOURCE,
    MISSING_TARGET,
    AMBIGUOUS_SOURCE,
    AMBIGUOUS_TARGET,
    CONFLICTING_MAPPING,
    INVALID_MAPPING_INDEX,
    TEMPLATE_LAYOUT_MISMATCH,
    TEMPLATE_REFERENCE_MISMATCH,
    INVALID_CLIP,
    UNMATCHED_SOURCE,
    INVALID_MORPH_STRIDE,
    UNSUPPORTED_ANIMATED_TRANSFORM,
    CAPACITY_LIMIT,
}

<* One source node corresponds to one target node. *>
struct NodeIndexMapping {
    uint source_node;
    uint target_node;
}

<* Caller-owned context containing no borrowed data. *>
struct RetargetDiagnostic {
    RetargetReason reason;
    uint source_node;
    uint target_node;
    uint mapping_row;
}

<* Immutable calibration and mapping inputs copied during preparation. *>
struct RetargetProfileDesc {
    ProfileMappingMode mapping_mode;
    NodeIndexMapping[] index_map;
    NameMapping[] name_map;
    Quat[] source_calibration;
    Quat[] target_calibration;
    uint source_motion_node;
    uint target_motion_node;
    uint target_carrier;
    Mat4 facing;
}

<* Sole owner of immutable preparation; copied values are borrowed aliases. *>
struct RetargetProfile {
    void* data;
}

<* Finite positive cadence and translation scale for calibrated baking. *>
struct RetargetBakeOptions {
    RootMotion root_motion;
    bool allow_partial;
    float bake_rate;
    float root_translation_scale;
}

struct ProfileNode @private {
    String name;
    int parent;
    Transform authored;
    Quat calibration;
    Transform reference;
    uint mapped;
    uint mapping_row;
    bool consumed;
    bool motion;
    bool controlled;
    bool boundary;
}

struct ProfileData @private {
    Allocator allocator;
    ProfileNode[] source_nodes;
    ProfileNode[] target_nodes;
    Quat facing;
    uint source_motion_node;
    uint target_motion_node;
    uint target_carrier;
    usz bytes;
}

<*
 Validate the exact template pair and reserved carrier.
 @param source_nodes : "Current imported source template."
 @param [&in] target : "Current destination template."
 @param [inout] diagnostic : "Optional deterministic failure context."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? RetargetProfile.validate_templates(
    &self,
    NodeTemplate[] source_nodes,
    ModelTemplate* target,
    RetargetDiagnostic* diagnostic = null,
) {
    clear_retarget_diagnostic(diagnostic);
    if (!self.data) {
        return profile_failure(diagnostic, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_PROFILE)~;
    }
    ProfileData* data = (ProfileData*)self.data;
    validate_profile_snapshot(
        snapshot: data.source_nodes,
        nodes: source_nodes,
        source: true,
        diagnostic: diagnostic,
    )!;
    validate_profile_snapshot(
        snapshot: data.target_nodes,
        nodes: target.nodes,
        source: false,
        diagnostic: diagnostic,
    )!;
    validate_profile_carrier(
        nodes: data.target_nodes,
        target: target,
        carrier: data.target_carrier,
        diagnostic: diagnostic,
    )!;
}

<*
 Prepare an owning immutable calibration for an exact template pair.
 @param source_nodes : "Borrowed only during preparation."
 @param [&in] target : "Authored transforms remain unchanged."
 @param [inout] diagnostic : "Optional deterministic failure context."
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_FORMAT_ERROR, c3d::CAPACITY_EXCEEDED
*>
fn RetargetProfile? create_retarget_profile(
    Allocator allocator,
    NodeTemplate[] source_nodes,
    ModelTemplate* target,
    RetargetProfileDesc desc,
    RetargetDiagnostic* diagnostic = null,
) {
    clear_retarget_diagnostic(diagnostic);
    defer catch {
        if (diagnostic && diagnostic.reason == RetargetReason.NONE) {
            diagnostic.reason = RetargetReason.CAPACITY_LIMIT;
        }
    }
    @pool() {
        validate_profile_templates(source_nodes, target.nodes, diagnostic)!;
        validate_profile_calibration(
            source: source_nodes,
            target: target.nodes,
            desc: &desc,
            diagnostic: diagnostic,
        )!;
        Quat facing = profile_facing_rotation(desc.facing, diagnostic)!;
        ProfileNode[] source = alloc::new_array_try(tmem, ProfileNode, source_nodes.len)
            ?? c3d::CAPACITY_EXCEEDED~!;
        ProfileNode[] destination = alloc::new_array_try(tmem, ProfileNode, target.nodes.len)
            ?? c3d::CAPACITY_EXCEEDED~!;
        foreach (index, &node : source_nodes) {
            source[index] = {
                .name = node.name,
                .parent = node.parent,
                .authored = node.local,
                .calibration = desc.source_calibration[index].normalize(),
                .mapped = RETARGET_NO_NODE,
                .mapping_row = RETARGET_NO_NODE,
            };
        }
        foreach (index, &node : target.nodes) {
            destination[index] = {
                .name = node.name,
                .parent = node.parent,
                .authored = node.local,
                .calibration = node.local.rotation.normalize(),
                .mapped = RETARGET_NO_NODE,
                .mapping_row = RETARGET_NO_NODE,
            };
        }
        prepare_profile_bindings(
            source: source,
            target: destination,
            desc: &desc,
            diagnostic: diagnostic,
        )!;
        foreach (index, &node : destination) {
            if (node.mapped != RETARGET_NO_NODE) node.calibration = desc.target_calibration[index].normalize();
        }
        prepare_profile_motion(
            source: source,
            target: destination,
            desc: &desc,
            diagnostic: diagnostic,
        )!;
        validate_profile_carrier(
            nodes: destination,
            target: target,
            carrier: desc.target_carrier,
            diagnostic: diagnostic,
        )!;
        foreach (index, &node : source) {
            if (node.mapped == RETARGET_NO_NODE) continue;
            for (int ancestor = (int)index; ancestor >= 0; ancestor = source[ancestor].parent) {
                source[ancestor].consumed = true;
            }
        }
        foreach (index, &node : destination) {
            node.controlled = desc.target_carrier == RETARGET_NO_NODE
              || profile_descendant(destination, (uint)index, desc.target_carrier);
            node.boundary = desc.target_carrier == RETARGET_NO_NODE
              ? node.parent < 0 : node.parent == (int)desc.target_carrier;
        }
        compose_profile_references(source, true, diagnostic)!;
        compose_profile_references(destination, false, diagnostic)!;

        usz header_bytes = profile_align(ProfileData::size, ProfileNode::alignment);
        usz node_count = source.len + destination.len;
        if (node_count > (usz)sz::max / ProfileNode::size) return c3d::CAPACITY_EXCEEDED~;
        usz node_bytes = node_count * ProfileNode::size;
        usz bytes = header_bytes + node_bytes;
        foreach (&node : source) bytes = profile_add_bytes(bytes, node.name.len)!;
        foreach (&node : destination) bytes = profile_add_bytes(bytes, node.name.len)!;
        void* storage = alloc::calloc_aligned(allocator, (sz)bytes, ProfileNode::alignment)
            ?? c3d::CAPACITY_EXCEEDED~!;
        ProfileData* data = (ProfileData*)storage;
        *data = {
            .allocator = allocator,
            .source_nodes = ((ProfileNode*)((char*)storage + header_bytes))[:source.len],
            .target_nodes = ((ProfileNode*)((char*)storage + header_bytes
              + source.len * ProfileNode::size))[:destination.len],
            .facing = facing,
            .source_motion_node = desc.source_motion_node,
            .target_motion_node = desc.target_motion_node,
            .target_carrier = desc.target_carrier,
            .bytes = bytes,
        };
        data.source_nodes[..] = source[..];
        data.target_nodes[..] = destination[..];
        char* names = (char*)storage + header_bytes + node_bytes;
        foreach (&node : data.source_nodes) copy_profile_name(node, &names);
        foreach (&node : data.target_nodes) copy_profile_name(node, &names);
        return { .data = data };
    };
}

<*
 Release the sole profile owner and clear its value.
 @param [&inout] profile : "Borrowed aliases must never be destroyed separately."
*>
fn void destroy_retarget_profile(RetargetProfile* profile) {
    if (!profile.data) return;
    ProfileData* data = (ProfileData*)profile.data;
    Allocator allocator = data.allocator;
    alloc::free_aligned(allocator, data);
    *profile = {};
}

fn void clear_retarget_diagnostic(RetargetDiagnostic* diagnostic) @private {
    if (diagnostic) *diagnostic = {
        .reason = RetargetReason.NONE,
        .source_node = RETARGET_NO_NODE,
        .target_node = RETARGET_NO_NODE,
        .mapping_row = RETARGET_NO_NODE,
    };
}

fn fault profile_failure(
    RetargetDiagnostic* diagnostic,
    fault excuse,
    RetargetReason reason,
    uint source_node = RETARGET_NO_NODE,
    uint target_node = RETARGET_NO_NODE,
    uint mapping_row = RETARGET_NO_NODE,
) @private {
    if (diagnostic) *diagnostic = {
        .reason = reason,
        .source_node = source_node,
        .target_node = target_node,
        .mapping_row = mapping_row,
    };
    return excuse;
}

fn bool profile_finite_vec(Vec3 value) @private {
    return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
}

fn bool profile_unit_rotation(Quat rotation) @private {
    foreach (value : rotation.v) if (!math::is_finite(value)) return false;
    return math::abs(rotation.v.dot(rotation.v) - 1) <= PROFILE_FRAME_TOLERANCE;
}

fn bool profile_uniform_scale(Vec3 scale) @private {
    if (!profile_finite_vec(scale) || scale.x <= 0 || scale.y <= 0 || scale.z <= 0) return false;
    float largest = math::max(scale.x, math::max(scale.y, scale.z));
    return math::abs(scale.x - scale.y) <= largest * PROFILE_FRAME_TOLERANCE
        && math::abs(scale.x - scale.z) <= largest * PROFILE_FRAME_TOLERANCE;
}

fn bool profile_valid_transform(Transform local) @private {
    return profile_finite_vec(local.position) && profile_unit_rotation(local.rotation)
        && profile_uniform_scale(local.scale);
}

fn Transform profile_compose(Transform parent, Transform local) @private {
    return {
        .position = parent.position + parent.rotation.rotate_vec3(local.position * parent.scale.x),
        .rotation = parent.rotation.mul(local.rotation).normalize(),
        .scale = local.scale * parent.scale.x,
    };
}

fn Transform profile_relative(Transform parent, Transform world) @private {
    return {
        .position = parent.rotation.conjugate().rotate_vec3(world.position - parent.position) / parent.scale.x,
        .rotation = parent.rotation.conjugate().mul(world.rotation).normalize(),
        .scale = world.scale / parent.scale.x,
    };
}

fn void? compose_profile_references(
    ProfileNode[] nodes,
    bool source,
    RetargetDiagnostic* diagnostic,
) @private {
    foreach (uint index, &node : nodes) {
        Transform local = node.authored;
        local.rotation = node.calibration;
        node.reference = node.parent < 0 ? local : profile_compose(nodes[node.parent].reference, local);
        if (!profile_valid_transform(node.reference)) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::INVALID_ARGUMENT,
                reason: RetargetReason.INVALID_STATIC_TRANSFORM,
                source_node: source ? index : RETARGET_NO_NODE,
                target_node: source ? RETARGET_NO_NODE : index,
            )~;
        }
    }
}

fn bool profile_descendant(ProfileNode[] nodes, uint node, uint ancestor) @private {
    for (int parent = nodes[node].parent; parent >= 0; parent = nodes[parent].parent) {
        if (parent == (int)ancestor) return true;
    }
    return false;
}

fn usz profile_align(usz value, usz alignment) @private => (value + alignment - 1) & ~(alignment - 1);

fn usz? profile_add_bytes(usz current, usz added) @private {
    if (current > (usz)sz::max || added > (usz)sz::max - current) return c3d::CAPACITY_EXCEEDED~;
    return current + added;
}

fn void copy_profile_name(ProfileNode* node, char** cursor) @private {
    String original = node.name;
    node.name = (String)(*cursor)[:original.len];
    node.name[..] = original[..];
    *cursor += original.len;
}
