#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 1) in;
layout(push_constant) uniform Push { uint64_t root; } pc;
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Draw {
    uint64_t output_address;
    uint first;
    uint entries_per_instance;
    uint previous;
    uint selected;
    uint scene;
    uint mode;
    uint has_previous;
    uint unused0;
    uint unused1;
    uint unused2;
};
layout(buffer_reference, std430, buffer_reference_align = 4) buffer Counts {
    uint pixels;
    uint overflow;
};

void main() {
    Draw root = Draw(pc.root);
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
}
