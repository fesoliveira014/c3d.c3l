module c3d::particle;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Samples in an over-lifetime table.
*>
const uint LIFETIME_TABLE_ENTRIES = 8; // 32 bytes per scalar table; one lerp per sample

<*
 Most octaves a turbulence field can sum.
*>
const uint MAX_TURBULENCE_OCTAVES = 3; // each octave adds one curl evaluation per particle per step

<*
 Most lattice cells in one tile of a turbulence field.
*>
const uint MAX_TURBULENCE_PERIOD = uint::max >> MAX_TURBULENCE_OCTAVES; // period << octaves stays inside 32 bits

<*
 Most points one particle's trail keeps.
*>
const uint MAX_TRAIL_POINTS = 64; // per particle; the ring is capacity * max_points points in the pool

<*
 Maximum simulated duration of one update.
*>
const float MAX_PARTICLE_STEP_SECONDS = 0.1f; // caps hitch integration; excess wall time is dropped

<*
 World acceleration at unit gravity scale.
*>
const Vec3 PARTICLE_GRAVITY = { 0, -9.81f, 0 };

<*
 Sub-emitters one system can carry.
*>
const uint MAX_SUB_EMITTERS = 4; // each adds one trigger test per raised event

const uint DEFAULT_COLLISION_QUERIES @private = 256; // callback casts per step; each is one world query
const float DEFAULT_IMPACT_SPEED @private = 1; // above the 0.98 m/s gravity adds in the longest step
const uint DEFAULT_PARTICLE_CAPACITY @private = 1024; // 56 KiB pool for a small effect; draw arrays are additional
const usz PARTICLE_FLOAT_STREAMS @private = 5;
const usz TRAIL_POINT_FLOAT_STREAMS @private = 2; // stamp and distance of each stored point
const usz TRAIL_PARTICLE_FLOAT_STREAMS @private = 2; // record clock and path length of each particle
const usz TRAIL_PARTICLE_UINT_STREAMS @private = 2; // ring write cursor and stored count of each particle

<*
 Volume and direction distribution of new particles.
*>
enum EmitterShape {
    POINT,
    SPHERE,
    BOX,
    CONE,
}

<*
 Draw representation owned by an emitter.
*>
enum ParticleRenderMode {
    BILLBOARD,
    STRETCHED,
    MESH,
}

<*
 Policy for emission requests that exceed the free capacity of a pool.
*>
enum ParticleSaturation {
    REFUSE,
    DROP_OLDEST,
}

<*
 Occurrence in a particle's life that a sub-emitter reacts to.
*>
enum ParticleTrigger {
    DEATH,
    IMPACT,
    BIRTH,
}

<*
 How a flipbook chooses the frame of a particle.
*>
enum FlipbookMode {
    OVER_LIFE,
    FPS,
}

<*
 How a trail maps its texture coordinate along the strip.
*>
enum TrailUv {
    STRETCH,
    TILE,
}

<*
 Reason a particle left its pool.
*>
enum ParticleEventCause {
    EXPIRED,
    EVICTED,
    IMPACT,
}

<*
 What a particle does when its path meets a surface.
*>
enum CollisionResponse {
    NONE,
    BOUNCE,
    STICK,
    DIE,
}

<*
 Hit of a particle's path against the world.
*>
struct ParticleHit {
    Vec3 point; // on the surface, not the particle centre
    Vec3 normal; // unit length, facing the particle
    float fraction; // along the path, [0, 1]
}

<*
 Sweep a sphere along a particle path and report the first hit.
 @param context : "The pointer given to ParticleSystem.set_collision."
 @param from : "Scene-space start of the path."
 @param to : "Scene-space end of the path; never equal to from."
 @param [&out] out : "Written only when the cast returns true."
 @return "Whether the sphere met a surface."
*>
alias ParticleCollisionFn = fn bool(void* context, Vec3 from, Vec3 to, float radius, ParticleHit* out);

