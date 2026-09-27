module c3d_nav_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::nav @public;
import c3d::scene;

const uint  QUERY_NODES @private = 2048;
const Vec3  NEAR_EXTENTS @private = { 1, 2, 1 };
const usz   PATH_CAPACITY @private = 256;
const usz   POINT_CAPACITY @private = 64;
const float QUERY_TOLERANCE @private = 0.001f;
const Vec3  PLATFORM_SIZE @private = { 4.2f, 1.5f, 4.2f }; // taller than the 0.9 m climb; its eroded top keeps a region
const Vec3  PLATFORM_CENTRE @private = { 6.5f, 0.75f, 4.8f };
const float MUD_COST @private = 10;

struct QueryFixture @private {
    BuilderFixture*              level;
    NavQuery                     query;
    QueryFilter                  filter;
    PolyRef[PATH_CAPACITY]       path;
    StraightPoint[POINT_CAPACITY] points;
}

struct ExcludingFilter @private {
    inline QueryFilter base;
    PolyRef            excluded;
}

// A floor of tiles by tiles; the test adds its geometry, then calls build_level.
fn QueryFixture* floor_level(uint tiles) @private {
    QueryFixture* fixture = mem::new(QueryFixture);
    fixture.level = mem::new(BuilderFixture);
    setup(fixture.level, tile_grid_bounds(tiles));
    float side = fixture.level.builder.tile_world_size * tiles;
    add_plane(fixture.level, { side, side }, { side * 0.5f, 0, side * 0.5f });
    fixture.filter = nav::default_query_filter();
    return fixture;
}

fn void build_level(QueryFixture* fixture) @private {
    NavSyncResult result = build_everything(fixture.level);
    assert(result.pending == 0 && result.failed == 0);
    fixture.query = nav::create_nav_query(mem, &fixture.level.mesh, QUERY_NODES)!!;
}

fn void destroy_level(QueryFixture* fixture) @private {
    nav::destroy_nav_query(&fixture.query);
    teardown(fixture.level);
    free(fixture.level);
    free(fixture);
}

fn NearestPoly nearest(QueryFixture* fixture, Vec3 position) @private {
    return fixture.query.find_nearest_poly(position, NEAR_EXTENTS, &fixture.filter)!!;
}

fn PathResult path_between(QueryFixture* fixture, Vec3 from, Vec3 to, QueryFilter* filter) @private {
    return fixture.query.find_path(
        start_ref: nearest(fixture, from).ref,
        end_ref:   nearest(fixture, to).ref,
        start:     from,
        end:       to,
        filter:    filter,
        out_path:  fixture.path[..],
    )!!;
}

fn PathResult straight_between(QueryFixture* fixture, Vec3 from, Vec3 to, usz path_count) @private {
    return fixture.query.straight_path(from, to, fixture.path[:path_count], fixture.points[..])!!;
}

fn bool path_holds(PolyRef[] path, PolyRef ref) @private {
    foreach (entry : path) {
        if (entry == ref) return true;
    }
    return false;
}

fn bool path_crosses_area(NavMesh* mesh, PolyRef[] path, char area) @private {
    foreach (ref : path) {
        if (mesh.poly_area(ref)!! == area) return true;
    }
    return false;
}

fn bool same_xz(Vec3 first, Vec3 second) @private {
    return math::abs(first.x - second.x) < QUERY_TOLERANCE && math::abs(first.z - second.z) < QUERY_TOLERANCE;
}

fn Node* add_platform(QueryFixture* fixture) @private => add_box(fixture.level, PLATFORM_SIZE, PLATFORM_CENTRE);

// A mud strip across the middle of one tile, leaving a gap along both edges.
fn void add_mud_strip(QueryFixture* fixture) @private {
    Node* mud = fixture.level.scene.add_node()!!;
    fixture.level.scene.add_nav_volume(mud, {
        .kind = BOX,
        .area = MUD_AREA,
        .box  = { .min = { 3.8f, -1, 1.5f }, .max = { 5.8f, 1, 8.1f } },
    })!!;
}

fn bool pass_unless_excluded(QueryFilter* filter, PolyRef ref, Poly* poly) @private {
    return ref != ((ExcludingFilter*)filter).excluded;
}

fn float ramp_height(float z) @private {
    float sine = math::sin(RAMP_ANGLE);
    float cosine = math::cos(RAMP_ANGLE);
    float local_z = (z - 5 - 0.1f * sine) / cosine;
    return 0.6f + 0.1f * cosine - local_z * sine;
}

fn void test_find_nearest_poly_faults_outside_the_extents() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    build_level(fixture);
    float middle = fixture.level.builder.tile_world_size * 0.5f;
    Vec3 above = { middle, 5, middle };

    NearestPoly? missed = fixture.query.find_nearest_poly(above, { 1, 1, 1 }, &fixture.filter);
    NearestPoly found = fixture.query.find_nearest_poly(above, { 1, 10, 1 }, &fixture.filter)!!;

    assert(@catch(missed) == nav::NO_POLY);
    assert(found.over_poly && fixture.level.mesh.is_valid_ref(found.ref));
    assert(same_xz(found.point, above));
}

