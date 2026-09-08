module c3d::scene;

import c3d::ecs;
import c3d::maths;
import std::math;

<*
 Layer every new node starts on; cameras and lights carry a matching mask.
*>
const uint DEFAULT_LAYERS = 1;

<*
 Scene entity with a stable address and a place in the hierarchy.
*>
struct Node {
    Entity    id;
    String    name;
    Transform local;
    Mat4      world;
    uint      layers;
    bool      visible;
    bool      visible_effective;
    Node*     parent;
    Node*     first_child;
    Node*     next_sibling;
}

<*
 Translation of the world matrix left by the last update.
*>
fn Vec3 Node.world_position(&self) {
    return maths::translation(self.world);
}

<*
 Point the local -Z axis at a world-space target.
 Reads the parent's world matrix as left by the last update.
 @param target : "World space."
 @param up : "World space."
 @require self.parent != null, (target - self.world_position()).length_sq() > 0
*>
fn void Node.look_at(&self, Vec3 target, Vec3 up = { 0, 1, 0 }) {
    Mat4 parent_inverse = maths::inverse_affine(self.parent.world);
    Vec3 forward = maths::transform_dir(parent_inverse, target - self.world_position());
    Vec3 up_local = maths::transform_dir(parent_inverse, up);
    self.local.rotation = maths::look_rotation(forward, up_local);
}
