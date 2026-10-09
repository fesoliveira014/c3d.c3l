#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer PreparationTypeRoot {
    uint64_t output_address;
    uint mip;
    uint width;
    uint height;
    uint depth;
    uint dimension;
    uint layer;
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer PreparationTypeOutput {
    uint pixels[];
};

const uint TEXTURE_SAMPLE_CUBE = 1u; // mirrored as CUBE in TextureSampleDimension
const uint TEXTURE_SAMPLE_VOLUME = 2u; // mirrored as VOLUME in TextureSampleDimension

vec3 cube_direction(uint face, vec2 coordinate) {
    switch (face) {
        case 0u: return vec3(1.0, -coordinate.y, -coordinate.x);
        case 1u: return vec3(-1.0, -coordinate.y, coordinate.x);
        case 2u: return vec3(coordinate.x, 1.0, coordinate.y);
        case 3u: return vec3(coordinate.x, -1.0, -coordinate.y);
        case 4u: return vec3(coordinate.x, -coordinate.y, 1.0);
        default: return vec3(-coordinate.x, -coordinate.y, -1.0);
    }
}

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    PreparationTypeRoot root = PreparationTypeRoot(dispatch.parameters);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    DispatchTextureGpu texture = DispatchTexturesGpu(dispatch.textures).slots[0];
    vec2 uv = (vec2(texel) + 0.5) / vec2(root.width, root.height);
    vec4 color;
    if (root.dimension == TEXTURE_SAMPLE_CUBE) {
        color = sample_texture_cube_lod(
            texture.texture_index,
            texture.sampler_index,
            cube_direction(root.layer, uv * 2.0 - 1.0),
            float(root.mip)
        );
    } else if (root.dimension == TEXTURE_SAMPLE_VOLUME) {
        color = sample_texture_3d(
            texture.texture_index,
            texture.sampler_index,
            vec3(uv, (float(root.layer) + 0.5) / float(root.depth))
        );
    } else {
        return;
    }
    PreparationTypeOutput(root.output_address).pixels[texel.y * root.width + texel.x] =
        packUnorm4x8(clamp(color, 0.0, 1.0));
}
