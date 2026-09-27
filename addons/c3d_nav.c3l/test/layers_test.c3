module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const uint  LAYER_FLOOR_SIDE @private = 12;
const uint  BRIDGE_MIN_X @private = 3;
const uint  BRIDGE_MAX_X @private = 8;
const uint  BRIDGE_MIN_Z @private = 5;
const uint  BRIDGE_MAX_Z @private = 6;
const uint  BRIDGE_BOTTOM @private = 9; // voxels; eight above the floor, clear of the three-voxel agent
const int   LAYER_TILE_X @private = 1;
const int   LAYER_TILE_Z @private = 2;
const usz   LAYER_VERSION_BYTE @private = 4; // LayerHeader.version starts after the four-byte magic
const usz   LAYER_BUILD_BYTES @private = 2 * 1024 * 1024;
const char  MARKING_LAYER_SIDE @private = 16;
const usz   MARKING_LAYER_CELLS @private = (usz)MARKING_LAYER_SIDE * MARKING_LAYER_SIDE;
const Vec3  MARKING_BOX_CENTRE @private = { 8, 0, 8 };
const Vec3  MARKING_BOX_HALF_EXTENTS @private = { 4, 1, 1 };
const usz   MARKING_DIAGONAL_X @private = 10; // two cells along +X and -Z from the centre
const usz   MARKING_DIAGONAL_Z @private = 6;

// A 12 by 12 floor one voxel thick; with a bridge, a walkable deck crosses it at BRIDGE_BOTTOM.
fn void layer_floor(CompactFixture* fixture, bool bridge) @private {
    fixture.field = heightfield(
        width:       LAYER_FLOOR_SIDE,
        height:      LAYER_FLOOR_SIDE,
        layers:      COMPACT_FIXTURE_LAYERS,
        cell_size:   1,
        cell_height: 1,
    );
    for (uint z = 0; z < LAYER_FLOOR_SIDE; z++) {
        for (uint x = 0; x < LAYER_FLOOR_SIDE; x++) {
            fixture.field.add_span(
                x:               x,
                z:               z,
                min:             0,
                max:             1,
                area:            nav::WALKABLE_AREA,
                merge_threshold: 0,
            )!!;
            if (!bridge || x < BRIDGE_MIN_X || x > BRIDGE_MAX_X || z < BRIDGE_MIN_Z || z > BRIDGE_MAX_Z) continue;
            fixture.field.add_span(
                x:               x,
                z:               z,
                min:             BRIDGE_BOTTOM,
                max:             BRIDGE_BOTTOM + 1,
                area:            nav::WALKABLE_AREA,
                merge_threshold: 0,
            )!!;
        }
    }
    compact_fixture_field(fixture);
}

fn HeightfieldLayer[] fixture_layers(CompactFixture* fixture) @private {
    return nav::build_heightfield_layers(
        allocator:       &fixture.arena,
        scratch:         &fixture.arena,
        compact:         &fixture.compact,
        border_size:     0,
        walkable_height: FIXTURE_WALKABLE_HEIGHT,
    )!!;
}

// A flat walkable layer in the cells, heights 0, with no links.
fn TileCacheLayer marking_layer(LayerHeader* header, char[] cells) @private {
    TileCacheLayer layer = {
        .header      = header,
        .heights     = cells[:MARKING_LAYER_CELLS],
        .areas       = cells[MARKING_LAYER_CELLS:MARKING_LAYER_CELLS],
        .connections = cells[MARKING_LAYER_CELLS * 2:MARKING_LAYER_CELLS],
        .regions     = cells[MARKING_LAYER_CELLS * 3:MARKING_LAYER_CELLS],
    };
    layer.areas[..] = nav::WALKABLE_AREA;
    return layer;
}

fn bool contains_area(char[] areas, char area) @private {
    foreach (candidate : areas) {
        if (candidate == area) return true;
    }
    return false;
}

