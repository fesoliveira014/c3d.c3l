#ifndef C3D_CLUSTERS_GLSL
#define C3D_CLUSTERS_GLSL

#include "buffer_reference.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(ClusterRanges, ClusterRange);
GPU_DECLARE_READONLY_ARRAY_REF(ClusterIndices, uint);
GPU_DECLARE_WRITEONLY_ARRAY_REF(ClusterRangesOutput, ClusterRange);
GPU_DECLARE_WRITEONLY_ARRAY_REF(ClusterIndicesOutput, uint);

uint cluster_index(ClusterGpu clusters, uvec3 cell) {
    return cell.x + clusters.tiles_x * (cell.y + clusters.tiles_y * cell.z);
}

bool cluster_cell_of(
    ClusterGpu clusters,
    vec3 world_position,
    float view_depth,
    out uint cell
) {
    if (clusters.depth.x >= clusters.depth.y
        || view_depth < clusters.depth.x || view_depth >= clusters.depth.y) return false;

    vec4 projected = clusters.view_proj * vec4(world_position, 1.0);
    if (projected.w <= 0.0) return false;

    vec2 uv = projected.xy / projected.w * vec2(0.5, -0.5) + 0.5;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) return false;

    float slice = floor((clusters.orthographic != 0u ? view_depth : log(view_depth))
        * clusters.depth.z + clusters.depth.w);
    if (slice < 0.0 || slice >= float(clusters.depth_slices)) return false;

    uvec2 tile = uvec2(uv * vec2(clusters.tiles_x, clusters.tiles_y));
    if (tile.x >= clusters.tiles_x || tile.y >= clusters.tiles_y) return false;

    cell = cluster_index(clusters, uvec3(tile, uint(slice)));
    return true;
}

float cluster_depth_boundary(ClusterGpu clusters, uint boundary) {
    if (boundary == 0u) return clusters.depth.x;
    if (boundary == clusters.depth_slices) return clusters.depth.y;

    float fraction = float(boundary) / float(clusters.depth_slices);
    if (clusters.orthographic != 0u) return mix(clusters.depth.x, clusters.depth.y, fraction);
    return exp(mix(log(clusters.depth.x), log(clusters.depth.y), fraction));
}

vec4 cluster_matrix_row(mat4 matrix, uint row) {
    return vec4(matrix[0][row], matrix[1][row], matrix[2][row], matrix[3][row]);
}

vec4 cluster_normalized_plane(vec4 plane) {
    return plane / length(plane.xyz);
}

#endif
