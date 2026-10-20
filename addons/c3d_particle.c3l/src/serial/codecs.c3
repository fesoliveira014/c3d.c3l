module c3d::particle @feat(C3D_PARTICLE_SERIAL);

import c3d;
import c3d::describe;
import c3d::ecs;
import c3d::scene;
import c3d::serial;
import std::math;

const ulong RANGE_LAYOUT @private = 0xaf1f0c33b5e51627;
const ulong TABLE_LAYOUT @private = 0xe4c18077262a7a22;
const ulong COLOR_TABLE_LAYOUT @private = 0x4eacd1a988dfc1b2;
const ulong DESC_V1_LAYOUT @private = 0x1a366da2bd207420;
const ulong DESC_LAYOUT @private = 0x63291d71ce5d82d3;
const ulong AUTHORING_V1_LAYOUT @private = 0xea58cb75a4a73416;
const ulong AUTHORING_LAYOUT @private = 0x2bb779bddc9e4271;

struct ParticleSystemDescV1 @private {
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

struct ParticleAuthoringV1 @private {
    ParticleSystemDescV1 desc;
    bool emitting;
}

struct ParticleAuthoring @private {
    ParticleSystemDesc desc;
    bool emitting;
}

serial::BinaryCompatibility[1] particle_binary_compatibility @local = {
    { .version = 1, .read = &read_system_v1 },
};
uint[1] particle_text_default_versions @local = { 1 };

<*
 Register particle authoring codecs and generated draw ownership.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn void? register_serial_codecs() {
    serial::register_core_value_types()!;
    register_value(ParticleRange, RANGE_LAYOUT, &defaults_range)!;
    register_value(LifetimeTable, TABLE_LAYOUT, &defaults_table)!;
    register_value(LifetimeColorTable, COLOR_TABLE_LAYOUT, &defaults_color_table)!;
    register_value(ParticleSystemDescV1, DESC_V1_LAYOUT, &defaults_desc_v1)!;
    describe::register_reflected(ParticleSystemDesc)!;
    serial::register_described_type(
        $Type: ParticleSystemDesc,
        version: 2,
        layout: DESC_LAYOUT,
        defaults: &defaults_desc,
    )!;
    register_value(ParticleAuthoringV1, AUTHORING_V1_LAYOUT, &defaults_authoring_v1)!;
    describe::register_reflected(ParticleAuthoring)!;
    serial::register_described_type(
        $Type: ParticleAuthoring,
        version: 2,
        layout: AUTHORING_LAYOUT,
        defaults: &defaults_authoring,
    )!;
    serial::register_described_owner(ParticleSystem, ParticleAuthoring, {
        .name = "particle_system",
        .phase = VALUE,
        .collect = &collect_system,
        .project = &project_system,
        .validate = &validate_system,
        .attach = &attach_system,
        .binary_compatibility = particle_binary_compatibility[..],
        .text_default_versions = particle_text_default_versions[..],
    })!;
    serial::register_transient(ParticleDrawOwner, &collect_draw)!;
}

macro void? register_value($Type, ulong layout, serial::DefaultsFn defaults) @private {
    describe::register_reflected($Type)!;
    serial::register_described_type(
        $Type: $Type,
        version: 1,
        layout: layout,
        defaults: defaults,
    )!;
}

fn void defaults_range(void* value) @private => *(ParticleRange*)value = {};
fn void defaults_table(void* value) @private => ((LifetimeTable*)value).values[..] = 1;
fn void defaults_color_table(void* value) @private => ((LifetimeColorTable*)value).values[..] = (Vec4){ 1, 1, 1, 1 };
fn void defaults_desc(void* value) @private => *(ParticleSystemDesc*)value = default_particle_system_desc();
fn void defaults_desc_v1(void* value) @private {
    *(ParticleSystemDescV1*)value = particle_desc_v1(default_particle_system_desc());
}
fn void defaults_authoring(void* value) @private {
    *(ParticleAuthoring*)value = { .desc = default_particle_system_desc(), .emitting = true };
}
fn void defaults_authoring_v1(void* value) @private {
    *(ParticleAuthoringV1*)value = { .desc = particle_desc_v1(default_particle_system_desc()), .emitting = true };
}

fn ParticleSystemDescV1 particle_desc_v1(ParticleSystemDesc desc) @private {
    return {
        .capacity = desc.capacity,
        .seed = desc.seed,
        .render_mode = desc.render_mode,
        .material = desc.material,
        .geometry = desc.geometry,
        .shape = desc.shape,
        .radius = desc.radius,
        .half_extents = desc.half_extents,
        .cone_angle = desc.cone_angle,
        .rate = desc.rate,
        .lifetime = desc.lifetime,
        .speed = desc.speed,
        .size = desc.size,
        .rotation = desc.rotation,
        .spin = desc.spin,
        .color_min = desc.color_min,
        .color_max = desc.color_max,
        .size_over_life = desc.size_over_life,
        .color_over_life = desc.color_over_life,
        .gravity_scale = desc.gravity_scale,
        .drag = desc.drag,
        .stretch = desc.stretch,
    };
}

fn ParticleSystemDesc particle_desc_from_v1(ParticleSystemDescV1 legacy) @private {
    ParticleSystemDesc desc = default_particle_system_desc();
    desc.capacity = legacy.capacity;
    desc.seed = legacy.seed;
    desc.render_mode = legacy.render_mode;
    desc.material = legacy.material;
    desc.geometry = legacy.geometry;
    desc.shape = legacy.shape;
    desc.radius = legacy.radius;
    desc.half_extents = legacy.half_extents;
    desc.cone_angle = legacy.cone_angle;
    desc.rate = legacy.rate;
    desc.lifetime = legacy.lifetime;
    desc.speed = legacy.speed;
    desc.size = legacy.size;
    desc.rotation = legacy.rotation;
    desc.spin = legacy.spin;
    desc.color_min = legacy.color_min;
    desc.color_max = legacy.color_max;
    desc.size_over_life = legacy.size_over_life;
    desc.color_over_life = legacy.color_over_life;
    desc.gravity_scale = legacy.gravity_scale;
    desc.drag = legacy.drag;
    desc.stretch = legacy.stretch;
    return desc;
}

fn void? project_system(void* component, void* value, serial::WriteContext* context) @private {
    ParticleSystem* system = component;
    check_particle_desc(&system.desc)!;
    *(ParticleAuthoring*)value = { .desc = system.desc, .emitting = system.emitting };
}

fn void? validate_system(void* value, serial::ReadContext* context) @private {
    check_particle_desc(&((ParticleAuthoring*)value).desc)!;
}

fn void? attach_system(void* value, serial::ReadContext* context) @private {
    ParticleAuthoring* authoring = value;
    context.scene.attach_particle_system(context.node, authoring.desc)!;
    context.scene.get(context.node, ParticleSystem).emitting = authoring.emitting;
}

fn void? read_system_v1(serial::Reader* reader, serial::ReadContext* context) @private {
    ParticleAuthoringV1* legacy = context.read_value(ParticleAuthoringV1, reader)!;
    ParticleAuthoring authoring = {
        .desc = particle_desc_from_v1(legacy.desc),
        .emitting = legacy.emitting,
    };

    validate_system(&authoring, context)!;
    attach_system(&authoring, context)!;
}

fn void? collect_system(void* component, serial::WriteContext* context) @private {
    ParticleSystem* system = component;
    if (!system.is_prepared()) return;
    if (!context.scene.world.is_alive(system.draw_node)) return c3d::INVALID_ARGUMENT~;
    Node* draw = context.scene.node(system.draw_node);
    ParticleDrawOwner* owner = context.scene.get(draw, ParticleDrawOwner);
    if (!owner || !c3d::same_id(owner.emitter, context.node.id) || draw.parent != context.node) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (system.desc.render_mode == ParticleRenderMode.MESH) {
        if (!context.scene.has(draw, InstancedMesh)) return c3d::INVALID_ARGUMENT~;
        context.omit_component(draw, ecs::slot_of(InstancedMesh)!)!;
    } else {
        if (!context.scene.has(draw, BillboardBatch)) return c3d::INVALID_ARGUMENT~;
        context.omit_component(draw, ecs::slot_of(BillboardBatch)!)!;
    }
    context.omit_node(draw)!;
}

fn void? collect_draw(void* component, serial::WriteContext* context) @private {
    ParticleDrawOwner* owner = component;
    if (!context.scene.world.is_alive(owner.emitter)) return c3d::INVALID_ARGUMENT~;
    Node* emitter = context.scene.node(owner.emitter);
    if (!context.contains_node(emitter) || context.node.parent != emitter) return c3d::INVALID_ARGUMENT~;
    ParticleSystem* system = context.scene.get(emitter, ParticleSystem);
    if (!system || !system.is_prepared() || !c3d::same_id(system.draw_node, context.node.id)) {
        return c3d::INVALID_ARGUMENT~;
    }
}