// The layer path of the job's rasterized tile, in the arena, packed as a TileMesh blob.
fn char[] build_layer_tile_mesh(ArenaAllocator* arena, TileJob* job) @private {
    TileConfig* config = &job.config;
    CompactHeightfield compact = nav::build_compact_heightfield(
        allocator:       arena,
        heightfield:     &job.heightfield,
        walkable_height: config.walkable_height,
        walkable_climb:  config.walkable_climb,
    )!!;
    compact.erode_walkable_area(arena, config.walkable_radius)!!;
    HeightfieldLayer[] layers = nav::build_heightfield_layers(
        allocator:       arena,
        scratch:         arena,
        compact:         &compact,
        border_size:     config.border_size,
        walkable_height: config.walkable_height,
    )!!;
    assert(layers.len == 1);

    char[] blob = alloc::alloc_array(arena, char, (sz)nav::layer_blob_size(&layers[0]));
    nav::build_tile_cache_layer(
        layer:      &layers[0],
        tile_x:     job.tile_x,
        tile_z:     job.tile_z,
        tile_layer: 0,
        blob:       blob,
    );
    char[] scratch = alloc::alloc_array(arena, char, (sz)layers[0].width * layers[0].height * 4);
    TileCacheLayer layer = nav::read_tile_cache_layer(blob, scratch)!!;
    layer.build_regions(arena, config.walkable_climb)!!;
    LayerContourSet contours = nav::build_tile_cache_contours(
        allocator:      arena,
        scratch:        arena,
        layer:          &layer,
        walkable_climb: config.walkable_climb,
        max_error:      config.max_simplification_error,
    )!!;
    LayerPolyMesh mesh = nav::build_tile_cache_poly_mesh(arena, arena, &contours)!!;
    char[] packed = alloc::alloc_array(arena, char, (sz)nav::layer_tile_mesh_size(&mesh));
    nav::pack_layer_tile_mesh(
        mesh:        &mesh,
        header:      layer.header,
        cell_size:   config.cell_size,
        cell_height: config.cell_height,
        blob:        packed,
    );
    return packed;
}

fn void test_layers_split_an_overpass_into_two() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    layer_floor(fixture, bridge: false);
    defer destroy_compact_fixture(fixture);
    assert(fixture_layers(fixture).len == 1, "a flat floor is one layer");

    destroy_compact_fixture(fixture);
    layer_floor(fixture, bridge: true);
    HeightfieldLayer[] layers = fixture_layers(fixture);

    assert(layers.len == 2);
    HeightfieldLayer* low = layers[0].hmin < layers[1].hmin ? &layers[0] : &layers[1];
    HeightfieldLayer* high = low == &layers[0] ? &layers[1] : &layers[0];
    assert(low.hmax < high.hmin, "the height ranges do not overlap");
    for (uint z = BRIDGE_MIN_Z; z <= BRIDGE_MAX_Z; z++) {
        for (uint x = BRIDGE_MIN_X; x <= BRIDGE_MAX_X; x++) {
            usz cell = (usz)(x + z * low.width);
            assert(low.heights[cell] != 0xff && high.heights[cell] != 0xff, "cell %d %d is in both layers", x, z);
            assert(low.hmin + low.heights[cell] < high.hmin + high.heights[cell]);
        }
    }
    assert(high.min_x == BRIDGE_MIN_X && high.max_x == BRIDGE_MAX_X);
    assert(high.min_z == BRIDGE_MIN_Z && high.max_z == BRIDGE_MAX_Z);
}

