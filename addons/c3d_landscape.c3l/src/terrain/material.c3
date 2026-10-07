module c3d::landscape::terrain;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::landscape @public;
import c3d::material;
import c3d::maths;
import c3d::scene;
import std::math;

const uint HEIGHT_SLOT @private = 0; // mirrored as TERRAIN_HEIGHT_SLOT in landscape/terrain_height.glsl
const uint CONTROL_SLOT @private = 1; // mirrored as TERRAIN_CONTROL_SLOT in landscape/terrain_height.glsl
const uint SKIRT_EDGES @private = 4;
const uint QUAD_INDICES @private = 6;
const String SHADER_KEY @private = "c3d_landscape/terrain_shader";
const String GRID_KEY @private = "c3d_landscape/terrain_grid";

struct TerrainParams @private {
    uint  texels; // mirrored as TerrainParams in landscape/terrain_height.glsl
    float cell_size;
    float height_scale;
    uint  layer_count;
}

$assert TerrainParams::size == 16;

// Descs come from files as well as code, so every value check is a fault; negated so NaN faults too.
fn uint? check_terrain_desc(AssetStore* assets, TerrainDesc* desc) @private {
    if (!(desc.cell_size > 0) || !(desc.height_scale > 0)) return c3d::INVALID_ARGUMENT~;
    if (!(desc.lod_threshold >= 0) || !(desc.lod_hysteresis >= 0)) return c3d::INVALID_ARGUMENT~;
    if (!assets.textures.is_live(desc.height_map)) return c3d::INVALID_ID~;
    check_height_map(assets.texture(desc.height_map))!;
    if (desc.control_map.generation) {
        if (!assets.textures.is_live(desc.control_map)) return c3d::INVALID_ID~;
        // The stage samples weights through the float heap, unconverted.
        if (assets.texture(desc.control_map).desc.format != RGBA8_UNORM) return c3d::UNSUPPORTED~;
    }
    uint layer_count;
    foreach (layer : desc.layers) {
        if (!layer.generation) break;
        if (!assets.materials.is_live(layer)) return c3d::INVALID_ID~;
        if (assets.material(layer).data.kind != MaterialKind.STANDARD) return c3d::INVALID_ARGUMENT~;
        layer_count++;
    }
    if (!layer_count) return c3d::INVALID_ARGUMENT~;
    foreach (layer : desc.layers[layer_count..]) {
        if (layer.generation) return c3d::INVALID_ARGUMENT~;
    }
    return layer_count;
}

// One shader per store: every terrain shares its pipelines.
fn ShaderId? terrain_shader(AssetStore* assets, bool* created = null) @private {
    if (created) *created = false;
    if (try found = assets.find_shader(SHADER_KEY)) return found;
    ShaderDesc desc = {
        .fragment         = landscape::TERRAIN_FRAGMENT_SPIRV[..],
        .gbuffer          = landscape::TERRAIN_GBUFFER_SPIRV[..],
        .traced_fragment  = {
            .hardware = landscape::TERRAIN_FRAGMENT_RT_SHADOWS_SPIRV[..],
            .software = landscape::TERRAIN_FRAGMENT_RT_SHADOWS_SCENE_TRACE_BVH_SPIRV[..],
        },
        .vertex           = {
            .shaded             = landscape::TERRAIN_VERTEX_SPIRV[..],
            .depth              = landscape::TERRAIN_VERTEX_DEPTH_ONLY_SPIRV[..],
            .instanced_shaded   = landscape::TERRAIN_VERTEX_INSTANCED_SPIRV[..],
            .instanced_depth    = landscape::TERRAIN_VERTEX_DEPTH_ONLY_INSTANCED_SPIRV[..],
            .velocity           = landscape::TERRAIN_VERTEX_VELOCITY_SPIRV[..],
            .instanced_velocity = landscape::TERRAIN_VERTEX_INSTANCED_VELOCITY_SPIRV[..],
        },
        .param_block_size = TerrainParams::size,
    };
    ShaderId shader = assets.add_shader(&desc, SHADER_KEY)!;
    if (created) *created = true;
    return shader;
}

// One grid per store: CHUNK_CELLS is fixed, so every terrain draws the same chunk.
fn GeometryId? terrain_grid(AssetStore* assets, bool* created = null) @private {
    if (created) *created = false;
    if (try found = assets.find_geometry(GRID_KEY)) return found;
    GeometryId grid;
    @pool() {
        Geometry geometry = grid_geometry(tmem);
        grid = assets.add_geometry(&geometry, GRID_KEY)!;
    };
    if (created) *created = true;
    return grid;
}

