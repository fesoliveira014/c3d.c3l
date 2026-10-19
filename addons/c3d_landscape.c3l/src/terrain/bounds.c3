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

// The root is the last node and the only one of the top level.
fn uint node_count(TerrainRuntime* runtime) @private {
    return runtime.level_offset[runtime.level_count - 1] + 1;
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

fn TerrainRuntime? create_runtime(Allocator allocator, uint texels, TerrainDesc* desc) @private {
    TerrainRuntime runtime = {
        .allocator   = allocator,
        .texels      = texels,
        .level_count = level_count_of(texels)!,
    };
    if (desc.trace) runtime.trace_level = desc.trace_level;
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
    if (desc.trace) {
        uint leaves = level_side(&runtime, 0);
        float[]? deviation = alloc::new_array_try(allocator, float, (sz)leaves * leaves);
        if (catch deviation) return c3d::CAPACITY_EXCEEDED~;
        runtime.trace_deviation = deviation;
    }
    return runtime;
}

fn void free_runtime(TerrainRuntime* runtime) @private {
    alloc::free(runtime.allocator, runtime.minimum.ptr);
    alloc::free(runtime.allocator, runtime.maximum.ptr);
    alloc::free(runtime.allocator, runtime.trace_deviation.ptr);
    *runtime = {};
}

fn void refresh_bounds(
    TerrainRuntime* runtime,
    ushort[] texels,
    TexelRect rect,
    float height_scale,
) @private {
    uint leaf_side = level_side(runtime, 0);
    uint last_chunk = leaf_side - 1;
    // A texel on a shared chunk edge belongs to the chunks on both sides.
    uint first_x = rect.x > 0 ? (rect.x - 1) / CHUNK_CELLS : 0;
    uint first_z = rect.z > 0 ? (rect.z - 1) / CHUNK_CELLS : 0;
    uint last_x = min((rect.x + rect.columns - 1) / CHUNK_CELLS, last_chunk);
    uint last_z = min((rect.z + rect.rows - 1) / CHUNK_CELLS, last_chunk);
    for (uint z = first_z; z <= last_z; z++) {
        for (uint x = first_x; x <= last_x; x++) {
            QuadNode leaf = { .x = x, .z = z };
            build_leaf(runtime, texels, leaf);
            if (runtime.trace_deviation.len) {
                runtime.trace_deviation[z * leaf_side + x] = chunk_trace_deviation(runtime, texels, leaf);
            }
        }
    }
    if (runtime.trace_deviation.len) {
        float widest;
        foreach (deviation : runtime.trace_deviation) widest = max(widest, deviation);
        runtime.trace_error = widest * height_scale / TEXEL_MAX;
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

// The grid's triangles split each cell along its (x + 1, z) to (x, z + 1) diagonal, so they refine to the texels' own
// triangles and both surfaces are linear on each of those: the gap peaks at a texel.
fn float chunk_trace_deviation(TerrainRuntime* runtime, ushort[] texels, QuadNode leaf) @private {
    if (!runtime.trace_level) return 0;

    uint span = 1 << runtime.trace_level;
    uint first_x = leaf.x * CHUNK_CELLS;
    uint first_z = leaf.z * CHUNK_CELLS;
    float widest;
    for (uint cell_z = first_z; cell_z < first_z + CHUNK_CELLS; cell_z += span) {
        for (uint cell_x = first_x; cell_x < first_x + CHUNK_CELLS; cell_x += span) {
            float near_near = (float)texels[(usz)cell_z * runtime.texels + cell_x];
            float far_near = (float)texels[(usz)cell_z * runtime.texels + cell_x + span];
            float near_far = (float)texels[(usz)(cell_z + span) * runtime.texels + cell_x];
            float far_far = (float)texels[(usz)(cell_z + span) * runtime.texels + cell_x + span];
            for (uint step_z = 0; step_z <= span; step_z++) {
                for (uint step_x = 0; step_x <= span; step_x++) {
                    float along_x = (float)step_x / span;
                    float along_z = (float)step_z / span;
                    float on_grid = along_x + along_z <= 1
                        ? near_near + along_x * (far_near - near_near) + along_z * (near_far - near_near)
                        : far_far + (1 - along_x) * (near_far - far_far) + (1 - along_z) * (far_near - far_far);
                    float drawn = (float)texels[(usz)(cell_z + step_z) * runtime.texels + cell_x + step_x];
                    widest = max(widest, math::abs(drawn - on_grid));
                }
            }
        }
    }
    return widest;
}
