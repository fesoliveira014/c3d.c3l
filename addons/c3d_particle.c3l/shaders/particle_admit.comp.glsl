#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_step.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Mirrors sphere_direction in step.c3.
vec3 sphere_direction(uint stream, uvec2 ordinal) {
    float vertical = 1.0 - 2.0 * particle_unit(stream, ordinal, PARTICLE_DRAW_DIRECTION_HEIGHT);
    float angle = PARTICLE_FULL_TURN * particle_unit(stream, ordinal, PARTICLE_DRAW_DIRECTION_ANGLE);
    float radius = sqrt(max(0.0, 1.0 - vertical * vertical));
    return vec3(radius * cos(angle), vertical, radius * sin(angle));
}

// Mirrors emit_particle in step.c3.
ParticleGpu spawn_particle(StepRoot root, uvec2 ordinal) {
    uint stream = root.seed;
    vec3 position = vec3(0.0);
    vec3 direction;
    if (root.shape == PARTICLE_SHAPE_POINT) {
        direction = sphere_direction(stream, ordinal);
    } else if (root.shape == PARTICLE_SHAPE_BOX) {
        position = vec3(
            2.0 * particle_unit(stream, ordinal, PARTICLE_DRAW_POSITION_A) - 1.0,
            2.0 * particle_unit(stream, ordinal, PARTICLE_DRAW_POSITION_B) - 1.0,
            2.0 * particle_unit(stream, ordinal, PARTICLE_DRAW_POSITION_C) - 1.0
        ) * root.half_extents_friction.xyz;
        direction = sphere_direction(stream, ordinal);
    } else if (root.shape == PARTICLE_SHAPE_SPHERE) {
        direction = sphere_direction(stream, ordinal);
        position = direction * (root.acceleration_radius.w
            * pow(particle_unit(stream, ordinal, PARTICLE_DRAW_POSITION_A), 1.0 / 3.0));
    } else {
        float radius = root.acceleration_radius.w * sqrt(particle_unit(stream, ordinal, PARTICLE_DRAW_POSITION_A));
        float angle = PARTICLE_FULL_TURN * particle_unit(stream, ordinal, PARTICLE_DRAW_POSITION_B);
        position = vec3(radius * cos(angle), 0.0, radius * sin(angle));
        float vertical = 1.0
            - particle_unit(stream, ordinal, PARTICLE_DRAW_DIRECTION_HEIGHT) * (1.0 - cos(root.wind_cone.w));
        angle = PARTICLE_FULL_TURN * particle_unit(stream, ordinal, PARTICLE_DRAW_DIRECTION_ANGLE);
        float lateral = sqrt(max(0.0, 1.0 - vertical * vertical));
        direction = vec3(lateral * cos(angle), vertical, lateral * sin(angle));
    }
    ParticleGpu particle;
    particle.position = vec3(
        dot(root.emitter_row0.xyz, position) + root.emitter_row0.w,
        dot(root.emitter_row1.xyz, position) + root.emitter_row1.w,
        dot(root.emitter_row2.xyz, position) + root.emitter_row2.w
    );
    direction = vec3(
        dot(root.emitter_row0.xyz, direction),
        dot(root.emitter_row1.xyz, direction),
        dot(root.emitter_row2.xyz, direction)
    );
    float direction_length = length(direction);
    if (direction_length > 0.0) direction /= direction_length;
    particle.age = 0.0;
    particle.lifetime = particle_sample(stream, ordinal, PARTICLE_DRAW_LIFETIME, root.lifetime_speed.xy);
    particle.velocity = direction * particle_sample(stream, ordinal, PARTICLE_DRAW_SPEED, root.lifetime_speed.zw);
    particle.size = particle_sample(stream, ordinal, PARTICLE_DRAW_SIZE, root.size_rotation.xy);
    particle.rotation = particle_sample(stream, ordinal, PARTICLE_DRAW_ROTATION, root.size_rotation.zw);
    particle.spin = particle_sample(stream, ordinal, PARTICLE_DRAW_SPIN, root.spin_ground.xy);
    particle.seed = particle_spawn_hash(stream, ordinal, PARTICLE_DRAW_SEED);
    particle.spawn = ordinal;
    particle._pad0 = 0u;
    particle._pad1 = 0u;
    return particle;
}

// Packs the survivors and their trails to the front of the alternate buffer, then appends the admitted newborns in
// ordinal order.
void main() {
    StepRoot root = StepRoot(DispatchRoot(pc.root_gpu).parameters);
    ParticleControl control = ParticleControl(root.control);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.capacity) return;

    ParticleStates home = ParticleStates(root.state_home);
    ParticleStates alternate = ParticleStates(root.state_alt);
    if (index < control.alive) {
        uvec4 flags = ParticleScan(root.scan).values[index];
        if (flags.x != 0u) {
            uint slot = flags.z + ParticleTotals(root.totals).values[index / PARTICLE_GROUP].x;
            alternate.values[slot] = home.values[index];
            if (root.trail_max_points != 0u) particle_copy_trail(root, true, index, slot);
        }
    }
    if (index < particle_emitted(root, control)) {
        uvec2 ordinal;
        ordinal.x = uaddCarry(control.spawn_low, index, ordinal.y);
        ordinal.y += control.spawn_high;
        uint slot = control.live_total + index;
        alternate.values[slot] = spawn_particle(root, ordinal);
        if (root.trail_max_points != 0u) {
            TrailHeaders(root.trail_headers_alt).values[slot] = TrailHeaderGpu(0u, 0u, 0.0, 0.0);
        }
    }
}
