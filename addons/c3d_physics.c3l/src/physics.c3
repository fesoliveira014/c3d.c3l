module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import b3;

alias Quat @private = Quaternionf;

<* Earth gravity, Y up, meters per second squared. *>
const Vec3  DEFAULT_GRAVITY = { 0, -9.81f, 0 };
<* Fixed step of sixty hertz. *>
const float DEFAULT_FIXED_DT = 1.0f / 60;
<* Solver sub-steps per fixed step. *>
const uint  DEFAULT_SUB_STEPS = 4;
<* Fixed steps one update may take. *>
const uint  DEFAULT_MAX_STEPS = 4; // a longer backlog is dropped, not simulated; the stall recovery lever
<* Approach speed above which hits are reported, meters per second. *>
const float DEFAULT_HIT_SPEED_THRESHOLD = 1;
<* Entries per event list. *>
const uint  DEFAULT_EVENT_CAPACITY = 4096; // five lists of 4096 entries, about 800 KiB per world; the contact burst lever
<* Collision snapshots per collider kind. *>
const uint  DEFAULT_SNAPSHOT_CAPACITY = 256; // one slot per distinct geometry revision; the level variety lever
<* Water density, kilograms per cubic meter. *>
const float DEFAULT_DENSITY = 1000;
<* Dry friction coefficient. *>
const float DEFAULT_FRICTION = 0.6f;

<*
 Every category, colliding with everything.
*>
const CollisionFilter FILTER_ALL = { .category = 1, .mask = ulong::max };

<*
 How a body moves: never, by target pose, or by the solver.
*>
enum BodyKind {
    STATIC,
    KINEMATIC,
    DYNAMIC,
}

<*
 Shape of one collider.
*>
enum ColliderKind {
    SPHERE,
    CAPSULE,
    BOX,
    HULL,
    MESH,
    HEIGHT_FIELD,
}

<*
 Category and mask bits box3d tests before two shapes may touch.
*>
struct CollisionFilter {
    ulong category;
    ulong mask;
    int   group;
}

<*
 Row-major heights, x fastest; copied when snapshot.
*>
struct HeightField {
    float[] heights;
    uint    count_x;
    uint    count_z;
}

<*
 One shape of a body; which fields apply depends on kind.
*>
struct ColliderDesc {
    ColliderKind     kind;
    maths::Transform local;
    float            radius;
    float            half_height;
    Vec3             half_extents;
    GeometryId       geometry;
    HeightField      height_field;
    float            density;
    float            friction;
    float            restitution;
    bool             sensor;
    bool             contact_events;
    bool             hit_events;
    CollisionFilter  filter;
}

<*
 Motion properties of a body at creation.
*>
struct BodyDesc {
    BodyKind kind;
    Vec3     linear_velocity;
    Vec3     angular_velocity;
    float    linear_damping;
    float    angular_damping;
    float    gravity_scale;
    bool     allow_sleep;
    bool     bullet;
    bool     lock_rotation;
}

<*
 World configuration: stepping policy, capacities and debug data.
 cache_wireframes builds collider wireframes with each collision snapshot; off, debug_draw skips hull, mesh and height-field colliders.
*>
struct PhysicsDesc {
    Vec3  gravity;
    float fixed_dt;
    uint  sub_steps;
    uint  max_steps_per_frame;
    float hit_speed_threshold;
    bool  interpolate;
    bool  cache_wireframes;
    uint  event_capacity;
    uint  snapshot_capacity;
}

<*
 One shape of a rigid body; wire borrows the world's snapshot snapshot.
*>
struct Collider {
    b3::ShapeId      shape;
    ColliderKind     kind;
    maths::Transform local;
    float            radius;
    float            half_height;
    Vec3             half_extents;
    Vec3[]           wire;
}

<*
 Body bound to a node; owned by the physics world through the store's removal hook.
