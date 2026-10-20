#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "instance_record.glsl"

layout(local_size_x = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Mirrors InstanceRecordProbeRoot in test_device_instances.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer InstanceRecordProbeRoot {
    uint64_t output_address;
    uint64_t _pad0;
    mat4     model;
    vec4     color;
    float    seed;
    uint     _pad1;
    uint     _pad2;
    uint     _pad3;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer Packed {
    InstanceGpu value;
};

void main() {
    InstanceRecordProbeRoot root = InstanceRecordProbeRoot(DispatchRoot(pc.root_gpu).parameters);
    Packed(root.output_address).value = pack_instance_record(root.model, root.color, root.seed);
}
