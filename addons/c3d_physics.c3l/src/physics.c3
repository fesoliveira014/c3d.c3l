module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import b3;

<*
 Application-defined surface identity passed to events, queries and mixing.
*>
typedef SurfaceMaterialId = ulong;

alias Quat @private = Quaternionf;

<*
 Friction of two touching surfaces; pure, called inside the step.
*>
alias FrictionMixFn = fn float(float friction_a, SurfaceMaterialId surface_a, float friction_b, SurfaceMaterialId surface_b);

<*
 Restitution of two touching surfaces; pure, called inside the step.
*>
alias RestitutionMixFn = fn float(float restitution_a, SurfaceMaterialId surface_a, float restitution_b, SurfaceMaterialId surface_b);

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
const uint  DEFAULT_EVENT_CAPACITY = 4096; // six lists, 144 bytes per index across them: 576 KiB per world; the contact burst lever
<* Collision snapshot slots per world. *>
const uint  DEFAULT_SNAPSHOT_CAPACITY = 256; // one slot per distinct cooked key; the level variety lever
<* Water density, kilograms per cubic meter. *>
const float DEFAULT_DENSITY = 1000;
<* Dry friction coefficient. *>
const float DEFAULT_FRICTION = 0.6f;
<* Explosion impulse multiplier of a shape. *>
const float DEFAULT_EXPLOSION_SCALE = 1;
<* Height-field cell index that removes the cell. *>
const char  HEIGHT_FIELD_HOLE = char::max; // mirrored as B3_HEIGHT_FIELD_HOLE in box3d's types.h

<*
 Every category, colliding with everything.
*>
const CollisionFilter FILTER_ALL = { .category = 1, .mask = ulong::max };

$assert SurfaceMaterialId::size == ulong::size;

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
    COMPOUND,
}

<*
 Shape of one compound part.
