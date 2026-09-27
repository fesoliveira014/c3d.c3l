module c3d::nav;

import std::math;
import c3d;

<*
 Floors of one grid cell, bottom to top.
 @param [out] out_floors : "MAX_GRID_FLOORS entries."
 @return "How many floors were written; 0 for an empty or out-of-map cell."
*>
alias GridFloorsFn = fn usz (void* context, int cell_x, int cell_z, GridFloor[] out_floors);

<* Floors one grid cell may hold. *>
const uint MAX_GRID_FLOORS = 16; // 16 * 12 bytes of stack per cell query; a voxel column with 15 overhangs

<* Arena of one grid tile build; the blob of the last build lives in it. *>
const usz DEFAULT_GRID_SCRATCH_BYTES = 256 * 1024; // once per builder; a busy default tile peaks at 123 KiB

const float        GRID_CELL_HEIGHT @local = 0.05f; // metres; flat floors quantize to this step
const uint         GRID_SPANS_PER_COLUMN @local = 2 * MAX_GRID_FLOORS; // 256 bytes per column; no build grows the pool
const ContourFlags GRID_CONTOUR_FLAGS @local = { .tessellate_wall_edges = true, .refine_region_edges = true };

<* One walkable or blocking surface of a grid cell. *>
struct GridFloor {
    float height;     // world Y of the top of the solid below the surface
    float ceiling;    // world Y of the next solid above; float::max when open to the next floor or the sky
    char  area;       // WALKABLE_AREA or a custom area id; NULL_AREA blocks without being walkable
}

<* Where the grid lies and how to read it. *>
struct GridSourceDesc {
    Vec3         origin;          // world XZ of the minimum corner of cell (0, 0); its Y is unused
    float        min_height;      // world Y range every floor and ceiling lies in
    float        max_height;
    GridFloorsFn floors;
    void*        context;
}

<* Heightfield and arena reused by every grid tile build. *>
struct GridTileBuilder {
    Allocator      allocator;
    NavBuildConfig config;
    TileConfig     tile_config;
    GridSourceDesc source;
    Heightfield    heightfield;
    char[]         scratch;
    ArenaAllocator arena;
}

<*
 Build the TileMesh blob of one tile; empty when nothing is walkable.
 Invalidates the blob of the previous build.
 @return? c3d::CAPACITY_EXCEEDED
*>
fn char[]? GridTileBuilder.build(&self, int tile_x, int tile_z) {
    self.arena.clear();
    Allocator arena = &self.arena;
    TileConfig* config = &self.tile_config;
    Heightfield* heightfield = &self.heightfield;
    heightfield.bounds = window_bounds(self, tile_x, tile_z);
    heightfield.reset();
    add_floor_spans(self, tile_x, tile_z)!;
    heightfield.filter_walkable_low_height_spans(config.walkable_height);

    CompactHeightfield compact = build_compact_heightfield(
        allocator:       arena,
        heightfield:     heightfield,
        walkable_height: config.walkable_height,
        walkable_climb:  config.walkable_climb,
    )!;
    if (compact.span_count == 0) return {};
    if (config.walkable_radius > 0) compact.erode_walkable_area(arena, config.walkable_radius)!;
    // Without a detail mesh a polygon's height comes from its outline, so each region keeps one floor height;
    // the links return for the contours, which keep every corner of a step and join the regions across it.
    CompactLinks[] links = unlink_height_changes(&compact, arena)!;
    compact.build_regions_monotone(
        scratch:           arena,
        border_size:       config.border_size,
        min_region_area:   config.min_region_area,
        merge_region_area: config.merge_region_area,
    )!;
    foreach (index, span_links : links) compact.spans[index].links = span_links;

    ContourSet contours = build_contours(
        allocator:       arena,
        scratch:         arena,
        compact:         &compact,
        max_error:       config.max_simplification_error,
        max_edge_length: config.max_edge_length,
        flags:           GRID_CONTOUR_FLAGS,
    )!;
    if (contours.contours.len == 0) return {};
    // Regions meet on the tile border at steps, so those corners stay instead of being removed as redundant.
    foreach (&contour : contours.contours) {
        for (usz flag_word = 3; flag_word < contour.verts.len; flag_word += 4) contour.verts[flag_word] &= ~BORDER_VERTEX;
    }
    PolyMesh mesh = build_poly_mesh(
        allocator:      arena,
        scratch:        arena,
        contours:       &contours,
        verts_per_poly: config.verts_per_poly,
    )!;
    if (mesh.poly_count == 0) return {};

    char[]? blob = alloc::alloc_array_try(arena, char, (sz)tile_mesh_size(&mesh));
    if (catch blob) return c3d::CAPACITY_EXCEEDED~;
    pack_tile_mesh(
        mesh:   &mesh,
        tile_x: tile_x,
        tile_z: tile_z,
        blob:   blob,
    );
    return blob;
}

