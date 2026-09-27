module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const int   GRID_MAP_SIDE @private = 32; // cells; one default tile, two 16-cell or four 8-cell tiles across
const uint  GRID_MAP_FLOORS @private = 2;
const float GRID_MAP_CELL_SIZE @private = 1;
const float GRID_MAP_MIN_HEIGHT @private = 0;
const float GRID_MAP_MAX_HEIGHT @private = 8;
const uint  GRID_MAP_MESH_TILES @private = 16;
const uint  GRID_MAP_QUERY_NODES @private = 1024;
const usz   GRID_MAP_PATH_CAPACITY @private = 128;
const usz   GRID_MAP_POINT_CAPACITY @private = 32;
const Vec3  GRID_MAP_NEAR_EXTENTS @private = { 0.5f, 1, 0.5f };
const float GRID_MAP_TOLERANCE @private = 0.01f;
const uint  SMALL_GRID_TILE @private = 8;
const uint  GRID_TILE @private = 16;
const float BRIDGE_HEIGHT @private = 3;
const float BRIDGE_UNDERSIDE @private = 2.7f;
const float WALL_HEIGHT @private = 2;
const float LOW_NULL_FLOOR @private = 1.5f; // under the 2 m agent above a floor at 0
const float RAISED_FLOOR @private = 0.6f; // one step within the 0.9 m climb

// Floors of a GRID_MAP_SIDE square of cells, read by the builder through grid_map_floors.
struct GridMap @private {
    GridFloor[GRID_MAP_FLOORS][GRID_MAP_SIDE * GRID_MAP_SIDE] floors;
    usz[GRID_MAP_SIDE * GRID_MAP_SIDE]                         counts;
}

struct GridFixture @private {
    GridMap                                map;
    GridTileBuilder                        builder;
    NavMesh                                mesh;
    NavQuery                               query;
    QueryFilter                            filter;
    PolyRef[GRID_MAP_PATH_CAPACITY]        path;
    StraightPoint[GRID_MAP_POINT_CAPACITY] points;
}

fn usz grid_map_floors(
    void* context,
    int cell_x,
    int cell_z,
    GridFloor[] out_floors,
) @private {
    GridMap* map = context;
    if (cell_x < 0 || cell_z < 0 || cell_x >= GRID_MAP_SIDE || cell_z >= GRID_MAP_SIDE) return 0;
    int cell = cell_x + cell_z * GRID_MAP_SIDE;
    usz count = map.counts[cell];
    out_floors[:count] = map.floors[cell][:count];
    return count;
}

fn GridSourceDesc grid_map_source(GridMap* map) @private {
    return {
        .min_height = GRID_MAP_MIN_HEIGHT,
        .max_height = GRID_MAP_MAX_HEIGHT,
        .floors     = &grid_map_floors,
        .context    = map,
    };
}

fn GridFixture* grid_fixture(uint tile_size, float agent_radius) @private {
    GridFixture* fixture = mem::new(GridFixture);
    NavBuildConfig config = nav::default_grid_build_config(GRID_MAP_CELL_SIZE);
    config.tile_size = tile_size;
    config.agent_radius = agent_radius;
    fixture.builder = nav::create_grid_tile_builder(mem, config, grid_map_source(&fixture.map))!!;
    fixture.mesh = nav::create_nav_mesh(mem, fixture.builder.mesh_desc(GRID_MAP_MESH_TILES))!!;
    fixture.query = nav::create_nav_query(mem, &fixture.mesh, GRID_MAP_QUERY_NODES)!!;
    fixture.filter = nav::default_query_filter();
    return fixture;
}

fn void destroy_grid_fixture(GridFixture* fixture) @private {
    nav::destroy_nav_query(&fixture.query);
    nav::destroy_nav_mesh(&fixture.mesh);
    nav::destroy_grid_tile_builder(&fixture.builder);
    free(fixture);
}

// Cells run from x, z of the first to x, z past the last; each gets the floor on top of the ones it holds.
fn void lay_floor(GridMap* map, int[<4>] cells, GridFloor floor) @private {
    for (int z = cells[1]; z < cells[3]; z++) {
        for (int x = cells[0]; x < cells[2]; x++) {
            int cell = x + z * GRID_MAP_SIDE;
            map.floors[cell][map.counts[cell]++] = floor;
        }
    }
}

fn void clear_cells(GridMap* map, int[<4>] cells) @private {
    for (int z = cells[1]; z < cells[3]; z++) {
        for (int x = cells[0]; x < cells[2]; x++) map.counts[x + z * GRID_MAP_SIDE] = 0;
    }
}