*>
struct RigidBody {
    b3::BodyId       body;
    BodyKind         kind;
    maths::Transform previous;
    maths::Transform current;
    Collider[]       colliders;
}

<*
 Geometry revision a collision snapshot was snapshot from.
*>
struct PhysicsSourceKey {
    GeometryId geometry;
    uint       revision;
}

<*
 Convex hull snapshot from a geometry revision, with its wireframe.
*>
struct PhysicsHull {
    PhysicsSourceKey key;
    b3::HullData*    hull;
    Vec3[]           wire;
}

<*
 Triangle mesh snapshot from a geometry revision, with its wireframe.
*>
struct PhysicsMesh {
    PhysicsSourceKey key;
    b3::MeshData*    mesh;
    Vec3[]           wire;
}

<*
 Height field snapshot from application heights, with its wireframe.
*>
struct PhysicsHeightField {
    b3::HeightFieldData* field;
    Vec3[]               wire;
}

<*
 Two shapes began or stopped touching; nodes are frame borrows.
*>
struct ContactEvent {
    Node* a;
    Node* b;
}

<*
 Two shapes collided above the hit speed threshold; nodes are frame borrows.
*>
struct HitEvent {
    Node* a;
    Node* b;
    Vec3  point;
    Vec3  normal;
    float approach_speed;
}

<*
 A visitor entered or left a sensor; nodes are frame borrows.
*>
struct SensorEvent {
    Node* sensor;
    Node* visitor;
}

<*
 Closest body along a ray.
*>
struct RayHit {
    Node* node;
    Vec3  point;
    Vec3  normal;
    float fraction;
}

<*
 What debug_draw appends to the sink.
*>
struct PhysicsDebugOptions {
    bool colliders;
    bool contacts;
    bool bounds;
}

<*
 Owner of one box3d world, its snapshot collision data and the frame event lists.
*>
struct PhysicsWorld {
    Allocator            allocator;
    Allocator*           hook_allocator;
    b3::WorldId          world;
    AssetStore*          assets;
    Scene*               scene;
    PhysicsDesc          desc;
    float                accumulator;
    float                alpha;
    uint                 steps_last_update;
    uint                 dropped_events;
    PhysicsHull[]        hulls;
    uint                 hull_count;
    PhysicsMesh[]        meshes;
    uint                 mesh_count;
    PhysicsHeightField[] height_fields;
    uint                 height_field_count;
    ContactEvent[]       contact_begin_storage;
    uint                 contact_begin_count;
    ContactEvent[]       contact_end_storage;
    uint                 contact_end_count;
    HitEvent[]           hit_storage;
    uint                 hit_count;
    SensorEvent[]        sensor_begin_storage;
    uint                 sensor_begin_count;
    SensorEvent[]        sensor_end_storage;
    uint                 sensor_end_count;
}

<*
 Create the body and its shapes from the node's world pose and attach a RigidBody.
 @param [&in] node : "Its world matrix is the initial pose; update_world first."
 @param colliders : "At least one; a visitor with contact_events is visible to sensors."
 @return? BODY_EXISTS, STATIC_ONLY, SOURCE_UNAVAILABLE, c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, b3::INVALID_DEFINITION, b3::INVALID_HANDLE, b3::DEGENERATE_GEOMETRY
