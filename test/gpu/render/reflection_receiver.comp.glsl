#version 460
#define RECEIVER_COMPUTE
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "reflection_receiver_input.glsl"

layout(local_size_x = 8, local_size_y = 8) in;
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ReceiverDispatch {
    uint64_t receiver;
    uint64_t output;
    uint width;
    uint height;
    uint mode;
    uint padding;
};
layout(buffer_reference, std430, buffer_reference_align = 4) buffer ReceiverWords { uint values[]; };

void main() {
    ReceiverDispatch dispatch = ReceiverDispatch(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= dispatch.width || pixel.y >= dispatch.height) return;
    ReceiverRoot root = ReceiverRoot(dispatch.receiver);
    uint words[7];
    receiver_load(root, ivec2(pixel), words);
    uint offset = (pixel.y * dispatch.width + pixel.x) * 8u;
    ReceiverWords output_words = ReceiverWords(dispatch.output);
    for (uint word = 0u; word < RECEIVER_WORD_COUNT; word++) output_words.values[offset + word] = words[word];
    output_words.values[offset + 7u] = floatBitsToUint(
        texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.source_depth))], ivec2(pixel), 0).r
    );
}