fn GridFloor open_floor(float height, char area = nav::WALKABLE_AREA) @private {
    return { .height = height, .ceiling = float::max, .area = area };
}

fn TileMeshView build_grid_tile(GridFixture* fixture, int tile_x, int tile_z) @private {
    return nav::tile_mesh_view(fixture.builder.build(tile_x, tile_z)!!);
}

fn TileRef install_grid_tile(GridFixture* fixture, int tile_x, int tile_z) @private {
    NavBuildConfig config = fixture.builder.config;
    return fixture.mesh.install_tile_mesh(
        tile_mesh:   fixture.builder.build(tile_x, tile_z)!!,
        connections: {},
        params:      {
            .tile_x          = tile_x,
            .tile_z          = tile_z,
            .walkable_height = config.agent_height,
            .walkable_radius = config.agent_radius,
            .walkable_climb  = config.agent_max_climb,
            .build_bv_tree   = true,
        },
    )!!;
}

fn NearestPoly grid_nearest(GridFixture* fixture, Vec3 position) @private {
    return fixture.query.find_nearest_poly(position, GRID_MAP_NEAR_EXTENTS, &fixture.filter)!!;
}

fn PathResult grid_path(GridFixture* fixture, Vec3 from, Vec3 to) @private {
    return fixture.query.find_path(
        start_ref: grid_nearest(fixture, from).ref,
        end_ref:   grid_nearest(fixture, to).ref,
        start:     from,
        end:       to,
        filter:    &fixture.filter,
        out_path:  fixture.path[..],
    )!!;
}

fn bool grid_near(float value, float expected) @private => math::abs(value - expected) <= GRID_MAP_TOLERANCE;

fn Aabb polygon_extent(TileMeshView view) @private {
    Aabb extent = { .min = { float::max, float::max, float::max }, .max = { -float::max, -float::max, -float::max } };
    for (uint poly = 0; poly < view.header.poly_count; poly++) {
        ushort[] indices = view_polygon(view, poly);
        foreach (vertex : indices[:nav::count_poly_verts(indices)]) {
            Vec3 position = world_vertex(view, vertex);
            extent.min = math::min(extent.min, position);
            extent.max = math::max(extent.max, position);
        }
    }
    return extent;
}

fn float polygon_area_sum(TileMeshView view) @private {
    float total;
    for (uint poly = 0; poly < view.header.poly_count; poly++) {
        ushort[] indices = view_polygon(view, poly);
        int count = nav::count_poly_verts(indices);
        float twice_area;
        for (int corner = 0; corner < count; corner++) {
            Vec3 current = world_vertex(view, indices[corner]);
            Vec3 next = world_vertex(view, indices[(corner + 1) % count]);
            twice_area += current.x * next.z - next.x * current.z;
        }
        total += math::abs(twice_area) * 0.5f;
    }
    return total;
}

fn bool extent_is(Aabb extent, float min, float max) @private {
    return grid_near(extent.min.x, min) && grid_near(extent.min.z, min)
        && grid_near(extent.max.x, max) && grid_near(extent.max.z, max);
}

fn void fill_terraces_pillars_and_bridges(GridMap* map) @private {
    for (int z = 0; z < GRID_MAP_SIDE; z++) {
        for (int x = 0; x < GRID_MAP_SIDE; x++) {
            int cell = x + z * GRID_MAP_SIDE;
            float terrace = (float)((x / 4 + z / 4) % 4) * 0.3f;
            if (x % 6 == 0 && z % 6 == 0) {
                map.floors[cell][0] = open_floor(WALL_HEIGHT, nav::NULL_AREA);
                map.counts[cell] = 1;
            } else if (z % 8 == 3) {
                map.floors[cell][0] = { .height = terrace, .ceiling = BRIDGE_UNDERSIDE, .area = nav::WALKABLE_AREA };
                map.floors[cell][1] = open_floor(BRIDGE_HEIGHT);
                map.counts[cell] = 2;
            } else {
                map.floors[cell][0] = open_floor(terrace);
                map.counts[cell] = 1;
            }
        }
    }
}

fn void test_open_grid_tile_yields_one_polygon() @test {
    GridFixture* fixture = grid_fixture(SMALL_GRID_TILE, 0);
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 0, 0, 8, 8 }, open_floor(GRID_MAP_MIN_HEIGHT));

    TileMeshView view = build_grid_tile(fixture, 0, 0);

    assert(view.header.poly_count == 1);
    Aabb extent = polygon_extent(view);
    assert(extent_is(extent, 0, 8));
    assert(grid_near(extent.min.y, GRID_MAP_MIN_HEIGHT) && grid_near(extent.max.y, GRID_MAP_MIN_HEIGHT));
}

