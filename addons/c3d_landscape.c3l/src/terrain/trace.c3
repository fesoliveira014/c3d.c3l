module c3d::landscape::terrain;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::scene;
import std::math;

const String TRACE_GRID_KEY_PREFIX @private = "c3d_landscape/terrain_trace_grid";
const String TRACE_GRID_NAME @private = "terrain_trace";

// A grid is one dispatch of one thread per vertex, so the device's group limit caps it.
fn void? check_trace_grid(TerrainDesc* desc, uint texels) @private {
    if (!desc.trace) return;

    if (desc.trace_level >= level_count_of(texels)!) return c3d::INVALID_ARGUMENT~;

    uint side = ((texels - 1) >> desc.trace_level) + 1;
    if (side * side > MAX_TRACE_VERTICES) return c3d::INVALID_ARGUMENT~;
}

// Vertices along one edge of the trace grid: one per 2^trace_level texels, and both ends.
fn uint trace_side(TerrainRuntime* runtime) @private => ((runtime.texels - 1) >> runtime.trace_level) + 1;

// One grid per side length and store: the trace stage reads only each vertex's place in the unit square.
fn GeometryId? terrain_trace_grid(AssetStore* assets, uint side, bool* created = null) @private {
    if (created) *created = false;
    GeometryId grid;
    @pool() {
        String key = string::tformat("%s/%d", TRACE_GRID_KEY_PREFIX, side);
        if (try found = assets.find_geometry(key)) return found;
        Geometry geometry = trace_grid_geometry(tmem, side);
        grid = assets.add_geometry(&geometry, key)!;
    };
    if (created) *created = true;
    return grid;
}

// The normals stream carries the posed normals: a stream the rest geometry lacks is never written.
fn Geometry trace_grid_geometry(Allocator allocator, uint side) @private {
    uint cells = side - 1;
    Geometry grid = {
        .topology  = TRIANGLES,
        .positions = alloc::new_array(allocator, Vec3, (sz)side * side),
        .normals   = alloc::new_array(allocator, Vec3, (sz)side * side),
        .indices   = alloc::new_array(allocator, uint, (sz)QUAD_INDICES * cells * cells),
    };
    for (uint z = 0; z < side; z++) {
        for (uint x = 0; x < side; x++) {
            grid.positions[z * side + x] = { (float)x / cells, 0, (float)z / cells };
            grid.normals[z * side + x] = { 0, 1, 0 };
        }
    }

    usz slot;
    for (uint z = 0; z < cells; z++) {
        for (uint x = 0; x < cells; x++) {
            uint corner = z * side + x;
            // The split of the drawn chunks and of box3d's height field, so the error bound describes this surface.
            uint[QUAD_INDICES] quad = {
                corner, corner + side, corner + 1,
                corner + 1, corner + side, corner + side + 1,
            };
            grid.indices[slot : QUAD_INDICES] = quad[..];
            slot += QUAD_INDICES;
        }
    }

    grid.finalize();
    return grid;
}

// The grid's vertices are texels and its triangles lie between them, so the terrain's own box holds it.
fn Aabb trace_bounds(TerrainRuntime* runtime, TerrainDesc* desc) @private {
    uint root = node_count(runtime) - 1;
    float unit = desc.height_scale / TEXEL_MAX;
    float extent = (float)(runtime.texels - 1) * desc.cell_size;
    float low = (float)runtime.minimum[root] * unit;
    float high = (float)runtime.maximum[root] * unit;
    return {
        .min = { 0, low, 0 },
        .max = { extent, max(high, low + unit), extent },
    };
}

fn Entity? add_trace_grid(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    TerrainRuntime* runtime,
    TerrainDesc* desc,
) @private {
    Node* child = scene.add_node(node, TRACE_GRID_NAME)!;
    defer catch scene.remove(child);
    bool grid_created;
    GeometryId grid = terrain_trace_grid(assets, trace_side(runtime), &grid_created)!;
    defer catch if (grid_created) assets.remove_geometry(grid);

    child.layers = node.layers;
    scene.add(child, (Mesh){
        .geometry            = grid,
        .material            = runtime.material,
        .cast_shadow         = desc.cast_shadow,
        .trace               = true,
        .trace_only          = true,
        .has_bounds_override = true,
        .local_bounds        = trace_bounds(runtime, desc),
    });
    return child.id;
}

// The fragment stage reads the gaps to raise its proxy skip height; an unchanged block uploads nothing.
fn void publish_trace_params(AssetStore* assets, TerrainRuntime* runtime) @private {
    TerrainParams* params = assets.@custom_params(runtime.material, TerrainParams);
    if (params.trace_error == runtime.trace_error && params.drawn_deviation == runtime.drawn_deviation) return;

    params.trace_error = runtime.trace_error;
    params.drawn_deviation = runtime.drawn_deviation;
    assets.mark_material_dirty(runtime.material);
}

fn void sync_trace_grid(Scene* scene, Node* node, TerrainRuntime* runtime, TerrainDesc* desc) @private {
    Node* child = scene.node(runtime.trace_grid);
    Mesh* mesh = scene.get(child, Mesh);

    child.layers = node.layers;
    mesh.cast_shadow = desc.cast_shadow;
    mesh.local_bounds = trace_bounds(runtime, desc);
}

// update runs after the frame's world update, so the flag the trace reads is set here too.
fn void show_trace_grid(Scene* scene, Node* node, TerrainRuntime* runtime, bool shown) @private {
    Node* child = scene.node(runtime.trace_grid);
    child.visible = shown;
    child.visible_effective = shown && node.visible_effective;
}