<*
 Closed interval for an emitted scalar value.
*>
struct ParticleRange {
    float min;
    float max;
}

<*
 Piecewise-linear scalar multiplier over normalized lifetime.
*>
struct LifetimeTable {
    float[LIFETIME_TABLE_ENTRIES] values;
}

<*
 Piecewise-linear colour multiplier over normalized lifetime.
*>
struct LifetimeColorTable {
    Vec4[LIFETIME_TABLE_ENTRIES] values;
}

<*
 Another system that emits where this system's particles are born, die or hit.
*>
struct SubEmitter {
    ParticleTrigger trigger;
    Entity target; // another particle system's node, inside the same exported subtree when serialized
    uint count;
    float inherit_velocity; // share of the parent particle's velocity added to each child, [0, 1]
    bool on_evict; // DEATH also fires for evicted particles; off bounds cascades
}

<*
 Queued occurrence that the sub-emitters of a system react to.
*>
struct ParticleEvent {
    ParticleTrigger trigger;
    ParticleEventCause cause; // read only for DEATH
    uint parent_seed;
    ulong index; // position in the system's event sequence; distinguishes repeated events of one particle
    Vec3 position;
    Vec3 velocity;
}

<*
 How a system's particles meet the world.
*>
struct ParticleCollision {
    CollisionResponse response;
    float restitution; // share of the normal speed kept by a bounce, [0, 1]
    float friction; // share of the tangent speed lost by a bounce, [0, 1]
    float radius_scale; // drawn particle size to collision radius
    bool ground_plane; // collide with the plane at ground_height without the callback
    float ground_height; // world height; the horizontal-only origin rebase never moves it
    uint max_queries; // callback casts per step; the rest wait, see ParticleSystem.query_cursor
    float impact_speed; // least speed into the surface that raises IMPACT, metres per second
}

<*
 Sprite-sheet playback for billboard and stretched particles; zero columns disables it.
*>
struct ParticleFlipbook {
    uint columns;
    uint rows;
    uint frame_count;
    Vec2 inset; // UV units cut from each cell edge, as BillboardAtlas.inset
    FlipbookMode mode;
    float fps; // read in FPS mode
    bool random_start; // each particle starts on a frame drawn from its seed
    bool blend; // off writes whole frames
}

<*
 Divergence-free air motion that particles follow through their drag; zero strength disables it.
 A system with zero drag ignores it.
*>
struct ParticleTurbulence {
    float strength; // metres per second of air velocity at the first octave
    float frequency; // lattice cells per metre
    uint octaves; // 1 to MAX_TURBULENCE_OCTAVES; each doubles the frequency and halves the strength
    uint period; // lattice cells per tile, so the field repeats every period / frequency metres
    Vec3 scroll; // metres per second that the pattern drifts
}

<*
 Ribbon trail behind each particle; zero max_points disables it.
 The trail leaves with its particle.
*>
struct ParticleTrail {
    uint max_points; // 0, or 2 to MAX_TRAIL_POINTS; the stored points, besides the live position
    float point_interval; // seconds of particle age between recorded points; at most one point per update
    float lifetime; // seconds a recorded point lives
    float width; // metres across the strip at the live position
    LifetimeTable width_over_trail; // by point age over lifetime; may end at 0
    LifetimeColorTable color_over_trail; // by point age over lifetime; multiplies the particle colour
    TrailUv uv;
    float tile_length; // metres of path per texture coordinate unit under TILE
    MaterialId material; // blended material of the trail batch
}

<*
 Immutable emission, simulation and draw configuration of one system.
