module c3d_nav_test;

import std::math;
import std::math::random;
import c3d;
import c3d::nav @public;

const float HAND_CELL @private = 0.5f; // metres per voxel of the hand-built levels, both axes
const uint  HAND_MAX_POLYS @private = 8;
const uint  QUAD_VERTS @private = 4;
const float SEARCH_RADIUS @private = 3;
const usz   RESULT_CAPACITY @private = 64;
const usz   SEGMENT_CAPACITY @private = 16;
const float WALL_TOLERANCE @private = 0.001f;
const float HALL_WIDTH @private = 2;
const float HALL_LENGTH @private = 20;
const float OVERPASS_RADIUS @private = 12; // metres; reaches the deck that returns over the floor
const float FLOOR_REACH @private = 20; // metres; covers the whole floor from any point
const uint  REACHABLE_DRAWS @private = 1000;
const uint  WEIGHTED_DRAWS @private = 2000;
const ulong RANDOM_SEED @private = 0x5eed;

// A mesh of hand-placed quads; the tests read exact distances from it.
struct HandLevel @private {
    NavMesh     mesh;
    NavQuery    query;
    QueryFilter filter;
}

fn HandLevel* create_hand_level(Vec2 tile_size, uint tiles) @private {
    HandLevel* level = mem::new(HandLevel);
    NavMeshDesc desc = { .tile_width = tile_size.x, .tile_height = tile_size.y, .max_tiles = tiles };
    level.mesh = nav::create_nav_mesh(mem, desc)!!;
    level.filter = nav::default_query_filter();
    return level;
}

fn void destroy_hand_level(HandLevel* level) @private {
    nav::destroy_nav_query(&level.query);
    nav::destroy_nav_mesh(&level.mesh);
    free(level);
}

// Verts are voxels from bounds.min; each quad lists four vertex indices, then the quad across each edge.
fn void add_hand_tile(
    HandLevel* level,
    ushort[] verts,
    ushort[] quads,
    Aabb bounds,
    int tile_x = 0,
) @private {
    uint poly_count = (uint)(quads.len / (QUAD_VERTS * 2));
    ushort[HAND_MAX_POLYS] regions;
    ushort[HAND_MAX_POLYS] flags;
    char[HAND_MAX_POLYS] areas;
    areas[..] = nav::WALKABLE_AREA;
    PolyMesh poly_mesh = {
        .verts          = verts,
        .polys          = quads,
        .regions        = regions[:poly_count],
        .flags          = flags[:poly_count],
        .areas          = areas[:poly_count],
        .vert_count     = (uint)(verts.len / 3),
        .poly_count     = poly_count,
        .verts_per_poly = QUAD_VERTS,
        .bounds         = bounds,
        .cell_size      = HAND_CELL,
        .cell_height    = HAND_CELL,
    };
    char[] tile_mesh = mem::new_array(char, (sz)nav::tile_mesh_size(&poly_mesh));
    defer free(tile_mesh);
    nav::pack_tile_mesh(&poly_mesh, tile_x, 0, tile_mesh);
    TileMeshView view = nav::tile_mesh_view(tile_mesh);
    TileDataParams params = default_tile_params(tile_x, 0);
    char[] blob = mem::new_array(char, (sz)nav::tile_data_size(view, {}, params));
    nav::create_tile_data(view, {}, params, blob)!!;
    level.mesh.add_tile(blob, { .free_data = true })!!;
}

fn void finish_hand_level(HandLevel* level) @private {
    level.query = nav::create_nav_query(mem, &level.mesh, QUERY_NODES)!!;
}

// A 2 m by 20 m hall of four quads along +Z; its walls are the mesh edges at x 0 and 2.
fn HandLevel* hall_level() @private {
    HandLevel* level = create_hand_level({ HALL_LENGTH, HALL_LENGTH }, 1);
    ushort[*] verts = {
        0, 0, 0,    4, 0, 0,
        0, 0, 10,   4, 0, 10,
        0, 0, 20,   4, 0, 20,
        0, 0, 30,   4, 0, 30,
        0, 0, 40,   4, 0, 40,
    };
    ushort none = nav::MESH_NULL_INDEX;
    ushort[*] quads = {
        0, 2, 3, 1,    none, 1, none, none,
        2, 4, 5, 3,    none, 2, none, 0,
        4, 6, 7, 5,    none, 3, none, 1,
        6, 8, 9, 7,    none, none, none, 2,
    };
    add_hand_tile(
        level:  level,
        verts:  verts[..],
        quads:  quads[..],
        bounds: { .min = { 0, 0, 0 }, .max = { HALL_WIDTH, 1, HALL_LENGTH } },
    );
    finish_hand_level(level);
    return level;
}

