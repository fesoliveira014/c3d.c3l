#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "normal_mapping.glsl"

layout(local_size_x = 64) in; // mirrored as FIDELITY_GROUP_SIZE in test_texture_fidelity.c3
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;

struct FidelityInput {
    vec4 encoded_scale;
    vec4 normal;
    vec4 tangent;
    mat4 model;
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FidelityInputs {
    FidelityInput values[];
};
layout(buffer_reference, std430, buffer_reference_align = 16) buffer FidelityOutputs {
    vec4 values[];
};
layout(buffer_reference, std430, buffer_reference_align = 8) readonly buffer FidelityRoot {
    uint64_t inputs;
    uint64_t outputs;
    uint count;
    uint mode;
    uint rg;
    uint padding;
};

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    FidelityRoot root = FidelityRoot(dispatch.parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;
    FidelityInput input_value = FidelityInputs(root.inputs).values[index];
    vec3 mapped = decode_normal(input_value.encoded_scale.xyz, input_value.encoded_scale.w, root.rg != 0u);
    vec3 result = mapped;
    if (root.mode != 0u) {
        result = tangent_normal(input_value.normal.xyz, input_value.tangent, mapped);
    }

    FidelityOutputs(root.outputs).values[index] = vec4(result, 1.0);
}
