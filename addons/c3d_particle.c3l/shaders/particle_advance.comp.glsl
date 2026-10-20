#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_step.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float TURBULENCE_CURL_SCALE = 0.6; // mirrored as CURL_SCALE in turbulence.c3
const float TURBULENCE_OCTAVE_GAIN = 0.5; // mirrored as OCTAVE_GAIN in turbulence.c3
const uint TURBULENCE_GRADIENT_FIELD_BITS = 10u; // mirrored as GRADIENT_FIELD_BITS in turbulence.c3
const uint TURBULENCE_GRADIENT_CHOICES = 12u; // mirrored as GRADIENT_CHOICES in turbulence.c3
// Mirrored as LATTICE_GRADIENTS in turbulence.c3.
const vec3 LATTICE_GRADIENTS[12] = vec3[12](
    vec3(1.0, 1.0, 0.0), vec3(-1.0, 1.0, 0.0), vec3(1.0, -1.0, 0.0), vec3(-1.0, -1.0, 0.0),
    vec3(1.0, 0.0, 1.0), vec3(-1.0, 0.0, 1.0), vec3(1.0, 0.0, -1.0), vec3(-1.0, 0.0, -1.0),
    vec3(0.0, 1.0, 1.0), vec3(0.0, -1.0, 1.0), vec3(0.0, 1.0, -1.0), vec3(0.0, -1.0, -1.0)
);

// Mirrors wrap_to_tile in turbulence.c3.
float wrap_to_tile(float value, float tile_length) {
    float remainder = value - trunc(value / tile_length) * tile_length;
    return remainder < 0.0 ? remainder + tile_length : remainder;
}

// Mirrors potential_gradient in turbulence.c3.
vec3 potential_gradient(vec3 gradients[24], uint first, vec3 fraction) {
    vec3 fade = fraction * fraction * fraction * (fraction * (fraction * 6.0 - 15.0) + 10.0);
    vec3 remainder = fraction - 1.0;
    vec3 fade_slope = fraction * fraction * remainder * remainder * 30.0;
    float value[8];
    for (uint index = 0u; index < 8u; index++) {
        vec3 offset = vec3(float(index & 1u), float((index >> 1u) & 1u), float((index >> 2u) & 1u));
        value[index] = dot(gradients[first + index], fraction - offset);
    }
    float slope_x = mix(
        mix(value[1] - value[0], value[3] - value[2], fade.y),
        mix(value[5] - value[4], value[7] - value[6], fade.y),
        fade.z
    );
    float slope_y = mix(
        mix(value[2] - value[0], value[3] - value[1], fade.x),
        mix(value[6] - value[4], value[7] - value[5], fade.x),
        fade.z
    );
    float slope_z = mix(
        mix(value[4] - value[0], value[5] - value[1], fade.x),
        mix(value[6] - value[2], value[7] - value[3], fade.x),
        fade.y
    );
    vec3 near_plane = mix(
        mix(gradients[first], gradients[first + 1u], fade.x),
        mix(gradients[first + 2u], gradients[first + 3u], fade.x),
        fade.y
    );
    vec3 far_plane = mix(
        mix(gradients[first + 4u], gradients[first + 5u], fade.x),
        mix(gradients[first + 6u], gradients[first + 7u], fade.x),
        fade.y
    );
    return mix(near_plane, far_plane, fade.z) + fade_slope * vec3(slope_x, slope_y, slope_z);
}

// Mirrors turbulence_curl in turbulence.c3, in float.
vec3 turbulence_curl(vec3 cells, uint period) {
    uvec2 lattice[3];
    vec3 fraction;
    for (uint axis = 0u; axis < 3u; axis++) {
        float lower = floor(cells[axis]);
        fraction[axis] = cells[axis] - lower;
        uint near_cell = uint(lower) % period;
        lattice[axis] = uvec2(near_cell, near_cell + 1u == period ? 0u : near_cell + 1u);
    }

    vec3 gradients[24];
    for (uint z = 0u; z < 2u; z++) {
        uint plane = particle_pcg_hash(lattice[2][z]);
        for (uint y = 0u; y < 2u; y++) {
            uint row = particle_pcg_hash(plane + lattice[1][y]);
            for (uint x = 0u; x < 2u; x++) {
                uint hash = particle_pcg_hash(row + lattice[0][x]);
                uint corner = x + 2u * y + 4u * z;
                for (uint potential = 0u; potential < 3u; potential++) {
                    uint field = (hash >> (potential * TURBULENCE_GRADIENT_FIELD_BITS))
                        & ((1u << TURBULENCE_GRADIENT_FIELD_BITS) - 1u);
                    uint choice = (field * TURBULENCE_GRADIENT_CHOICES) >> TURBULENCE_GRADIENT_FIELD_BITS;
                    gradients[potential * 8u + corner] = LATTICE_GRADIENTS[choice];
                }
            }
        }
    }

    vec3 along_x = potential_gradient(gradients, 0u, fraction);
    vec3 along_y = potential_gradient(gradients, 8u, fraction);
    vec3 along_z = potential_gradient(gradients, 16u, fraction);
    return vec3(along_z.y - along_y.z, along_x.z - along_z.x, along_y.x - along_x.y);
}

