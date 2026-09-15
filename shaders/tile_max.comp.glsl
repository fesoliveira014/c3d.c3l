#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Largest value of a 16x16 input block: alpha coverage, or the longest velocity.
void main() {
    TileRoot root = TileRoot(pc.root_gpu);
    uvec2 tile = gl_GlobalInvocationID.xy;
    if (tile.x >= root.width || tile.y >= root.height) return;

    vec2 best = vec2(0.0);
    float best_metric = -1.0;
    ivec2 origin = ivec2(tile * POST_TILE_SIZE);
    for (uint y = 0u; y < POST_TILE_SIZE; y++) {
        for (uint x = 0u; x < POST_TILE_SIZE; x++) {
            vec4 value = load_storage_texture(root.input_texture, origin + ivec2(x, y));
            vec2 candidate = root.mode == TILE_MODE_ALPHA ? vec2(value.a, 0.0) : value.rg;
            float metric = root.mode == TILE_MODE_ALPHA ? value.a : dot(value.rg, value.rg);
            if (metric > best_metric) {
                best_metric = metric;
                best = candidate;
            }
        }
    }
    store_storage_texture(root.output_texture, ivec2(tile), vec4(best, 0.0, 0.0));
}
