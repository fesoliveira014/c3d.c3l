module c3d::scene;

import c3d::ecs;
import c3d::maths;
import std::math;

<*
 Layer every new node starts on; cameras and lights carry a matching mask.
*>
const uint DEFAULT_LAYERS = 1;

<*
 Reference frame of a node's authored transform.
*>
enum TransformSpace {
    PARENT,
    WORLD,
}

<*
 Scene entity with a stable address and a place in the hierarchy.
*>
struct Node {
    Entity         id;
    String         name;
    TransformSpace transform_space;
    Transform      local;
    Mat4           world;
    uint           layers;
    bool           visible;
    bool           visible_effective;
    Node*          parent;
    Node*          first_child;
    Node*          next_sibling;
}

<*
 World frame containing the node's authored pose.
 @param [&in] self : "Live scene node."
 @return "Identity or the parent's last published world matrix."
 @pure
*>
fn Mat4 Node.transform_basis(&self) {
    if (self.transform_space == TransformSpace.WORLD || !self.parent) return matrix::IDENTITY4;
    return self.parent.world;
}

<*
 Translation of the world matrix left by the last update.
*>
fn Vec3 Node.world_position(&self) {
    return maths::translation(self.world);
}

<*
 Point the local -Z axis at a world-space target.
 @param [&inout] self : "Required world matrices are current."
 @param target : "World space."
 @param up : "World space."
 @require self.parent != null, (target - self.world_position()).length_sq() > 0
*>
fn void Node.look_at(&self, Vec3 target, Vec3 up = { 0, 1, 0 }) {
    Mat4 basis_inverse = maths::inverse_affine(self.transform_basis());
    Vec3 forward = maths::transform_dir(basis_inverse, target - self.world_position());
    Vec3 up_local = maths::transform_dir(basis_inverse, up);
    self.local.rotation = maths::look_rotation(forward, up_local);
}

<*
 Set world position, preserving authored rotation and scale.
 @param [&inout] self : "Required world matrices are current."
 @require self.parent != null
*>
fn void Node.set_world_position(&self, Vec3 position) {
    self.local.position = maths::transform_point(maths::inverse_affine(self.transform_basis()), position);
}

<*
 Set world position and rotation, preserving authored scale.
 @param [&inout] self : "Required world matrices are current."
 @require self.parent != null
*>
fn void Node.set_world_pose(&self, Vec3 position, Quaternionf rotation) {
    Mat4 basis = self.transform_basis();
    Quaternionf basis_rotation = maths::transform_from_mat4(basis).rotation;
    self.local.position = maths::transform_point(maths::inverse_affine(basis), position);
    self.local.rotation = basis_rotation.conjugate().mul(rotation).normalize();
}
