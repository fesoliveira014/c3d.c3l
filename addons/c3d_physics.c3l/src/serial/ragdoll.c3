module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import c3d::serial;
import std::math;
import std::math::quaternion;

struct RagdollAuthoring @private {
    serial::NodeReference[] bone_nodes;
    uint[] bone_joints;
    maths::Transform[] joint_in_bone;
    float[] bone_weights;
    RagdollMode[] bone_modes;
    JointSpring[] bone_drives;
    int[] bone_parents;
    int[] parents;
    Quaternionf hips_bind_rotation;
    float weight;
    float drive_strength;
}

fn void? register_ragdoll_codec() @private {
    describe::register_reflected(RagdollAuthoring)!;
    serial::register_described_type(
        $Type: RagdollAuthoring,
        version: 1,
        layout: 0x15958c9213b44a67,
        defaults: &defaults_ragdoll,
    )!;
    serial::register_described_owner(Ragdoll, RagdollAuthoring, {
        .name = "ragdoll",
        .phase = OWNER,
        .collect = &collect_ragdoll,
        .project = &project_ragdoll,
        .validate = &validate_ragdoll,
        .attach = &attach_ragdoll,
    })!;
}

fn void defaults_ragdoll(void* value) @private {
    *(RagdollAuthoring*)value = { .hips_bind_rotation = { .v = { 0, 0, 0, 1 } } };
}

fn void set_bone_diagnostic(serial::SerialDiagnostic* diagnostic, uint index) @private {
    if (!diagnostic) return;
    diagnostic.has_bone_index = true;
    diagnostic.bone_index = index;
}

fn void clear_bone_diagnostic(serial::SerialDiagnostic* diagnostic) @private {
    if (diagnostic) diagnostic.has_bone_index = false;
}

