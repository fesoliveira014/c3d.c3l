#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

const uint TILE_THREADS = POST_TILE_SIZE * POST_TILE_SIZE;

layout(local_size_x = POST_TILE_SIZE, local_size_y = POST_TILE_SIZE) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared vec2 group_values[TILE_THREADS];
shared float group_metrics[TILE_THREADS];

// Largest value of a 16x16 input block: alpha coverage, or the longest velocity.
void main() {
    TileRoot root = TileRoot(pc.root_gpu);
    uvec2 tile = gl_WorkGroupID.xy;
    uint lane = gl_LocalInvocationID.y * POST_TILE_SIZE + gl_LocalInvocationID.x;
    ivec2 origin = ivec2(tile * POST_TILE_SIZE);

    vec4 value = load_storage_texture(root.input_texture, origin + ivec2(gl_LocalInvocationID.xy));
    group_values[lane] = root.mode == TILE_MODE_ALPHA ? vec2(value.a, 0.0) : value.rg;
    group_metrics[lane] = root.mode == TILE_MODE_ALPHA ? value.a : dot(value.rg, value.rg);
    barrier();

    for (uint stride = 1u; stride < TILE_THREADS; stride <<= 1u) {
        uint index = lane * stride * 2u;
        if (index < TILE_THREADS && group_metrics[index + stride] > group_metrics[index]) {
            group_metrics[index] = group_metrics[index + stride];
            group_values[index] = group_values[index + stride];
        }
        barrier();
    }

    if (lane == 0u) {
        store_storage_texture(root.output_texture, ivec2(tile), vec4(group_values[0], 0.0, 0.0));
    }
}
