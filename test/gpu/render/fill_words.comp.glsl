#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(local_size_x = 64) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FillWordsRoot {
    uint64_t words;
    uint     count;
    uint     value;
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer Words {
    uint values[];
};

void main() {
    FillWordsRoot root = FillWordsRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;
    Words(root.words).values[index] = root.value;
}
