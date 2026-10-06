#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "brdf.glsl"
#include "lights.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(DecalArray, DecalGpu);

const uint DECAL_MASK_WORD_BITS = 32u;

layout(local_size_x = CLUSTER_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared vec4 planes[6];
shared uint candidate_count;
shared uint decal_mask[MAX_DECALS / DECAL_MASK_WORD_BITS];

// mirrored as decal_intersects_planes in render/decal.c3
bool decal_intersects(DecalGpu decal) {
    vec3 center = vec3(decal.local_to_world_0.w, decal.local_to_world_1.w, decal.local_to_world_2.w);
    vec3 half_edge_x = DECAL_HALF_EXTENT * vec3(
        decal.local_to_world_0.x, decal.local_to_world_1.x, decal.local_to_world_2.x);
    vec3 half_edge_y = DECAL_HALF_EXTENT * vec3(
        decal.local_to_world_0.y, decal.local_to_world_1.y, decal.local_to_world_2.y);
    vec3 half_edge_z = DECAL_HALF_EXTENT * vec3(
        decal.local_to_world_0.z, decal.local_to_world_1.z, decal.local_to_world_2.z);
    for (uint plane = 0u; plane < 6u; plane++) {
        vec3 normal = planes[plane].xyz;
        float radius = abs(dot(normal, half_edge_x)) + abs(dot(normal, half_edge_y))
            + abs(dot(normal, half_edge_z));
        if (dot(planes[plane], vec4(center, 1.0)) < -radius) return false;
    }
    return true;
}

void main() {
    FrameRoot frame = FrameRoot(pc.root_gpu);
    ClusterGpu clusters = ClusterGpu(frame.clusters);
    uvec3 cell = gl_WorkGroupID;
    uint lane = gl_LocalInvocationIndex;
    uint segment = cluster_index(clusters, cell) * clusters.lights_per_cluster;
    for (uint word = lane; word < MAX_DECALS / DECAL_MASK_WORD_BITS; word += CLUSTER_GROUP_SIZE) {
        decal_mask[word] = 0u;
    }
    if (lane == 0u) {
        // mirrored as cluster_cell_planes in render/clusters.c3
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
    for (uint index = lane; index < frame.decal_count; index += CLUSTER_GROUP_SIZE) {
        if (decal_intersects(DecalArray(frame.decals).values[index])) {
            atomicOr(decal_mask[index / DECAL_MASK_WORD_BITS], 1u << (index % DECAL_MASK_WORD_BITS));
        }
    }
    memoryBarrierBuffer();
    barrier();

    if (lane == 0u) {
        uint overflow = candidate_count > clusters.lights_per_cluster ? 1u : 0u;
        ClusterRangesOutput(clusters.ranges).values[cluster_index(clusters, cell)] =
            ClusterRange(min(candidate_count, clusters.lights_per_cluster), overflow);
        if (overflow != 0u) atomicAdd(ClusterCounterGpu(clusters.counter).overflows, 1u);

        uint decal_count = 0u;
        uint decal_segment = cluster_index(clusters, cell) * MAX_CLUSTER_DECALS;
        for (uint word = 0u; word < MAX_DECALS / DECAL_MASK_WORD_BITS; word++) {
            uint selected = decal_mask[word];
            while (selected != 0u) {
                uint index = word * DECAL_MASK_WORD_BITS + uint(findLSB(selected));
                if (decal_count < MAX_CLUSTER_DECALS) {
                    ClusterIndicesOutput(clusters.decal_indices).values[decal_segment + decal_count] = index;
                }
                decal_count++;
                selected &= selected - 1u;
            }
        }
        uint decal_overflow = decal_count > MAX_CLUSTER_DECALS ? 1u : 0u;
        ClusterRangesOutput(clusters.decal_ranges).values[cluster_index(clusters, cell)] =
            ClusterRange(min(decal_count, MAX_CLUSTER_DECALS), decal_overflow);
        if (decal_overflow != 0u) atomicAdd(ClusterCounterGpu(clusters.counter).decal_overflows, 1u);
    }
}
