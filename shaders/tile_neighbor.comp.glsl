#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Largest value among a tile and its eight neighbors.
void main() {
    TileRoot root = TileRoot(pc.root_gpu);
    uvec2 tile = gl_GlobalInvocationID.xy;
    if (tile.x >= root.width || tile.y >= root.height) return;

    vec2 best = vec2(0.0);
    float best_metric = -1.0;
    ivec2 last = ivec2(root.width - 1u, root.height - 1u);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            ivec2 coordinate = clamp(ivec2(tile) + ivec2(x, y), ivec2(0), last);
            vec2 value = load_storage_texture(root.input_texture, coordinate).rg;
            float metric = root.mode == TILE_MODE_ALPHA ? value.r : dot(value, value);
            if (metric > best_metric) {
                best_metric = metric;
                best = value;
            }
        }
    }
    store_storage_texture(root.output_texture, ivec2(tile), vec4(best, 0.0, 0.0));
}
