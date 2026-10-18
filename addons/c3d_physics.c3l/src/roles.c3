module c3d::physics;

import c3d;
import c3d::ecs;
import c3d::scene;

struct BodyRoles @private {
    Scene*         scene;
    SnapshotTable* snapshots;
    Allocator*     hook_allocator;
    Entity[]       moving_storage; // scene node capacity
    uint           moving_count;
    bool           orphans_dirty;
}

fn BodyRoles* create_body_roles(Allocator allocator, Scene* scene, SnapshotTable* snapshots) @private {
    BodyRoles* roles = alloc::new(allocator, BodyRoles);
    *roles = {
        .scene          = scene,
        .snapshots      = snapshots,
        .hook_allocator = scene.hook_allocator,
        .moving_storage = alloc::new_array(allocator, Entity, (sz)scene.nodes.len),
    };
    return roles;
}

fn void destroy_body_roles(Allocator allocator, BodyRoles* roles) @private {
    alloc::free(allocator, roles.moving_storage.ptr);
    alloc::free(allocator, roles);
}

fn Entity[] BodyRoles.moving_bodies(&self) => self.moving_storage[:self.moving_count];

fn void BodyRoles.add_body(&self, Entity entity, RigidBody* body) {
    if (body.kind == STATIC) return;
    body.moving_index = self.moving_count;
    self.moving_storage[self.moving_count++] = entity;
}

// Runs inside the removal hook, while the departing body is still addressable.
fn void BodyRoles.remove_body(&self, RigidBody* body) {
    if (body.kind == STATIC) return;
    self.moving_count--;
    Entity moved = self.moving_storage[self.moving_count];
    self.moving_storage[body.moving_index] = moved;
    self.scene.world.get(moved, RigidBody).moving_index = body.moving_index;
}

fn void remove_rigid_body(Entity entity, void* component, void* user) @private {
    RigidBody* body = component;
    BodyRoles* roles = user;
    roles.remove_body(body);
    destroy_rigid_body(roles.snapshots, body.body, body.colliders);
}

fn void remove_physics_body(Entity entity, void* component, void* user) @private {
    BodyRoles* roles = user;
    free_physics_body(entity, component, roles.hook_allocator);
    roles.orphans_dirty = true;
}
