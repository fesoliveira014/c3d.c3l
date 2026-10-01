module c3d::anim;

import c3d::asset;

<* Owned membership over one model's local node indices. *>
struct JointMask {
    Allocator allocator;
    bool[] nodes;
}

<*
 Select named model nodes and optionally their descendants.
 @param [&in] template : "Valid parent-before-child model template."
 @param names : "Exact names; every matching node is selected."
 @return? NOT_FOUND
*>
fn JointMask? create_joint_mask(
    Allocator allocator,
    ModelTemplate* template,
    String[] names,
    bool include_descendants = true,
) {
    foreach (name : names) {
        bool found;
        foreach (node : template.nodes) found |= node.name == name;
        if (!found) return NOT_FOUND~;
    }

    JointMask mask = { .allocator = allocator, .nodes = alloc::new_array(allocator, bool, template.nodes.len) };

    foreach (index, node : template.nodes) {
        foreach (name : names) mask.nodes[index] |= node.name == name;
        if (include_descendants && node.parent >= 0) mask.nodes[index] |= mask.nodes[node.parent];
    }

    return mask;
}

<*
 Release mask membership and leave it empty.
 @param [&inout] mask : "Owned mask; left zeroed."
*>
fn void destroy_joint_mask(JointMask* mask) {
    alloc::free(mask.allocator, mask.nodes.ptr);
    *mask = {};
}
