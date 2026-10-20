#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "instance_record.glsl"

layout(local_size_x = 16) in; // mirrored as DEVICE_INSTANCE_CAPACITY in test_device_instances.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Mirrors DeviceInstancesRoot in test_device_instances.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer DeviceInstancesRoot {
    uint64_t records;
    uint64_t count;
    uint     live;
    uint     capacity;
    float    spacing;
    float    scale;
    float    stale_scale;
    uint     _pad0;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer Records {
    InstanceGpu values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer Count {
    uint value;
};

// Lays the live records along x about the node origin. Each record past the count is a box that would cover the centre
// if it were drawn.
void main() {
    DeviceInstancesRoot root = DeviceInstancesRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.capacity) return;
    bool live = index < root.live;
    float x = live ? (float(index) - 0.5 * float(root.live - 1u)) * root.spacing : 0.0;
    float size = live ? root.scale : root.stale_scale;
    mat4 model = mat4(
        vec4(size, 0.0, 0.0, 0.0),
        vec4(0.0, size, 0.0, 0.0),
        vec4(0.0, 0.0, size, 0.0),
        vec4(x, 0.0, 0.0, 1.0)
    );
    Records(root.records).values[index] = pack_instance_record(model, vec4(1.0), 0.0);
    if (index == 0u) Count(root.count).value = root.live;
}
