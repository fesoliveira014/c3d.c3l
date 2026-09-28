#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "buffer_reference.glsl"
#include "descriptor_heap.glsl"
#include "probe_atlas.glsl"

layout(local_size_x = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ProbeTwinRoot {
    uint64_t output_address;
};

GPU_DECLARE_WRITEONLY_ARRAY_REF(ProbeTwinOutput, vec2);

// Mirrored as twin_direction in test_probe_volume.c3.
vec3 twin_direction(uint index) {
    return normalize(vec3(float(index % 4u) - 1.5, float((index / 4u) % 4u) - 1.5, float(index / 16u) - 1.5));
}

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    ProbeTwinOutput results = ProbeTwinOutput(ProbeTwinRoot(dispatch.parameters).output_address);
    uvec3 counts[2] = { uvec3(17u, 4u, 20u), uvec3(32u, 3u, 32u) };
    uint slices_per_row[2] = { 15u, 8u };
    uint edges[2] = { PROBE_IRRADIANCE_CELL, PROBE_VISIBILITY_CELL };
    uint slot = 0u;
    for (uint volume = 0u; volume < 2u; volume++) {
        for (uint z = 0u; z < counts[volume].z; z++) {
            for (uint y = 0u; y < counts[volume].y; y++) {
                for (uint x = 0u; x < counts[volume].x; x++) {
                    results.values[slot++] = vec2(probe_cell(counts[volume], slices_per_row[volume], uvec3(x, y, z)));
                }
            }
        }
        for (uint edge = 0u; edge < 2u; edge++) {
            results.values[slot++] = vec2(probe_atlas_extent(counts[volume], slices_per_row[volume], edges[edge]));
        }
    }
    for (uint edge = 0u; edge < 2u; edge++) {
        for (uint index = 0u; index < 64u; index++) {
            results.values[slot++] = probe_atlas_texel(uvec2(3u, 2u), edges[edge], twin_direction(index));
        }
        for (uint y = 0u; y < edges[edge]; y++) {
            for (uint x = 0u; x < edges[edge]; x++) {
                results.values[slot++] = vec2(probe_border_source(edges[edge], uvec2(x, y)));
            }
        }
    }
}
