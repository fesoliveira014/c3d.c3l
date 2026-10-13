#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "buffer_reference.glsl"
#include "gbuffer.glsl"
#include "texture_fetch.glsl"

GPU_DECLARE_WRITEONLY_ARRAY_REF(TileDepthOutput, float);

layout(local_size_x = CLUSTER_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared float group_farthest[CLUSTER_GROUP_SIZE];

// First pixel of a tile along one axis, for the mapping floor((pixel + 0.5) * tiles / extent) of cluster_cell_of.
uint tile_first_pixel(uint tile, uint extent, uint tiles) {
    uint scaled = (2u * extent * tile + tiles - 1u) / tiles;
    return scaled / 2u;
}

// Farthest view distance of one cluster tile's pixels; any pixel without geometry makes the tile unbounded.
void main() {
    ClusterDepthRoot root = ClusterDepthRoot(pc.root_gpu);
    FrameRoot frame = FrameRoot(root.frame);
    ClusterGpu clusters = ClusterGpu(frame.clusters);
    uvec2 tile = gl_WorkGroupID.xy;
    uvec2 extent = uvec2(texture_extent(root.depth));
    uvec2 tiles = uvec2(clusters.tiles_x, clusters.tiles_y);
    uvec2 first = uvec2(tile_first_pixel(tile.x, extent.x, tiles.x), tile_first_pixel(tile.y, extent.y, tiles.y));
    uvec2 last = uvec2(
        tile_first_pixel(tile.x + 1u, extent.x, tiles.x),
        tile_first_pixel(tile.y + 1u, extent.y, tiles.y));
    uvec2 size = last - first;
    uint lane = gl_LocalInvocationIndex;

    float farthest = 0.0;
    for (uint index = lane; index < size.x * size.y; index += CLUSTER_GROUP_SIZE) {
        ivec2 texel = ivec2(first + uvec2(index % size.x, index / size.x));
        float depth = fetch_texture_2d(root.depth, texel).r;
        farthest = max(farthest, depth == 0.0 ? BACKGROUND_VIEW_DISTANCE : view_distance(frame, depth));
    }

    group_farthest[lane] = farthest;
    barrier();

    for (uint stride = CLUSTER_GROUP_SIZE / 2u; stride > 0u; stride >>= 1u) {
        if (lane < stride) group_farthest[lane] = max(group_farthest[lane], group_farthest[lane + stride]);
        barrier();
    }

    if (lane == 0u) {
        bool empty = size.x * size.y == 0u;
        TileDepthOutput(clusters.tile_depth).values[tile.x + clusters.tiles_x * tile.y] =
            empty ? BACKGROUND_VIEW_DISTANCE : group_farthest[0];
    }
}
