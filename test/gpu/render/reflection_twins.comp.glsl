#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "buffer_reference.glsl"
#include "descriptor_heap.glsl"
#include "reflection_probe.glsl"

const uint REFLECTION_TWIN_VALUES = 3u; // mirrored as REFLECTION_TWIN_VALUES in test_reflection_probe.c3

layout(local_size_x = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ReflectionTwinRoot {
    uint64_t frame_address;
    uint64_t output_address;
};

GPU_DECLARE_WRITEONLY_ARRAY_REF(ReflectionTwinOutput, vec4);

const uint REFLECTION_TWIN_POINTS = 64u; // mirrored as REFLECTION_TWIN_POINTS in test_reflection_probe.c3

// Mirrored as reflection_twin_point in test_reflection_probe.c3.
vec3 reflection_twin_point(uint index) {
    return vec3(float(index % 4u) * 1.1 - 1.4, float((index / 4u) % 4u) * 0.6 - 0.9, float(index / 16u) * 0.9 - 1.3);
}

// Mirrored as reflection_twin_direction in test_reflection_probe.c3.
vec3 reflection_twin_direction(uint index) {
    return normalize(vec3(float(index % 4u) - 1.5, float((index / 4u) % 4u) - 1.5, float(index / 16u) - 1.5));
}

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    ReflectionTwinRoot root = ReflectionTwinRoot(dispatch.parameters);
    FrameRoot frame = FrameRoot(root.frame_address);
    ReflectionProbeSetGpu set = ReflectionProbeSetGpu(frame.reflection_probes);
    ReflectionTwinOutput results = ReflectionTwinOutput(root.output_address);
    for (uint index = 0u; index < REFLECTION_TWIN_POINTS; index++) {
        ReflectionSelection selection = reflection_probe_select(frame, reflection_twin_point(index));
        vec3 aimed = selection.count == 0u
            ? vec3(0.0)
            : reflection_box_direction(
                set.probes[selection.first],
                selection.first_position,
                reflection_twin_direction(index)
            );
        vec3 shares = vec3(selection.first_weight, selection.second_weight, selection.global_weight);
        results.values[index * REFLECTION_TWIN_VALUES] = vec4(float(selection.count), float(selection.first), float(selection.second), 0.0);
        results.values[index * REFLECTION_TWIN_VALUES + 1u] = vec4(shares, 0.0);
        results.values[index * REFLECTION_TWIN_VALUES + 2u] = vec4(aimed, 0.0);
    }
}