*>
struct ParticleSystemDesc {
    uint capacity;
    ParticleSaturation saturation;
    uint seed;
    ParticleRenderMode render_mode;
    MaterialId material;
    GeometryId geometry;
    EmitterShape shape;
    float radius;
    Vec3 half_extents;
    float cone_angle;
    float rate;
    ParticleRange lifetime;
    ParticleRange speed;
    ParticleRange size;
    ParticleRange rotation;
    ParticleRange spin;
    Vec4 color_min;
    Vec4 color_max;
    LifetimeTable size_over_life;
    LifetimeColorTable color_over_life;
    float gravity_scale;
    float drag;
    float stretch;
    SubEmitter[MAX_SUB_EMITTERS] sub_emitters;
    uint sub_emitter_count;
    uint max_events; // event queue capacity; 0 disables events
    ParticleCollision collision;
    ParticleFlipbook flipbook;
    ParticleTurbulence turbulence;
    ParticleTrail trail;
    bool mesh_cast_shadow; // MESH only; the batch casts into the shadow maps when its material is opaque or masked
    bool mesh_trace; // MESH only; one scene trace instance per live particle, against the renderer's trace capacity
}

<*
 Authored particle system with an optional pool and owned draw child.
*>
struct ParticleSystem {
    ParticleSystemDesc desc;
    Vec3[] position;
    Vec3[] velocity;
    float[] age;
    float[] lifetime;
    float[] size;
    float[] rotation;
    float[] spin;
    uint[] seed;
    ulong[] spawn;
    Vec3[] trail_position; // max_points ring slots per particle, in the particle's own block
    float[] trail_stamp; // particle age when the slot was recorded
    float[] trail_distance; // path length along the stored points when the slot was recorded
    float[] trail_clock; // seconds since the last recorded point
    float[] path_length; // path length at the newest recorded point
    uint[] trail_head; // ring slot the next point is written to
    uint[] trail_count; // stored points, newest just before trail_head
    uint alive;
    ulong pending_burst;
    ulong next_spawn;
    ulong dropped;
    ulong evicted;
    ParticleEvent[] events;
    uint event_count;
    uint event_due; // events raised by this system's last step; later entries wait for the next update
    ulong next_event;
    ulong dropped_events;
    ulong skipped_events; // sub-emitter deliveries whose target is dead, not a particle system or not prepared
    ulong collision_skips; // particles that waited out a step because the callback budget ran out
    uint query_cursor; // pool index where the next step starts its callback queries; wraps
    ParticleCollisionFn collision_cast;
    void* collision_context;
    double emit_accumulator;
    double turbulence_time; // seconds this system has stepped; the turbulence pattern drifts with it
    Entity draw_node;
    Entity trail_node; // the ribbon child; unset while the trail is disabled
    bool emitting;
    void* block;
}

struct ParticleDrawOwner @private {
    Entity emitter;
}

<*
 Queue emission for the next step.
*>
fn void ParticleSystem.emit_burst(&self, uint count) {
    self.pending_burst = count > ulong::max - self.pending_burst ? ulong::max : self.pending_burst + count;
}

<*
 Install the cast the system's particles collide through; a null cast removes it.
 The cast runs on the calling thread inside particle::update.
 @param context : "Passed to every cast; must outlive the system or be cleared first."
 @require self.is_prepared()
*>
fn void ParticleSystem.set_collision(&self, ParticleCollisionFn cast, void* context) {
    self.collision_cast = cast;
    self.collision_context = context;
}

<*
 Create an emitter and its owned draw child.
 @param [in] parent : "Null selects the scene root."
 @param name : "Copied into the scene allocator."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require self.world.is_registered(ParticleSystem)
*>
fn Node*? Scene.add_particle_system(
    &self,
    ParticleSystemDesc desc,
    Node* parent = null,
    String name = "",
) {
    check_particle_desc(&desc)!;
    Node* emitter = self.add_node(parent, name)!;
    defer catch self.remove(emitter);
    self.attach_particle_system(emitter, desc)!;
    prepare(self, emitter)!;
    return emitter;
}

<*
 Attach particle authoring without allocating its pool or draw child.
 @param [&in] node : "Receives the pending system."
 @return? c3d::INVALID_ARGUMENT
 @require self.world.is_registered(ParticleSystem), !self.has(node, ParticleSystem)
