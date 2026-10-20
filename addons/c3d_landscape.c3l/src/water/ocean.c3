module c3d::landscape::water;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;
import std::math::quaternion;

const uint MAX_OCEAN_LEVELS @private = scene::MAX_QUADTREE_DEPTH + 1;
const float OCEAN_LOD_THRESHOLD @private = 512; // pixels: the terrain's; the ranges' clamp sets the finest reach
const float OCEAN_LOD_HYSTERESIS @private = 0.25f; // the terrain's: merges below 410 px
const float OCEAN_MORPH_BAND @private = 0.25f; // at most (1 - hysteresis) / 2; wide enough to hide a pop
const float MIN_NODE_HEIGHT @private = 0.001f; // metres: instance culling and picking invert the instance matrix
const String CHUNK_KEY @private = "c3d_landscape/water_ocean_chunk";

<*
 Chunk layout, anchor and node boxes of an ocean, written by the library.
*>
struct OceanState {
    uint                   chunks;       // per side at the finest level; a power of two
    uint                   level_count;  // level 0 is the finest
    uint[MAX_OCEAN_LEVELS] level_offset; // first node of each level, which is also its instance index
    double[<2>]            anchor;       // absolute world XZ of the node the phases were folded at
    Vec3                   growth;       // what the node boxes hold beyond their rest footprint
}

// The anchor's shift since the last fold, and the node's inverse world that turns it into phase.
struct OceanMove @private {
    bool        moved;
    Mat4        inverse;
    double[<2>] delta;
}

<*
 Metres an ocean node moves by so every level's vertices keep their world positions.
 @param [&in] desc : "A checked desc."
 @require desc.mode == WaterMode.OCEAN
*>
fn float ocean_snap_step(WaterDesc* desc) {
    return desc.cell_size * (float)ocean_chunks(desc.extent, desc.cell_size);
}

// The next power of two at or above the chunks the extent needs; check_desc keeps it within MAX_OCEAN_CHUNKS.
fn uint ocean_chunks(float extent, float cell_size) @private {
    uint needed = (uint)math::ceil(extent / (cell_size * (float)OCEAN_CHUNK_CELLS));
    uint chunks = 1;
    while (chunks < needed) chunks <<= 1;
    return chunks;
}

fn OceanState ocean_layout(WaterDesc* desc) @private {
    OceanState ocean = { .chunks = ocean_chunks(desc.extent, desc.cell_size) };
    uint nodes;
    for (uint side = ocean.chunks; side > 0; side >>= 1) {
        ocean.level_offset[ocean.level_count++] = nodes;
        nodes += side * side;
    }
    return ocean;
}

fn uint ocean_node_count(OceanState* ocean) @private {
    return ocean.level_offset[ocean.level_count - 1] + 1;
}

// One unit chunk for every ocean of the store: the instance record maps it onto its node's box.
fn GeometryId? ocean_chunk(AssetStore* assets, bool* created = null) @private {
    if (created) *created = false;
    if (try found = assets.find_geometry(CHUNK_KEY)) return found;
    GeometryId chunk;
    @pool() {
        Geometry geometry = chunk_geometry(tmem);
        chunk = assets.add_geometry(&geometry, CHUNK_KEY)!;
    };
    if (created) *created = true;
    return chunk;
}

// The vertex stage reads only x and z, as lattice coordinates; the bounds give the instance boxes their thickness.
fn Geometry chunk_geometry(Allocator allocator) @private {
    uint row = OCEAN_CHUNK_CELLS + 1;
    Geometry chunk = {
        .topology  = TRIANGLES,
        .positions = alloc::new_array(allocator, Vec3, (sz)row * row),
        .indices   = alloc::new_array(allocator, uint, (sz)QUAD_INDICES * OCEAN_CHUNK_CELLS * OCEAN_CHUNK_CELLS),
    };
    for (uint z = 0; z < row; z++) {
        for (uint x = 0; x < row; x++) {
            chunk.positions[z * row + x] = { (float)x / OCEAN_CHUNK_CELLS, 0, (float)z / OCEAN_CHUNK_CELLS };
        }
    }
    usz slot;
    for (uint z = 0; z < OCEAN_CHUNK_CELLS; z++) {
        for (uint x = 0; x < OCEAN_CHUNK_CELLS; x++) {
            uint corner = z * row + x;
            // The terrain's split, counter-clockwise from above: the diagonal runs from (x + 1, z) to (x, z + 1).
            uint[QUAD_INDICES] quad = { corner, corner + row, corner + 1, corner + 1, corner + row, corner + row + 1 };
            chunk.indices[slot : QUAD_INDICES] = quad[..];
            slot += QUAD_INDICES;
        }
    }
    chunk.finalize();
    chunk.bounds = { .min = { 0, 0, 0 }, .max = { 1, 1, 1 } };
    return chunk;
}

