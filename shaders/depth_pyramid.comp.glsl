#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    DepthPyramidRoot root = DepthPyramidRoot(pc.root_gpu);
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 output_extent = ivec2(root.width, root.height);
    if (any(greaterThanEqual(texel, output_extent))) return;

    // The last texel of an odd input also covers its leftover row or column.
    ivec2 scale = ivec2(root.input_width == root.width ? 1 : 2, root.input_height == root.height ? 1 : 2);
    ivec2 first = texel * scale;
    ivec2 last = first + scale - 1;
    ivec2 input_last = ivec2(root.input_width, root.input_height) - 1;
    if (texel.x == output_extent.x - 1) last.x = input_last.x;
    if (texel.y == output_extent.y - 1) last.y = input_last.y;

    // Reverse-Z stores the nearest surface as the largest depth, so the maximum keeps occluders.
    float nearest = 0.0;
    for (int y = first.y; y <= last.y; y++) {
        for (int x = first.x; x <= last.x; x++) {
            nearest = max(nearest, fetch_texture_2d(root.input_texture, ivec2(x, y)).r);
        }
    }

    store_storage_texture(root.output_texture, texel, vec4(nearest));
}