// Floor quads A, B and C, a ramp up from B, and a deck that turns back to pass 3 m above C.
fn HandLevel* overpass_level() @private {
    HandLevel* level = create_hand_level({ 16, 8 }, 1);
    ushort[*] verts = {
        0, 0, 0,     0, 0, 8,     8, 0, 8,     8, 0, 0,
        16, 0, 8,    16, 0, 0,    0, 0, 16,    8, 0, 16,
        24, 6, 8,    24, 6, 0,    32, 6, 8,    32, 6, 0,
        32, 6, 16,   24, 6, 16,   0, 6, 16,    0, 6, 8,
    };
    ushort none = nav::MESH_NULL_INDEX;
    ushort[*] quads = {
        0, 1, 2, 3,        none, 2, 1, none,
        3, 2, 4, 5,        0, none, 3, none,
        1, 6, 7, 2,        none, none, none, 0,
        5, 4, 8, 9,        1, none, 4, none,
        9, 8, 10, 11,      3, 5, none, none,
        8, 13, 12, 10,     6, none, none, 4,
        15, 14, 13, 8,     none, none, 5, none,
    };
    add_hand_tile(
        level:  level,
        verts:  verts[..],
        quads:  quads[..],
        bounds: { .min = { 0, 0, 0 }, .max = { 16, 3, 8 } },
    );
    finish_hand_level(level);
    return level;
}

// One quad whose +X edge borders two quads of the next tile, so that edge holds two portals.
fn HandLevel* split_portal_level() @private {
    HandLevel* level = create_hand_level({ 2, 4 }, 2);
    ushort none = nav::MESH_NULL_INDEX;
    ushort positive_x = nav::PORTAL_EDGE | 2;
    ushort negative_x = nav::PORTAL_EDGE | 0;
    ushort[*] left_verts = { 0, 0, 0,   0, 0, 8,   4, 0, 8,   4, 0, 0 };
    ushort[*] left_quads = { 0, 1, 2, 3,   none, none, positive_x, none };
    add_hand_tile(
        level:  level,
        verts:  left_verts[..],
        quads:  left_quads[..],
        bounds: { .min = { 0, 0, 0 }, .max = { 2, 1, 4 } },
    );
    ushort[*] right_verts = { 0, 0, 0,   0, 0, 4,   4, 0, 4,   4, 0, 0,   0, 0, 8,   4, 0, 8 };
    ushort[*] right_quads = {
        0, 1, 2, 3,    negative_x, 1, none, none,
        1, 4, 5, 2,    negative_x, none, none, 0,
    };
    add_hand_tile(
        level:  level,
        verts:  right_verts[..],
        quads:  right_quads[..],
        bounds: { .min = { 2, 0, 0 }, .max = { 4, 1, 4 } },
        tile_x: 1,
    );
    finish_hand_level(level);
    return level;
}

// Two separate squares of 1 and 9 square metres.
fn HandLevel* weighted_level() @private {
    HandLevel* level = create_hand_level({ 5, 3 }, 1);
    ushort[*] verts = {
        0, 0, 0,   0, 0, 2,   2, 0, 2,    2, 0, 0,
        4, 0, 0,   4, 0, 6,   10, 0, 6,   10, 0, 0,
    };
    ushort none = nav::MESH_NULL_INDEX;
    ushort[*] quads = {
        0, 1, 2, 3,   none, none, none, none,
        4, 5, 6, 7,   none, none, none, none,
    };
    add_hand_tile(
        level:  level,
        verts:  verts[..],
        quads:  quads[..],
        bounds: { .min = { 0, 0, 0 }, .max = { 5, 1, 3 } },
    );
    finish_hand_level(level);
    return level;
}

