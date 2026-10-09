#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in; // mirrored as FIDELITY_SAMPLE_GROUP in test_texture_fidelity.c3
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;
layout(buffer_reference, std430, buffer_reference_align = 8) readonly buffer FidelitySampleRoot {
    uint64_t outputs;
    uint mip;
    uint width;
    uint height;
    uint padding;
};
layout(buffer_reference, std430, buffer_reference_align = 16) buffer FidelitySamples {
    vec4 values[];
};
void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    FidelitySampleRoot root = FidelitySampleRoot(dispatch.parameters);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;
    DispatchTextureGpu source = DispatchTexturesGpu(dispatch.textures).slots[0];
    FidelitySamples(root.outputs).values[pixel.y * root.width + pixel.x] = texelFetch(
        sampler2D(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(source.texture_index))],
            gpu_sampler_heap[nonuniformEXT(GPU_HEAP_SLOT(source.sampler_index))]),
        ivec2(pixel), int(root.mip)
    );
}