fn void write_ocean_records(OceanState* ocean, WaterDesc* desc, InstancedMesh* batch) @private {
    float height = max(2 * ocean.growth.y, MIN_NODE_HEIGHT);
    int half = (int)(ocean.chunks * OCEAN_CHUNK_CELLS / 2);
    for (uint level = 0; level < ocean.level_count; level++) {
        uint side = ocean.chunks >> level;
        uint span = OCEAN_CHUNK_CELLS << level;
        float edge = (float)span * desc.cell_size;
        for (uint z = 0; z < side; z++) {
            for (uint x = 0; x < side; x++) {
                // Lattice coordinates in finest cells from the node's centre: integers, so a coarse and a fine vertex
                // at one place compute the same float.
                float first_x = (float)((int)(x * span) - half);
                float first_z = (float)((int)(z * span) - half);
                uint index = ocean.level_offset[level] + z * side + x;
                batch.transforms[index] = {
                    .position = {
                        first_x * desc.cell_size - ocean.growth.x,
                        -0.5f * height,
                        first_z * desc.cell_size - ocean.growth.z,
                    },
                    .rotation = quaternion::IDENTITY,
                    .scale    = { edge + 2 * ocean.growth.x, height, edge + 2 * ocean.growth.z },
                };
                batch.colors[index] = { first_x, first_z, (float)span, 0 };
            }
        }
    }
}

fn void write_ocean_parents(OceanState* ocean, uint[] parents) @private {
    for (uint level = 0; level < ocean.level_count; level++) {
        uint side = ocean.chunks >> level;
        bool top = level + 1 == ocean.level_count;
        for (uint z = 0; z < side; z++) {
            for (uint x = 0; x < side; x++) {
                uint index = ocean.level_offset[level] + z * side + x;
                if (top) {
                    parents[index] = scene::QUADTREE_ROOT;
                } else {
                    uint parent_side = side >> 1;
                    parents[index] = ocean.level_offset[level + 1] + (z >> 1) * parent_side + (x >> 1);
                }
            }
        }
    }
}

// Indexed by depth: the root is depth 0.
fn void ocean_levels(OceanState* ocean, WaterDesc* desc, QuadtreeLevel[] levels) @private {
    float height = max(2 * ocean.growth.y, MIN_NODE_HEIGHT);
    for (uint level = 0; level < ocean.level_count; level++) {
        float edge = (float)(OCEAN_CHUNK_CELLS << level) * desc.cell_size;
        float width = edge + 2 * ocean.growth.x;
        levels[ocean.level_count - 1 - level] = {
            .extent   = edge,
            .diagonal = math::sqrt(2 * width * width + height * height),
        };
    }
}

fn void? install_ocean(Scene* scene, Node* node, OceanState* ocean, WaterDesc* desc) @private {
    @pool() {
        uint[] parents = alloc::new_array(tmem, uint, (sz)ocean_node_count(ocean));
        write_ocean_parents(ocean, parents);
        scene.set_instance_quadtree(
            node:         node,
            parents:      parents,
            split_pixels: OCEAN_LOD_THRESHOLD,
            hysteresis:   OCEAN_LOD_HYSTERESIS,
        )!;
    };
    QuadtreeLevel[MAX_OCEAN_LEVELS] storage;
    QuadtreeLevel[] levels = storage[:ocean.level_count];
    ocean_levels(ocean, desc, levels);
    return scene.set_quadtree_ranges(node, levels, OCEAN_MORPH_BAND);
}

// All or nothing: a fault leaves the node without the batch.
fn void? add_ocean_batch(
    Scene* scene,
    Node* node,
    OceanState* ocean,
    WaterDesc* desc,
    GeometryId surface,
    MaterialId material,
    float envelope,
) @private {
    uint count = ocean_node_count(ocean);
    Transform[]? transforms = alloc::new_array_try(scene.allocator, Transform, (sz)count);
    if (catch transforms) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(scene.allocator, transforms.ptr);
    Vec4[]? colors = alloc::new_array_try(scene.allocator, Vec4, (sz)count);
    if (catch colors) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(scene.allocator, colors.ptr);

    ocean.growth = surface_reach(desc, desc.waves[:desc.wave_count], envelope);
    InstancedMesh batch = {
        .geometry       = surface,
        .material       = material,
        .transforms     = transforms,
        .colors         = colors,
        .count          = count,
        .receive_shadow = true,
        .revision       = 1,
    };
    write_ocean_records(ocean, desc, &batch);
    scene.add(node, batch);
    defer catch scene.remove_component(node, InstancedMesh);

    return install_ocean(scene, node, ocean, desc);
}