*>
fn void? Scene.attach_particle_system(&self, Node* node, ParticleSystemDesc desc) {
    check_particle_desc(&desc)!;
    self.add(node, (ParticleSystem){ .desc = desc, .emitting = true });
}

<*
 Whether the particle system has its pool and draw child.
*>
fn bool ParticleSystem.is_prepared(&self) => self.block != null;

<*
 Prepare a pending particle system atomically; prepared systems are unchanged.
 @param [&inout] scene : "Registered; owns the pool and draw child."
 @param [&in] emitter : "Carries ParticleSystem."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require scene.has(emitter, ParticleSystem)
*>
fn void? prepare(Scene* scene, Node* emitter) {
    ParticleSystem system = *scene.get(emitter, ParticleSystem);
    if (system.is_prepared()) return;
    ParticleSystemDesc desc = system.desc;
    check_particle_desc(&desc)!;
    usz pool_bytes = particle_pool_bytes(desc.capacity, desc.max_events, desc.trail.max_points);
    void*? block = alloc::malloc_try(scene.allocator, (sz)pool_bytes);
    if (catch block) return c3d::CAPACITY_EXCEEDED~;
    system.block = block;
    defer catch alloc::free(scene.allocator, system.block);
    usz cursor;
    system.position = @carve_stream(Vec3, &system, &cursor, desc.capacity);
    system.velocity = @carve_stream(Vec3, &system, &cursor, desc.capacity);
    system.age = @carve_stream(float, &system, &cursor, desc.capacity);
    system.lifetime = @carve_stream(float, &system, &cursor, desc.capacity);
    system.size = @carve_stream(float, &system, &cursor, desc.capacity);
    system.rotation = @carve_stream(float, &system, &cursor, desc.capacity);
    system.spin = @carve_stream(float, &system, &cursor, desc.capacity);
    system.seed = @carve_stream(uint, &system, &cursor, desc.capacity);
    system.spawn = @carve_stream(ulong, &system, &cursor, desc.capacity);
    system.events = @carve_stream(ParticleEvent, &system, &cursor, desc.max_events);
    if (desc.trail.max_points) {
        usz points = (usz)desc.capacity * desc.trail.max_points;
        system.trail_position = @carve_stream(Vec3, &system, &cursor, points);
        system.trail_stamp = @carve_stream(float, &system, &cursor, points);
        system.trail_distance = @carve_stream(float, &system, &cursor, points);
        system.trail_clock = @carve_stream(float, &system, &cursor, desc.capacity);
        system.path_length = @carve_stream(float, &system, &cursor, desc.capacity);
        system.trail_head = @carve_stream(uint, &system, &cursor, desc.capacity);
        system.trail_count = @carve_stream(uint, &system, &cursor, desc.capacity);
    }
    Node* child;
    if (desc.render_mode == ParticleRenderMode.MESH) {
        child = scene.add_instanced_mesh(
            geometry: desc.geometry,
            material: desc.material,
            capacity: desc.capacity,
            parent: emitter,
        )!;
        InstancedMesh* batch = scene.get(child, InstancedMesh);
        batch.cast_shadow = desc.mesh_cast_shadow;
        batch.trace = desc.mesh_trace;
    } else {
        child = scene.add_billboards(
            material: desc.material,
            capacity: desc.capacity,
            facing: desc.render_mode == ParticleRenderMode.STRETCHED
              ? BillboardFacing.DIRECTIONAL : BillboardFacing.CAMERA,
            parent: emitter,
            atlas: flipbook_atlas(&desc.flipbook),
        )!;
    }
    defer catch scene.remove(child);
    child.transform_space = TransformSpace.WORLD;
    child.layers = emitter.layers;
    system.draw_node = child.id;
    scene.add(child, (ParticleDrawOwner){ .emitter = emitter.id });
    if (desc.trail.max_points) {
        Node* trail = scene.add_ribbons(
            material: desc.trail.material,
            capacity: desc.capacity * (desc.trail.max_points + 1),
            parent: emitter,
        )!;
        trail.transform_space = TransformSpace.WORLD;
        trail.layers = emitter.layers;
        system.trail_node = trail.id;
        scene.add(trail, (ParticleDrawOwner){ .emitter = emitter.id });
    }
    *scene.get(emitter, ParticleSystem) = system;
}

