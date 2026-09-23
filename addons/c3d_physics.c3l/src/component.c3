module c3d::physics;

import std::math;
import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;

<*
 Build state of an authored body, written by the world.
*>
enum BodyStatus {
    PENDING,
    LIVE,
    FAILED,
}

<*
 Authored body the world builds into a RigidBody; arrays are its own copy.
*>
struct PhysicsBody {
    BodyDesc       body;
    ColliderDesc[] colliders;
    BodyStatus     status;
    fault          failure;
    ulong          failed_revisions; // summed source revisions when SOURCE_UNAVAILABLE was recorded
}

<*
 Air flow applied to every shape of the body in each fixed step.
*>
struct Wind {
    Vec3  velocity;
    float drag;
    float lift;
    float max_speed;
}

<*
 Force applied at a body-local point in each fixed step.
*>
struct Force {
    Vec3 force;       // world space
    Vec3 local_point; // body space
}

struct BlockCursor @local {
    char* base;
    usz   offset;
}

$assert ColliderDesc::alignment <= mem::DEFAULT_MEM_ALIGNMENT;

<*
 Request a rebuild from the current desc on the next update.
 Resets motion to the desc.
*>
fn void PhysicsBody.mark_changed(&self) {
    self.status = PENDING;
}

<*
 Attach a copy of the body; the next world update builds it.
 @param [&in] node : "Its world matrix is read at build time."
 @return? BODY_EXISTS
 @require self.world.is_registered(PhysicsBody), colliders.len > 0
*>
fn void? Scene.add_physics_body(
    &self,
    Node* node,
    BodyDesc body,
    ColliderDesc[] colliders,
) {
    if (self.has(node, PhysicsBody)) return BODY_EXISTS~;
    self.add(node, copy_physics_body(self.allocator, body, colliders));
}

<*
 Author one static MESH body per Mesh node under root that has none.
 @param [&in] root : "Subtree walked including root; world matrices current."
 @return "How many bodies were authored."
 @require self.world.is_registered(PhysicsBody)
*>
fn uint Scene.add_static_mesh_bodies(&self, Node* root, CollisionFilter filter = FILTER_ALL) {
    uint added;
    if (self.has(root, scene::Mesh) && !self.has(root, PhysicsBody)) {
        ColliderDesc collider = default_collider_desc(MESH);
        collider.geometry = self.get(root, scene::Mesh).geometry;
        collider.local.scale = maths::transform_from_mat4(root.world).scale;
        collider.filter = filter;
        self.add(root, copy_physics_body(self.allocator, default_body_desc(STATIC), (&collider)[:1]));
        added++;
    }
    for (Node* child = root.first_child; child; child = child.next_sibling) {
        added += self.add_static_mesh_bodies(child, filter);
    }
    return added;
}

<*
 Register the physics components and the PhysicsBody removal hook.
 @param [&inout] scene : "Gains the PhysicsBody, Wind and Force stores."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? register_physics(Scene* scene) {
    scene.register(PhysicsBody)!;
    scene.register(Wind)!;
    scene.register(Force)!;
    scene.set_remove_hook(PhysicsBody, &free_physics_body, scene.hook_allocator);
}

fn PhysicsBody copy_physics_body(Allocator allocator, BodyDesc body, ColliderDesc[] colliders) @local {
    BlockCursor measure;
    carve_physics_body(&measure, body, colliders);
    BlockCursor fill = { .base = alloc::malloc(allocator, (sz)measure.offset) };
    return carve_physics_body(&fill, body, colliders);
}

// One walk serves both passes: with a null base it only measures, so the copy cannot outgrow the block.
fn PhysicsBody carve_physics_body(BlockCursor* cursor, BodyDesc body, ColliderDesc[] colliders) @local {
    ColliderDesc[] copies = carve(cursor, ColliderDesc, colliders.len);
    foreach (index, &source : colliders) {
        ColliderDesc copy = *source;
        copy.children = carve(cursor, CompoundChild, source.children.len);
        foreach (child_index, &child : source.children) {
            CompoundChild child_copy = *child;
            child_copy.face_materials = carve_copy(cursor, child.face_materials);
            child_copy.material_indices = carve_copy(cursor, child.material_indices);
            if (cursor.base) copy.children[child_index] = child_copy;
        }
        copy.face_materials = carve_copy(cursor, source.face_materials);
        copy.material_indices = carve_copy(cursor, source.material_indices);
        copy.height_field.heights = carve_copy(cursor, source.height_field.heights);
        if (cursor.base) copies[index] = copy;
    }

    char[] name = carve(cursor, char, body.name.len + 1);
    BodyDesc body_copy = body;
    if (cursor.base) {
        name[:body.name.len] = body.name[..];
        name[body.name.len] = 0;
        body_copy.name = (String)name[:body.name.len];
    }
    return { .body = body_copy, .colliders = copies, .status = PENDING };
}

macro carve(BlockCursor* cursor, $Type, usz count) @local {
    cursor.offset = (usz)mem::aligned_offset((sz)cursor.offset, $Type::alignment);
    $Type[] slice;
    if (cursor.base) slice = (($Type*)(cursor.base + cursor.offset))[:count];
    cursor.offset += $Type::size * count;
    return slice;
}

macro carve_copy(BlockCursor* cursor, source) @local {
    var copy = carve(cursor, $Typeof(source[0]), source.len);
    if (cursor.base) copy[..] = source[..];
    return copy;
}

fn void free_physics_body(Entity entity, void* component, void* user) @local {
    PhysicsBody* physics_body = component;
    alloc::free(*(Allocator*)user, physics_body.colliders.ptr);
}
