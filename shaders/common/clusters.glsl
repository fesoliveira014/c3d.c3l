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