fn PolyRef hand_ref(HandLevel* level, uint poly, int tile_x = 0) @private {
    return level.mesh.poly_ref_base(level.mesh.tile_at(tile_x, 0, 0)) | (PolyRef)poly;
}

fn float next_random(void* context) @private => random::next_float((Lcg64Random*)context);

fn Lcg64Random seeded_random() @private {
    Lcg64Random generator;
    random::seed(&generator, RANDOM_SEED);
    return generator;
}

fn bool holds_ref(PolyRef[] refs, PolyRef ref) @private {
    foreach (entry : refs) {
        if (entry == ref) return true;
    }
    return false;
}

// Every vertex of the polygon lies above the height.
fn bool raised_poly(NavMesh* mesh, PolyRef ref, float height) @private {
    TileAndPoly found = mesh.tile_and_poly(ref)!!;
    for (usz slot = 0; slot < found.poly.vert_count; slot++) {
        if (found.tile.verts[found.poly.verts[slot]].y <= height) return false;
    }
    return true;
}

fn void test_polys_around_circle_returns_parents_and_costs_in_pop_order() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    add_stripes(fixture, 2);
    build_level(fixture);
    float middle = fixture.level.builder.tile_world_size;
    Vec3 center = { middle, 0, middle };
    PolyRef start_ref = nearest(fixture, center).ref;
    PolyRef[RESULT_CAPACITY] refs;
    PolyRef[RESULT_CAPACITY] parents;
    float[RESULT_CAPACITY] costs;
    PolyRef[RESULT_CAPACITY] refs_only;

    DijkstraResult result = fixture.query.find_polys_around_circle(
        start_ref:   start_ref,
        center:      center,
        radius:      SEARCH_RADIUS,
        filter:      &fixture.filter,
        out_refs:    refs[..],
        out_parents: parents[..],
        out_costs:   costs[..],
    )!!;
    DijkstraResult without_parents = fixture.query.find_polys_around_circle(
        start_ref: start_ref,
        center:    center,
        radius:    SEARCH_RADIUS,
        filter:    &fixture.filter,
        out_refs:  refs_only[..],
    )!!;

    assert(result.count > 4 && !result.truncated);
    assert(refs[0] == start_ref && !parents[0] && costs[0] == 0);
    for (usz index = 1; index < result.count; index++) {
        assert(holds_ref(refs[:index], parents[index]), "a parent is popped before its child");
        assert(costs[index] >= costs[index - 1]);
    }
    assert(same_refs(refs_only[:without_parents.count], refs[:result.count]));
}

fn void test_polys_around_shape_matches_the_circle_for_an_enclosing_polygon() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    add_stripes(fixture, 2);
    build_level(fixture);
    float middle = fixture.level.builder.tile_world_size;
    Vec3 center = { middle, 0, middle };
    PolyRef start_ref = nearest(fixture, center).ref;
    Vec3[4] square = {
        center + { -SEARCH_RADIUS, 0, -SEARCH_RADIUS },
        center + { -SEARCH_RADIUS, 0, SEARCH_RADIUS },
        center + { SEARCH_RADIUS, 0, SEARCH_RADIUS },
        center + { SEARCH_RADIUS, 0, -SEARCH_RADIUS },
    };
    PolyRef[RESULT_CAPACITY] circle_refs;
    PolyRef[RESULT_CAPACITY] shape_refs;

    DijkstraResult circle = fixture.query.find_polys_around_circle(
        start_ref: start_ref,
        center:    center,
        radius:    SEARCH_RADIUS,
        filter:    &fixture.filter,
        out_refs:  circle_refs[..],
    )!!;
    DijkstraResult shape = fixture.query.find_polys_around_shape(
        start_ref: start_ref,
        vertices:  square[..],
        filter:    &fixture.filter,
        out_refs:  shape_refs[..],
    )!!;

    assert(circle.count > 1 && !shape.truncated);
    foreach (ref : circle_refs[:circle.count]) assert(holds_ref(shape_refs[:shape.count], ref));
}