// Mirrors turbulence_air_velocity in turbulence.c3; the tile offset already holds the shift and the drift.
vec3 turbulence_air_velocity(StepRoot root, vec3 position) {
    float tile_length = root.turbulence_offset.w;
    vec3 point = position + root.turbulence_offset.xyz;
    vec3 cells;
    for (uint axis = 0u; axis < 3u; axis++) {
        cells[axis] = wrap_to_tile(point[axis], tile_length) * root.turbulence_frequency;
    }

    vec3 air = vec3(0.0);
    float amplitude = root.turbulence_strength * TURBULENCE_CURL_SCALE;
    for (uint octave = 0u; octave < root.octaves; octave++) {
        air += turbulence_curl(cells * float(1u << octave), root.period << octave) * amplitude;
        amplitude *= TURBULENCE_OCTAVE_GAIN;
    }
    return air;
}

// Mirrors respond_to_hit in collide.c3 for the ground plane, whose normal is up.
void respond_to_ground(StepRoot root, inout ParticleGpu particle, vec3 hit_point, float radius) {
    float approach = max(0.0, -particle.velocity.y);
    vec3 resting = hit_point + vec3(0.0, radius, 0.0);
    particle.position = hit_point;
    if (root.response == PARTICLE_RESPONSE_BOUNCE) {
        if (approach > 0.0) {
            vec3 into = vec3(0.0, -approach, 0.0);
            particle.velocity = (particle.velocity - into) * (1.0 - root.half_extents_friction.w)
                - into * root.origin_restitution.w;
        }
        particle.position = resting;
    } else if (root.response == PARTICLE_RESPONSE_STICK) {
        particle.velocity = vec3(0.0);
        particle.position = resting;
    } else {
        particle.age = particle.lifetime;
    }
}

// Mirrors collide_ground_blocks and hit_ground_plane in collide.c3.
void collide_ground(StepRoot root, inout ParticleGpu particle) {
    vec3 to = particle.position;
    vec3 from = particle.position - particle.velocity * root.seconds;
    if (from == to) return;

    float plane = root.spin_ground.z;
    float life = particle.age / particle.lifetime;
    float radius = particle.size * particle_size_scale(root, life) * root.spin_ground.w;
    float clearance_from = from.y - plane - radius;
    float clearance_to = to.y - plane - radius;
    if (clearance_to >= 0.0 || to.y >= from.y) return;

    float fraction = clearance_from > 0.0 ? clearance_from / (clearance_from - clearance_to) : 0.0;
    vec3 centre = from + (to - from) * fraction;
    respond_to_ground(root, particle, vec3(centre.x, plane, centre.z), radius);
}

// Mirrors record_trail_blocks, append_trail_point and drop_expired_trail_points in trail.c3.
void record_trail(StepRoot root, uint index, ParticleGpu particle) {
    uint size = root.trail_max_points;
    uint base = index * size;
    TrailHeaders headers = TrailHeaders(root.trail_headers_alt);
    TrailPoints points = TrailPoints(root.trail_points_alt);
    TrailDistances distances = TrailDistances(root.trail_distances_alt);
    TrailHeaderGpu header = headers.values[index];

    float clock = header.clock + root.seconds;
    if (clock >= root.trail_interval) {
        float distance = header.path_length;
        if (header.count != 0u) {
            distance += length(particle.position - points.values[base + particle_trail_slot(header, size, 0u)].xyz);
        }
        points.values[base + header.head] = vec4(particle.position, particle.age);
        distances.values[base + header.head] = distance;
        header.path_length = distance;
        header.head = (header.head + 1u) % size;
        header.count = min(header.count + 1u, size);
        clock -= root.trail_interval;
        if (clock >= root.trail_interval) clock = 0.0;
    }
    header.clock = clock;
    while (header.count != 0u) {
        uint oldest = base + particle_trail_slot(header, size, header.count - 1u);
        if (particle.age - points.values[oldest].w <= root.trail_lifetime) break;
        header.count--;
    }
    headers.values[index] = header;
}

// Advances the survivors and the newborns together, flags who lives and who draws, and books the admission.
void main() {
    StepRoot root = StepRoot(DispatchRoot(pc.root_gpu).parameters);
    ParticleControl control = ParticleControl(root.control);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.capacity) return;

    uint survivors = control.live_total;
    uint emitted = particle_emitted(root, control);
    uint pool = survivors + emitted;
    if (index == 0u) {
        uint carry;
        control.pool_count = pool;
        control.dropped_low = uaddCarry(control.dropped_low, root.requested - emitted, carry);
        control.dropped_high += carry;
        control.spawn_low = uaddCarry(control.spawn_low, emitted, carry);
        control.spawn_high += carry;
    }

    uvec4 flags = uvec4(0u);
    if (index < pool) {
        ParticleStates alternate = ParticleStates(root.state_alt);
        ParticleGpu particle = alternate.values[index];
        vec3 velocity = particle.velocity + root.acceleration_radius.xyz;
        vec3 air = root.wind_cone.xyz;
        if (root.octaves != 0u) air += turbulence_air_velocity(root, particle.position);
        velocity = velocity * (1.0 - root.drag) + air * root.drag;
        particle.velocity = velocity;
        particle.position += velocity * root.seconds;
        particle.rotation += particle.spin * root.seconds;
        if (index >= survivors) particle.age = root.seconds;
        bool live = particle.age < particle.lifetime;
        if (live && root.collides != 0u) {
            collide_ground(root, particle);
            live = particle.age < particle.lifetime;
        }
        alternate.values[index] = particle;
        if (live && root.trail_max_points != 0u) record_trail(root, index, particle);
        bool drawn = live && particle_draw_extent(root, particle) != 0.0;
        flags = uvec4(live ? 1u : 0u, drawn ? 1u : 0u, 0u, 0u);
    }
    ParticleScan(root.scan).values[index] = flags;
}
