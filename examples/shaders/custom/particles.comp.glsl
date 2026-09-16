#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(local_size_x = 64) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

struct Particle {
    vec4 position_life;
    vec4 velocity_seed;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer Particles {
    Particle values[];
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Emitter {
    vec4 origin_radius;
    vec4 gravity_lifetime;
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ParticleRoot {
    uint64_t particles;
    uint64_t emitter;
    uint count;
    float delta;
    float time;
    uint reset;
};

uint hash(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return value;
}

float unit(uint value) {
    return float(value & 0xffffffu) / 16777216.0;
}

Particle respawn(Emitter emitter, uint seed, float life_scale) {
    float angle = unit(hash(seed)) * 6.2831853;
    float radius = sqrt(unit(hash(seed + 1u))) * emitter.origin_radius.w;
    vec3 offset = vec3(cos(angle) * radius, 0.0, sin(angle) * radius);
    float rise = 2.0 + unit(hash(seed + 2u)) * 2.0;
    vec3 drift = (offset / max(emitter.origin_radius.w, 0.001)) * 0.6;
    Particle particle;
    particle.position_life = vec4(emitter.origin_radius.xyz + offset, emitter.gravity_lifetime.w * life_scale);
    particle.velocity_seed = vec4(drift.x, rise, drift.z, float(seed));
    return particle;
}

void main() {
    ParticleRoot root = ParticleRoot(pc.root_gpu);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;

    Particles particles = Particles(root.particles);
    Emitter emitter = Emitter(root.emitter);
    uint seed = hash(index * 3u + uint(root.time * 1000.0));
    if (root.reset != 0u) {
        particles.values[index] = respawn(emitter, seed, unit(hash(index)));
        return;
    }

    Particle particle = particles.values[index];
    particle.velocity_seed.xyz += emitter.gravity_lifetime.xyz * root.delta;
    particle.position_life.xyz += particle.velocity_seed.xyz * root.delta;
    particle.position_life.w -= root.delta;
    if (particle.position_life.w <= 0.0) particle = respawn(emitter, seed, 1.0);
    particles.values[index] = particle;
}
