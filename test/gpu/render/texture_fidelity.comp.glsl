#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "normal_mapping.glsl"

layout(local_size_x = 64) in; // mirrored as FIDELITY_GROUP_SIZE in test_texture_fidelity.c3
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FidelityInputs {
    vec4 encoded_scales[];
};
layout(buffer_reference, std430, buffer_reference_align = 16) buffer FidelityOutputs {
    vec4 values[];
};
layout(buffer_reference, std430, buffer_reference_align = 8) readonly buffer FidelityRoot {
    uint64_t inputs;
    uint64_t outputs;
    uint count;
    uint rg;
};

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    FidelityRoot root = FidelityRoot(dispatch.parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;

    vec4 encoded_scale = FidelityInputs(root.inputs).encoded_scales[index];
    vec3 mapped = decode_normal(encoded_scale.xyz, encoded_scale.w, root.rg != 0u);

    FidelityOutputs(root.outputs).values[index] = vec4(mapped, 1.0);
}
