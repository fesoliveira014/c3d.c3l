module c3d::anim::retarget;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import std::math;

<* Absent node in a profile description. *>
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

<* One source node corresponds to one target node. *>
struct NodeIndexMapping {
    uint source_node;
    uint target_node;
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
    bool consumed;
    bool requires_uniform_scale;
    bool motion;
}

struct ProfileData @private {
    Allocator allocator;
    ProfileNode[] source_nodes;
    ProfileNode[] target_nodes;
    Quat facing;
    uint source_motion_node;
    uint target_motion_node;
    uint target_carrier;
    uint target_boundary;
    usz bytes;
}

<*
 Validate the exact template pair and reserved carrier.
 @param source_nodes : "Current imported source template."
 @param [&in] target : "Current destination template."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? RetargetProfile.validate_templates(&self, NodeTemplate[] source_nodes, ModelTemplate* target) {
    if (!self.data) return c3d::INVALID_ARGUMENT~;

    ProfileData* data = (ProfileData*)self.data;
    validate_profile_snapshot(data.source_nodes, source_nodes)!;
    validate_profile_snapshot(data.target_nodes, target.nodes)!;
    validate_profile_carrier(data.target_nodes, target, data.target_carrier)!;
}

<*
 Prepare an owning immutable calibration for an exact template pair.
 @param source_nodes : "Borrowed only during preparation."
 @param [&in] target : "Authored transforms remain unchanged."
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_FORMAT_ERROR, c3d::CAPACITY_EXCEEDED
*>
fn RetargetProfile? create_retarget_profile(
    Allocator allocator,
    NodeTemplate[] source_nodes,
    ModelTemplate* target,
    RetargetProfileDesc desc,
) {
    @pool() {
        validate_profile_templates(source_nodes, target.nodes)!;
        validate_profile_calibration(source_nodes, target.nodes, &desc)!;
        Quat facing = profile_facing_rotation(desc.facing)!;

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
            };
        }

        foreach (index, &node : target.nodes) {
            destination[index] = {
                .name = node.name,
                .parent = node.parent,
                .authored = node.local,
                .calibration = node.local.rotation.normalize(),
                .mapped = RETARGET_NO_NODE,
            };
        }

        prepare_profile_bindings(source, destination, &desc)!;

        foreach (index, &node : destination) {
            if (node.mapped != RETARGET_NO_NODE) node.calibration = desc.target_calibration[index].normalize();
        }

        prepare_profile_motion(source, destination, &desc)!;
        validate_profile_carrier(destination, target, desc.target_carrier)!;

        foreach (index, &node : source) {
            if (node.mapped == RETARGET_NO_NODE) continue;

            for (int ancestor = (int)index; ancestor >= 0; ancestor = source[ancestor].parent) {
                source[ancestor].consumed = true;
                if (ancestor != (int)index) source[ancestor].requires_uniform_scale = true;
            }
        }

        foreach (&node : source) node.requires_uniform_scale |= node.motion;

        foreach (&node : destination) {
            node.requires_uniform_scale |= node.motion;
            if (node.mapped == RETARGET_NO_NODE && !node.motion) continue;

            for (int ancestor = node.parent; ancestor >= 0; ancestor = destination[ancestor].parent) {
                destination[ancestor].requires_uniform_scale = true;
            }
        }

        compose_profile_references(source)!;
        compose_profile_references(destination)!;

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
            .target_boundary = profile_motion_boundary(destination, desc.target_motion_node, desc.target_carrier),
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

fn void? compose_profile_references(ProfileNode[] nodes) @private {
    foreach (&node : nodes) {
        Transform local = node.authored;
        local.rotation = node.calibration;
        node.reference = node.parent < 0 ? local : profile_compose(nodes[node.parent].reference, local);
        if (!profile_valid_transform(node.reference)) return c3d::INVALID_ARGUMENT~;
    }
}

fn bool profile_descendant(ProfileNode[] nodes, uint node, uint ancestor) @private {
    for (int parent = nodes[node].parent; parent >= 0; parent = nodes[parent].parent) {
        if (parent == (int)ancestor) return true;
    }

    return false;
}

fn uint profile_motion_boundary(ProfileNode[] nodes, uint motion, uint carrier) @private {
    if (motion == RETARGET_NO_NODE) return RETARGET_NO_NODE;

    int stop = carrier == RETARGET_NO_NODE ? -1 : (int)carrier;
    uint boundary = motion;
    while (nodes[boundary].parent != stop) boundary = (uint)nodes[boundary].parent;

    return boundary;
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
