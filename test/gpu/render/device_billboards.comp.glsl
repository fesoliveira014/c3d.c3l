#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(local_size_x = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer DeviceBillboardsRoot {
    uint64_t records;
    uint64_t count;
    uint     live;
    uint     capacity;
    float    spacing;
    float    width;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer Records {
    BillboardGpu values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer Count {
    uint value;
};

void main() {
    DeviceBillboardsRoot root = DeviceBillboardsRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.capacity) return;
    float x = (float(index) - 0.5 * float(root.capacity - 1u)) * root.spacing;
    Records(root.records).values[index] = BillboardGpu(
        vec4(x, 0.0, 0.0, root.width),
        vec4(0.0, 1.0, 0.0, root.width),
        vec4(1.0),
        0.0,
        0u,
        0.0,
        0u
    );
    if (index == 0u) Count(root.count).value = root.live;
}
