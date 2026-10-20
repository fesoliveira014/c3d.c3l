module c3d::particle::gpu @feat(C3D_PARTICLE_GPU);

import c3d;
import c3d::particle @public;
import c3d::scene;
import std::math;

const uint GROUP_SIZE @private = 256; // mirrored as local_size_x in each stage and PARTICLE_GROUP in particle_step.glsl
const usz PARTICLE_STATE_BYTES @private = 64; // mirrored as ParticleGpu in particle_step.glsl
const usz SCAN_ENTRY_BYTES @private = 16; // mirrored as the uvec4 of ParticleScan in particle_step.glsl
const usz TOTAL_ENTRY_BYTES @private = 8; // mirrored as the uvec2 of ParticleTotals in particle_step.glsl
const usz CONTROL_BYTES @private = 256; // mirrored as ParticleControl in particle_step.glsl; pads every offset to 16
const usz COUNT_WORD_BYTES @private = 16; // one uint, padded
const usz TRAIL_HEADER_BYTES @private = 16; // mirrored as TrailHeaderGpu in particle_step.glsl
const usz TRAIL_POINT_BYTES @private = 16; // mirrored as the vec4 of TrailPoints in particle_step.glsl
const usz TRAIL_DISTANCE_BYTES @private = 4; // mirrored as the float of TrailDistances in particle_step.glsl
const usz REGION_ALIGNMENT @private = 16; // the records offset of a device batch is a multiple of 16
const usz COUNTER_BYTES @private = 48; // mirrored as the three uvec4 of ParticleCounters in particle_publish.comp.glsl
const usz EVENT_BYTES @private = 48; // mirrored as ParticleEventGpu in particle_step.glsl
const usz EVENT_HALVES @private = 2; // one for the step in flight, one for the step delivered last
const usz EVENT_ACCEPT_WORDS @private = 4; // mirrored as the uvec4 event_accept of StepRoot; one word per trigger
const usz MIRROR_HEADER_BYTES @private = 16; // the live count, padded; mirrored as the offset of MirrorRecords
const usz MIRROR_RECORD_BYTES @private = 48; // mirrored as ParticleMirrorGpu in particle_publish.comp.glsl

$assert EmitterShape.POINT.ordinal == 0; // mirrored as PARTICLE_SHAPE_POINT in particle_step.glsl
$assert EmitterShape.SPHERE.ordinal == 1; // mirrored as PARTICLE_SHAPE_SPHERE in particle_step.glsl
$assert EmitterShape.BOX.ordinal == 2; // mirrored as PARTICLE_SHAPE_BOX in particle_step.glsl
$assert EmitterShape.CONE.ordinal == 3; // mirrored as PARTICLE_SHAPE_CONE in particle_step.glsl
$assert CollisionResponse.BOUNCE.ordinal == 1; // mirrored as PARTICLE_RESPONSE_BOUNCE in particle_step.glsl
$assert CollisionResponse.STICK.ordinal == 2; // mirrored as PARTICLE_RESPONSE_STICK in particle_step.glsl
$assert CollisionResponse.DIE.ordinal == 3; // mirrored as PARTICLE_RESPONSE_DIE in particle_step.glsl
$assert particle::LIFETIME_TABLE_ENTRIES == 8; // mirrored as PARTICLE_TABLE_ENTRIES in particle_step.glsl
$assert ParticleTrigger.DEATH.ordinal == 0; // mirrored as PARTICLE_TRIGGER_DEATH in particle_step.glsl
$assert ParticleTrigger.IMPACT.ordinal == 1; // mirrored as PARTICLE_TRIGGER_IMPACT in particle_step.glsl
$assert ParticleTrigger.BIRTH.ordinal == 2; // mirrored as PARTICLE_TRIGGER_BIRTH in particle_step.glsl
$assert particle::MAX_SUB_EMITTERS <= uint::size * 8; // one bit per sub-emitter in a word of event_accept
$assert ParticleTrigger::values.len <= EVENT_ACCEPT_WORDS; // the event_accept words are indexed by trigger

const uint FLIPBOOK_FPS @private = 1; // mirrored as PARTICLE_FLIPBOOK_FPS in particle_step.glsl
const uint FLIPBOOK_RANDOM_START @private = 2; // mirrored as PARTICLE_FLIPBOOK_RANDOM_START in particle_step.glsl
const uint FLIPBOOK_BLEND @private = 4; // mirrored as PARTICLE_FLIPBOOK_BLEND in particle_step.glsl