// The vertex stage reads y = 0 as a skirt vertex under the grid vertex of the same x and z.
fn Geometry grid_geometry(Allocator allocator) @private {
    uint row = CHUNK_CELLS + 1;
    uint surface = row * row;
    uint quads = CHUNK_CELLS * CHUNK_CELLS + SKIRT_EDGES * CHUNK_CELLS;
    Geometry grid = {
        .topology  = TRIANGLES,
        .positions = alloc::new_array(allocator, Vec3, (sz)(surface + SKIRT_EDGES * row)),
        .indices   = alloc::new_array(allocator, uint, (sz)(QUAD_INDICES * quads)),
    };
    for (uint z = 0; z < row; z++) {
        for (uint x = 0; x < row; x++) {
            grid.positions[z * row + x] = { (float)x / CHUNK_CELLS, 1, (float)z / CHUNK_CELLS };
        }
    }
    usz slot;
    for (uint z = 0; z < CHUNK_CELLS; z++) {
        for (uint x = 0; x < CHUNK_CELLS; x++) {
            uint corner = z * row + x;
            // Diagonal from (x + 1, z) to (x, z + 1): box3d's height-field split, counter-clockwise from above.
            uint[QUAD_INDICES] quad = { corner, corner + row, corner + 1, corner + 1, corner + row, corner + row + 1 };
            grid.indices[slot : QUAD_INDICES] = quad[..];
            slot += QUAD_INDICES;
        }
    }
    for (uint edge = 0; edge < SKIRT_EDGES; edge++) {
        uint first_skirt = surface + edge * row;
        for (uint step = 0; step < row; step++) {
            uint top = edge_vertex(edge, step);
            Vec3 above = grid.positions[top];
            grid.positions[first_skirt + step] = { above.x, 0, above.z };
        }
        for (uint step = 0; step < CHUNK_CELLS; step++) {
            uint top = edge_vertex(edge, step);
            uint next_top = edge_vertex(edge, step + 1);
            uint bottom = first_skirt + step;
            // Walking counter-clockwise from above, each quad faces out of the chunk.
            uint[QUAD_INDICES] quad = { top, next_top, bottom, next_top, bottom + 1, bottom };
            grid.indices[slot : QUAD_INDICES] = quad[..];
            slot += QUAD_INDICES;
        }
    }
    grid.finalize();
    return grid;
}

fn uint edge_vertex(uint edge, uint step) @private {
    uint row = CHUNK_CELLS + 1;
    switch (edge) {
        case 0: return step;
        case 1: return step * row + CHUNK_CELLS;
        case 2: return CHUNK_CELLS * row + CHUNK_CELLS - step;
        default: return (CHUNK_CELLS - step) * row;
    }
}

fn MaterialId? add_terrain_material(
    AssetStore* assets,
    ShaderId shader,
    TerrainDesc* desc,
    uint layer_count,
) @private {
    TerrainParams params = {
        .texels       = assets.texture(desc.height_map).desc.width,
        .cell_size    = desc.cell_size,
        .height_scale = desc.height_scale,
        .layer_count  = layer_count,
    };
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
    slots[HEIGHT_SLOT] = material::texture_slot(desc.height_map);
    if (desc.control_map.generation) {
        slots[CONTROL_SLOT] = material::texture_slot(
            texture: desc.control_map,
            sampler: asset::SAMPLER_LINEAR_CLAMP,
            uv_set:  1,
        );
    }
    return assets.add_material(material::custom(
        shader:      shader,
        param_block: material::@as_bytes(params),
        slots:       slots,
        references:  desc.layers,
    ));
}

fn InstancedMesh? create_batch(
    Allocator allocator,
    GeometryId grid,
    MaterialId owned,
    uint capacity,
    TerrainDesc* desc,
) @private {
    Transform[]? transforms = alloc::new_array_try(allocator, Transform, (sz)capacity);
    if (catch transforms) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(allocator, transforms.ptr);
    Vec4[]? colors = alloc::new_array_try(allocator, Vec4, (sz)capacity);
    if (catch colors) return c3d::CAPACITY_EXCEEDED~;
    return {
        .geometry       = grid,
        .material       = owned,
        .transforms     = transforms,
        .colors         = colors,
        .cast_shadow    = desc.cast_shadow,
        .receive_shadow = desc.receive_shadow,
        .trace          = false,
        .revision       = 1,
    };
}
