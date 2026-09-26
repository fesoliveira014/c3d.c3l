module c3d::anim::ik;

import c3d::scene;
import std::math;

<*
 Aim constraint on one joint.
 Node and target outlive the constraint.
*>
struct LookAt {
    Node* node;
    Node* target;
    Vec3  forward;     // node-local axis to aim, unit
    float max_angle;   // radians from the incoming forward; PI disables the clamp
    float weight;
}

<*
 Turn the node's forward axis toward the target within max_angle.
 Writes the node's local rotation only.
 @require self.node != null, self.target != null, self.node.parent != null, self.target.parent != null
*>
fn void LookAt.solve(&self) {
    if (self.weight == 0) return;

    Node* node = self.node;
    Quat world = world_rotation(node);
    Vec3 current = (world * self.forward).normalize();
    Vec3 desired = self.target.world_position() - node.world_position();
    if (desired.length() < IK_EPSILON) return;
    desired = desired.normalize();

    Vec3 axis = current.cross(desired);
    if (axis.length() < IK_EPSILON) return;
    float angle = math::min(math::acos(math::clamp(current.dot(desired), -1.0f, 1.0f)), self.max_angle);
    Quat delta = quaternion::from_axis_angle{float}(axis.normalize(), angle);
    Quat aimed = parent_rotation(node).conjugate() * delta * world;
    node.local.rotation = node.local.rotation.slerp(aimed, self.weight);
}

<*
 Constraint with unit weight and no clamp.
 @param forward : "Node-local, unit."
*>
fn LookAt look_at(Node* node, Node* target, Vec3 forward) {
    return {
        .node      = node,
        .target    = target,
        .forward   = forward,
        .max_angle = (float)math::PI,
        .weight    = 1,
    };
}
