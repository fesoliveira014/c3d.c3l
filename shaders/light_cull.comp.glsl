#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "brdf.glsl"
#include "lights.glsl"

layout(local_size_x = CLUSTER_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared vec4 planes[6];
shared uint candidate_count;

void main() {
    FrameRoot frame = FrameRoot(pc.root_gpu);
    ClusterGpu clusters = ClusterGpu(frame.clusters);
    uvec3 cell = gl_WorkGroupID;
    uint lane = gl_LocalInvocationIndex;
    uint segment = cluster_index(clusters, cell) * clusters.lights_per_cluster;
    if (lane == 0u) {
        vec2 minimum = vec2(cell.xy) / vec2(clusters.tiles_x, clusters.tiles_y);
        vec2 maximum = vec2(cell.xy + 1u) / vec2(clusters.tiles_x, clusters.tiles_y);
        float left = 2.0 * minimum.x - 1.0;
        float right = 2.0 * maximum.x - 1.0;
        float top = 1.0 - 2.0 * minimum.y;
        float bottom = 1.0 - 2.0 * maximum.y;
        vec4 projection_row_x = cluster_matrix_row(clusters.view_proj, 0u);
        vec4 projection_row_y = cluster_matrix_row(clusters.view_proj, 1u);
        vec4 projection_row_w = cluster_matrix_row(clusters.view_proj, 3u);
        vec4 view_row_z = cluster_matrix_row(frame.view, 2u);
        vec4 view_row_w = cluster_matrix_row(frame.view, 3u);
        float near_depth = cluster_depth_boundary(clusters, cell.z);
        float far_depth = cluster_depth_boundary(clusters, cell.z + 1u);
        planes[0] = cluster_normalized_plane(projection_row_x - left * projection_row_w);
        planes[1] = cluster_normalized_plane(right * projection_row_w - projection_row_x);
        planes[2] = cluster_normalized_plane(top * projection_row_w - projection_row_y);
        planes[3] = cluster_normalized_plane(projection_row_y - bottom * projection_row_w);
        planes[4] = cluster_normalized_plane(-view_row_z - near_depth * view_row_w);
        planes[5] = cluster_normalized_plane(view_row_z + far_depth * view_row_w);
        candidate_count = 0u;
    }
    barrier();

    for (uint index = lane; index < frame.light_count; index += CLUSTER_GROUP_SIZE) {
        LightGpu light = LightArray(frame.lights).values[index];
        if (global_light(light)) continue;

        bool intersects = true;
        for (uint plane = 0u; plane < 6u; plane++) {
            if (dot(planes[plane], vec4(light.position_range.xyz, 1.0)) < -light.position_range.w) {
                intersects = false;
                break;
            }
        }
        if (!intersects) continue;

        uint slot = atomicAdd(candidate_count, 1u);
        if (slot < clusters.lights_per_cluster) {
            ClusterIndicesOutput(clusters.indices).values[segment + slot] = index;
        }
    }
    memoryBarrierBuffer();
    barrier();

    if (lane == 0u) {
        uint overflow = candidate_count > clusters.lights_per_cluster ? 1u : 0u;
        ClusterRangesOutput(clusters.ranges).values[cluster_index(clusters, cell)] =
            ClusterRange(min(candidate_count, clusters.lights_per_cluster), overflow);
        if (overflow != 0u) atomicAdd(ClusterCounterGpu(clusters.counter).overflows, 1u);
    }
}