enum ScanMode : uint @private {
    BLOCKS, // mirrored as PARTICLE_SCAN_BLOCKS in particle_step.glsl
    TOTALS, // mirrored as PARTICLE_SCAN_TOTALS in particle_step.glsl
}

// Mirrors ParticleMirrorGpu in particle_publish.comp.glsl.
struct MirrorRecord @private {
    Vec4 position_size;
    Vec4 color;
    float rotation;
    float _pad0;
    float _pad1;
    float _pad2;
}
$assert MirrorRecord::size == MIRROR_RECORD_BYTES;

// Mirrors StepRoot in particle_step.glsl.
struct StepRoot @private {
    ulong control;
    ulong state_home;
    ulong state_alt;
    ulong scan;
    ulong totals;
    ulong records;
    ulong count;
    ulong counters;
    uint capacity;
    uint requested;
    uint reset;
    ScanMode mode;
    float seconds;
    float drag;
    uint seed;
    uint shape;
    Vec4 acceleration_radius;
    Vec4 wind_cone;
    Vec4 shift_stretch;
    Vec4 origin_restitution;
    Vec4 half_extents_friction;
    Vec4 emitter_row0;
    Vec4 emitter_row1;
    Vec4 emitter_row2;
    Vec4 lifetime_speed;
    Vec4 size_rotation;
    Vec4 spin_ground;
    Vec4 turbulence_offset;
    uint response;
    uint collides;
    uint octaves;
    uint period;
    float turbulence_strength;
    float turbulence_frequency;
    uint stretched;
    uint facing;
    uint flipbook_columns;
    uint flipbook_frames;
    uint flipbook_flags;
    uint _pad0;
    float flipbook_fps;
    uint _pad1;
    uint _pad2;
    uint _pad3;
    Vec4 color_min;
    Vec4 color_max;
    float[particle::LIFETIME_TABLE_ENTRIES] size_over_life;
    Vec4[particle::LIFETIME_TABLE_ENTRIES] color_over_life;
    ulong trail_headers_home;
    ulong trail_headers_alt;
    ulong trail_points_home;
    ulong trail_points_alt;
    ulong trail_distances_home;
    ulong trail_distances_alt;
    ulong ribbon_records;
    ulong ribbon_count;
    uint trail_max_points;
    float trail_interval;
    float trail_lifetime;
    float trail_width;
    float trail_tile_length;
    uint trail_tiled;
    uint _pad4;
    uint _pad5;
    float[particle::LIFETIME_TABLE_ENTRIES] width_over_trail;
    Vec4[particle::LIFETIME_TABLE_ENTRIES] color_over_trail;
    ulong events;
    ulong source_control;
    ulong source_events;
    uint event_capacity;
    uint source_event_capacity;
    uint[EVENT_ACCEPT_WORDS] event_accept;
    uint delivery_sub;
    uint delivery_count;
    float delivery_inherit;
    float impact_speed;
    uint delivery_valid;
    uint mesh;
    ulong mirror;
    uint evict_accept;
    uint evicts;
    uint _pad6;
    uint _pad7;
}

$assert StepRoot::size == 896;
$assert $reflect(StepRoot.capacity).offset == 64;
$assert $reflect(StepRoot.acceleration_radius).offset == 96;
$assert $reflect(StepRoot.emitter_row0).offset == 176;
$assert $reflect(StepRoot.response).offset == 288;
$assert $reflect(StepRoot.flipbook_columns).offset == 320;
$assert $reflect(StepRoot.color_min).offset == 352;
$assert $reflect(StepRoot.size_over_life).offset == 384;
$assert $reflect(StepRoot.color_over_life).offset == 416;
$assert $reflect(StepRoot.trail_headers_home).offset == 544;
$assert $reflect(StepRoot.trail_max_points).offset == 608;
$assert $reflect(StepRoot.width_over_trail).offset == 640;
$assert $reflect(StepRoot.color_over_trail).offset == 672;
$assert $reflect(StepRoot.events).offset == 800;
$assert $reflect(StepRoot.event_capacity).offset == 824;
$assert $reflect(StepRoot.event_accept).offset == 832;
$assert $reflect(StepRoot.delivery_sub).offset == 848;
$assert $reflect(StepRoot.delivery_valid).offset == 864;
$assert $reflect(StepRoot.mirror).offset == 872;
$assert $reflect(StepRoot.evict_accept).offset == 880;

struct SystemLayout @private {
    usz state_home;
    usz state_alt;
    usz scan;
    usz totals;
    usz records;
    usz count;
    usz trail_headers_home;
    usz trail_headers_alt;
    usz trail_points_home;
    usz trail_points_alt;
    usz trail_distances_home;
    usz trail_distances_alt;
    usz ribbons;
    usz ribbon_count;
    usz events;
    usz size;
    uint groups;
}

