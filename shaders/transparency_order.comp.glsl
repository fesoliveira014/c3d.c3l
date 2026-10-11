#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "buffer_reference.glsl"

layout(local_size_x = TRANSPARENCY_ORDER_GROUP_SIZE) in;

const uint TRANSPARENCY_UINT_BYTES = 4u;
const uint TRANSPARENCY_INDIRECT_INSTANCE_COUNT_WORD = 1u;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer TransparencyOrderArguments {
    DrawIndirectCommand value;
};

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer TransparencyOrderIndices {
    uint values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) writeonly buffer TransparencyOrderOutput {
    uint values[];
};

void main() {
    TransparencyOrderRoot root = TransparencyOrderRoot(pc.root_gpu);
    uint index = gl_GlobalInvocationID.x;
    uint visible_count = TransparencyOrderArguments(root.source_args).value.instance_count;
    if (index >= root.count || index >= visible_count) return;

    uint source = TransparencyOrderIndices(root.source_indices).values[index];
    uint destination = ((source - root.first) * root.stride) / TRANSPARENCY_UINT_BYTES
      + TRANSPARENCY_INDIRECT_INSTANCE_COUNT_WORD;
    TransparencyOrderOutput(root.output_args).values[destination] = 1u;
}
