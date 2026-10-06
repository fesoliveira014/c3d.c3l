#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "vertex_pull.glsl"

layout(local_size_x = TRACE_REFIT_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

GPU_DECLARE_READONLY_ARRAY_REF(RefitSourceNodes, BvhNodeGpu);
GPU_DECLARE_READONLY_ARRAY_REF(RefitIndices, uint);

// An interior node reads children another invocation wrote before the level barrier.
layout(buffer_reference, std430, buffer_reference_align = 16) coherent buffer RefitNodes {
    BvhNodeGpu values[];
};

vec3 node_min(BvhNodeGpu node) {
    return vec3(node.min_x, node.min_y, node.min_z);
}

vec3 node_max(BvhNodeGpu node) {
    return vec3(node.max_x, node.max_y, node.max_z);
}

// One workgroup refits one tree, deepest level first; topology and leaf primitives stay those of the rest tree.
void main() {
    TraceRefitRoot root = TraceRefitRoot(pc.root_gpu);
    GeometryRoot geometry = GeometryRoot(root.geometry);
    RefitSourceNodes source = RefitSourceNodes(root.source_nodes);
    RefitNodes nodes = RefitNodes(root.nodes);
    RefitIndices primitives = RefitIndices(root.primitives);
    RefitIndices starts = RefitIndices(root.depth_starts);
    RefitIndices order = RefitIndices(root.depth_order);
    for (int depth = int(BVH_STACK_DEPTH) - 1; depth >= 0; depth--) {
        uint last = starts.values[depth + 1];
        uint first = starts.values[depth] + gl_LocalInvocationIndex;
        for (uint entry = first; entry < last; entry += TRACE_REFIT_GROUP_SIZE) {
            uint index = order.values[entry];
            BvhNodeGpu node = source.values[index];
            vec3 low;
            vec3 high;
            if (node.count == 0u) {
                BvhNodeGpu left = nodes.values[node.left_or_first];
                BvhNodeGpu right = nodes.values[node.left_or_first + 1u];
                low = min(node_min(left), node_min(right));
                high = max(node_max(left), node_max(right));
            } else {
                uvec3 corners = pull_triangle(geometry, primitives.values[node.left_or_first]);
                low = pull_vec3(geometry.positions, corners.x);
                high = low;
                for (uint slot = 0u; slot < node.count; slot++) {
                    corners = pull_triangle(geometry, primitives.values[node.left_or_first + slot]);
                    vec3 a = pull_vec3(geometry.positions, corners.x);
                    vec3 b = pull_vec3(geometry.positions, corners.y);
                    vec3 c = pull_vec3(geometry.positions, corners.z);
                    low = min(low, min(min(a, b), c));
                    high = max(high, max(max(a, b), c));
                }
            }
            node.min_x = low.x;
            node.min_y = low.y;
            node.min_z = low.z;
            node.max_x = high.x;
            node.max_y = high.y;
            node.max_z = high.z;
            nodes.values[index] = node;
        }
        memoryBarrierBuffer();
        barrier();
    }
}