<*
 Prepare pending particle systems in a subtree, retaining successful owners.
 @param [&inout] scene : "Registered; prepared owners remain unchanged."
 @param [in] root : "Null selects the scene root; root is included."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? prepare_subtree(Scene* scene, Node* root = null) {
    if (!root) root = scene.root;
    fault failure;
    scene.@each(ParticleSystem; entity, owner) {
        Node* node = scene.node(entity);
        Node* ancestor = node;
        while (ancestor && ancestor != root) ancestor = ancestor.parent;
        if (ancestor) {
            if (catch excuse = prepare(scene, node)) {
                if (!failure) failure = excuse;
            }
        }
    };
    if (failure) return failure~;
}

<*
 Move every particle, trail point and queued event by the negated offset and put draw children back at the origin.
 Call after Scene.shift_origin and before update_world.
 @param [&inout] self : "Prepared systems are written; pending ones are skipped."
 @require offset.y == 0
*>
fn void Scene.shift_particles(&self, Vec3 offset) {
    self.@each(ParticleSystem; entity, system) {
        if (system.is_prepared()) {
            for (uint index = 0; index < system.alive; index++) system.position[index] -= offset;
            for (uint index = 0; index < system.event_count; index++) system.events[index].position -= offset;
            self.node(system.draw_node).local = maths::TRANSFORM_IDENTITY;
            if (system.desc.trail.max_points) {
                shift_trail_points(system, offset);
                self.node(system.trail_node).local = maths::TRANSFORM_IDENTITY;
            }
        }
    };
}

<*
 White point emitter with fixed capacity and unit lifetime tables.
*>
fn ParticleSystemDesc default_particle_system_desc() {
    ParticleSystemDesc desc = {
        .capacity = DEFAULT_PARTICLE_CAPACITY,
        .seed = 1,
        .render_mode = ParticleRenderMode.BILLBOARD,
        .shape = EmitterShape.POINT,
        .radius = 1,
        .half_extents = { 1, 1, 1 },
        .cone_angle = (float)math::PI / 6,
        .lifetime = { .min = 1, .max = 1 },
        .size = { .min = 1, .max = 1 },
        .color_min = { 1, 1, 1, 1 },
        .color_max = { 1, 1, 1, 1 },
        .collision = {
            .restitution = 0.5f,
            .radius_scale = 0.5f,
            .max_queries = DEFAULT_COLLISION_QUERIES,
            .impact_speed = DEFAULT_IMPACT_SPEED,
        },
    };
    desc.size_over_life.values[..] = 1;
    desc.color_over_life.values[..] = (Vec4){ 1, 1, 1, 1 };
    desc.trail.width_over_trail.values[..] = 1;
    desc.trail.color_over_trail.values[..] = (Vec4){ 1, 1, 1, 1 };
    return desc;
}

<*
 Register particle data and removal hooks with the scene.
 @param [&inout] scene : "No particle registration has occurred in this scene."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? register_particles(Scene* scene) {
    scene.register(ParticleSystem)!;
    scene.register(ParticleDrawOwner)!;
    scene.set_remove_hook(ParticleSystem, &free_particle_system, scene.hook_allocator);
}

fn usz particle_align(usz cursor, usz alignment) @private {
    return (cursor + alignment - 1) & ~(alignment - 1);
}