<*
 World bounds of a tile, without the border; Y spans min_height to max_height.
*>
fn Aabb GridTileBuilder.tile_bounds(&self, int tile_x, int tile_z) {
    float tile_world_size = self.config.tile_size * self.config.cell_size;
    Vec3 origin = self.source.origin;
    return {
        .min = {
            origin.x + (float)tile_x * tile_world_size,
            self.source.min_height,
            origin.z + (float)tile_z * tile_world_size,
        },
        .max = {
            origin.x + (float)(tile_x + 1) * tile_world_size,
            self.source.max_height,
            origin.z + (float)(tile_z + 1) * tile_world_size,
        },
    };
}

<*
 Mesh layout matching the builder's tiles.
*>
fn NavMeshDesc GridTileBuilder.mesh_desc(&self, uint max_tiles) {
    float tile_world_size = self.config.tile_size * self.config.cell_size;
    return {
        .origin      = { self.source.origin.x, self.source.min_height, self.source.origin.z },
        .tile_width  = tile_world_size,
        .tile_height = tile_world_size,
        .max_tiles   = max_tiles,
    };
}

<*
 Grid defaults: RecastDemo's agent with 5 cm floor steps, every island kept, walls on cell edges.
 @param cell_size : "Metres; the grid cell."
 @require cell_size > 0
*>
fn NavBuildConfig default_grid_build_config(float cell_size) {
    NavBuildConfig config = default_nav_build_config();
    config.cell_size = cell_size;
    config.cell_height = GRID_CELL_HEIGHT;
    config.region_min_size = 0;
    config.edge_max_error = 0;
    return config;
}

<*
 Builder for tiles of tile_size cells over the grid; allocates the heightfield and arena once.
 @param scratch_bytes : "Arena of one tile build; its blob stays there until the next build."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require source.floors != null, source.max_height > source.min_height
*>
fn GridTileBuilder? create_grid_tile_builder(
    Allocator allocator,
    NavBuildConfig config,
    GridSourceDesc source,
    usz scratch_bytes = DEFAULT_GRID_SCRATCH_BYTES,
) {
    TileConfig tile = tile_config(config)!;
    float top_voxel = 1 + math::round((source.max_height - source.min_height) / config.cell_height);
    if (top_voxel >= (float)SPAN_MAX_HEIGHT) return c3d::INVALID_ARGUMENT~;

    GridTileBuilder builder = {
        .allocator   = allocator,
        .config      = config,
        .tile_config = tile,
        .source      = source,
    };
    builder.heightfield = create_heightfield(
        allocator:     allocator,
        width:         tile.width,
        height:        tile.height,
        bounds:        window_bounds(&builder, 0, 0),
        cell_size:     tile.cell_size,
        cell_height:   tile.cell_height,
        initial_spans: tile.width * tile.height * GRID_SPANS_PER_COLUMN,
    )!;
    defer catch destroy_heightfield(&builder.heightfield);
    char[]? scratch = alloc::alloc_array_try(allocator, char, (sz)scratch_bytes);
    if (catch scratch) return c3d::CAPACITY_EXCEEDED~;
    builder.scratch = scratch;
    builder.arena.init(scratch);
    return builder;
}