struct SystemAddresses @private {
    ulong base;
    ulong counters;
    ulong mirror; // zero without a host mirror
}

fn bool mirrors_instances(ParticleSystemDesc* desc) @private {
    return desc.render_mode == ParticleRenderMode.MESH && desc.mesh_trace;
}

fn usz mirror_bytes(uint capacity) @private => MIRROR_HEADER_BYTES + (usz)capacity * MIRROR_RECORD_BYTES;

fn usz record_bytes(ParticleSystemDesc* desc) @private {
    return desc.render_mode == ParticleRenderMode.MESH ? scene::INSTANCE_RECORD_BYTES : BillboardRecord::size;
}

fn SystemLayout system_layout(ParticleSystemDesc* desc) @private {
    uint capacity = desc.capacity;
    uint groups = (capacity + GROUP_SIZE - 1) / GROUP_SIZE;
    SystemLayout layout;
    layout.state_home = CONTROL_BYTES;
    layout.state_alt = layout.state_home + (usz)capacity * PARTICLE_STATE_BYTES;
    layout.scan = layout.state_alt + (usz)capacity * PARTICLE_STATE_BYTES;
    layout.totals = layout.scan + (usz)capacity * SCAN_ENTRY_BYTES;
    layout.records = particle::particle_align(layout.totals + (usz)groups * TOTAL_ENTRY_BYTES, REGION_ALIGNMENT);
    layout.count = layout.records + (usz)capacity * record_bytes(desc);
    layout.size = layout.count + COUNT_WORD_BYTES;
    layout.groups = groups;
    uint trail_max_points = desc.trail.max_points;
    if (trail_max_points) {
        usz stored = (usz)capacity * trail_max_points;
        layout.trail_headers_home = layout.size;
        layout.trail_headers_alt = layout.trail_headers_home + (usz)capacity * TRAIL_HEADER_BYTES;
        layout.trail_points_home = layout.trail_headers_alt + (usz)capacity * TRAIL_HEADER_BYTES;
        layout.trail_points_alt = layout.trail_points_home + stored * TRAIL_POINT_BYTES;
        layout.trail_distances_home = layout.trail_points_alt + stored * TRAIL_POINT_BYTES;
        layout.trail_distances_alt = particle::particle_align(
            layout.trail_distances_home + stored * TRAIL_DISTANCE_BYTES,
            REGION_ALIGNMENT,
        );
        layout.ribbons = particle::particle_align(
            layout.trail_distances_alt + stored * TRAIL_DISTANCE_BYTES,
            REGION_ALIGNMENT,
        );
        usz strip_points = (usz)trail_max_points + 1;
        layout.ribbon_count = layout.ribbons + ((usz)capacity * strip_points + 1) * scene::RIBBON_RECORD_BYTES;
        layout.size = layout.ribbon_count + COUNT_WORD_BYTES;
    }
    if (desc.sub_emitter_count) {
        layout.events = particle::particle_align(layout.size, REGION_ALIGNMENT);
        layout.size = layout.events + EVENT_HALVES * (usz)desc.max_events * EVENT_BYTES;
    }
    return layout;
}

