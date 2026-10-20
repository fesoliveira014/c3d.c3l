#ifndef PARTICLE_SPAWN_GLSL
#define PARTICLE_SPAWN_GLSL

#include "particle/particle_step.glsl"

// Mirrors sphere_direction in step.c3.
vec3 particle_sphere_direction(uint stream, uvec2 ordinal) {
    float vertical = 1.0 - 2.0 * particle_unit(stream, ordinal, PARTICLE_DRAW_DIRECTION_HEIGHT);
    float angle = PARTICLE_FULL_TURN * particle_unit(stream, ordinal, PARTICLE_DRAW_DIRECTION_ANGLE);
    float radius = sqrt(max(0.0, 1.0 - vertical * vertical));
    return vec3(radius * cos(angle), vertical, radius * sin(angle));
}

// Mirrors emit_particle in step.c3. The emitter matrix carries the orientation and scale; origin is its translation.
ParticleGpu particle_spawn(StepRoot root, uint stream, uvec2 ordinal, vec3 origin) {
    vec3 position = vec3(0.0);
    vec3 direction;
    if (root.shape == PARTICLE_SHAPE_POINT) {
        direction = particle_sphere_direction(stream, ordinal);
    } else if (root.shape == PARTICLE_SHAPE_BOX) {
        position = vec3(
            2.0 * particle_unit(stream, ordinal, PARTICLE_DRAW_POSITION_A) - 1.0,
            2.0 * particle_unit(stream, ordinal, PARTICLE_DRAW_POSITION_B) - 1.0,
            2.0 * particle_unit(stream, ordinal, PARTICLE_DRAW_POSITION_C) - 1.0
        ) * root.half_extents_friction.xyz;
        direction = particle_sphere_direction(stream, ordinal);
    } else if (root.shape == PARTICLE_SHAPE_SPHERE) {
        direction = particle_sphere_direction(stream, ordinal);
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
        dot(root.emitter_row0.xyz, position) + origin.x,
        dot(root.emitter_row1.xyz, position) + origin.y,
        dot(root.emitter_row2.xyz, position) + origin.z
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
    particle.fresh = 0u;
    particle._pad0 = 0u;
    return particle;
}

#endif
