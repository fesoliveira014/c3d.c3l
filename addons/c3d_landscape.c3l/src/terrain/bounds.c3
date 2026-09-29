module c3d::landscape::terrain;

import c3d;
import c3d::asset;
import std::math;

const float TEXEL_MAX @private = 65535; // height = height_scale * texel / 65535, the physics height-field rule

struct QuadNode @private {
    uint level;
    uint x;
    uint z;
}

fn uint? level_count_of(uint texels) @private {
    for (uint level = 0; level < MAX_TERRAIN_LEVELS; level++) {
        if (texels == (CHUNK_CELLS << level) + 1) return level + 1;
    }
    return c3d::INVALID_ARGUMENT~;
}

fn uint level_side(TerrainRuntime* runtime, uint level) @private {
    return ((runtime.texels - 1) / CHUNK_CELLS) >> level;
}

fn uint node_index(TerrainRuntime* runtime, QuadNode node) @private {
    return runtime.level_offset[node.level] + node.z * level_side(runtime, node.level) + node.x;
}

// A selection partitions the extent into quadtree nodes, so it never holds more than the finest level.
fn uint finest_chunk_count(TerrainRuntime* runtime) @private {
    return level_side(runtime, 0) * level_side(runtime, 0);
}

fn QuadNode child_of(QuadNode node, uint child) @private {
    return { .level = node.level - 1, .x = 2 * node.x + (child & 1), .z = 2 * node.z + (child >> 1) };
}

fn ushort[] height_texels(TextureAsset* texture) @private {
    return ((ushort*)texture.pixels.ptr)[:(usz)texture.desc.width * texture.desc.height];
}

fn void? check_height_map(TextureAsset* texture) @private {
    TextureDesc desc = texture.desc;
    if (texture.source_kind != MIP_ZERO || desc.format != R16_UINT) return c3d::UNSUPPORTED~;
    if (desc.layers != 1 || desc.depth != 0 || desc.is_cube) return c3d::UNSUPPORTED~;
    if (desc.width != desc.height) return c3d::INVALID_ARGUMENT~;
    level_count_of(desc.width)!;
    if (texture.pixels.len != (usz)desc.width * desc.height * ushort::size) return c3d::INVALID_ARGUMENT~;
}

fn TerrainRuntime? create_runtime(Allocator allocator, uint texels) @private {
    TerrainRuntime runtime = {
        .allocator   = allocator,
        .texels      = texels,
        .level_count = level_count_of(texels)!,
    };
    uint nodes;
    for (uint level = 0; level < runtime.level_count; level++) {
        uint side = level_side(&runtime, level);
        runtime.level_offset[level] = nodes;
        nodes += side * side;
    }

    ushort[]? minimum = alloc::new_array_try(allocator, ushort, (sz)nodes);
    if (catch minimum) return c3d::CAPACITY_EXCEEDED~;
    runtime.minimum = minimum;
    defer catch alloc::free(allocator, runtime.minimum.ptr);
    ushort[]? maximum = alloc::new_array_try(allocator, ushort, (sz)nodes);
    if (catch maximum) return c3d::CAPACITY_EXCEEDED~;
    runtime.maximum = maximum;
    defer catch alloc::free(allocator, runtime.maximum.ptr);
    bool[]? split = alloc::new_array_try(allocator, bool, (sz)nodes);
    if (catch split) return c3d::CAPACITY_EXCEEDED~;
    runtime.split = split;
    runtime.stale = true;
    return runtime;
}

fn void free_runtime(TerrainRuntime* runtime) @private {
    alloc::free(runtime.allocator, runtime.minimum.ptr);
    alloc::free(runtime.allocator, runtime.maximum.ptr);
    alloc::free(runtime.allocator, runtime.split.ptr);
    *runtime = {};
}

fn void refresh_bounds(TerrainRuntime* runtime, ushort[] texels, TexelRect rect) @private {
    uint last_chunk = level_side(runtime, 0) - 1;
    // A texel on a shared chunk edge belongs to the chunks on both sides.
    uint first_x = rect.x > 0 ? (rect.x - 1) / CHUNK_CELLS : 0;
    uint first_z = rect.z > 0 ? (rect.z - 1) / CHUNK_CELLS : 0;
    uint last_x = min((rect.x + rect.columns - 1) / CHUNK_CELLS, last_chunk);
    uint last_z = min((rect.z + rect.rows - 1) / CHUNK_CELLS, last_chunk);
    for (uint z = first_z; z <= last_z; z++) {
        for (uint x = first_x; x <= last_x; x++) build_leaf(runtime, texels, { .x = x, .z = z });
    }
    for (uint level = 1; level < runtime.level_count; level++) {
        first_x >>= 1;
        first_z >>= 1;
        last_x >>= 1;
        last_z >>= 1;
        for (uint z = first_z; z <= last_z; z++) {
            for (uint x = first_x; x <= last_x; x++) build_parent(runtime, { .level = level, .x = x, .z = z });
        }
    }
}

fn void build_leaf(TerrainRuntime* runtime, ushort[] texels, QuadNode leaf) @private {
    uint first_x = leaf.x * CHUNK_CELLS;
    uint first_z = leaf.z * CHUNK_CELLS;
    ushort lowest = ushort::max;
    ushort highest = 0;
    for (uint z = first_z; z <= first_z + CHUNK_CELLS; z++) {
        foreach (value : texels[(usz)z * runtime.texels + first_x : CHUNK_CELLS + 1]) {
            lowest = min(lowest, value);
            highest = max(highest, value);
        }
    }
    uint index = node_index(runtime, leaf);
    runtime.minimum[index] = lowest;
    runtime.maximum[index] = highest;
}

fn void build_parent(TerrainRuntime* runtime, QuadNode parent) @private {
    ushort lowest = ushort::max;
    ushort highest = 0;
    for (uint child = 0; child < 4; child++) {
        uint index = node_index(runtime, child_of(parent, child));
        lowest = min(lowest, runtime.minimum[index]);
        highest = max(highest, runtime.maximum[index]);
    }
    uint index = node_index(runtime, parent);
    runtime.minimum[index] = lowest;
    runtime.maximum[index] = highest;
}
