#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 1) in;
layout(push_constant) uniform Push { uint64_t root; } pc;
struct Surface {
    vec4 bounds;
    vec4 color;
    float depth;
    float coverage;
    uint kind;
    uint node;
    uint part;
    uint instance;
    uint primitive;
    uint reader;
    vec4 plane;
    uint range;
    uint padding0;
    uint padding1;
    uint padding2;
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Surfaces {
    Surface values[];
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer CountRoot {
    uint64_t output_address;
    uint64_t surfaces;
    uint selected;
    uint count;
    uint unused0;
    uint unused1;
};
layout(buffer_reference, std430, buffer_reference_align = 4) buffer Counts {
    uint pixels;
    uint overflow;
    uint fallback_entries;
    uint participating_entries;
};

void main() {
    CountRoot root = CountRoot(pc.root);
    uint count = 0u;
    for (int y = 0; y < 128; y++) {
        for (int x = 0; x < 128; x++) {
            float depth = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.selected))], ivec2(x, y), 0).x;
            count += depth > 0.0 ? 1u : 0u;
        }
    }
    Counts output_value = Counts(root.output_address);
    output_value.pixels = count;
    output_value.overflow = count != 0u ? 1u : 0u;
    uint fallback = 0u;
    for (uint index = 0u; index < root.count; index++) {
        fallback += Surfaces(root.surfaces).values[index].kind >= 2u ? 1u : 0u;
    }
    output_value.fallback_entries = fallback;
    output_value.participating_entries = root.count - fallback;
}
