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
    uint words;
    uint _pad0;
};

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer SourceWords {
    uint values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer CopiedWords {
    uint values[];
};

// Copies words of records, then the count word after them.
void main() {
    RecordCopyRoot root = RecordCopyRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index < root.words) {
        CopiedWords(root.destination).values[index] = SourceWords(root.records).values[index];
    }
    if (index == 0u) {
        CopiedWords(root.destination).values[root.words] = SourceWords(root.count).values[0];
    }
}