fn void test_poly_height_matches_a_sloped_polygon() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    Node* ramp = add_box(fixture.level, { 2, 0.2f, 4 }, { 6.5f, 0.6f, 5 });
    ramp.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, RAMP_ANGLE);
    fixture.level.scene.update_world();
    build_level(fixture);
    float[3] depths = { 4.5f, 5, 5.5f };
    NavBuildConfig config = fixture.level.builder.config;
    // Span tops round up one cell and hold the surface's highest point over the cell; contour corners take
    // the highest span around them. Without a detail mesh the polygon sits that much above the ramp.
    float tolerance = config.cell_height + 2 * config.cell_size * math::tan(RAMP_ANGLE);

    float previous = float::max;
    foreach (z : depths) {
        Vec3 surface = { 6.5f, ramp_height(z), z };
        NearestPoly found = nearest(fixture, surface);
        float height = fixture.query.poly_height(found.ref, surface)!!;
        assert(found.over_poly);
        assert(math::abs(height - surface.y) <= tolerance, "height %f against the ramp's %f", height, surface.y);
        assert(height < previous, "the ramp falls toward +Z");
        previous = height;
    }
}

fn void test_path_across_a_tile_border() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    build_level(fixture);
    float tile = fixture.level.builder.tile_world_size;
    Vec3 start = { tile * 0.5f, 0, tile * 0.5f };
    Vec3 end = { tile * 1.5f, 0, tile * 0.5f };

    PathResult corridor = path_between(fixture, start, end, &fixture.filter);
    PathResult straight = straight_between(fixture, start, end, corridor.count);

    assert(!corridor.partial && !corridor.truncated);
    uint changes;
    for (usz index = 1; index < corridor.count; index++) {
        if (nav::decode_tile(fixture.path[index]) != nav::decode_tile(fixture.path[index - 1])) changes++;
    }
    assert(changes == 1);
    StraightPoint first = fixture.points[0];
    StraightPoint last = fixture.points[straight.count - 1];
    assert(first.flags.start && same_xz(first.position, start));
    assert(last.flags.end && same_xz(last.position, end));
}

fn void test_nav_link_shortens_a_path() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    add_platform(fixture);
    Node* link_node = fixture.level.scene.add_node()!!;
    fixture.level.scene.update_world();
    fixture.level.scene.add_nav_link(link_node, {
        .start  = { 3, 0, 4.8f },
        .end    = { 6.5f, PLATFORM_SIZE.y, 4.8f },
        .radius = 0.6f,
        .area   = nav::WALKABLE_AREA,
    })!!;
    build_level(fixture);
    Vec3 start = { 1.5f, 0, 4.8f };
    Vec3 goal = { 6.5f, PLATFORM_SIZE.y, 4.8f };

    PathResult corridor = path_between(fixture, start, goal, &fixture.filter);
    PathResult straight = straight_between(fixture, start, goal, corridor.count);

    assert(!corridor.partial);
    bool through_link;
    foreach (ref : fixture.path[:corridor.count]) {
        if (fixture.level.mesh.tile_and_poly(ref)!!.poly.area_type.type == OFF_MESH_CONNECTION) through_link = true;
    }
    assert(through_link);
    bool link_point;
    foreach (point : fixture.points[:straight.count]) {
        if (point.flags.off_mesh_connection) link_point = true;
    }
    assert(link_point);

    fixture.level.scene.remove_component(link_node, NavLink);
    build_everything(fixture.level);

    assert(path_between(fixture, start, goal, &fixture.filter).partial);
}

fn void test_partial_when_the_goal_is_unreachable() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    add_platform(fixture);
    build_level(fixture);
    Vec3 start = { 1.5f, 0, 4.8f };
    Vec3 goal = { 6.5f, PLATFORM_SIZE.y, 4.8f };
    PolyRef goal_ref = nearest(fixture, goal).ref;

    PathResult corridor = path_between(fixture, start, goal, &fixture.filter);

    assert(corridor.partial && corridor.count >= 1);
    PolyRef last = fixture.path[corridor.count - 1];
    Vec3 closest = fixture.query.closest_point_on_poly(last, goal)!!.point;
    assert(last != goal_ref);
    assert((goal - closest).length() < (goal - start).length(), "the path ends nearer the goal than it starts");
}