*>
fn void? PhysicsWorld.add_body(
    &self,
    Node* node,
    BodyDesc body,
    ColliderDesc[] colliders,
) {
    if (self.scene.has(node, RigidBody)) return BODY_EXISTS~;
    foreach (&collider : colliders) check_collider(self, collider, body.kind)!;

    maths::Transform pose = maths::transform_from_mat4(node.world);
    pose.scale = { 1, 1, 1 };
    b3::BodyDef def = b3::default_body_def();
    def.type = body_type(body.kind);
    def.position = (b3::Pos)pose.position;
    def.rotation = pose.rotation;
    def.linear_velocity = body.linear_velocity;
    def.angular_velocity = body.angular_velocity;
    def.linear_damping = body.linear_damping;
    def.angular_damping = body.angular_damping;
    def.gravity_scale = body.gravity_scale;
    def.enable_sleep = body.allow_sleep;
    def.is_bullet = body.bullet;
    def.motion_locks = {
        .angular_x = body.lock_rotation,
        .angular_y = body.lock_rotation,
        .angular_z = body.lock_rotation,
    };
    def.user_data = pack_entity(node.id);
    b3::BodyId body_id = b3::create_body(self.world, &def)!;
    defer catch b3::destroy_body(body_id);

    Collider[] records = alloc::new_array(self.allocator, Collider, (sz)colliders.len);
    defer catch alloc::free(self.allocator, records.ptr);
    foreach (index, &collider : colliders) records[index] = create_shape(self, body_id, collider)!;
    if (body.kind == DYNAMIC) b3::body_apply_mass_from_shapes(body_id);

    self.scene.add(node, (RigidBody){
        .body      = body_id,
        .kind      = body.kind,
        .previous  = pose,
        .current   = pose,
        .colliders = records,
    });
}

<*
 Remove the body through the component's removal hook.
 Invalidates RigidBody pointers.
 @require self.scene.has(node, RigidBody)
*>
fn void PhysicsWorld.remove_body(&self, Node* node) {
    self.scene.remove_component(node, RigidBody);
}

<*
 The box3d body of the node.
 @return? NO_BODY
*>
fn b3::BodyId? PhysicsWorld.body(&self, Node* node) {
    if (!self.scene.has(node, RigidBody)) return NO_BODY~;
    return self.scene.get(node, RigidBody).body;
}

<*
 One static MESH body per Mesh node under root that has no body yet.
 @param [&in] root : "Subtree walked including root; world matrices current."
 @return "How many bodies were added."
 @return? SOURCE_UNAVAILABLE, c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED, b3::INVALID_DEFINITION, b3::INVALID_HANDLE, b3::DEGENERATE_GEOMETRY
*>
fn uint? PhysicsWorld.add_static_meshes(&self, Node* root, CollisionFilter filter = FILTER_ALL) {
    uint added;
    if (self.scene.has(root, scene::Mesh) && !self.scene.has(root, RigidBody)) {
        ColliderDesc collider = default_collider_desc(MESH);
        collider.geometry = self.scene.get(root, scene::Mesh).geometry;
        collider.local.scale = maths::transform_from_mat4(root.world).scale;
        collider.filter = filter;
        self.add_body(root, default_body_desc(STATIC), (&collider)[:1])!;
        added++;
    }
    for (Node* child = root.first_child; child; child = child.next_sibling) {
        added += self.add_static_meshes(child, filter)!;
    }
    return added;
}

<*
 Set the body's velocities and wake it.
 @require self.scene.has(node, RigidBody)
*>
fn void PhysicsWorld.set_velocity(
    &self,
    Node* node,
    Vec3 linear,
    Vec3 angular,
) {
    b3::BodyId body = self.scene.get(node, RigidBody).body;
    body.set_linear_velocity(linear);
    body.set_angular_velocity(angular);
    body.set_awake(true);
}

<*
 Apply a force at a world point and wake the body.
 @require self.scene.has(node, RigidBody)
*>
fn void PhysicsWorld.apply_force(
    &self,
    Node* node,
    Vec3 force,
    Vec3 world_point,
) {
    b3::body_apply_force(
        body:  self.scene.get(node, RigidBody).body,
        force: force,
        point: (b3::Pos)world_point,
        wake:  true,
    );
}

<*
 Apply an impulse at a world point and wake the body.
 @require self.scene.has(node, RigidBody)