*>
enum CompoundChildKind {
    SPHERE,
    CAPSULE,
    BOX,
    HULL,
    MESH,
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
 Row-major heights, x fastest; copied when cooked.
*>
struct HeightField {
    float[] heights;
    uint    count_x;
    uint    count_z;
}

<*
 Contact properties of a surface.
*>
struct SurfaceMaterialDesc {
    float             friction;
    float             restitution;
    float             rolling_resistance; // spheres and capsules only
    Vec3              tangent_velocity;   // shape-local; conveyor belts
    SurfaceMaterialId id;
}

<*
 Axes the solver may not move or turn the body along.
*>
struct MotionLocks {
    bool linear_x;
    bool linear_y;
    bool linear_z;
    bool angular_x;
    bool angular_y;
    bool angular_z;
}

<*
 One part of a compound collider; which fields apply depends on kind.
*>
struct CompoundChild {
    CompoundChildKind     kind;
    maths::Transform      local;
    float                 radius;
    float                 half_height;
    Vec3                  half_extents;
    GeometryId            geometry;
    SurfaceMaterialDesc   material;
    SurfaceMaterialDesc[] face_materials;   // MESH: highest material index plus one, at most b3::MAX_COMPOUND_MESH_MATERIALS
    char[]                material_indices; // MESH: one per triangle
}

<*
 One shape of a body; which fields apply depends on kind.
*>
struct ColliderDesc {
    ColliderKind          kind;
    maths::Transform      local;
    float                 radius;
    float                 half_height;
    Vec3                  half_extents;
    GeometryId            geometry;
    HeightField           height_field;
    CompoundChild[]       children;
    float                 density;
    float                 explosion_scale;
    SurfaceMaterialDesc   material;
    SurfaceMaterialDesc[] face_materials;
    char[]                material_indices; // MESH: one per triangle; HEIGHT_FIELD: one per cell
    bool                  sensor;
    bool                  contact_events;
    bool                  hit_events;
    CollisionFilter       filter;
}

<*
 Motion properties of a body at creation.
*>
struct BodyDesc {
    BodyKind    kind;
    String      name;
    Vec3        linear_velocity;
    Vec3        angular_velocity;
    float       linear_damping;
    float       angular_damping;
    float       gravity_scale;
    bool        allow_sleep;
    bool        bullet;
    MotionLocks locks;
}

<*
 World settings that may change while bodies live.
*>
struct PhysicsTuning {
    Vec3             gravity;
    float            fixed_dt;
    uint             sub_steps;
    uint             max_steps_per_frame;
    bool             interpolate;
    float            hit_speed_threshold;
    float            contact_hertz;
    float            contact_damping_ratio;
    float            contact_speed;
    float            maximum_linear_speed;
    float            restitution_threshold;
    bool             continuous;
    bool             sleep;
    FrictionMixFn    friction_mix;
    RestitutionMixFn restitution_mix;
}

<*
 World configuration: runtime tuning plus creation-only capacities.
 cache_wireframes builds collider wireframes with each collision snapshot; off, debug_draw skips cooked colliders.
*>
struct PhysicsDesc {
    PhysicsTuning tuning;
    bool          cache_wireframes;
    uint          event_capacity;
    uint          snapshot_capacity;
}

<*
 Radial impulse from a point.
*>
struct ExplosionDesc {
    Vec3  position;
    float radius;
    float falloff;
    float impulse_per_area;
    ulong mask;
}

<*
 One shape of a rigid body; wire borrows its snapshot's.
*>
struct Collider {
    b3::ShapeId      shape;
    ColliderKind     kind;
    maths::Transform local;
    float            radius;
    float            half_height;
    Vec3             half_extents;
    SnapshotHandle   snapshot; // generation 0 for primitives
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
    Node*             a;
    Node*             b;
    Vec3              point;
    Vec3              normal;
    float             approach_speed;
    SurfaceMaterialId surface_a;
    SurfaceMaterialId surface_b;
}

<*
 A visitor entered or left a sensor; nodes are frame borrows.
*>
struct SensorEvent {
    Node* sensor;
    Node* visitor;
}

<*
 A body the world could not build this update; node is a frame borrow.
*>
struct BuildFailure {
    Node* node;
    fault reason;
}

<*
 Closest body along a ray.
*>
struct RayHit {
    Node*             node;
    Vec3              point;
    Vec3              normal;
    float             fraction;
    SurfaceMaterialId surface;
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
 Owner of one box3d world, its collision snapshots and the frame event lists.
*>
struct PhysicsWorld {
    Allocator      allocator;
    SnapshotTable* snapshots;      // heap, so the RigidBody removal hook keeps a stable address
    b3::WorldId    world;
    AssetStore*    assets;
    Scene*         scene;
    PhysicsDesc    desc;
    float          accumulator;
    float          alpha;
    uint           steps_last_update;
    uint           dropped_events;
    Entity[]       orphan_scratch; // scene node capacity
    ContactEvent[] contact_begin_storage;
    uint           contact_begin_count;
    ContactEvent[] contact_end_storage;
    uint           contact_end_count;
    HitEvent[]     hit_storage;
    uint           hit_count;
    SensorEvent[]  sensor_begin_storage;
    uint           sensor_begin_count;
    SensorEvent[]  sensor_end_storage;
    uint           sensor_end_count;
    BuildFailure[] failure_storage;
    uint           failure_count;
}

<*
 Author a body on the node and build it now.
 @param [&in] node : "Its world matrix is the initial pose; update_world first."
 @param colliders : "Copied; a visitor with contact_events is visible to sensors."
 @return? BODY_EXISTS, STATIC_ONLY, SOURCE_UNAVAILABLE, c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, b3::INVALID_DEFINITION, b3::INVALID_HANDLE, b3::DEGENERATE_GEOMETRY, b3::CHILD_LIMIT_REACHED
 @require self.scene.world.is_registered(PhysicsBody), colliders.len > 0
*>
fn void? PhysicsWorld.add_body(
    &self,
    Node* node,
    BodyDesc body,
    ColliderDesc[] colliders,
) {
    self.scene.add_physics_body(node, body, colliders)!;
    defer catch self.scene.remove_component(node, PhysicsBody);
    build_body(self, node, self.scene.get(node, PhysicsBody))!;
}

<*
 Remove the node's authored body and its built body now.
 Invalidates PhysicsBody and RigidBody pointers.
 @require self.scene.has(node, PhysicsBody)
*>
fn void PhysicsWorld.remove_body(&self, Node* node) {
    if (self.scene.has(node, RigidBody)) self.scene.remove_component(node, RigidBody);
    self.scene.remove_component(node, PhysicsBody);
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
 Apply new world settings to the live world.
 @require tuning.fixed_dt > 0, tuning.sub_steps > 0
*>
fn void PhysicsWorld.set_tuning(&self, PhysicsTuning tuning) {
    b3::WorldId world = self.world;
    world.set_gravity(tuning.gravity);
    world.set_hit_event_threshold(tuning.hit_speed_threshold);
    world.set_contact_tuning(tuning.contact_hertz, tuning.contact_damping_ratio, tuning.contact_speed);
    world.set_maximum_linear_speed(tuning.maximum_linear_speed);
    world.set_restitution_threshold(tuning.restitution_threshold);
    world.enable_continuous(tuning.continuous);
    world.enable_sleeping(tuning.sleep);
    world.set_friction_callback((b3::FrictionFn)tuning.friction_mix);
    world.set_restitution_callback((b3::RestitutionFn)tuning.restitution_mix);
    self.desc.tuning = tuning;
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
 Bodies the last update could not build.
*>
fn BuildFailure[] PhysicsWorld.build_failures(&self) => self.failure_storage[:self.failure_count];

<*
 Default world configuration, with box3d's own contact tuning.
*>
fn PhysicsDesc default_physics_desc() {
    b3::WorldDef world = b3::default_world_def();
    return {
        .tuning = {
            .gravity               = DEFAULT_GRAVITY,
            .fixed_dt              = DEFAULT_FIXED_DT,
            .sub_steps             = DEFAULT_SUB_STEPS,
            .max_steps_per_frame   = DEFAULT_MAX_STEPS,
            .interpolate           = true,
            .hit_speed_threshold   = DEFAULT_HIT_SPEED_THRESHOLD,
            .contact_hertz         = world.contact_hertz,
            .contact_damping_ratio = world.contact_damping_ratio,
            .contact_speed         = world.contact_speed,
            .maximum_linear_speed  = world.maximum_linear_speed,
            .restitution_threshold = world.restitution_threshold,
            .continuous            = world.enable_continuous,
            .sleep                 = world.enable_sleep,
        },
        .cache_wireframes  = true,
        .event_capacity    = DEFAULT_EVENT_CAPACITY,
        .snapshot_capacity = DEFAULT_SNAPSHOT_CAPACITY,
    };
}

<*
 Default body of the kind: unit gravity, sleeping allowed.
*>
fn BodyDesc default_body_desc(BodyKind kind = DYNAMIC) {
    return { .kind = kind, .gravity_scale = 1, .allow_sleep = true };
}

<*
 Default surface: dry friction, no bounce.
*>
fn SurfaceMaterialDesc default_surface_material() {
    return { .friction = DEFAULT_FRICTION };
}

<*
 Default collider of the kind: identity placement, water density, dry friction.
*>
fn ColliderDesc default_collider_desc(ColliderKind kind) {
    return {
        .kind            = kind,
        .local           = maths::TRANSFORM_IDENTITY,
        .density         = DEFAULT_DENSITY,
        .explosion_scale = DEFAULT_EXPLOSION_SCALE,
        .material        = default_surface_material(),
        .filter          = FILTER_ALL,
    };
}

<*
 Default compound part of the kind: identity placement, dry friction.
*>
fn CompoundChild default_compound_child(CompoundChildKind kind) {
    return {
        .kind     = kind,
        .local    = maths::TRANSFORM_IDENTITY,
        .material = default_surface_material(),
    };
}

<*
 Explosion affecting every category; position, reach and strength left to fill.
*>
fn ExplosionDesc default_explosion_desc() {
    return { .mask = ulong::max };
}

<*
 Create a physics world bound to the scene and its asset store.
 @param [&in] assets : "Borrowed; outlives the world."
 @param [&inout] scene : "Borrowed; outlives the world; gains the RigidBody store and hook."
 @return? c3d::CAPACITY_EXCEEDED, b3::WORLD_LIMIT_REACHED, b3::INVALID_DEFINITION
 @require scene.world.is_registered(PhysicsBody)
*>
fn PhysicsWorld? create_physics_world(
    Allocator allocator,
    AssetStore* assets,
    Scene* scene,
    PhysicsDesc desc,
) {
    PhysicsTuning tuning = desc.tuning;
    b3::WorldDef def = b3::default_world_def();
    def.gravity = tuning.gravity;
    def.hit_event_threshold = tuning.hit_speed_threshold;
    def.contact_hertz = tuning.contact_hertz;
    def.contact_damping_ratio = tuning.contact_damping_ratio;
    def.contact_speed = tuning.contact_speed;
    def.maximum_linear_speed = tuning.maximum_linear_speed;
    def.restitution_threshold = tuning.restitution_threshold;
    def.enable_continuous = tuning.continuous;
    def.enable_sleep = tuning.sleep;
    def.friction_callback = (b3::FrictionFn)tuning.friction_mix;
    def.restitution_callback = (b3::RestitutionFn)tuning.restitution_mix;
    b3::WorldId world = b3::create_world(&def)!;
    defer catch b3::destroy_world(world);
    scene.register(RigidBody)!;

    SnapshotTable* snapshots = create_snapshot_table(allocator, desc.snapshot_capacity);
    scene.set_remove_hook(RigidBody, &remove_rigid_body, snapshots);

    return {
        .allocator             = allocator,
        .snapshots             = snapshots,
        .world                 = world,
        .assets                = assets,
        .scene                 = scene,
        .desc                  = desc,
        .orphan_scratch        = alloc::new_array(allocator, Entity, (sz)scene.nodes.len),
        .contact_begin_storage = alloc::new_array(allocator, ContactEvent, desc.event_capacity),
        .contact_end_storage   = alloc::new_array(allocator, ContactEvent, desc.event_capacity),
        .hit_storage           = alloc::new_array(allocator, HitEvent, desc.event_capacity),
        .sensor_begin_storage  = alloc::new_array(allocator, SensorEvent, desc.event_capacity),
        .sensor_end_storage    = alloc::new_array(allocator, SensorEvent, desc.event_capacity),
        .failure_storage       = alloc::new_array(allocator, BuildFailure, desc.event_capacity),
    };
}

<*
 Destroy the world, bodies and snapshots; nodes and PhysicsBody components remain.
 @param [&inout] world : "Destroyed before its scene and asset store."
*>
fn void destroy_physics_world(PhysicsWorld* world) {
    Scene* scene = world.scene;
    usz count;
    scene.@each(RigidBody; entity, body) {
        world.orphan_scratch[count++] = entity;
    };
    foreach (entity : world.orphan_scratch[:count]) scene.remove_component(scene.node(entity), RigidBody);
    scene.@each(PhysicsBody; entity, physics_body) {
        physics_body.status = PENDING;
    };
    scene.set_remove_hook(RigidBody, null, null);
    b3::destroy_world(world.world);
    destroy_snapshot_table(world.snapshots);

    alloc::free(world.allocator, world.orphan_scratch.ptr);
    alloc::free(world.allocator, world.contact_begin_storage.ptr);
    alloc::free(world.allocator, world.contact_end_storage.ptr);
    alloc::free(world.allocator, world.hit_storage.ptr);
    alloc::free(world.allocator, world.sensor_begin_storage.ptr);
    alloc::free(world.allocator, world.sensor_end_storage.ptr);
    alloc::free(world.allocator, world.failure_storage.ptr);
    *world = {};
}

fn b3::SurfaceMaterial surface_material(SurfaceMaterialDesc desc) @private {
    b3::SurfaceMaterial material = b3::default_surface_material();
    material.friction = desc.friction;
    material.restitution = desc.restitution;
    material.rolling_resistance = desc.rolling_resistance;
    material.tangent_velocity = desc.tangent_velocity;
    material.user_material_id = (ulong)desc.id;
    return material;
}

fn b3::MotionLocks motion_locks(MotionLocks locks) @private {
    return {
        .linear_x  = locks.linear_x,
        .linear_y  = locks.linear_y,
        .linear_z  = locks.linear_z,
        .angular_x = locks.angular_x,
        .angular_y = locks.angular_y,
        .angular_z = locks.angular_z,
    };
}

fn b3::BodyType body_type(BodyKind kind) @private {
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