fn void test_layer_blob_round_trips() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    layer_floor(fixture, bridge: true);
    defer destroy_compact_fixture(fixture);
    HeightfieldLayer[] layers = fixture_layers(fixture);

    foreach (index, &layer : layers) {
        char[] blob = mem::new_array(char, (sz)nav::layer_blob_size(layer));
        defer free(blob);
        char[] scratch = mem::new_array(char, (sz)layer.width * layer.height * 4);
        defer free(scratch);
        nav::build_tile_cache_layer(
            layer:      layer,
            tile_x:     LAYER_TILE_X,
            tile_z:     LAYER_TILE_Z,
            tile_layer: (int)index,
            blob:       blob,
        );

        TileCacheLayer read = nav::read_tile_cache_layer(blob, scratch)!!;

        LayerHeader* header = read.header;
        assert(header.tile_x == LAYER_TILE_X && header.tile_z == LAYER_TILE_Z && header.tile_layer == (int)index);
        assert(header.hmin == layer.hmin && header.hmax == layer.hmax);
        assert(header.bounds.min == layer.bounds.min && header.bounds.max == layer.bounds.max);
        assert(header.width == layer.width && header.max_x == layer.max_x && header.max_z == layer.max_z);
        assert(same_bytes(read.heights, layer.heights));
        assert(same_bytes(read.areas, layer.areas));
        assert(same_bytes(read.connections, layer.connections));

        blob[LAYER_VERSION_BYTE] ^= 0xff;
        assert(@catch(nav::read_tile_cache_layer(blob, scratch)) == nav::LAYER_CORRUPTED);
        blob[LAYER_VERSION_BYTE] ^= 0xff;
        assert(@catch(nav::read_tile_cache_layer(blob[:blob.len - 1], scratch)) == nav::LAYER_CORRUPTED);
    }
}

fn void test_layer_regions_contours_and_mesh_match_the_direct_build() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    add_plane(fixture, { tile, tile }, { tile * 0.5f, 0, tile * 0.5f });
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    TileJob* job = rasterize(fixture);
    nav::build_tile(job)!!;
    TileMeshView direct = nav::tile_mesh_view(job.output);

    char[] buffer = mem::new_array(char, LAYER_BUILD_BYTES);
    defer free(buffer);
    ArenaAllocator arena;
    arena.init(buffer);
    TileMeshView cached = nav::tile_mesh_view(build_layer_tile_mesh(&arena, job));

    assert(direct.header.poly_count > 0);
    assert(cached.header.poly_count == direct.header.poly_count);
    foreach (area : direct.areas) assert(contains_area(cached.areas, area));
    foreach (area : cached.areas) assert(contains_area(direct.areas, area));
}

fn void test_oriented_box_marks_a_rotated_footprint() @test {
    LayerHeader header = { .width = MARKING_LAYER_SIDE, .height = MARKING_LAYER_SIDE };
    char[MARKING_LAYER_CELLS * 4] rotated_cells;
    char[MARKING_LAYER_CELLS * 4] aligned_cells;
    TileCacheLayer rotated = marking_layer(&header, rotated_cells[..]);
    TileCacheLayer aligned = marking_layer(&header, aligned_cells[..]);

    rotated.mark_oriented_box_area(
        origin:       { 0, 0, 0 },
        cell_size:    1,
        cell_height:  1,
        centre:       MARKING_BOX_CENTRE,
        half_extents: MARKING_BOX_HALF_EXTENTS,
        rotation:     nav::yaw_rotation((float)math::PI / 4),
        area:         nav::NULL_AREA,
    );
    aligned.mark_oriented_box_area(
        origin:       { 0, 0, 0 },
        cell_size:    1,
        cell_height:  1,
        centre:       MARKING_BOX_CENTRE,
        half_extents: MARKING_BOX_HALF_EXTENTS,
        rotation:     nav::yaw_rotation(0),
        area:         nav::NULL_AREA,
    );

    // A yaw about +Y turns the box's long X axis towards -Z.
    usz diagonal = MARKING_DIAGONAL_X + MARKING_DIAGONAL_Z * MARKING_LAYER_SIDE;
    usz centre = (usz)(MARKING_BOX_CENTRE.x + MARKING_BOX_CENTRE.z * MARKING_LAYER_SIDE);
    assert(rotated.areas[centre] == nav::NULL_AREA && aligned.areas[centre] == nav::NULL_AREA);
    assert(rotated.areas[diagonal] == nav::NULL_AREA);
    assert(aligned.areas[diagonal] == nav::WALKABLE_AREA);
}
