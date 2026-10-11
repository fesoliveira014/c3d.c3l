#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;
layout(push_constant) uniform Push { uint64_t root; } pc;
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OpticalResolve {
    uint64_t output_address;
    uint capacity;
    uint enabled;
    uint opaque_depth;
    uint legacy_depth;
    uint overflow_depth;
    float receiver_depth;
    uint width;
    uint height;
    uint products[16];
    uint padding0;
    uint padding1;
};
layout(buffer_reference, std430, buffer_reference_align = 16) buffer OpticalOutput { vec4 values[]; };

void main() {
    OpticalResolve root = OpticalResolve(pc.root);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;
    ivec2 coordinate = ivec2(pixel);
    float legacy = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.legacy_depth))], coordinate, 0).r;
    float scalar = legacy > root.receiver_depth ? 0.0 : 1.0;
    vec3 visibility = vec3(scalar);
    if (root.enabled != 0u) {
        float blocker = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.opaque_depth))], coordinate, 0).r;
        float overflow = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.overflow_depth))], coordinate, 0).r;
        visibility = vec3(1.0);
        for (uint group = 0u; group < root.capacity; group++) {
            visibility *= texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.products[group]))], coordinate, 0).rgb;
        }
        if (blocker > root.receiver_depth || overflow > root.receiver_depth) visibility = vec3(0.0);
    }
    OpticalOutput(root.output_address).values[pixel.y * root.width + pixel.x] = vec4(visibility, scalar);
}
