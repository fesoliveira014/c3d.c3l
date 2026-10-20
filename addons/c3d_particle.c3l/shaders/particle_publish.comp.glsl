#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_step.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ParticleRecords {
    BillboardGpu values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer ParticleCountWord {
    uint value;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ParticleCounters {
    uvec4 value; // alive, dropped low and high words, unused
};

// Mirrors flipbook_frame in flipbook.c3, in float.
float flipbook_frame(StepRoot root, ParticleGpu particle) {
    float frames = float(root.flipbook_frames);
    bool blended = (root.flipbook_flags & PARTICLE_FLIPBOOK_BLEND) != 0u;
    float position = 0.0;
    if ((root.flipbook_flags & PARTICLE_FLIPBOOK_RANDOM_START) != 0u) {
        uint sample_hash = particle_pcg_hash(particle_pcg_hash(particle.seed));
        float fraction = float(sample_hash >> 8u) * PARTICLE_UNIT_SCALE;
        position = float(min(uint(fraction * frames), root.flipbook_frames - 1u));
    }
    if ((root.flipbook_flags & PARTICLE_FLIPBOOK_FPS) != 0u) {
        float elapsed = particle.age * root.flipbook_fps;
        position += blended ? elapsed : floor(elapsed);
    } else {
        float life = clamp(particle.age / particle.lifetime, 0.0, 1.0);
        position += blended ? life * (frames - 1.0) : min(floor(life * frames), frames - 1.0);
    }
    float wrapped = position - floor(position / frames) * frames;
    return clamp(wrapped, 0.0, frames);
}

// Mirrors write_billboard_blocks and particle_color, relative to the frame origin.
BillboardGpu particle_record(StepRoot root, ParticleGpu particle) {
    float life = particle.age / particle.lifetime;
    float width = particle_draw_extent(root, particle);
    float height = width;
    vec3 direction = vec3(0.0);
    if (root.stretched != 0u) {
        float speed = length(particle.velocity);
        height += speed * root.shift_stretch.w;
        if (speed > 0.0) direction = particle.velocity / speed;
    }
    float frame = root.flipbook_columns != 0u ? flipbook_frame(root, particle) : 0.0;
    float fraction = float(particle_pcg_hash(particle.seed) >> 8u) * PARTICLE_UNIT_SCALE;
    vec4 color = (root.color_min * (1.0 - fraction) + root.color_max * fraction) * particle_color_scale(root, life);
    return BillboardGpu(
        vec4(particle.position - root.origin_restitution.xyz, width),
        vec4(direction, height),
        color,
        particle.rotation,
        root.facing,
        frame,
        0u
    );
}

// Packs the live particles back to the home buffer, writes the drawn ones as records, and publishes the counts.
void main() {
    StepRoot root = StepRoot(DispatchRoot(pc.root_gpu).parameters);
    ParticleControl control = ParticleControl(root.control);
    uint index = gl_GlobalInvocationID.x;
    if (index < control.pool_count) {
        ParticleGpu particle = ParticleStates(root.state_alt).values[index];
        uvec4 flags = ParticleScan(root.scan).values[index];
        uvec2 base = ParticleTotals(root.totals).values[index / PARTICLE_GROUP];
        if (flags.x != 0u) ParticleStates(root.state_home).values[flags.z + base.x] = particle;
        if (flags.y != 0u) ParticleRecords(root.records).values[flags.w + base.y] = particle_record(root, particle);
    }
    if (index == 0u) {
        control.alive = control.live_total;
        ParticleCountWord(root.count).value = control.drawn_total;
        ParticleCounters(root.counters).value = uvec4(control.live_total, control.dropped_low, control.dropped_high, 0u);
    }
}
