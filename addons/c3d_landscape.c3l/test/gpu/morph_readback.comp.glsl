#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "texture_fetch.glsl"

layout(local_size_x = 1) in;

const uint MORPH_READBACK_POINTS = 32u; // mirrored as MORPH_READBACK_POINTS in morph_acceptance.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer MorphReadbackRoot {
    uint64_t output_address;
    uint point_count;
    uint read_color;
    ivec2 pixels[MORPH_READBACK_POINTS];
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer MorphReadbackOutput {
    vec4 texels[MORPH_READBACK_POINTS];
};

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    MorphReadbackRoot root = MorphReadbackRoot(dispatch.parameters);
    DispatchTexturesGpu textures = DispatchTexturesGpu(dispatch.textures);
    DispatchTextureGpu depth = textures.slots[0];
    ivec2 last = texture_extent(depth.texture_index) - 1;
    MorphReadbackOutput destination = MorphReadbackOutput(root.output_address);
    for (uint point = 0u; point < root.point_count; point++) {
        ivec2 pixel = root.pixels[point];
        // The temporal resolve follows the nearest, reverse-Z largest, depth of the 3 x 3 taps around a pixel.
        float nearest = 0.0;
        for (int row = -1; row <= 1; row++) {
            for (int column = -1; column <= 1; column++) {
                ivec2 tap = clamp(pixel + ivec2(column, row), ivec2(0), last);
                nearest = max(nearest, fetch_texture_2d(depth.texture_index, tap).x);
            }
        }
        vec2 velocity = vec2(0.0);
        if (root.read_color != 0u) {
            velocity = fetch_texture_2d(textures.slots[1].texture_index, pixel).xy;
        }
        destination.texels[point] = vec4(fetch_texture_2d(depth.texture_index, pixel).x, nearest, velocity);
    }
}