// The boxes and ranges follow the waves; steady frames and unchanged bounds write and upload nothing.
fn void place_ocean_bounds(
    Scene* scene,
    Node* node,
    OceanState* ocean,
    WaterDesc* desc,
    Wave[] waves,
    float envelope,
) @private {
    Vec3 growth = surface_reach(desc, waves, envelope);
    if (growth == ocean.growth) return;

    ocean.growth = growth;
    write_ocean_records(ocean, desc, scene.get(node, InstancedMesh));
    scene.mark_instances_dirty(node);

    QuadtreeLevel[MAX_OCEAN_LEVELS] storage;
    QuadtreeLevel[] levels = storage[:ocean.level_count];
    ocean_levels(ocean, desc, levels);
    // The levels come from a checked desc and the batch's own depth count: they cannot fault.
    scene.set_quadtree_ranges(node, levels, OCEAN_MORPH_BAND)!!;
}

fn double[<2>] ocean_anchor(Scene* scene, Node* node) @private {
    Vec3 position = maths::translation(node.world);
    return { (double)position.x + scene.world_shift.x, (double)position.z + scene.world_shift.z };
}

// Compares the node's absolute position with the last fold; a shift of the world counts as a move of the node.
fn OceanMove ocean_move(Scene* scene, Node* node, WaterRuntime* runtime) @private {
    if (runtime.desc.mode != WaterMode.OCEAN) return {};

    double[<2>] anchor = ocean_anchor(scene, node);
    double[<2>] delta = anchor - runtime.ocean.anchor;
    if (delta.x == 0 && delta.y == 0) return {};

    runtime.ocean.anchor = anchor;
    return { .moved = true, .inverse = maths::inverse_affine(node.world), .delta = delta };
}

// Cycles a wave's phase gains when the anchor moves by delta: the world gradient of the local phase times delta.
// The gradient is the node's inverse linear part applied to the direction, so scale and a turn about Y are included.
fn double anchor_cycles(WaveGpu* wave, Mat4 inverse, double[<2>] delta) @private {
    double gradient_x = (double)wave.direction.x * (double)inverse.m00 + (double)wave.direction.y * (double)inverse.m20;
    double gradient_z = (double)wave.direction.x * (double)inverse.m02 + (double)wave.direction.y * (double)inverse.m22;
    return (gradient_x * delta.x + gradient_z * delta.y) * (double)wave.cycles_per_metre;
}

fn void anchor_waves(WaveGpu[] waves, Mat4 inverse, double[<2>] delta) @private {
    foreach (&wave : waves) {
        double cycles = anchor_cycles(wave, inverse, delta) + (double)wave.phase_offset;
        wave.phase_offset = (float)(cycles - math::floor(cycles));
    }
}

// An edit keeps the offset of a wave whose direction and wavelength it left alone; a changed wave anchors from zero.
fn void anchor_changed_waves(
    WaterParams* params,
    WaterParams* before,
    Mat4 inverse,
    double[<2>] anchor,
) @private {
    foreach (index, &wave : params.waves[:params.wave_count]) {
        bool kept = index < before.wave_count
            && wave.direction == before.waves[index].direction
            && wave.cycles_per_metre == before.waves[index].cycles_per_metre;
        if (kept) continue;

        wave.phase_offset = 0;
        anchor_waves(wave[:1], inverse, anchor);
    }
    params.previous = params.waves;
}

// The ripples sample the node-local rest position, so a move adds its local image to each layer's scroll,
// in that layer's coordinates.
fn void anchor_ripples(
    AssetStore* assets,
    WaterRuntime* runtime,
    WaterParams* params,
    OceanMove move,
) @private {
    if (!runtime.desc.ripples.generation) return;

    Mat4 inverse = move.inverse;
    float local_x = (float)((double)inverse.m00 * move.delta.x + (double)inverse.m02 * move.delta.y);
    float local_z = (float)((double)inverse.m20 * move.delta.x + (double)inverse.m22 * move.delta.y);
    Vec2 second = second_layer_coordinates({ local_x, local_z });
    Vec4 shifted = params.scroll_origin + (Vec4){ local_x, local_z, second.x, second.y };
    params.scroll_origin = wrap_scroll(assets, runtime.desc.ripples, shifted);
}