fn void? validate_ragdoll_controls(
    float weight,
    float[] bone_weights,
    float drive_strength,
    serial::SerialDiagnostic* diagnostic,
) @private {
    clear_bone_diagnostic(diagnostic);
    if (!math::is_finite(weight) || weight < 0 || !math::is_finite(drive_strength) || drive_strength < 0) {
        return c3d::INVALID_ARGUMENT~;
    }
    foreach (uint index, value : bone_weights) {
        if (!math::is_finite(value) || value < 0) {
            set_bone_diagnostic(diagnostic, index);
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn void? collect_ragdoll(void* component, serial::WriteContext* context) @private {
    Ragdoll* ragdoll = component;
    validate_ragdoll_controls(
        weight: ragdoll.weight,
        bone_weights: ragdoll.bone_weights,
        drive_strength: ragdoll.drive_strength,
        diagnostic: context.diagnostic,
    )!;
    if (!context.scene.has(context.node, SkinBinding)) return NO_SKIN~;
    foreach (uint index, node : ragdoll.bone_nodes) {
        set_bone_diagnostic(context.diagnostic, index);
        (void)context.make_node_reference(node, true, NO_BODY)!;
        PhysicsBody* body = context.scene.get(node, PhysicsBody);
        if (!body) return NO_BODY~;
        BodyKind expected = ragdoll.bone_modes[index] == SIMULATED ? DYNAMIC : KINEMATIC;
        if (body.body.kind != expected) return c3d::INVALID_ARGUMENT~;
        PhysicsBody projected = *body;
        projected.body.linear_velocity = {};
        projected.body.angular_velocity = {};
        context.project_component(node, projected)!;
        int parent = ragdoll.bone_parents[index];
        if (parent < 0) continue;
        PhysicsJoint* joint = context.scene.get(node, PhysicsJoint);
        if (!joint) return NO_JOINT~;
        if (joint.desc.kind != SPHERICAL && joint.desc.kind != REVOLUTE) return c3d::INVALID_ARGUMENT~;
        if (!c3d::same_id(joint.desc.other, ragdoll.bone_nodes[parent].id)) return c3d::INVALID_ARGUMENT~;
    }
    clear_bone_diagnostic(context.diagnostic);
}

fn void? project_ragdoll(void* component, void* value, serial::WriteContext* context) @private {
    Ragdoll* ragdoll = component;
    serial::NodeReference[] bones = alloc::new_array_try(tmem, serial::NodeReference, ragdoll.bone_nodes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    foreach (uint index, node : ragdoll.bone_nodes) {
        set_bone_diagnostic(context.diagnostic, index);
        bones[index] = context.make_node_reference(node, true, NO_BODY)!;
    }
    clear_bone_diagnostic(context.diagnostic);
    *(RagdollAuthoring*)value = {
        .bone_nodes = bones,
        .bone_joints = ragdoll.bone_joints,
        .joint_in_bone = ragdoll.joint_in_bone,
        .bone_weights = ragdoll.bone_weights,
        .bone_modes = ragdoll.bone_modes,
        .bone_drives = ragdoll.bone_drives,
        .bone_parents = ragdoll.bone_parents,
        .parents = ragdoll.parents,
        .hips_bind_rotation = ragdoll.hips_bind_rotation,
        .weight = ragdoll.weight,
        .drive_strength = ragdoll.drive_strength,
    };
}

fn void? validate_ragdoll_parents(int[] parents) @private {
    char[] marks = alloc::new_array_try(tmem, char, parents.len) ?? c3d::CAPACITY_EXCEEDED~!;
    foreach (parent : parents) {
        if (parent < -1 || (parent >= 0 && (usz)parent >= parents.len)) return c3d::INVALID_ARGUMENT~;
    }
    for (usz index = 0; index < parents.len; index++) {
        for (int joint = (int)index; joint >= 0; joint = parents[joint]) {
            if (marks[joint] == 2) break;
            if (marks[joint] == 1) return c3d::INVALID_ARGUMENT~;
            marks[joint] = 1;
        }
        for (int joint = (int)index; joint >= 0 && marks[joint] == 1; joint = parents[joint]) marks[joint] = 2;
    }
}

fn void? validate_ragdoll(void* value, serial::ReadContext* context) @private {
    RagdollAuthoring* source = value;
    validate_ragdoll_controls(
        weight: source.weight,
        bone_weights: source.bone_weights,
        drive_strength: source.drive_strength,
        diagnostic: context.diagnostic,
    )!;
    serial::SkinAuthoring* skin = context.authored(SkinBinding, serial::SkinAuthoring, context.node.id)!;
    if (!skin) return NO_SKIN~;
    usz bones = source.bone_nodes.len;
    usz joints = source.parents.len;
    if (!bones || !joints || joints != skin.joints.len || source.bone_joints.len != bones
        || source.joint_in_bone.len != bones || source.bone_weights.len != bones
        || source.bone_modes.len != bones || source.bone_drives.len != bones
        || source.bone_parents.len != bones) return c3d::INVALID_ARGUMENT~;
    validate_ragdoll_parents(source.parents)!;
    int[] joint_bones = alloc::new_array_try(tmem, int, (sz)joints) ?? c3d::CAPACITY_EXCEEDED~!;
    joint_bones[..] = -1;
    foreach (uint index, joint : source.bone_joints) {
        set_bone_diagnostic(context.diagnostic, index);
        if (joint >= joints || joint_bones[joint] >= 0) return c3d::INVALID_ARGUMENT~;
        joint_bones[joint] = (int)index;
    }
    foreach (uint index, reference : source.bone_nodes) {
        set_bone_diagnostic(context.diagnostic, index);
        Node* node = context.resolve_node_reference(reference, true, NO_BODY)!;
        if (node.parent != context.node) return c3d::INVALID_ARGUMENT~;
        foreach (previous : source.bone_nodes[:index]) {
            if (context.resolve_node_reference(previous, true, NO_BODY)! == node) return c3d::INVALID_ARGUMENT~;
        }
        BodyAuthoring* body = context.authored(PhysicsBody, BodyAuthoring, node.id)!;
        if (!body) return NO_BODY~;
        BodyKind expected = source.bone_modes[index] == SIMULATED ? DYNAMIC : KINEMATIC;
        if (body.body.kind != expected) return c3d::INVALID_ARGUMENT~;
        (void)context.resolve_node_reference(skin.joints[source.bone_joints[index]], true)!;
        int expected_parent = -1;
        for (int joint = source.parents[source.bone_joints[index]]; joint >= 0; joint = source.parents[joint]) {
            if (joint_bones[joint] < 0) continue;
            expected_parent = joint_bones[joint];
            break;
        }
        if (expected_parent >= (int)index || source.bone_parents[index] != expected_parent) return c3d::INVALID_ARGUMENT~;
        if (expected_parent < 0) continue;
        JointAuthoring* joint = context.authored(PhysicsJoint, JointAuthoring, node.id)!;
        if (!joint) return NO_JOINT~;
        if (joint.kind != SPHERICAL && joint.kind != REVOLUTE) return c3d::INVALID_ARGUMENT~;
        Node* parent = context.resolve_node_reference(source.bone_nodes[expected_parent], true, NO_BODY)!;
        if (context.resolve_node_reference(joint.other, true, NO_BODY)! != parent) return c3d::INVALID_ARGUMENT~;
    }
    clear_bone_diagnostic(context.diagnostic);
}

fn void? attach_ragdoll(void* value, serial::ReadContext* context) @private {
    RagdollAuthoring* source = value;
    Ragdoll ragdoll = try_carve_ragdoll_block(context.scene.allocator, source.bone_nodes.len, source.parents.len)!;
    defer catch alloc::free(context.scene.allocator, ragdoll.bone_nodes.ptr);
    foreach (index, reference : source.bone_nodes) ragdoll.bone_nodes[index] = context.resolve_node_reference(reference, true, NO_BODY)!;
    ragdoll.bone_joints[..] = source.bone_joints[..];
    ragdoll.joint_in_bone[..] = source.joint_in_bone[..];
    ragdoll.bone_weights[..] = source.bone_weights[..];
    ragdoll.bone_modes[..] = source.bone_modes[..];
    ragdoll.bone_drives[..] = source.bone_drives[..];
    ragdoll.bone_parents[..] = source.bone_parents[..];
    ragdoll.parents[..] = source.parents[..];
    ragdoll.hips_bind_rotation = source.hips_bind_rotation;
    ragdoll.weight = source.weight;
    ragdoll.drive_strength = source.drive_strength;
    ragdoll.joint_bone[..] = -1;
    foreach (index, joint : ragdoll.bone_joints) ragdoll.joint_bone[joint] = (int)index;
    order_joints(&ragdoll);
    assign_joint_owners(&ragdoll);
    SkinBinding* skin = context.scene.get(context.node, SkinBinding);
    foreach (index, joint : skin.joints) ragdoll.frozen[index] = joint.local;
    ragdoll.joint_worlds[..] = {};
    foreach (node : ragdoll.bone_nodes) {
        BodyDesc* body = &context.scene.get(node, PhysicsBody).body;
        body.linear_velocity = {};
        body.angular_velocity = {};
    }
    context.scene.add(context.node, ragdoll);
}
