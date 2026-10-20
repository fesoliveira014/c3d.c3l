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
const ulong SUB_EMITTER_LAYOUT @private = 0xbc17df2b03f79e67;
const ulong COLLISION_LAYOUT @private = 0xb3c1e7574d47f9eb;
const ulong FLIPBOOK_LAYOUT @private = 0x3ff56ab69bece737;
const ulong TURBULENCE_LAYOUT @private = 0x3a1f2d4e38ebc210;
const ulong TRAIL_LAYOUT @private = 0x8ca2db8e1e495b9f;
const ulong DESC_V1_LAYOUT @private = 0x1a366da2bd207420;
const ulong DESC_V2_LAYOUT @private = 0x63291d71ce5d82d3;
const ulong DESC_V3_LAYOUT @private = 0x09ff25e64a1b07c9;
const ulong DESC_V4_LAYOUT @private = 0x2bcd644f0dae365e;
const ulong DESC_V5_LAYOUT @private = 0x9112174200c2df34;
const ulong DESC_V6_LAYOUT @private = 0x07763ae500c62112;
const ulong DESC_V7_LAYOUT @private = 0x4c53c2a840dc4b22;
const ulong DESC_V8_LAYOUT @private = 0xf4e634d538fb6561;
const ulong DESC_LAYOUT @private = 0xac2f8cc71b7487d9;
const ulong AUTHORING_V1_LAYOUT @private = 0xea58cb75a4a73416;
const ulong AUTHORING_V2_LAYOUT @private = 0x2bb779bddc9e4271;
const ulong AUTHORING_V3_LAYOUT @private = 0xfce463fdcc2f5ec7;
const ulong AUTHORING_V4_LAYOUT @private = 0xbc9869b807205e38;
const ulong AUTHORING_V5_LAYOUT @private = 0x35b8ed9f357f1cbe;
const ulong AUTHORING_V6_LAYOUT @private = 0x5cdb9677e6a87b8c;
const ulong AUTHORING_V7_LAYOUT @private = 0xa19169c0d642b947;
const ulong AUTHORING_V8_LAYOUT @private = 0x80aadf92bb6def28;
const ulong AUTHORING_LAYOUT @private = 0xc05a0e8dbcf9506c;

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

struct ParticleSystemDescV2 @private {
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
}

struct ParticleSystemDescV3 @private {
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
    uint max_events;
}

struct ParticleSystemDescV4 @private {
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
    uint max_events;
    ParticleCollision collision;
}

struct ParticleSystemDescV5 @private {
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
    uint max_events;
    ParticleCollision collision;
    ParticleFlipbook flipbook;
}

struct ParticleSystemDescV6 @private {
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
    uint max_events;
    ParticleCollision collision;
    ParticleFlipbook flipbook;
    ParticleTurbulence turbulence;
}

struct ParticleSystemDescV7 @private {
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
    uint max_events;
    ParticleCollision collision;
    ParticleFlipbook flipbook;
    ParticleTurbulence turbulence;
    ParticleTrail trail;
}

struct ParticleSystemDescV8 @private {
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
    uint max_events;
    ParticleCollision collision;
    ParticleFlipbook flipbook;
    ParticleTurbulence turbulence;
    ParticleTrail trail;
    bool mesh_cast_shadow;
    bool mesh_trace;
}

struct ParticleAuthoringV1 @private {
    ParticleSystemDescV1 desc;
    bool emitting;
}

struct ParticleAuthoringV2 @private {
    ParticleSystemDescV2 desc;
    bool emitting;
}

struct ParticleAuthoringV3 @private {
    ParticleSystemDescV3 desc;
    bool emitting;
}

struct ParticleAuthoringV4 @private {
    ParticleSystemDescV4 desc;
    bool emitting;
}

struct ParticleAuthoringV5 @private {
    ParticleSystemDescV5 desc;
    bool emitting;
}

struct ParticleAuthoringV6 @private {
    ParticleSystemDescV6 desc;
    bool emitting;
}

struct ParticleAuthoringV7 @private {
    ParticleSystemDescV7 desc;
    bool emitting;
}