fn void test_walls_follow_cell_edges() @test {
    GridFixture* fixture = grid_fixture(GRID_TILE, 0);
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 2, 2, 14, 6 }, open_floor(0));
    lay_floor(&fixture.map, { 2, 6, 6, 14 }, open_floor(0));

    TileMeshView view = build_grid_tile(fixture, 0, 0);

    for (uint vertex = 0; vertex < view.header.vert_count; vertex++) {
        Vec3 position = world_vertex(view, (ushort)vertex);
        assert(grid_near(position.x, math::round(position.x)) && grid_near(position.z, math::round(position.z)));
    }
    assert(grid_near(polygon_area_sum(view), 12 * 4 + 4 * 8));
}

fn void test_step_within_climb_connects() @test {
    GridFixture* fixture = grid_fixture(SMALL_GRID_TILE, 0);
    defer destroy_grid_fixture(fixture);
    float cell_height = fixture.builder.config.cell_height;
    float climb = fixture.builder.tile_config.walkable_climb * cell_height;
    lay_floor(&fixture.map, { 0, 0, 4, 8 }, open_floor(0));
    lay_floor(&fixture.map, { 4, 0, 8, 8 }, open_floor(climb));
    install_grid_tile(fixture, 0, 0);

    PathResult within = grid_path(fixture, { 1.5f, 0, 4 }, { 6.5f, climb, 4 });
    assert(!within.partial);

    clear_cells(&fixture.map, { 4, 0, 8, 8 });
    lay_floor(&fixture.map, { 4, 0, 8, 8 }, open_floor(climb + cell_height));
    install_grid_tile(fixture, 0, 0);

    PathResult beyond = grid_path(fixture, { 1.5f, 0, 4 }, { 6.5f, climb + cell_height, 4 });
    assert(beyond.partial);
}

fn void test_raised_floor_keeps_its_height() @test {
    GridFixture* fixture = grid_fixture(GRID_TILE, GRID_MAP_CELL_SIZE);
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 0, 0, 16, 16 }, open_floor(0));
    clear_cells(&fixture.map, { 6, 6, 10, 10 });
    lay_floor(&fixture.map, { 6, 6, 10, 10 }, open_floor(RAISED_FLOOR));
    install_grid_tile(fixture, 0, 0);

    assert(grid_near(grid_nearest(fixture, { 8, RAISED_FLOOR, 8 }).point.y, RAISED_FLOOR));
    assert(!grid_path(fixture, { 2, 0, 2 }, { 8, RAISED_FLOOR, 8 }).partial);
}

fn void test_bridge_over_a_floor_gives_two_levels() @test {
    GridFixture* fixture = grid_fixture(GRID_TILE, GRID_MAP_CELL_SIZE);
    defer destroy_grid_fixture(fixture);
    GridFloor under_bridge = { .height = 0, .ceiling = BRIDGE_UNDERSIDE, .area = nav::WALKABLE_AREA };
    lay_floor(&fixture.map, { 0, 0, 16, 6 }, open_floor(0));
    lay_floor(&fixture.map, { 0, 6, 16, 10 }, under_bridge);
    lay_floor(&fixture.map, { 0, 10, 16, 16 }, open_floor(0));
    lay_floor(&fixture.map, { 0, 6, 16, 10 }, open_floor(BRIDGE_HEIGHT));
    install_grid_tile(fixture, 0, 0);

    assert(grid_near(grid_nearest(fixture, { 8, BRIDGE_HEIGHT, 8 }).point.y, BRIDGE_HEIGHT));
    assert(grid_near(grid_nearest(fixture, { 8, 0, 8 }).point.y, 0));

    PathResult under = grid_path(fixture, { 8, 0, 2 }, { 8, 0, 14 });
    assert(!under.partial);
    foreach (ref : fixture.path[:under.count]) {
        TileAndPoly found = fixture.mesh.tile_and_poly(ref)!!;
        assert(grid_near(found.tile.verts[found.poly.verts[0]].y, 0));
    }
}

fn void test_low_ceiling_blocks_the_cell() @test {
    GridFixture* fixture = grid_fixture(SMALL_GRID_TILE, 0);
    defer destroy_grid_fixture(fixture);
    NavBuildConfig config = fixture.builder.config;
    GridFloor floor = { .height = 0, .ceiling = config.agent_height, .area = nav::WALKABLE_AREA };
    lay_floor(&fixture.map, { 0, 0, 8, 8 }, floor);

    assert(fixture.builder.build(0, 0)!!.len > 0);

    floor.ceiling = config.agent_height - config.cell_height;
    clear_cells(&fixture.map, { 0, 0, 8, 8 });
    lay_floor(&fixture.map, { 0, 0, 8, 8 }, floor);

    assert(fixture.builder.build(0, 0)!!.len == 0);
}

