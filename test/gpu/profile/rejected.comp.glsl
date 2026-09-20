#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(local_size_x = 1) in;

layout(push_constant) uniform Push {
    int64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer CounterRoot {
    uint64_t output_address;
    uint value;
    uint padding;
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer CounterOutput {
    uint value;
};

void main() {
    CounterRoot root = CounterRoot(DispatchRoot(uint64_t(pc.root_gpu)).parameters);
    CounterOutput(root.output_address).value = root.value;
}