fn StepRoot step_root(
    ParticleSystem* system,
    GpuStepPlan* plan,
    SystemLayout* layout,
    SystemAddresses addresses,
    Mat4 emitter_world,
    Vec3 wind,
    Vec3 origin,
) @private {
    ParticleSystemDesc* desc = &system.desc;
    ParticleCollision* collision = &desc.collision;
    ParticleFlipbook* flipbook = &desc.flipbook;
    ParticleTrail* trail = &desc.trail;
    float drag = math::min(1.0f, desc.drag * plan.seconds);
    bool turbulent = desc.turbulence.strength > 0 && drag > 0;
    bool stretched = desc.render_mode == ParticleRenderMode.STRETCHED;
    uint[EVENT_ACCEPT_WORDS] event_accept;
    uint evict_accept;
    foreach (sub_index, &sub_emitter : desc.sub_emitters[:desc.sub_emitter_count]) {
        event_accept[sub_emitter.trigger.ordinal] |= 1u << sub_index;
        if (sub_emitter.trigger == ParticleTrigger.DEATH && sub_emitter.on_evict) evict_accept |= 1u << sub_index;
    }
    Vec3 acceleration = particle::PARTICLE_GRAVITY * (desc.gravity_scale * plan.seconds);
    Vec3 half_extents = desc.half_extents;
    Vec3 tile = plan.turbulence_offset;
    float tile_length = turbulent ? (float)desc.turbulence.period / desc.turbulence.frequency : 0;
    uint flipbook_flags = (flipbook.mode == FlipbookMode.FPS ? FLIPBOOK_FPS : 0)
        | (flipbook.random_start ? FLIPBOOK_RANDOM_START : 0)
        | (flipbook.blend ? FLIPBOOK_BLEND : 0);

    return {
        .control = addresses.base,
        .state_home = addresses.base + layout.state_home,
        .state_alt = addresses.base + layout.state_alt,
        .scan = addresses.base + layout.scan,
        .totals = addresses.base + layout.totals,
        .records = addresses.base + layout.records,
        .count = addresses.base + layout.count,
        .counters = addresses.counters,
        .capacity = desc.capacity,
        .requested = plan.requested,
        .reset = plan.first ? 1 : 0,
        .seconds = plan.seconds,
        .drag = drag,
        .seed = desc.seed,
        .shape = (uint)desc.shape.ordinal,
        .acceleration_radius = { acceleration.x, acceleration.y, acceleration.z, desc.radius },
        .wind_cone = { wind.x, wind.y, wind.z, desc.cone_angle },
        .shift_stretch = { plan.shift.x, plan.shift.y, plan.shift.z, desc.stretch },
        .origin_restitution = { origin.x, origin.y, origin.z, collision.restitution },
        .half_extents_friction = { half_extents.x, half_extents.y, half_extents.z, collision.friction },
        .emitter_row0 = { emitter_world.m00, emitter_world.m01, emitter_world.m02, emitter_world.m03 },
        .emitter_row1 = { emitter_world.m10, emitter_world.m11, emitter_world.m12, emitter_world.m13 },
        .emitter_row2 = { emitter_world.m20, emitter_world.m21, emitter_world.m22, emitter_world.m23 },
        .lifetime_speed = { desc.lifetime.min, desc.lifetime.max, desc.speed.min, desc.speed.max },
        .size_rotation = { desc.size.min, desc.size.max, desc.rotation.min, desc.rotation.max },
        .spin_ground = { desc.spin.min, desc.spin.max, collision.ground_height, collision.radius_scale },
        .turbulence_offset = { tile.x, tile.y, tile.z, tile_length },
        .response = (uint)collision.response.ordinal,
        .collides = collision.response != CollisionResponse.NONE && collision.ground_plane ? 1 : 0,
        .octaves = turbulent ? desc.turbulence.octaves : 0,
        .period = desc.turbulence.period,
        .turbulence_strength = desc.turbulence.strength,
        .turbulence_frequency = desc.turbulence.frequency,
        .stretched = stretched ? 1 : 0,
        .facing = (uint)(stretched ? BillboardFacing.DIRECTIONAL : BillboardFacing.CAMERA).ordinal,
        .flipbook_columns = flipbook.columns,
        .flipbook_frames = flipbook.frame_count,
        .flipbook_flags = flipbook_flags,
        .flipbook_fps = flipbook.fps,
        .color_min = desc.color_min,
        .color_max = desc.color_max,
        .size_over_life = desc.size_over_life.values,
        .color_over_life = desc.color_over_life.values,
        .trail_headers_home = addresses.base + layout.trail_headers_home,
        .trail_headers_alt = addresses.base + layout.trail_headers_alt,
        .trail_points_home = addresses.base + layout.trail_points_home,
        .trail_points_alt = addresses.base + layout.trail_points_alt,
        .trail_distances_home = addresses.base + layout.trail_distances_home,
        .trail_distances_alt = addresses.base + layout.trail_distances_alt,
        .ribbon_records = addresses.base + layout.ribbons,
        .ribbon_count = addresses.base + layout.ribbon_count,
        .trail_max_points = trail.max_points,
        .trail_interval = trail.point_interval,
        .trail_lifetime = trail.lifetime,
        .trail_width = trail.width,
        .trail_tile_length = trail.tile_length,
        .trail_tiled = trail.uv == TrailUv.TILE ? 1 : 0,
        .width_over_trail = trail.width_over_trail.values,
        .color_over_trail = trail.color_over_trail.values,
        .events = addresses.base + layout.events,
        .event_capacity = desc.sub_emitter_count ? desc.max_events : 0,
        .event_accept = event_accept,
        .impact_speed = collision.impact_speed,
        .mesh = desc.render_mode == ParticleRenderMode.MESH ? 1 : 0,
        .mirror = addresses.mirror,
        .evict_accept = evict_accept,
        .evicts = desc.saturation == ParticleSaturation.DROP_OLDEST ? 1 : 0,
    };
}