fn void test_path_from_dijkstra_search_reaches_an_explored_polygon() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    add_stripes(fixture, 2);
    build_level(fixture);
    float middle = fixture.level.builder.tile_world_size;
    Vec3 center = { middle, 0, middle };
    PolyRef start_ref = nearest(fixture, center).ref;
    PolyRef far_ref = nearest(fixture, { 1, 0, 1 }).ref;
    PolyRef[RESULT_CAPACITY] refs;
    DijkstraResult result = fixture.query.find_polys_around_circle(
        start_ref: start_ref,
        center:    center,
        radius:    SEARCH_RADIUS,
        filter:    &fixture.filter,
        out_refs:  refs[..],
    )!!;
    PolyRef target = refs[result.count - 1];

    PathResult corridor = fixture.query.path_from_dijkstra_search(target, fixture.path[..])!!;

    assert(corridor.count >= 2 && !corridor.truncated);
    assert(fixture.path[0] == start_ref && fixture.path[corridor.count - 1] == target);
    assert(connected_corridor(&fixture.level.mesh, fixture.path[:corridor.count]));
    assert(!holds_ref(refs[:result.count], far_ref));
    assert(@catch(fixture.query.path_from_dijkstra_search(far_ref, fixture.path[..])) == nav::NO_PATH);
}

fn void test_local_neighbourhood_excludes_overlapping_polygons() @test {
    HandLevel* level = overpass_level();
    defer destroy_hand_level(level);
    Vec3 center = { 2, 0, 2 };
    PolyRef start_ref = hand_ref(level, 0);
    PolyRef under_deck = hand_ref(level, 2);
    PolyRef deck_over_floor = hand_ref(level, 6);
    PolyRef[RESULT_CAPACITY] reached;
    PolyRef[RESULT_CAPACITY] local;
    PolyRef[RESULT_CAPACITY] parents;

    DijkstraResult circle = level.query.find_polys_around_circle(
        start_ref: start_ref,
        center:    center,
        radius:    OVERPASS_RADIUS,
        filter:    &level.filter,
        out_refs:  reached[..],
    )!!;
    DijkstraResult neighbourhood = level.query.find_local_neighbourhood(
        start_ref:   start_ref,
        center:      center,
        radius:      OVERPASS_RADIUS,
        filter:      &level.filter,
        out_refs:    local[..],
        out_parents: parents[..],
    )!!;

    assert(holds_ref(reached[:circle.count], deck_over_floor), "the deck is reachable");
    assert(neighbourhood.count == circle.count - 1);
    assert(holds_ref(local[:neighbourhood.count], under_deck));
    assert(!holds_ref(local[:neighbourhood.count], deck_over_floor));
    assert(local[0] == start_ref && !parents[0]);
}

fn void test_move_along_surface_slides_along_a_wall() @test {
    HandLevel* level = hall_level();
    defer destroy_hand_level(level);
    Vec3 start = { 1, 0, 2 };
    Vec3 into_wall = { 3, 0, 4 };
    PolyRef start_ref = hand_ref(level, 0);
    PolyRef[RESULT_CAPACITY] visited;

    MoveResult moved = level.query.move_along_surface(
        start_ref:   start_ref,
        start:       start,
        end:         into_wall,
        filter:      &level.filter,
        out_visited: visited[..],
    )!!;

    assert(math::abs(moved.position.x - HALL_WIDTH) <= WALL_TOLERANCE, "flush with the wall");
    assert(moved.position.z > start.z, "advanced along the wall");
    assert(moved.visited_count >= 1 && visited[0] == start_ref);
}

fn void test_move_along_surface_crosses_portals() @test {
    HandLevel* level = hall_level();
    defer destroy_hand_level(level);
    Vec3 start = { 1, 0, 2 };
    Vec3 end = { 1, 0, 12 };
    PolyRef[RESULT_CAPACITY] visited;

    MoveResult moved = level.query.move_along_surface(
        start_ref:   hand_ref(level, 0),
        start:       start,
        end:         end,
        filter:      &level.filter,
        out_visited: visited[..],
    )!!;

    assert(moved.visited_count == 3 && !moved.truncated);
    for (uint poly = 0; poly < 3; poly++) assert(visited[poly] == hand_ref(level, poly));
    assert(same_xz(moved.position, end));
}