*>
fn void PhysicsWorld.apply_impulse(
    &self,
    Node* node,
    Vec3 impulse,
    Vec3 world_point,
) {
    b3::body_apply_linear_impulse(
        body:    self.scene.get(node, RigidBody).body,
        impulse: impulse,
        point:   (b3::Pos)world_point,
        wake:    true,
    );
}

<*
 Move the body without sweeping and write the pose to the node now.
 @require self.scene.has(node, RigidBody)
*>
fn void PhysicsWorld.teleport(
    &self,
    Node* node,
    Vec3 position,
    Quat rotation,
) {
    RigidBody* body = self.scene.get(node, RigidBody);
    body.body.set_transform((b3::Pos)position, rotation);
    body.current = { .position = position, .rotation = rotation, .scale = { 1, 1, 1 } };
    body.previous = body.current;
    write_pose(self.scene, node, body.current);
}

<*
 Pairs that began touching during the last update.
*>
fn ContactEvent[] PhysicsWorld.contacts_begin(&self) => self.contact_begin_storage[:self.contact_begin_count];

<*
 Pairs that stopped touching during the last update.
*>
fn ContactEvent[] PhysicsWorld.contacts_end(&self) => self.contact_end_storage[:self.contact_end_count];

<*
 Collisions above the hit speed threshold during the last update.
*>
fn HitEvent[] PhysicsWorld.hits(&self) => self.hit_storage[:self.hit_count];

<*
 Sensor overlaps that began during the last update.
*>
fn SensorEvent[] PhysicsWorld.sensors_begin(&self) => self.sensor_begin_storage[:self.sensor_begin_count];

<*
 Sensor overlaps that ended during the last update.
*>
fn SensorEvent[] PhysicsWorld.sensors_end(&self) => self.sensor_end_storage[:self.sensor_end_count];

<*
 Default world configuration.
*>
fn PhysicsDesc default_physics_desc() {
    return {
        .gravity             = DEFAULT_GRAVITY,
        .fixed_dt            = DEFAULT_FIXED_DT,
        .sub_steps           = DEFAULT_SUB_STEPS,
        .max_steps_per_frame = DEFAULT_MAX_STEPS,
        .hit_speed_threshold = DEFAULT_HIT_SPEED_THRESHOLD,
        .interpolate         = true,
        .cache_wireframes    = true,
        .event_capacity      = DEFAULT_EVENT_CAPACITY,
        .snapshot_capacity   = DEFAULT_SNAPSHOT_CAPACITY,
    };
}

<*
 Default body of the kind: unit gravity, sleeping allowed.
*>
fn BodyDesc default_body_desc(BodyKind kind = DYNAMIC) {
    return { .kind = kind, .gravity_scale = 1, .allow_sleep = true };
}

<*
 Default collider of the kind: identity placement, water density, dry friction.
*>
fn ColliderDesc default_collider_desc(ColliderKind kind) {
    return {
        .kind     = kind,
        .local    = maths::TRANSFORM_IDENTITY,
        .density  = DEFAULT_DENSITY,
        .friction = DEFAULT_FRICTION,
        .filter   = FILTER_ALL,
    };
}

<*
 Create a physics world bound to the scene and its asset store.
 @param [&in] assets : "Borrowed; outlives the world."
 @param [&inout] scene : "Borrowed; outlives the world; gains the RigidBody store and hook."
 @return? c3d::CAPACITY_EXCEEDED, b3::WORLD_LIMIT_REACHED, b3::INVALID_DEFINITION
