#ifndef C3D_LIGHT_SPATIAL_GLSL
#define C3D_LIGHT_SPATIAL_GLSL

#include "lights.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(LightSpatialNodes, BvhNodeGpu);
GPU_DECLARE_READONLY_ARRAY_REF(LightSpatialIndices, uint);

struct LightCursor {
    uint64_t spatial;
    uint flat_count;
    uint global_index;
    uint leaf_first;
    uint leaf_count;
    uint stack_count;
    uint stack[BVH_STACK_DEPTH];
};

LightCursor light_cursor(uint64_t spatial, uint count) {
    LightCursor cursor;
    cursor.spatial = spatial;
    cursor.flat_count = count;
    cursor.global_index = 0u;
    cursor.leaf_first = 0u;
    cursor.leaf_count = 0u;
    cursor.stack_count = spatial != 0ul ? 1u : 0u;
    cursor.stack[0] = 0u;
    return cursor;
}

bool next_light(inout LightCursor cursor, vec3 position, out uint index) {
    if (cursor.spatial == 0ul) {
        if (cursor.global_index == cursor.flat_count) return false;
        index = cursor.global_index++;
        return true;
    }
    LightSpatialRoot root = LightSpatialRoot(cursor.spatial);
    if (cursor.global_index < root.global_count) {
        index = LightSpatialIndices(root.globals).values[cursor.global_index++];
        return true;
    }
    for (;;) {
        if (cursor.leaf_count != 0u) {
            index = LightSpatialIndices(root.indices).values[cursor.leaf_first++];
            cursor.leaf_count--;
            return true;
        }
        if (cursor.stack_count == 0u) return false;
        BvhNodeGpu node = LightSpatialNodes(root.nodes).values[cursor.stack[--cursor.stack_count]];
        vec3 minimum = vec3(node.min_x, node.min_y, node.min_z);
        vec3 maximum = vec3(node.max_x, node.max_y, node.max_z);
        if (any(lessThan(position, minimum)) || any(greaterThan(position, maximum))) continue;
        if (node.count == 0u) {
            cursor.stack[cursor.stack_count++] = node.left_or_first + 1u;
            cursor.stack[cursor.stack_count++] = node.left_or_first;
        } else {
            cursor.leaf_first = node.left_or_first;
            cursor.leaf_count = node.count;
        }
    }
}

#endif