fn void test_null_area_floor_is_solid_but_not_walkable() @test {
    GridFixture* fixture = grid_fixture(SMALL_GRID_TILE, 0);
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 0, 0, 8, 8 }, open_floor(0));
    lay_floor(&fixture.map, { 0, 0, 8, 8 }, open_floor(BRIDGE_HEIGHT, nav::NULL_AREA));

    Aabb extent = polygon_extent(build_grid_tile(fixture, 0, 0));
    assert(extent_is(extent, 0, 8));
    assert(grid_near(extent.max.y, 0));

    clear_cells(&fixture.map, { 0, 0, 8, 8 });
    lay_floor(&fixture.map, { 0, 0, 8, 8 }, open_floor(0));
    lay_floor(&fixture.map, { 0, 0, 8, 8 }, open_floor(LOW_NULL_FLOOR, nav::NULL_AREA));

    assert(fixture.builder.build(0, 0)!!.len == 0);
}

fn void test_erosion_trims_one_cell_from_walls() @test {
    GridFixture* fixture = grid_fixture(SMALL_GRID_TILE, GRID_MAP_CELL_SIZE);
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 0, 0, 8, 8 }, open_floor(0));

    TileMeshView view = build_grid_tile(fixture, 0, 0);

    assert(extent_is(polygon_extent(view), 1, 7));
    assert(grid_near(polygon_area_sum(view), 6 * 6));
}

fn void test_neighbouring_grid_tiles_link() @test {
    GridFixture* fixture = grid_fixture(SMALL_GRID_TILE, GRID_MAP_CELL_SIZE);
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 0, 0, 16, 8 }, open_floor(0));
    install_grid_tile(fixture, 0, 0);
    install_grid_tile(fixture, 1, 0);

    PathResult across = grid_path(fixture, { 2, 0, 4 }, { 14, 0, 4 });

    assert(!across.partial && across.count > 1);
}

fn void test_rebuilding_an_edited_tile_reroutes() @test {
    GridFixture* fixture = grid_fixture(GRID_TILE, GRID_MAP_CELL_SIZE);
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 0, 0, 16, 16 }, open_floor(0));
    install_grid_tile(fixture, 0, 0);
    Vec3 from = { 4, 0, 4 };
    Vec3 to = { 12, 0, 4 };
    PolyRef before = grid_nearest(fixture, from).ref;

    clear_cells(&fixture.map, { 8, 0, 9, 12 });
    lay_floor(&fixture.map, { 8, 0, 9, 12 }, open_floor(WALL_HEIGHT, nav::NULL_AREA));
    install_grid_tile(fixture, 0, 0);

    assert(!fixture.mesh.is_valid_ref(before));
    PathResult around = grid_path(fixture, from, to);
    assert(!around.partial);
    PathResult points = fixture.query.straight_path(
        start:      from,
        end:        to,
        path:       fixture.path[:around.count],
        out_points: fixture.points[..],
    )!!;
    float furthest_z = from.z;
    foreach (point : fixture.points[:points.count]) furthest_z = math::max(furthest_z, point.position.z);
    assert(furthest_z >= 12);
}

fn void test_grid_tile_fits_the_default_arena() @test {
    GridMap* map = mem::new(GridMap);
    defer free(map);
    fill_terraces_pillars_and_bridges(map);
    NavBuildConfig config = nav::default_grid_build_config(GRID_MAP_CELL_SIZE);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    GridTileBuilder builder = nav::create_grid_tile_builder(&tracker, config, grid_map_source(map))!!;
    defer nav::destroy_grid_tile_builder(&builder);
    sz allocations = tracker.total_allocation_count();
    assert(builder.build(0, 0)!!.len > 0);
    assert(tracker.total_allocation_count() == allocations, "a build allocates only from its arena");

    // The default keeps at least twice the measured peak.
    GridTileBuilder halved = nav::create_grid_tile_builder(
        allocator:     mem,
        config:        config,
        source:        grid_map_source(map),
        scratch_bytes: nav::DEFAULT_GRID_SCRATCH_BYTES / 2,
    )!!;
    defer nav::destroy_grid_tile_builder(&halved);
    assert(halved.build(0, 0)!!.len > 0);
}
