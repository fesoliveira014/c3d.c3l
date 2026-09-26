module c3d::anim::ik;

import c3d::maths;
import c3d::scene;
import std::math;

<*
 Joints one aim constraint can spread its turn over.
*>
const uint MAX_LOOK_AT_JOINTS = 8; // a Rigify spine, neck and head are five; 96 bytes of pointers and weights per constraint

const float WEIGHT_SUM_TOLERANCE @local = 1e-4f; // float sums of eight shares stay well inside it
const uint LOOK_AT_PASSES @local = 2; // the second pass corrects the tip's own swing about the lower joints

<*
 Aim constraint spread over a chain whose last joint carries the forward axis.
 Joints and target outlive the constraint.
*>
struct LookAt {
    Node*[MAX_LOOK_AT_JOINTS] joints;        // root to tip, each the parent of the next
    float[MAX_LOOK_AT_JOINTS] weights;       // share of the turn per joint; the used shares sum to 1
    uint                      joint_count;
    Node*                     target;
    Vec3                      forward;       // tip-local axis to aim, unit
    float                     max_angle;     // radians from the incoming forward; PI disables the clamp
    float                     weight;
}

<*
 Turn the tip's forward axis toward the target, spread over the joints.
 Writes the joints' local rotations only.
 @require look_at_valid(self)
*>
fn void LookAt.solve(&self) {
    if (self.weight == 0) return;

    uint count = self.joint_count;
    Node* tip = self.joints[count - 1];
    Quat[MAX_LOOK_AT_JOINTS] incoming;
    Quat[MAX_LOOK_AT_JOINTS] parent_worlds;
    for (uint index = 0; index < count; index++) {
        incoming[index] = self.joints[index].local.rotation;
        parent_worlds[index] = parent_rotation(self.joints[index]);
    }
    Vec3 current = (world_rotation(tip) * self.forward).normalize();
    Vec3 tip_position = tip.world_position();

    for (uint pass = 0; pass < LOOK_AT_PASSES; pass++) {
        Vec3 desired = self.target.world_position() - tip_position;
        if (desired.length() < IK_EPSILON) break;
        desired = desired.normalize();
        Vec3 axis = current.cross(desired);
        if (axis.length() < IK_EPSILON) break;
        axis = axis.normalize();
        float angle = math::min(math::acos(math::clamp(current.dot(desired), -1.0f, 1.0f)), self.max_angle);

        for (uint index = 0; index < count; index++) {
            Quat share = quaternion::from_axis_angle{float}(axis, angle * self.weights[index]);
            Quat parent_world = parent_worlds[index];
            Quat aimed = parent_world.conjugate() * share * parent_world * incoming[index];
            self.joints[index].local.rotation = incoming[index].slerp(aimed, self.weight);
        }
        tip_position = chain_tip_position(self);
    }
}

<*
 Constraint over the joints with unit weight, no clamp and shares growing toward the tip.
 @param joints : "Root to tip; copied."
 @param forward : "Tip-local, unit."
 @require joints.len >= 1 && joints.len <= MAX_LOOK_AT_JOINTS
*>
fn LookAt look_at(Node*[] joints, Node* target, Vec3 forward) {
    LookAt look_at = {
        .joint_count = (uint)joints.len,
        .target      = target,
        .forward     = forward,
        .max_angle   = (float)math::PI,
        .weight      = 1,
    };
    float total = (float)(joints.len * (joints.len + 1)) / 2;
    foreach (index, joint : joints) {
        look_at.joints[index] = joint;
        look_at.weights[index] = (float)(index + 1) / total;
    }
    return look_at;
}

<*
 Whether the joints form a live parent chain with shares summing to one.
 @param [&in] look_at : "Constraint to check before a solve."
*>
fn bool look_at_valid(LookAt* look_at) {
    if (look_at.joint_count == 0 || look_at.joint_count > MAX_LOOK_AT_JOINTS) return false;
    if (!look_at.target || !look_at.target.parent) return false;
    float total;
    for (uint index = 0; index < look_at.joint_count; index++) {
        Node* joint = look_at.joints[index];
        if (!joint || !joint.parent) return false;
        if (index > 0 && joint.parent != look_at.joints[index - 1]) return false;
        total += look_at.weights[index];
    }
    return math::abs(total - 1) <= WEIGHT_SUM_TOLERANCE;
}

fn Vec3 chain_tip_position(LookAt* look_at) @local {
    Mat4 world = look_at.joints[0].parent.world;
    for (uint index = 0; index < look_at.joint_count; index++) {
        world = world.mul(look_at.joints[index].local.to_mat4());
    }
    return maths::translation(world);
}