fn usz particle_pool_bytes(uint capacity, uint max_events, uint max_trail_points) @private {
    usz cursor = (usz)capacity * Vec3::size;
    cursor = particle_align(cursor, Vec3::alignment) + (usz)capacity * Vec3::size;
    cursor = particle_align(cursor, float::alignment) + (usz)capacity * PARTICLE_FLOAT_STREAMS * float::size;
    cursor = particle_align(cursor, uint::alignment) + (usz)capacity * uint::size;
    cursor = particle_align(cursor, ulong::alignment) + (usz)capacity * ulong::size;
    cursor = particle_align(cursor, ParticleEvent::alignment) + (usz)max_events * ParticleEvent::size;
    if (!max_trail_points) return cursor;

    usz points = (usz)capacity * max_trail_points;
    cursor = particle_align(cursor, Vec3::alignment) + points * Vec3::size;
    usz floats = points * TRAIL_POINT_FLOAT_STREAMS + (usz)capacity * TRAIL_PARTICLE_FLOAT_STREAMS;
    cursor = particle_align(cursor, float::alignment) + floats * float::size;
    return particle_align(cursor, uint::alignment) + (usz)capacity * TRAIL_PARTICLE_UINT_STREAMS * uint::size;
}

macro @carve_stream($Type, ParticleSystem* system, usz* cursor, usz count) @private {
    $assert $Type::alignment <= mem::DEFAULT_MEM_ALIGNMENT;
    usz offset = particle_align(*cursor, $Type::alignment);
    *cursor = offset + count * $Type::size;
    return (($Type*)((char*)system.block + offset))[:count];
}

fn void free_particle_system(Entity entity, void* component, void* user) @private {
    alloc::free(*(Allocator*)user, ((ParticleSystem*)component).block);
}

fn bool valid_particle_range(ParticleRange range) @private {
    return math::is_finite(range.min) && math::is_finite(range.max) && range.min <= range.max;
}

fn bool valid_particle_color(Vec4 color) @private {
    for (usz channel = 0; channel < 4; channel++) {
        if (!math::is_finite(color[channel]) || color[channel] < 0) return false;
    }
    return color.a <= 1;
}

