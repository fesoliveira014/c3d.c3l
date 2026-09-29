#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "buffer_reference.glsl"

layout(local_size_x = INSTANCE_SORT_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

GPU_DECLARE_WRITEONLY_ARRAY_REF(VisibleOutput, uint);

// Keys follow the list at an 8-byte boundary, below the 16-byte default of the array macros.
layout(buffer_reference, std430, buffer_reference_align = 8) buffer SortKeys {
    uint64_t values[];
};

// instance_count sits at offset 4 in both indirect command layouts.
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer CullArgs {
    uint first_count;
    uint instance_count;
};

shared uint64_t block_keys[INSTANCE_SORT_BLOCK];

// Pairs whose stage bit is clear sort descending, so the last stage leaves the whole list far to near.
void order_pair(inout uint64_t low, inout uint64_t high, uint index, uint stage) {
    if (((index & stage) == 0u) == (low < high)) {
        uint64_t held = low;
        low = high;
        high = held;
    }
}

uint pair_low(uint pair, uint distance) {
    return (pair / distance) * 2u * distance + pair % distance;
}

void order_global(InstanceSortRoot root) {
    uint low = pair_low(gl_GlobalInvocationID.x, root.distance);
    uint high = low + root.distance;
    SortKeys keys = SortKeys(root.keys);
    uint64_t low_key = keys.values[low];
    uint64_t high_key = keys.values[high];
    order_pair(low_key, high_key, low, root.stage);
    keys.values[low] = low_key;
    keys.values[high] = high_key;
}

void order_block(InstanceSortRoot root, uint visible_count) {
    uint length = min(root.capacity, INSTANCE_SORT_BLOCK);
    uint base = gl_WorkGroupID.x * length;
    bool blocks = (root.mode & INSTANCE_SORT_BLOCKS) != 0u;
    for (uint slot = gl_LocalInvocationID.x; slot < length; slot += INSTANCE_SORT_GROUP_SIZE) {
        uint index = base + slot;
        block_keys[slot] = blocks && index >= visible_count ? 0ul : SortKeys(root.keys).values[index];
    }
    barrier();
    for (uint stage = blocks ? 2u : root.stage; stage <= root.stage; stage <<= 1) {
        for (uint distance = blocks ? stage / 2u : root.distance; distance > 0u; distance >>= 1) {
            for (uint pair = gl_LocalInvocationID.x; pair < length / 2u; pair += INSTANCE_SORT_GROUP_SIZE) {
                uint low = pair_low(pair, distance);
                uint64_t low_key = block_keys[low];
                uint64_t high_key = block_keys[low + distance];
                // Direction follows the index in the whole list, so stages longer than a block merge correctly.
                order_pair(low_key, high_key, base + low, stage);
                block_keys[low] = low_key;
                block_keys[low + distance] = high_key;
            }
            barrier();
        }
    }
    bool write_list = (root.mode & INSTANCE_SORT_WRITE_LIST) != 0u;
    for (uint slot = gl_LocalInvocationID.x; slot < length; slot += INSTANCE_SORT_GROUP_SIZE) {
        uint index = base + slot;
        if (!write_list) {
            SortKeys(root.keys).values[index] = block_keys[slot];
        } else if (index < visible_count) {
            VisibleOutput(root.visible).values[index] = ~uint(block_keys[slot]);
        }
    }
}

void main() {
    InstanceSortRoot root = InstanceSortRoot(pc.root_gpu);
    if ((root.mode & INSTANCE_SORT_GLOBAL) != 0u) {
        order_global(root);
        return;
    }
    order_block(root, CullArgs(root.args).instance_count);
}
