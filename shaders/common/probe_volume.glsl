#ifndef C3D_PROBE_VOLUME_GLSL
#define C3D_PROBE_VOLUME_GLSL

#include "descriptor_heap.glsl"
#include "probe_atlas.glsl"

const float PROBE_BACKFACE_FLOOR = 0.2;   // keeps probes behind the surface from vanishing on thin walls
const float PROBE_MIN_VARIANCE = 1e-4;    // world units squared; a flat distance distribution still falls off smoothly
const float PROBE_CHEBYSHEV_FLOOR = 0.05; // an occluded probe keeps a trace of weight, so no cell goes black
const float PROBE_MIN_WEIGHT = 1e-3;      // the weight sum never reaches zero

vec3 probe_volume_last_corner(ProbeVolumeGpu volume) {
    vec3 last = vec3(float(volume.count_x - 1u), float(volume.count_y - 1u), float(volume.count_z - 1u));
    return volume.origin_energy.xyz + volume.spacing_max_distance.xyz * last;
}

bool probe_volume_contains(ProbeVolumeGpu volume, vec3 position) {
    return all(greaterThanEqual(position, volume.origin_energy.xyz))
        && all(lessThanEqual(position, probe_volume_last_corner(volume)));
}

// Mirrored as probe_volume_at in probe_volume.c3.
bool probe_volume_select(ProbeVolumeSetGpu set, vec3 position, out uint index) {
    for (index = 0u; index < set.count; index++) {
        if (probe_volume_contains(set.volumes[index], position)) return true;
    }
    return false;
}

// Explicit level: this include compiles into compute and ray-generation stages.
vec4 probe_atlas_sample(
    uint atlas,
    uint sampler_index,
    uvec2 cell,
    uint cell_edge,
    vec3 direction,
    uvec2 extent
) {
    vec2 texel = probe_atlas_texel(cell, cell_edge, direction);
    return sample_texture_2d(atlas, sampler_index, texel / vec2(extent));
}

// Irradiance E at a surface; the texels store E, so no factor of pi appears here.
vec3 probe_irradiance(ProbeVolumeGpu volume, vec3 position, vec3 normal, vec3 view_direction) {
    uvec3 counts = uvec3(volume.count_x, volume.count_y, volume.count_z);
    uvec2 irradiance_extent = probe_atlas_extent(counts, volume.slices_per_row, PROBE_IRRADIANCE_CELL);
    uvec2 visibility_extent = probe_atlas_extent(counts, volume.slices_per_row, PROBE_VISIBILITY_CELL);
    vec3 spacing = volume.spacing_max_distance.xyz;
    float max_distance = volume.spacing_max_distance.w;

    vec3 biased = position + normal * volume.biases.x + view_direction * volume.biases.y;
    vec3 grid = (biased - volume.origin_energy.xyz) / spacing;
    uvec3 base = uvec3(clamp(floor(grid), vec3(0.0), vec3(counts - 2u)));
    vec3 alpha = clamp(grid - vec3(base), 0.0, 1.0);

    vec3 sum = vec3(0.0);
    float weight_sum = 0.0;
    for (uint corner_index = 0u; corner_index < 8u; corner_index++) {
        uvec3 corner = uvec3(corner_index & 1u, (corner_index >> 1u) & 1u, (corner_index >> 2u) & 1u);
        uvec3 probe = base + corner;
        vec3 probe_position = volume.origin_energy.xyz + vec3(probe) * spacing;
        vec3 trilinear = mix(1.0 - alpha, alpha, vec3(corner));
        vec3 to_probe = probe_position - biased;
        float distance_to_probe = length(to_probe);
        to_probe = distance_to_probe > 0.0 ? to_probe / distance_to_probe : normal;

        float backface = (dot(to_probe, normal) + 1.0) * 0.5;
        float weight = backface * backface + PROBE_BACKFACE_FLOOR;

        uvec2 cell = probe_cell(counts, volume.slices_per_row, probe);
        vec2 moments = probe_atlas_sample(
            volume.visibility, volume.sampler_index, cell, PROBE_VISIBILITY_CELL, -to_probe, visibility_extent
        ).rg;
        float probe_distance = min(distance_to_probe, max_distance);
        if (probe_distance > moments.x) {
            float variance = max(moments.y - moments.x * moments.x, PROBE_MIN_VARIANCE);
            float gap = probe_distance - moments.x;
            float chebyshev = variance / (variance + gap * gap);
            weight *= max(chebyshev * chebyshev * chebyshev, PROBE_CHEBYSHEV_FLOOR);
        }
        weight = weight * trilinear.x * trilinear.y * trilinear.z + PROBE_MIN_WEIGHT;

        vec3 irradiance = probe_atlas_sample(
            volume.irradiance, volume.sampler_index, cell, PROBE_IRRADIANCE_CELL, normal, irradiance_extent
        ).rgb;
        sum += weight * irradiance;
        weight_sum += weight;
    }
    return sum / weight_sum * volume.origin_energy.w;
}

#endif