fn void? check_particle_desc(ParticleSystemDesc* desc) @private {
    check_particle_trail(&desc.trail, desc.capacity)!;
    usz pool_bytes = particle_pool_bytes(desc.capacity, desc.max_events, desc.trail.max_points);
    if (!desc.capacity || pool_bytes > (usz)sz::max) return c3d::INVALID_ARGUMENT~;
    ParticleRange[5] ranges = { desc.lifetime, desc.speed, desc.size, desc.rotation, desc.spin };
    foreach (range : ranges) if (!valid_particle_range(range)) return c3d::INVALID_ARGUMENT~;
    if (desc.lifetime.min <= 0 || desc.speed.min < 0 || desc.size.min < 0) return c3d::INVALID_ARGUMENT~;
    float[5] nonnegative = { desc.rate, desc.radius, desc.cone_angle, desc.drag, desc.stretch };
    foreach (value : nonnegative) {
        if (!math::is_finite(value) || value < 0) return c3d::INVALID_ARGUMENT~;
    }
    if (desc.cone_angle > (float)math::PI || !math::is_finite(desc.gravity_scale)) return c3d::INVALID_ARGUMENT~;
    for (usz axis = 0; axis < 3; axis++) {
        if (!math::is_finite(desc.half_extents[axis]) || desc.half_extents[axis] < 0) return c3d::INVALID_ARGUMENT~;
    }
    if (!valid_particle_color(desc.color_min) || !valid_particle_color(desc.color_max)) return c3d::INVALID_ARGUMENT~;
    foreach (value : desc.size_over_life.values) {
        if (!math::is_finite(value) || value < 0) return c3d::INVALID_ARGUMENT~;
    }
    foreach (color : desc.color_over_life.values) {
        if (!valid_particle_color(color)) return c3d::INVALID_ARGUMENT~;
    }
    if (desc.sub_emitter_count > MAX_SUB_EMITTERS || (desc.sub_emitter_count && !desc.max_events)) {
        return c3d::INVALID_ARGUMENT~;
    }
    foreach (sub_emitter : desc.sub_emitters[:desc.sub_emitter_count]) {
        float share = sub_emitter.inherit_velocity;
        if (!math::is_finite(share) || share < 0 || share > 1) return c3d::INVALID_ARGUMENT~;
    }
    check_particle_collision(&desc.collision)!;
    check_particle_flipbook(&desc.flipbook, desc.render_mode)!;
    check_particle_turbulence(&desc.turbulence)!;
    if (desc.render_mode != ParticleRenderMode.MESH && (desc.mesh_cast_shadow || desc.mesh_trace)) {
        return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_particle_collision(ParticleCollision* collision) @private {
    float[2] shares = { collision.restitution, collision.friction };
    foreach (share : shares) {
        if (!math::is_finite(share) || share < 0 || share > 1) return c3d::INVALID_ARGUMENT~;
    }
    float[2] nonnegative = { collision.radius_scale, collision.impact_speed };
    foreach (value : nonnegative) {
        if (!math::is_finite(value) || value < 0) return c3d::INVALID_ARGUMENT~;
    }
    if (!math::is_finite(collision.ground_height)) return c3d::INVALID_ARGUMENT~;
    if (collision.response != CollisionResponse.NONE && !collision.ground_plane && !collision.max_queries) {
        return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_particle_flipbook(ParticleFlipbook* flipbook, ParticleRenderMode render_mode) @private {
    if (!scene::billboard_atlas_valid(flipbook_atlas(flipbook))) return c3d::INVALID_ARGUMENT~;
    if (!flipbook.columns) return;

    if (render_mode == ParticleRenderMode.MESH) return c3d::INVALID_ARGUMENT~;
    if (flipbook.mode == FlipbookMode.FPS && !(math::is_finite(flipbook.fps) && flipbook.fps > 0)) {
        return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_particle_turbulence(ParticleTurbulence* turbulence) @private {
    float[5] finite = {
        turbulence.strength, turbulence.frequency, turbulence.scroll.x, turbulence.scroll.y, turbulence.scroll.z,
    };
    foreach (value : finite) if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
    if (turbulence.strength < 0) return c3d::INVALID_ARGUMENT~;
    if (turbulence.strength == 0) return;

    if (turbulence.frequency <= 0) return c3d::INVALID_ARGUMENT~;
    if (!turbulence.octaves || turbulence.octaves > MAX_TURBULENCE_OCTAVES) return c3d::INVALID_ARGUMENT~;
    if (!turbulence.period || turbulence.period > MAX_TURBULENCE_PERIOD) return c3d::INVALID_ARGUMENT~;
}

fn void? check_particle_trail(ParticleTrail* trail, uint capacity) @private {
    float[4] finite = { trail.point_interval, trail.lifetime, trail.width, trail.tile_length };
    foreach (value : finite) if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
    if (trail.width < 0) return c3d::INVALID_ARGUMENT~;
    foreach (value : trail.width_over_trail.values) {
        if (!math::is_finite(value) || value < 0) return c3d::INVALID_ARGUMENT~;
    }
    foreach (color : trail.color_over_trail.values) if (!valid_particle_color(color)) return c3d::INVALID_ARGUMENT~;
    if (!trail.max_points) return;

    if (trail.max_points < 2 || trail.max_points > MAX_TRAIL_POINTS) return c3d::INVALID_ARGUMENT~;
    if (trail.point_interval <= 0 || trail.lifetime <= 0) return c3d::INVALID_ARGUMENT~;
    if (trail.uv == TrailUv.TILE && trail.tile_length <= 0) return c3d::INVALID_ARGUMENT~;
    if ((ulong)capacity * (ulong)(trail.max_points + 1) > uint::max) return c3d::INVALID_ARGUMENT~;
}
