module c3d::particle;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;
import std::math::random;

<*
 Samples in an over-lifetime table.
*>
const uint LIFETIME_TABLE_ENTRIES = 8; // 32 bytes per scalar table; one lerp per sample

<*
 Maximum simulated duration of one update.
*>
const float MAX_PARTICLE_STEP_SECONDS = 0.1f; // caps hitch integration; excess wall time is dropped

<*
 World acceleration at unit gravity scale.
*>
const Vec3 PARTICLE_GRAVITY = { 0, -9.81f, 0 };

const uint DEFAULT_PARTICLE_CAPACITY @private = 1024; // 48 KiB pool for a small effect; draw arrays are additional
const usz PARTICLE_FLOAT_STREAMS @private = 5;
const uint SEED_BYTE_BITS @private = 8;

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
 Immutable emission, simulation and draw configuration of one system.
*>
struct ParticleSystemDesc {
    uint capacity;
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
}

<*
 Dense particle pool and its owned child draw node.
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
    uint alive;
    ulong pending_burst;
    ulong dropped;
    double emit_accumulator;
    Sfc32Random random;
    Entity draw_node;
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
    ParticleSystem system = { .desc = desc, .emitting = true };
    system.block = alloc::malloc(self.allocator, (sz)particle_pool_bytes(desc.capacity));
    defer catch alloc::free(self.allocator, system.block);
    usz cursor;
    system.position = @carve_stream(Vec3, &system, &cursor);
    system.velocity = @carve_stream(Vec3, &system, &cursor);
    system.age = @carve_stream(float, &system, &cursor);
    system.lifetime = @carve_stream(float, &system, &cursor);
    system.size = @carve_stream(float, &system, &cursor);
    system.rotation = @carve_stream(float, &system, &cursor);
    system.spin = @carve_stream(float, &system, &cursor);
    system.seed = @carve_stream(uint, &system, &cursor);
    char[uint::size] seed_bytes;
    foreach (index, &value : seed_bytes) *value = (char)(desc.seed >> (index * SEED_BYTE_BITS));
    system.random.set_seed(seed_bytes[..]);
    Node* child;
    if (desc.render_mode == ParticleRenderMode.MESH) {
        child = self.add_instanced_mesh(
            geometry: desc.geometry,
            material: desc.material,
            capacity: desc.capacity,
            parent: emitter,
        )!;
        InstancedMesh* batch = self.get(child, InstancedMesh);
        batch.cast_shadow = false;
        batch.trace = false;
    } else {
        child = self.add_billboards(
            material: desc.material,
            capacity: desc.capacity,
            facing: desc.render_mode == ParticleRenderMode.STRETCHED
              ? BillboardFacing.DIRECTIONAL : BillboardFacing.CAMERA,
            parent: emitter,
        )!;
    }
    child.transform_space = TransformSpace.WORLD;
    child.layers = emitter.layers;
    system.draw_node = child.id;
    self.add(child, (ParticleDrawOwner){ .emitter = emitter.id });
    self.add(emitter, system);
    return emitter;
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
    };
    desc.size_over_life.values[..] = 1;
    desc.color_over_life.values[..] = (Vec4){ 1, 1, 1, 1 };
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

fn usz particle_pool_bytes(uint capacity) @private {
    usz cursor = (usz)capacity * Vec3::size;
    cursor = particle_align(cursor, Vec3::alignment) + (usz)capacity * Vec3::size;
    cursor = particle_align(cursor, float::alignment) + (usz)capacity * PARTICLE_FLOAT_STREAMS * float::size;
    return particle_align(cursor, uint::alignment) + (usz)capacity * uint::size;
}

macro @carve_stream($Type, ParticleSystem* system, usz* cursor) @private {
    $assert $Type::alignment <= mem::DEFAULT_MEM_ALIGNMENT;
    usz offset = particle_align(*cursor, $Type::alignment);
    *cursor = offset + (usz)system.desc.capacity * $Type::size;
    return (($Type*)((char*)system.block + offset))[:system.desc.capacity];
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
    if (!desc.capacity || particle_pool_bytes(desc.capacity) > (usz)sz::max) return c3d::INVALID_ARGUMENT~;
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
}
