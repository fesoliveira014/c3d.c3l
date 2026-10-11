#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "texture_fetch.glsl"

// Matches TRANSPARENCY_OVERFLOW_GROUP_SIZE in render/transparency_stats.c3.
layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 4) buffer TransparencyCounters {
    uint pixel_count;
    uint overflow;
};

shared uint tile_count;

void main() {
    TransparencyOverflowRoot root = TransparencyOverflowRoot(pc.root_gpu);
    if (gl_LocalInvocationIndex == 0u) tile_count = 0u;
    barrier();

    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x < root.width && pixel.y < root.height
        && fetch_texture_2d(root.depth, ivec2(pixel)).r != 0.0) {
        atomicAdd(tile_count, 1u);
    }
    barrier();

    if (gl_LocalInvocationIndex == 0u && tile_count != 0u) {
        TransparencyCounters counters = TransparencyCounters(root.counters);
        atomicAdd(counters.pixel_count, tile_count);
        atomicOr(counters.overflow, 1u);
    }
}
