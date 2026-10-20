#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(local_size_x = 64) in; // mirrored as COPY_GROUP in gpu_acceptance.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Mirrors CopyRoot in gpu_acceptance.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer RecordCopyRoot {
    uint64_t records;
    uint64_t count;
    uint64_t destination;
    uint capacity;
    uint _pad0;
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer SourceRecords {
    BillboardGpu values[];
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer CopiedRecords {
    BillboardGpu values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer CopiedWord {
    uint value;
};

void main() {
    RecordCopyRoot root = RecordCopyRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index < root.capacity) {
        CopiedRecords(root.destination).values[index] = SourceRecords(root.records).values[index];
    }
    if (index == 0u) {
        CopiedWord(root.destination + uint64_t(root.capacity) * 64ul).value = CopiedWord(root.count).value;
    }
}