*>
fn PhysicsWorld? create_physics_world(
    Allocator allocator,
    AssetStore* assets,
    Scene* scene,
    PhysicsDesc desc,
) {
    b3::WorldDef def = b3::default_world_def();
    def.gravity = desc.gravity;
    def.hit_event_threshold = desc.hit_speed_threshold;
    b3::WorldId world = b3::create_world(&def)!;
    defer catch b3::destroy_world(world);
    scene.register(RigidBody)!;

    Allocator* hook_allocator = alloc::new(allocator, Allocator);
    *hook_allocator = allocator;
    scene.set_remove_hook(RigidBody, &destroy_body, hook_allocator);

    return {
        .allocator             = allocator,
        .hook_allocator        = hook_allocator,
        .world                 = world,
        .assets                = assets,
        .scene                 = scene,
        .desc                  = desc,
        .hulls                 = alloc::new_array(allocator, PhysicsHull, desc.snapshot_capacity),
        .meshes                = alloc::new_array(allocator, PhysicsMesh, desc.snapshot_capacity),
        .height_fields         = alloc::new_array(allocator, PhysicsHeightField, desc.snapshot_capacity),
        .contact_begin_storage = alloc::new_array(allocator, ContactEvent, desc.event_capacity),
        .contact_end_storage   = alloc::new_array(allocator, ContactEvent, desc.event_capacity),
        .hit_storage           = alloc::new_array(allocator, HitEvent, desc.event_capacity),
        .sensor_begin_storage  = alloc::new_array(allocator, SensorEvent, desc.event_capacity),
        .sensor_end_storage    = alloc::new_array(allocator, SensorEvent, desc.event_capacity),
    };
}

<*
 Destroy the world, its bodies, snapshot data and event lists; nodes remain.
 @param [&inout] world : "Destroyed before its scene and asset store."
*>
fn void destroy_physics_world(PhysicsWorld* world) {
    Entity[] entities = alloc::new_array(world.allocator, Entity, (sz)world.scene.count(RigidBody));
    usz cursor;
    world.scene.@each(RigidBody; entity, body) {
        entities[cursor++] = entity;
    };
    foreach (entity : entities) world.scene.remove_component(world.scene.node(entity), RigidBody);
    alloc::free(world.allocator, entities.ptr);
    world.scene.set_remove_hook(RigidBody, null, null);
    b3::destroy_world(world.world);

    foreach (&snapshot : world.hulls[:world.hull_count]) {
        b3::destroy_hull(snapshot.hull);
        alloc::free(world.allocator, snapshot.wire.ptr);
    }
    foreach (&snapshot : world.meshes[:world.mesh_count]) {
        b3::destroy_mesh(snapshot.mesh);
        alloc::free(world.allocator, snapshot.wire.ptr);
    }
    foreach (&snapshot : world.height_fields[:world.height_field_count]) {
        b3::destroy_height_field(snapshot.field);
        alloc::free(world.allocator, snapshot.wire.ptr);
    }
    alloc::free(world.allocator, world.hulls.ptr);
    alloc::free(world.allocator, world.meshes.ptr);
    alloc::free(world.allocator, world.height_fields.ptr);
    alloc::free(world.allocator, world.contact_begin_storage.ptr);
    alloc::free(world.allocator, world.contact_end_storage.ptr);
    alloc::free(world.allocator, world.hit_storage.ptr);
    alloc::free(world.allocator, world.sensor_begin_storage.ptr);
    alloc::free(world.allocator, world.sensor_end_storage.ptr);
    alloc::free(world.allocator, world.hook_allocator);
    *world = {};
}

fn void destroy_body(Entity entity, void* component, void* user) @local {
    RigidBody* body = component;
    b3::destroy_body(body.body);
    alloc::free(*(Allocator*)user, body.colliders.ptr);
}

fn b3::BodyType body_type(BodyKind kind) @local {
    switch (kind) {
        case STATIC:    return b3::BodyType.STATIC;
        case KINEMATIC: return b3::BodyType.KINEMATIC;
        case DYNAMIC:   return b3::BodyType.DYNAMIC;
    }
}

fn void* pack_entity(Entity entity) @private => (void*)(uptr)((ulong)entity.generation << 32 | entity.index);

fn Entity unpack_entity(void* user_data) @private {
    ulong packed = (ulong)(uptr)user_data;
    return { .index = (uint)packed, .generation = (uint)(packed >> 32) };
}
