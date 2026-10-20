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
const usz REGION_ALIGNMENT @private = 16; // the records offset of a device batch is a multiple of 16
const usz COUNTER_BYTES @private = 16; // alive, dropped low and high words, unused

$assert EmitterShape.POINT.ordinal == 0; // mirrored as PARTICLE_SHAPE_POINT in particle_step.glsl
$assert EmitterShape.SPHERE.ordinal == 1; // mirrored as PARTICLE_SHAPE_SPHERE in particle_step.glsl
$assert EmitterShape.BOX.ordinal == 2; // mirrored as PARTICLE_SHAPE_BOX in particle_step.glsl
$assert EmitterShape.CONE.ordinal == 3; // mirrored as PARTICLE_SHAPE_CONE in particle_step.glsl
$assert CollisionResponse.BOUNCE.ordinal == 1; // mirrored as PARTICLE_RESPONSE_BOUNCE in particle_step.glsl
$assert CollisionResponse.STICK.ordinal == 2; // mirrored as PARTICLE_RESPONSE_STICK in particle_step.glsl
$assert CollisionResponse.DIE.ordinal == 3; // mirrored as PARTICLE_RESPONSE_DIE in particle_step.glsl
$assert particle::LIFETIME_TABLE_ENTRIES == 8; // mirrored as PARTICLE_TABLE_ENTRIES in particle_step.glsl

const uint FLIPBOOK_FPS @private = 1; // mirrored as PARTICLE_FLIPBOOK_FPS in particle_step.glsl
const uint FLIPBOOK_RANDOM_START @private = 2; // mirrored as PARTICLE_FLIPBOOK_RANDOM_START in particle_step.glsl
const uint FLIPBOOK_BLEND @private = 4; // mirrored as PARTICLE_FLIPBOOK_BLEND in particle_step.glsl

enum ScanMode : uint @private {
    BLOCKS, // mirrored as PARTICLE_SCAN_BLOCKS in particle_step.glsl
    TOTALS, // mirrored as PARTICLE_SCAN_TOTALS in particle_step.glsl
}

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
}

$assert StepRoot::size == 544;
$assert $reflect(StepRoot.capacity).offset == 64;
$assert $reflect(StepRoot.acceleration_radius).offset == 96;
$assert $reflect(StepRoot.emitter_row0).offset == 176;
$assert $reflect(StepRoot.response).offset == 288;
$assert $reflect(StepRoot.flipbook_columns).offset == 320;
$assert $reflect(StepRoot.color_min).offset == 352;
$assert $reflect(StepRoot.size_over_life).offset == 384;
$assert $reflect(StepRoot.color_over_life).offset == 416;

struct SystemLayout @private {
    usz state_home;
    usz state_alt;
    usz scan;
    usz totals;
    usz records;
    usz count;
    usz size;
    uint groups;
}

struct SystemAddresses @private {
    ulong base;
    ulong counters;
}

fn SystemLayout system_layout(uint capacity) @private {
    uint groups = (capacity + GROUP_SIZE - 1) / GROUP_SIZE;
    SystemLayout layout;
    layout.state_home = CONTROL_BYTES;
    layout.state_alt = layout.state_home + (usz)capacity * PARTICLE_STATE_BYTES;
    layout.scan = layout.state_alt + (usz)capacity * PARTICLE_STATE_BYTES;
    layout.totals = layout.scan + (usz)capacity * SCAN_ENTRY_BYTES;
    layout.records = particle::particle_align(layout.totals + (usz)groups * TOTAL_ENTRY_BYTES, REGION_ALIGNMENT);
    layout.count = layout.records + (usz)capacity * BillboardRecord::size;
    layout.size = layout.count + COUNT_WORD_BYTES;
    layout.groups = groups;
    return layout;
}

fn Vec4 vec4_of(float first, float second, float third, float fourth) @private {
    return { first, second, third, fourth };
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
    float drag = math::min(1.0f, desc.drag * plan.seconds);
    bool turbulent = desc.turbulence.strength > 0 && drag > 0;
    bool stretched = desc.render_mode == ParticleRenderMode.STRETCHED;
    Vec3 acceleration = particle::PARTICLE_GRAVITY * (desc.gravity_scale * plan.seconds);
    Vec3 half_extents = desc.half_extents;
    Vec3 tile = plan.turbulence_offset;
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
        .acceleration_radius = vec4_of(acceleration.x, acceleration.y, acceleration.z, desc.radius),
        .wind_cone = vec4_of(wind.x, wind.y, wind.z, desc.cone_angle),
        .shift_stretch = vec4_of(plan.shift.x, plan.shift.y, plan.shift.z, desc.stretch),
        .origin_restitution = vec4_of(origin.x, origin.y, origin.z, collision.restitution),
        .half_extents_friction = vec4_of(half_extents.x, half_extents.y, half_extents.z, collision.friction),
        .emitter_row0 = vec4_of(emitter_world.m00, emitter_world.m01, emitter_world.m02, emitter_world.m03),
        .emitter_row1 = vec4_of(emitter_world.m10, emitter_world.m11, emitter_world.m12, emitter_world.m13),
        .emitter_row2 = vec4_of(emitter_world.m20, emitter_world.m21, emitter_world.m22, emitter_world.m23),
        .lifetime_speed = vec4_of(desc.lifetime.min, desc.lifetime.max, desc.speed.min, desc.speed.max),
        .size_rotation = vec4_of(desc.size.min, desc.size.max, desc.rotation.min, desc.rotation.max),
        .spin_ground = vec4_of(desc.spin.min, desc.spin.max, collision.ground_height, collision.radius_scale),
        .turbulence_offset = vec4_of(
            tile.x,
            tile.y,
            tile.z,
            turbulent ? (float)desc.turbulence.period / desc.turbulence.frequency : 0,
        ),
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
    };
}