fn void test_wall_distance_in_a_corridor() @test {
    HandLevel* level = hall_level();
    defer destroy_hand_level(level);
    Vec3 middle = { HALL_WIDTH * 0.5f, 0, HALL_LENGTH * 0.5f };
    Vec3 near_wall = { 0.25f, 0, HALL_LENGTH * 0.5f };
    PolyRef middle_ref = level.query.find_nearest_poly(middle, NEAR_EXTENTS, &level.filter)!!.ref;

    WallHit centred = level.query.find_distance_to_wall(
        start_ref:  middle_ref,
        center:     middle,
        max_radius: HALL_LENGTH,
        filter:     &level.filter,
    )!!;
    WallHit close = level.query.find_distance_to_wall(
        start_ref:  middle_ref,
        center:     near_wall,
        max_radius: HALL_LENGTH,
        filter:     &level.filter,
    )!!;

    assert(math::abs(centred.distance - HALL_WIDTH * 0.5f) <= WALL_TOLERANCE);
    assert(math::abs(math::abs(centred.normal.x) - 1) <= WALL_TOLERANCE);
    assert(centred.normal.dot(middle - centred.point) > 0, "the normal points toward the centre");
    assert(math::abs(close.distance - 0.25f) <= WALL_TOLERANCE);
    assert(close.normal.x > 0);
}

fn void test_wall_segments_split_portals_with_a_filter() @test {
    HandLevel* level = split_portal_level();
    defer destroy_hand_level(level);
    PolyRef bordering = hand_ref(level, 0);
    PolyRef[2] across = { hand_ref(level, 0, tile_x: 1), hand_ref(level, 1, tile_x: 1) };
    WallSegment[SEGMENT_CAPACITY] segments;

    QueryResult filtered = level.query.poly_wall_segments(bordering, &level.filter, segments[..])!!;
    uint portals;
    float length;
    foreach (segment : segments[:filtered.count]) {
        if (segment.neighbour) {
            assert(holds_ref(across[..], segment.neighbour));
            assert(math::abs(segment.start.x - 2) <= WALL_TOLERANCE && math::abs(segment.end.x - 2) <= WALL_TOLERANCE);
            portals++;
        }
        length += (segment.end - segment.start).length();
    }
    QueryResult unfiltered = level.query.poly_wall_segments(bordering, null, segments[..])!!;

    assert(portals == 2 && filtered.count == 5, "the portal edge splits in two, three walls remain");
    assert(math::abs(length - 12) <= WALL_TOLERANCE, "the segments cover the perimeter once");
    assert(unfiltered.count == 4);
    foreach (segment : segments[:unfiltered.count]) assert(!segment.neighbour);
}

fn void test_random_points_stay_on_reachable_polygons() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    add_platform(fixture);
    build_level(fixture);
    Vec3 start = { 1.5f, 0, 4.8f };
    PolyRef start_ref = nearest(fixture, start).ref;
    NavMesh* mesh = &fixture.level.mesh;
    float island_height = PLATFORM_SIZE.y * 0.5f;
    assert(raised_poly(mesh, nearest(fixture, { 6.5f, PLATFORM_SIZE.y, 4.8f }).ref, island_height));
    Lcg64Random generator = seeded_random();

    for (uint draw = 0; draw < REACHABLE_DRAWS; draw++) {
        RandomPoint picked = fixture.query.find_random_point_around_circle(
            start_ref:  start_ref,
            center:     start,
            max_radius: FLOOR_REACH,
            filter:     &fixture.filter,
            random:     &next_random,
            context:    &generator,
        )!!;
        assert(!raised_poly(mesh, picked.ref, island_height), "never on the island");
        assert(fixture.query.closest_point_on_poly(picked.ref, picked.point)!!.over_poly);
    }
}

fn void test_random_point_is_area_weighted() @test {
    HandLevel* level = weighted_level();
    defer destroy_hand_level(level);
    PolyRef large = hand_ref(level, 1);
    Lcg64Random generator = seeded_random();

    uint large_draws;
    for (uint draw = 0; draw < WEIGHTED_DRAWS; draw++) {
        RandomPoint picked = level.query.find_random_point(&level.filter, &next_random, &generator)!!;
        if (picked.ref == large) large_draws++;
    }

    float share = (float)large_draws / WEIGHTED_DRAWS;
    assert(share >= 0.8f && share <= 1, "large share %f", share);
}