<*
 Free the heightfield and the arena.
 @param [&inout] builder : "Left zeroed."
*>
fn void destroy_grid_tile_builder(GridTileBuilder* builder) {
    destroy_heightfield(&builder.heightfield);
    alloc::free(builder.allocator, builder.scratch.ptr);
    *builder = {};
}

// The tile plus its border; the floor lies one voxel below min_height so a floor there is the span [0, 1).
fn Aabb window_bounds(GridTileBuilder* builder, int tile_x, int tile_z) @local {
    float border = builder.tile_config.border_size * builder.config.cell_size;
    Aabb bounds = builder.tile_bounds(tile_x, tile_z);
    bounds.min -= { border, builder.config.cell_height, border };
    bounds.max.x += border;
    bounds.max.z += border;
    return bounds;
}

// Recast reads a surface from its span's top, so a floor is the one voxel under its height.
fn uint quantize_height(GridTileBuilder* builder, float height) @local {
    float voxel = 1 + math::round((height - builder.source.min_height) / builder.config.cell_height);
    return (uint)math::clamp(voxel, 1.0f, (float)SPAN_MAX_HEIGHT);
}

// The links of every span before neighbours at another height were cut.
fn CompactLinks[]? unlink_height_changes(CompactHeightfield* compact, Allocator scratch) @local {
    CompactLinks[]? saved = alloc::new_array_try(scratch, CompactLinks, compact.span_count);
    if (catch saved) return c3d::CAPACITY_EXCEEDED~;
    int width = (int)compact.width;
    for (int z = 0; z < (int)compact.height; z++) {
        for (int x = 0; x < width; x++) {
            CompactCell cell = compact.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                CompactSpan* span = &compact.spans[index];
                saved[index] = span.links;
                for (uint direction = 0; direction < 4; direction++) {
                    uint layer = span.connection(direction);
                    if (layer == NOT_CONNECTED) continue;
                    int neighbour_column = x + dir_offset_x(direction) + (z + dir_offset_z(direction)) * width;
                    CompactSpan* neighbour = &compact.spans[compact.cells[neighbour_column].index + layer];
                    if (neighbour.y != span.y) span.set_connection(direction, NOT_CONNECTED);
                }
            }
        }
    }
    return saved;
}

fn void? add_floor_spans(GridTileBuilder* builder, int tile_x, int tile_z) @local {
    Heightfield* heightfield = &builder.heightfield;
    GridSourceDesc* source = &builder.source;
    int border = (int)builder.tile_config.border_size;
    int first_x = tile_x * (int)builder.config.tile_size - border;
    int first_z = tile_z * (int)builder.config.tile_size - border;
    GridFloor[MAX_GRID_FLOORS] floors;
    for (uint z = 0; z < heightfield.height; z++) {
        for (uint x = 0; x < heightfield.width; x++) {
            usz count = source.floors(source.context, first_x + (int)x, first_z + (int)z, floors[..]);
            foreach (floor : floors[:count]) {
                uint surface = quantize_height(builder, floor.height);
                heightfield.add_span(
                    x:               x,
                    z:               z,
                    min:             surface - 1,
                    max:             surface,
                    area:            floor.area,
                    merge_threshold: 0,
                )!;
                // An open ceiling quantizes to the top of the field and adds nothing.
                uint ceiling = quantize_height(builder, floor.ceiling);
                if (ceiling >= SPAN_MAX_HEIGHT) continue;
                heightfield.add_span(
                    x:               x,
                    z:               z,
                    min:             ceiling,
                    max:             ceiling + 1,
                    area:            NULL_AREA,
                    merge_threshold: 0,
                )!;
            }
        }
    }
}
