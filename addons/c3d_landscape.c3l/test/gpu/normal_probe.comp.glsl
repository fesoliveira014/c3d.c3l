#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "landscape/terrain_normal.glsl"

layout(local_size_x = 1) in;

const uint PROBE_COUNT = 8u; // mirrored as PROBE_COUNT in terrain_acceptance.c3
const uint PARAMS_WORDS = 16u; // a TerrainParams block is 64 bytes

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

struct ProbeInput {
    vec2 texel_position;
    uint height_slot;
    uint border_slot;
};

// One TerrainParams block per probe sits between the header and the inputs.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ProbeRoot {
    uint64_t output_address;
    uint64_t padding;
    uint params_words[PROBE_COUNT * PARAMS_WORDS];
    ProbeInput inputs[PROBE_COUNT];
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ProbeOutput {
    vec4 normals[PROBE_COUNT];
};

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    ProbeRoot root = ProbeRoot(dispatch.parameters);
    DispatchTexturesGpu textures = DispatchTexturesGpu(dispatch.textures);
    ProbeOutput destination = ProbeOutput(root.output_address);
    for (uint point = 0u; point < PROBE_COUNT; point++) {
        TerrainParams params = TerrainParams(dispatch.parameters + 16ul + uint64_t(point) * 4ul * PARAMS_WORDS);
        ProbeInput probe = root.inputs[point];
        vec3 normal = terrain_local_normal(
            textures.slots[probe.height_slot].texture_index,
            textures.slots[probe.border_slot].texture_index,
            params,
            probe.texel_position
        );
        destination.normals[point] = vec4(normal, 0.0);
    }
}
