module c3d::particle;

import c3d::maths;
import std::math;
import std::math::random;

const float RANDOM_UNIT_SCALE @private = 1.0f / 16777216.0f; // high 24 bits fit a float mantissa exactly
const uint RANDOM_UNIT_SHIFT @private = 8;
const float FULL_TURN @private = 2 * (float)math::PI;
const uint HASH_MULTIPLIER @private = 747796405;
const uint HASH_INCREMENT @private = 2891336453;
const uint HASH_OUTPUT_MULTIPLIER @private = 277803737;
const uint HASH_STATE_SHIFT @private = 28;
const uint HASH_ROTATION_OFFSET @private = 4;
const uint HASH_OUTPUT_SHIFT @private = 22;

<*
 Advance one particle pool without touching scene structure.
 @param [&inout] system : "Live, initialized particle system."
 @param emitter_world : "Published affine emitter matrix."
 @param dt : "Finite nonnegative seconds; capped at the maximum step."
 @param wind : "Finite world-space air velocity in metres per second."
 @require system.is_prepared()
 @require dt >= 0 && math::is_finite(dt)
 @require math::is_finite(wind.x) && math::is_finite(wind.y) && math::is_finite(wind.z)
*>
fn void step(
    ParticleSystem* system,
    Mat4 emitter_world,
    float dt,
    Vec3 wind,
) {
    float seconds = math::min(dt, MAX_PARTICLE_STEP_SECONDS);
    uint index;
    while (index < system.alive) {
        system.age[index] += seconds;
        if (system.age[index] >= system.lifetime[index]) {
            remove_particle(system, index);
        } else {
            index++;
        }
    }
    uint survivors = system.alive;
    if (system.emitting) system.emit_accumulator += (double)system.desc.rate * seconds;
    double whole = math::floor(system.emit_accumulator);
    system.emit_accumulator -= whole;
    // A finite float rate over a clamped step fits uint128 before telemetry saturates.
    uint128 requested = (uint128)whole + system.pending_burst;
    system.pending_burst = 0;
    uint emitted = (uint)math::min(requested, (uint128)(system.desc.capacity - system.alive));
    uint128 dropped = (uint128)system.dropped + requested - emitted;
    system.dropped = dropped > ulong::max ? ulong::max : (ulong)dropped;
    for (uint spawned = 0; spawned < emitted; spawned++) emit_particle(system, emitter_world);

    Vec3 acceleration_step = PARTICLE_GRAVITY * (system.desc.gravity_scale * seconds);
    float drag = math::min(1.0f, system.desc.drag * seconds);
    for (index = 0; index < system.alive; index++) {
        Vec3 velocity = system.velocity[index] + acceleration_step;
        velocity = velocity * (1 - drag) + wind * drag;
        system.velocity[index] = velocity;
        system.position[index] += velocity * seconds;
        system.rotation[index] += system.spin[index] * seconds;
        if (index >= survivors) system.age[index] = seconds;
    }
    index = survivors;
    while (index < system.alive) {
        if (system.age[index] >= system.lifetime[index]) {
            remove_particle(system, index);
        } else {
            index++;
        }
    }
}

fn float random_unit(Sfc32Random* random) @private {
    return (float)(random.next_int() >> RANDOM_UNIT_SHIFT) * RANDOM_UNIT_SCALE;
}

fn float sample_range(Sfc32Random* random, ParticleRange range) @private {
    double fraction = random_unit(random);
    return (float)((double)range.min * (1 - fraction) + (double)range.max * fraction);
}

fn Vec3 sphere_direction(Sfc32Random* random) @private {
    float vertical = 1 - 2 * random_unit(random);
    float angle = FULL_TURN * random_unit(random);
    float radius = math::sqrt(math::max(0.0f, 1 - vertical * vertical));
    return { radius * math::cos(angle), vertical, radius * math::sin(angle) };
}

fn void emit_particle(ParticleSystem* system, Mat4 emitter_world) @private {
    ParticleSystemDesc* desc = &system.desc;
    Sfc32Random* random = &system.random;
    Vec3 position;
    Vec3 direction;
    switch (desc.shape) {
        case POINT:
            direction = sphere_direction(random);
        case BOX:
            for (usz axis = 0; axis < 3; axis++) {
                position[axis] = (2 * random_unit(random) - 1) * desc.half_extents[axis];
            }
            direction = sphere_direction(random);
        case SPHERE:
            direction = sphere_direction(random);
            position = direction * (desc.radius * math::pow(random_unit(random), 1.0f / 3));
        case CONE:
            float radius = desc.radius * math::sqrt(random_unit(random));
            float angle = FULL_TURN * random_unit(random);
            position = { radius * math::cos(angle), 0, radius * math::sin(angle) };
            float vertical = 1 - random_unit(random) * (1 - math::cos(desc.cone_angle));
            angle = FULL_TURN * random_unit(random);
            float lateral = math::sqrt(math::max(0.0f, 1 - vertical * vertical));
            direction = { lateral * math::cos(angle), vertical, lateral * math::sin(angle) };
    }
    uint index = system.alive++;
    system.position[index] = maths::transform_point(emitter_world, position);
    direction = maths::transform_dir(emitter_world, direction);
    float direction_length = direction.length();
    if (direction_length > 0) direction /= direction_length;
    system.age[index] = 0;
    system.lifetime[index] = sample_range(random, desc.lifetime);
    system.velocity[index] = direction * sample_range(random, desc.speed);
    system.size[index] = sample_range(random, desc.size);
    system.rotation[index] = sample_range(random, desc.rotation);
    system.spin[index] = sample_range(random, desc.spin);
    system.seed[index] = random.next_int();
}

fn void remove_particle(ParticleSystem* system, uint index) @private {
    uint last = --system.alive;
    system.position[index] = system.position[last];
    system.velocity[index] = system.velocity[last];
    system.age[index] = system.age[last];
    system.lifetime[index] = system.lifetime[last];
    system.size[index] = system.size[last];
    system.rotation[index] = system.rotation[last];
    system.spin[index] = system.spin[last];
    system.seed[index] = system.seed[last];
}

fn uint color_hash(uint value) @private {
    uint state = value * HASH_MULTIPLIER + HASH_INCREMENT;
    uint word = ((state >> ((state >> HASH_STATE_SHIFT) + HASH_ROTATION_OFFSET)) ^ state) * HASH_OUTPUT_MULTIPLIER;
    return (word >> HASH_OUTPUT_SHIFT) ^ word;
}

fn Vec4 particle_color(ParticleSystem* system, uint index, float life) @private {
    uint sample = color_hash(system.seed[index]);
    float fraction = (float)(sample >> RANDOM_UNIT_SHIFT) * RANDOM_UNIT_SCALE;
    Vec4 color = system.desc.color_min * (1 - fraction) + system.desc.color_max * fraction;
    return color * system.desc.color_over_life.sample(life);
}