fn void test_truncated_with_a_short_slice() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    add_box(fixture.level, { 2, 1, 2 }, { 9.6f, 0.5f, 9.6f });
    build_level(fixture);
    float tile = fixture.level.builder.tile_world_size;
    Vec3 start = { tile * 0.5f, 0, tile * 0.5f };
    Vec3 end = { tile * 1.5f, 0, tile * 1.5f };
    PathResult full = path_between(fixture, start, end, &fixture.filter);
    PolyRef[2] short_path;

    PathResult cut = fixture.query.find_path(
        start_ref: fixture.path[0],
        end_ref:   fixture.path[full.count - 1],
        start:     start,
        end:       end,
        filter:    &fixture.filter,
        out_path:  short_path[..],
    )!!;

    assert(full.count > 2 && !full.truncated);
    assert(cut.truncated && !cut.partial && cut.count == 2);
    assert(short_path[0] == fixture.path[0] && short_path[1] == fixture.path[1]);
}

fn void test_area_cost_steers_the_path() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    add_mud_strip(fixture);
    build_level(fixture);
    Vec3 start = { 1, 0, 4.8f };
    Vec3 end = { 8.6f, 0, 4.8f };
    NavMesh* mesh = &fixture.level.mesh;

    PathResult through = path_between(fixture, start, end, &fixture.filter);
    bool crossed = path_crosses_area(mesh, fixture.path[:through.count], MUD_AREA);
    fixture.filter.area_cost[MUD_AREA] = MUD_COST;
    PathResult around = path_between(fixture, start, end, &fixture.filter);

    assert(crossed && !through.partial);
    assert(!around.partial && !path_crosses_area(mesh, fixture.path[:around.count], MUD_AREA));
}

fn void test_pass_hook_excluding_a_polygon_reroutes() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    add_mud_strip(fixture);
    build_level(fixture);
    Vec3 start = { 1, 0, 4.8f };
    Vec3 end = { 8.6f, 0, 4.8f };
    NavMesh* mesh = &fixture.level.mesh;
    PathResult through = path_between(fixture, start, end, &fixture.filter);
    PolyRef end_ref = fixture.path[through.count - 1];
    ExcludingFilter excluding = { .base = nav::default_query_filter() };
    excluding.pass = &pass_unless_excluded;
    foreach (ref : fixture.path[:through.count]) {
        if (mesh.poly_area(ref)!! == MUD_AREA) excluding.excluded = ref;
    }
    assert(excluding.excluded, "the unfiltered corridor crosses the mud");

    PathResult rerouted = path_between(fixture, start, end, &excluding);

    assert(!rerouted.partial && fixture.path[rerouted.count - 1] == end_ref);
    assert(!path_holds(fixture.path[:rerouted.count], excluding.excluded));
}

fn void test_raycast_stops_at_a_wall() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    add_box(fixture.level, { 0.4f, 2, 5.6f }, { 6.2f, 1, 4.8f });
    build_level(fixture);
    Vec3 start = { 2, 0, 4.8f };
    Vec3 toward_wall = { 8, 0, 4.8f };
    Vec3 open = { 2, 0, 1.5f };
    PolyRef start_ref = nearest(fixture, start).ref;

    RaycastHit wall = fixture.query.raycast(start_ref, start, toward_wall, &fixture.filter, fixture.path[..])!!;
    RaycastHit clear = fixture.query.raycast(start_ref, start, open, &fixture.filter, fixture.path[..])!!;

    assert(wall.t > 0 && wall.t < 1);
    assert(wall.normal.dot(toward_wall - start) < 0, "the wall faces back along the ray");
    assert(wall.path_count >= 1 && fixture.path[0] == start_ref);
    assert(clear.t == float::max);
}

fn void test_closest_point_outside_projects_to_the_nearest_edge() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    build_level(fixture);
    PolyRef floor = nearest(fixture, { 4.8f, 0, 4.8f }).ref;
    TileAndPoly found = fixture.level.mesh.tile_and_poly(floor)!!;
    float left_edge = float::max;
    for (usz slot = 0; slot < found.poly.vert_count; slot++) {
        left_edge = math::min(left_edge, found.tile.verts[found.poly.verts[slot]].x);
    }
    Vec3 outside = { -1, 0, 4.8f };

    ClosestPoint closest = fixture.query.closest_point_on_poly(floor, outside)!!;
    Vec3 boundary = fixture.query.closest_point_on_poly_boundary(floor, outside)!!;

    assert(!closest.over_poly);
    assert(same_xz(closest.point, boundary));
    assert(same_xz(closest.point, { left_edge, 0, outside.z }));
}

fn void test_default_filter_passes_built_polygons() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    add_platform(fixture);
    build_level(fixture);
    NavMesh* mesh = &fixture.level.mesh;

    uint polys;
    foreach (&tile : mesh.tiles) {
        if (!tile.header) continue;
        PolyRef base = mesh.poly_ref_base(tile);
        foreach (index, &poly : tile.polys) {
            assert(poly.flags == nav::POLY_FLAG_WALK);
            assert(fixture.query.is_valid_ref(base | (PolyRef)index, &fixture.filter));
            polys++;
        }
    }
    assert(polys > 0);
}
