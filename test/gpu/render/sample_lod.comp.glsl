#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer LodSampleRoot {
    uint64_t output_address;
    uint lod;
    uint width;
    uint height;
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer LodSampleOutput {
    uint pixels[];
};

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    LodSampleRoot root = LodSampleRoot(dispatch.parameters);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    DispatchTextureGpu texture = DispatchTexturesGpu(dispatch.textures).slots[0];
    vec2 uv = (vec2(texel) + 0.5) / vec2(root.width, root.height);
    vec4 color = textureLod(
        sampler2D(
            gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(texture.texture_index))],
            gpu_sampler_heap[nonuniformEXT(GPU_HEAP_SLOT(texture.sampler_index))]),
        uv,
        float(root.lod));
    LodSampleOutput(root.output_address).pixels[texel.y * root.width + texel.x] = packUnorm4x8(clamp(color, 0.0, 1.0));
}
