#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(local_size_x = 8) in; // mirrored as DEVICE_RIBBON_CAPACITY in test_ribbons.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Mirrors DeviceRibbonsRoot in test_ribbons.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer DeviceRibbonsRoot {
    uint64_t records;
    uint64_t count;
    uint     live;
    uint     capacity;
    float    spacing;
    float    width;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer Points {
    RibbonPointGpu values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer Count {
    uint value;
};

// Lays the points along x. The point at the live count breaks the strip, as the writer of a real batch does.
void main() {
    DeviceRibbonsRoot root = DeviceRibbonsRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.capacity) return;
    float x = (float(index) - 0.5 * float(root.capacity - 1u)) * root.spacing;
    Points(root.records).values[index] = RibbonPointGpu(
        vec4(x, 0.0, 0.0, root.width),
        vec4(1.0),
        0.0,
        index == root.live ? RIBBON_POINT_BREAK : 0u,
        0u,
        0u
    );
    if (index == 0u) Count(root.count).value = root.live;
}