struct ParticleAuthoringV8 @private {
    ParticleSystemDescV8 desc;
    bool emitting;
}

struct ParticleAuthoring @private {
    ParticleSystemDesc desc;
    bool emitting;
}

serial::BinaryCompatibility[8] particle_binary_compatibility @local = {
    { .version = 1, .read = &read_system_v1 },
    { .version = 2, .read = &read_system_v2 },
    { .version = 3, .read = &read_system_v3 },
    { .version = 4, .read = &read_system_v4 },
    { .version = 5, .read = &read_system_v5 },
    { .version = 6, .read = &read_system_v6 },
    { .version = 7, .read = &read_system_v7 },
    { .version = 8, .read = &read_system_v8 },
};
uint[8] particle_text_default_versions @local = { 1, 2, 3, 4, 5, 6, 7, 8 };

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
    register_value(SubEmitter, SUB_EMITTER_LAYOUT, &defaults_sub_emitter)!;
    register_value(ParticleCollision, COLLISION_LAYOUT, &defaults_collision)!;
    register_value(ParticleFlipbook, FLIPBOOK_LAYOUT, &defaults_flipbook)!;
    register_value(ParticleTurbulence, TURBULENCE_LAYOUT, &defaults_turbulence)!;
    register_value(ParticleTrail, TRAIL_LAYOUT, &defaults_trail)!;
    register_value(ParticleSystemDescV1, DESC_V1_LAYOUT, &defaults_desc_v1)!;
    register_value(
        $Type: ParticleSystemDescV2,
        layout: DESC_V2_LAYOUT,
        defaults: &defaults_desc_v2,
        version: 2,
    )!;
    register_value(
        $Type: ParticleSystemDescV3,
        layout: DESC_V3_LAYOUT,
        defaults: &defaults_desc_v3,
        version: 3,
    )!;
    register_value(
        $Type: ParticleSystemDescV4,
        layout: DESC_V4_LAYOUT,
        defaults: &defaults_desc_v4,
        version: 4,
    )!;
    register_value(
        $Type: ParticleSystemDescV5,
        layout: DESC_V5_LAYOUT,
        defaults: &defaults_desc_v5,
        version: 5,
    )!;
    register_value(
        $Type: ParticleSystemDescV6,
        layout: DESC_V6_LAYOUT,
        defaults: &defaults_desc_v6,
        version: 6,
    )!;
    register_value(
        $Type: ParticleSystemDescV7,
        layout: DESC_V7_LAYOUT,
        defaults: &defaults_desc_v7,
        version: 7,
    )!;
    register_value(
        $Type: ParticleSystemDescV8,
        layout: DESC_V8_LAYOUT,
        defaults: &defaults_desc_v8,
        version: 8,
    )!;
    describe::register_reflected(ParticleSystemDesc)!;
    serial::register_described_type(
        $Type: ParticleSystemDesc,
        version: 9,
        layout: DESC_LAYOUT,
        defaults: &defaults_desc,
    )!;
    register_value(ParticleAuthoringV1, AUTHORING_V1_LAYOUT, &defaults_authoring_v1)!;
    register_value(
        $Type: ParticleAuthoringV2,
        layout: AUTHORING_V2_LAYOUT,
        defaults: &defaults_authoring_v2,
        version: 2,
    )!;
    register_value(
        $Type: ParticleAuthoringV3,
        layout: AUTHORING_V3_LAYOUT,
        defaults: &defaults_authoring_v3,
        version: 3,
    )!;
    register_value(
        $Type: ParticleAuthoringV4,
        layout: AUTHORING_V4_LAYOUT,
        defaults: &defaults_authoring_v4,
        version: 4,
    )!;
    register_value(
        $Type: ParticleAuthoringV5,
        layout: AUTHORING_V5_LAYOUT,
        defaults: &defaults_authoring_v5,
        version: 5,
    )!;
    register_value(
        $Type: ParticleAuthoringV6,
        layout: AUTHORING_V6_LAYOUT,
        defaults: &defaults_authoring_v6,
        version: 6,
    )!;
    register_value(
        $Type: ParticleAuthoringV7,
        layout: AUTHORING_V7_LAYOUT,
        defaults: &defaults_authoring_v7,
        version: 7,
    )!;
    register_value(
        $Type: ParticleAuthoringV8,
        layout: AUTHORING_V8_LAYOUT,
        defaults: &defaults_authoring_v8,
        version: 8,
    )!;
    describe::register_reflected(ParticleAuthoring)!;
    serial::register_described_type(
        $Type: ParticleAuthoring,
        version: 9,
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

macro void? register_value($Type, ulong layout, serial::DefaultsFn defaults, uint version = 1) @private {
    describe::register_reflected($Type)!;
    serial::register_described_type(
        $Type: $Type,
        version: version,
        layout: layout,
        defaults: defaults,
    )!;
}

fn void defaults_range(void* value) @private => *(ParticleRange*)value = {};
fn void defaults_table(void* value) @private => ((LifetimeTable*)value).values[..] = 1;
fn void defaults_color_table(void* value) @private => ((LifetimeColorTable*)value).values[..] = (Vec4){ 1, 1, 1, 1 };
fn void defaults_sub_emitter(void* value) @private => *(SubEmitter*)value = {};
fn void defaults_collision(void* value) @private {
    *(ParticleCollision*)value = default_particle_system_desc().collision;
}
fn void defaults_flipbook(void* value) @private => *(ParticleFlipbook*)value = default_particle_system_desc().flipbook;
fn void defaults_turbulence(void* value) @private {
    *(ParticleTurbulence*)value = default_particle_system_desc().turbulence;
}
fn void defaults_trail(void* value) @private => *(ParticleTrail*)value = default_particle_system_desc().trail;
fn void defaults_desc(void* value) @private => *(ParticleSystemDesc*)value = default_particle_system_desc();
fn void defaults_desc_v8(void* value) @private {
    *(ParticleSystemDescV8*)value = particle_desc_v8(default_particle_system_desc());
}
fn void defaults_desc_v7(void* value) @private {
    *(ParticleSystemDescV7*)value = particle_desc_v7(default_particle_system_desc());
}
fn void defaults_desc_v6(void* value) @private {
    *(ParticleSystemDescV6*)value = particle_desc_v6(default_particle_system_desc());
}
fn void defaults_desc_v5(void* value) @private {
    *(ParticleSystemDescV5*)value = particle_desc_v5(default_particle_system_desc());
}
fn void defaults_desc_v4(void* value) @private {
    *(ParticleSystemDescV4*)value = particle_desc_v4(default_particle_system_desc());
}
fn void defaults_desc_v3(void* value) @private {
    *(ParticleSystemDescV3*)value = particle_desc_v3(default_particle_system_desc());
}
fn void defaults_desc_v2(void* value) @private {
    *(ParticleSystemDescV2*)value = particle_desc_v2(default_particle_system_desc());
}
fn void defaults_desc_v1(void* value) @private {
    *(ParticleSystemDescV1*)value = particle_desc_v1(default_particle_system_desc());
}
fn void defaults_authoring(void* value) @private {
    *(ParticleAuthoring*)value = { .desc = default_particle_system_desc(), .emitting = true };
}
fn void defaults_authoring_v8(void* value) @private {
    *(ParticleAuthoringV8*)value = { .desc = particle_desc_v8(default_particle_system_desc()), .emitting = true };
}
fn void defaults_authoring_v7(void* value) @private {
    *(ParticleAuthoringV7*)value = { .desc = particle_desc_v7(default_particle_system_desc()), .emitting = true };
}
fn void defaults_authoring_v6(void* value) @private {
    *(ParticleAuthoringV6*)value = { .desc = particle_desc_v6(default_particle_system_desc()), .emitting = true };
}
fn void defaults_authoring_v5(void* value) @private {
    *(ParticleAuthoringV5*)value = { .desc = particle_desc_v5(default_particle_system_desc()), .emitting = true };
}
fn void defaults_authoring_v4(void* value) @private {
    *(ParticleAuthoringV4*)value = { .desc = particle_desc_v4(default_particle_system_desc()), .emitting = true };
}
fn void defaults_authoring_v3(void* value) @private {
    *(ParticleAuthoringV3*)value = { .desc = particle_desc_v3(default_particle_system_desc()), .emitting = true };
}
fn void defaults_authoring_v2(void* value) @private {
    *(ParticleAuthoringV2*)value = { .desc = particle_desc_v2(default_particle_system_desc()), .emitting = true };
}
fn void defaults_authoring_v1(void* value) @private {
    *(ParticleAuthoringV1*)value = { .desc = particle_desc_v1(default_particle_system_desc()), .emitting = true };
}

fn ParticleSystemDescV8 particle_desc_v8(ParticleSystemDesc desc) @private {
    return {
        .capacity = desc.capacity,
        .saturation = desc.saturation,
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
        .sub_emitters = desc.sub_emitters,
        .sub_emitter_count = desc.sub_emitter_count,
        .max_events = desc.max_events,
        .collision = desc.collision,
        .flipbook = desc.flipbook,
        .turbulence = desc.turbulence,
        .trail = desc.trail,
        .mesh_cast_shadow = desc.mesh_cast_shadow,
        .mesh_trace = desc.mesh_trace,
    };
}

fn ParticleSystemDescV7 particle_desc_v7(ParticleSystemDesc desc) @private {
    return {
        .capacity = desc.capacity,
        .saturation = desc.saturation,
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
        .sub_emitters = desc.sub_emitters,
        .sub_emitter_count = desc.sub_emitter_count,
        .max_events = desc.max_events,
        .collision = desc.collision,
        .flipbook = desc.flipbook,
        .turbulence = desc.turbulence,
        .trail = desc.trail,
    };
}

fn ParticleSystemDescV6 particle_desc_v6(ParticleSystemDesc desc) @private {
    return {
        .capacity = desc.capacity,
        .saturation = desc.saturation,
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
        .sub_emitters = desc.sub_emitters,
        .sub_emitter_count = desc.sub_emitter_count,
        .max_events = desc.max_events,
        .collision = desc.collision,
        .flipbook = desc.flipbook,
        .turbulence = desc.turbulence,
    };
}

fn ParticleSystemDescV5 particle_desc_v5(ParticleSystemDesc desc) @private {
    return {
        .capacity = desc.capacity,
        .saturation = desc.saturation,
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
        .sub_emitters = desc.sub_emitters,
        .sub_emitter_count = desc.sub_emitter_count,
        .max_events = desc.max_events,
        .collision = desc.collision,
        .flipbook = desc.flipbook,
    };
}

fn ParticleSystemDescV4 particle_desc_v4(ParticleSystemDesc desc) @private {
    return {
        .capacity = desc.capacity,
        .saturation = desc.saturation,
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
        .sub_emitters = desc.sub_emitters,
        .sub_emitter_count = desc.sub_emitter_count,
        .max_events = desc.max_events,
        .collision = desc.collision,
    };
}

fn ParticleSystemDescV3 particle_desc_v3(ParticleSystemDesc desc) @private {
    return {
        .capacity = desc.capacity,
        .saturation = desc.saturation,
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
        .sub_emitters = desc.sub_emitters,
        .sub_emitter_count = desc.sub_emitter_count,
        .max_events = desc.max_events,
    };
}

fn ParticleSystemDescV2 particle_desc_v2(ParticleSystemDesc desc) @private {
    return {
        .capacity = desc.capacity,
        .saturation = desc.saturation,
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

fn ParticleSystemDesc particle_desc_from_v2(ParticleSystemDescV2 legacy) @private {
    ParticleSystemDesc desc = default_particle_system_desc();
    desc.capacity = legacy.capacity;
    desc.saturation = legacy.saturation;
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

fn ParticleSystemDesc particle_desc_from_v3(ParticleSystemDescV3 legacy) @private {
    ParticleSystemDesc desc = default_particle_system_desc();
    desc.capacity = legacy.capacity;
    desc.saturation = legacy.saturation;
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
    desc.sub_emitters = legacy.sub_emitters;
    desc.sub_emitter_count = legacy.sub_emitter_count;
    desc.max_events = legacy.max_events;
    return desc;
}

fn ParticleSystemDesc particle_desc_from_v4(ParticleSystemDescV4 legacy) @private {
    ParticleSystemDesc desc = default_particle_system_desc();
    desc.capacity = legacy.capacity;
    desc.saturation = legacy.saturation;
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
    desc.sub_emitters = legacy.sub_emitters;
    desc.sub_emitter_count = legacy.sub_emitter_count;
    desc.max_events = legacy.max_events;
    desc.collision = legacy.collision;
    return desc;
}

fn ParticleSystemDesc particle_desc_from_v5(ParticleSystemDescV5 legacy) @private {
    ParticleSystemDesc desc = default_particle_system_desc();
    desc.capacity = legacy.capacity;
    desc.saturation = legacy.saturation;
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
    desc.sub_emitters = legacy.sub_emitters;
    desc.sub_emitter_count = legacy.sub_emitter_count;
    desc.max_events = legacy.max_events;
    desc.collision = legacy.collision;
    desc.flipbook = legacy.flipbook;
    return desc;
}

fn ParticleSystemDesc particle_desc_from_v6(ParticleSystemDescV6 legacy) @private {
    ParticleSystemDesc desc = default_particle_system_desc();
    desc.capacity = legacy.capacity;
    desc.saturation = legacy.saturation;
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
    desc.sub_emitters = legacy.sub_emitters;
    desc.sub_emitter_count = legacy.sub_emitter_count;
    desc.max_events = legacy.max_events;
    desc.collision = legacy.collision;
    desc.flipbook = legacy.flipbook;
    desc.turbulence = legacy.turbulence;
    return desc;
}

fn ParticleSystemDesc particle_desc_from_v7(ParticleSystemDescV7 legacy) @private {
    ParticleSystemDesc desc = default_particle_system_desc();
    desc.capacity = legacy.capacity;
    desc.saturation = legacy.saturation;
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
    desc.sub_emitters = legacy.sub_emitters;
    desc.sub_emitter_count = legacy.sub_emitter_count;
    desc.max_events = legacy.max_events;
    desc.collision = legacy.collision;
    desc.flipbook = legacy.flipbook;
    desc.turbulence = legacy.turbulence;
    desc.trail = legacy.trail;
    return desc;
}

fn ParticleSystemDesc particle_desc_from_v8(ParticleSystemDescV8 legacy) @private {
    ParticleSystemDesc desc = default_particle_system_desc();
    desc.capacity = legacy.capacity;
    desc.saturation = legacy.saturation;
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
    desc.sub_emitters = legacy.sub_emitters;
    desc.sub_emitter_count = legacy.sub_emitter_count;
    desc.max_events = legacy.max_events;
    desc.collision = legacy.collision;
    desc.flipbook = legacy.flipbook;
    desc.turbulence = legacy.turbulence;
    desc.trail = legacy.trail;
    desc.mesh_cast_shadow = legacy.mesh_cast_shadow;
    desc.mesh_trace = legacy.mesh_trace;
    return desc;
}

fn void? project_system(void* component, void* value, serial::WriteContext* context) @private {
    ParticleSystem* system = component;
    check_particle_desc(&system.desc)!;
    ParticleAuthoring* authoring = value;
    *authoring = { .desc = system.desc, .emitting = system.emitting };
    foreach (&sub_emitter : authoring.desc.sub_emitters[system.desc.sub_emitter_count..]) *sub_emitter = {};
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

fn void? read_system_v2(serial::Reader* reader, serial::ReadContext* context) @private {
    ParticleAuthoringV2* legacy = context.read_value(ParticleAuthoringV2, reader)!;
    ParticleAuthoring authoring = {
        .desc = particle_desc_from_v2(legacy.desc),
        .emitting = legacy.emitting,
    };

    validate_system(&authoring, context)!;
    attach_system(&authoring, context)!;
}

fn void? read_system_v3(serial::Reader* reader, serial::ReadContext* context) @private {
    ParticleAuthoringV3* legacy = context.read_value(ParticleAuthoringV3, reader)!;
    ParticleAuthoring authoring = {
        .desc = particle_desc_from_v3(legacy.desc),
        .emitting = legacy.emitting,
    };

    validate_system(&authoring, context)!;
    attach_system(&authoring, context)!;
}

fn void? read_system_v4(serial::Reader* reader, serial::ReadContext* context) @private {
    ParticleAuthoringV4* legacy = context.read_value(ParticleAuthoringV4, reader)!;
    ParticleAuthoring authoring = {
        .desc = particle_desc_from_v4(legacy.desc),
        .emitting = legacy.emitting,
    };

    validate_system(&authoring, context)!;
    attach_system(&authoring, context)!;
}

fn void? read_system_v5(serial::Reader* reader, serial::ReadContext* context) @private {
    ParticleAuthoringV5* legacy = context.read_value(ParticleAuthoringV5, reader)!;
    ParticleAuthoring authoring = {
        .desc = particle_desc_from_v5(legacy.desc),
        .emitting = legacy.emitting,
    };

    validate_system(&authoring, context)!;
    attach_system(&authoring, context)!;
}

fn void? read_system_v6(serial::Reader* reader, serial::ReadContext* context) @private {
    ParticleAuthoringV6* legacy = context.read_value(ParticleAuthoringV6, reader)!;
    ParticleAuthoring authoring = {
        .desc = particle_desc_from_v6(legacy.desc),
        .emitting = legacy.emitting,
    };

    validate_system(&authoring, context)!;
    attach_system(&authoring, context)!;
}

fn void? read_system_v7(serial::Reader* reader, serial::ReadContext* context) @private {
    ParticleAuthoringV7* legacy = context.read_value(ParticleAuthoringV7, reader)!;
    ParticleAuthoring authoring = {
        .desc = particle_desc_from_v7(legacy.desc),
        .emitting = legacy.emitting,
    };

    validate_system(&authoring, context)!;
    attach_system(&authoring, context)!;
}

fn void? read_system_v8(serial::Reader* reader, serial::ReadContext* context) @private {
    ParticleAuthoringV8* legacy = context.read_value(ParticleAuthoringV8, reader)!;
    ParticleAuthoring authoring = {
        .desc = particle_desc_from_v8(legacy.desc),
        .emitting = legacy.emitting,
    };

    validate_system(&authoring, context)!;
    attach_system(&authoring, context)!;
}

fn void? collect_system(void* component, serial::WriteContext* context) @private {
    ParticleSystem* system = component;
    if (!system.is_prepared()) return;
    if (system.desc.render_mode == ParticleRenderMode.MESH) {
        omit_draw_child(context, system.draw_node, InstancedMesh)!;
    } else {
        omit_draw_child(context, system.draw_node, BillboardBatch)!;
    }
    if (system.desc.trail.max_points) omit_draw_child(context, system.trail_node, RibbonBatch)!;
}

macro void? omit_draw_child(serial::WriteContext* context, Entity child, $Type) @private {
    if (!context.scene.world.is_alive(child)) return c3d::INVALID_ARGUMENT~;
    Node* draw = context.scene.node(child);
    ParticleDrawOwner* owner = context.scene.get(draw, ParticleDrawOwner);
    if (!owner || !c3d::same_id(owner.emitter, context.node.id) || draw.parent != context.node) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (!context.scene.has(draw, $Type)) return c3d::INVALID_ARGUMENT~;
    context.omit_component(draw, ecs::slot_of($Type)!)!;
    context.omit_node(draw)!;
}

fn void? collect_draw(void* component, serial::WriteContext* context) @private {
    ParticleDrawOwner* owner = component;
    if (!context.scene.world.is_alive(owner.emitter)) return c3d::INVALID_ARGUMENT~;
    Node* emitter = context.scene.node(owner.emitter);
    if (!context.contains_node(emitter) || context.node.parent != emitter) return c3d::INVALID_ARGUMENT~;
    ParticleSystem* system = context.scene.get(emitter, ParticleSystem);
    if (!system || !system.is_prepared()) return c3d::INVALID_ARGUMENT~;
    bool draws = c3d::same_id(system.draw_node, context.node.id);
    bool trails = system.desc.trail.max_points && c3d::same_id(system.trail_node, context.node.id);
    if (!draws && !trails) return c3d::INVALID_ARGUMENT~;
}
