module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;
import c3d::scene;

const uint  SLICE_ITERATIONS @private = 3;
const uint  PARTIAL_ITERATIONS @private = 2;
const usz   EXISTING_CORRIDOR @private = 6;
const float STRIPE_WIDTH @private = 1.2f;
const float STRIPE_PITCH @private = 3.2f; // metres between stripe starts; three per tile of a two-tile floor

// Mud stripes both ways across a floor of tiles by tiles; costs stay 1, so the floor is open but split.
fn void add_stripes(QueryFixture* fixture, uint tiles) @private {
    float side = fixture.level.builder.tile_world_size * tiles;
    for (float offset = STRIPE_PITCH * 0.5f; offset < side; offset += STRIPE_PITCH) {
        Node* along_z = fixture.level.scene.add_node()!!;
        fixture.level.scene.add_nav_volume(along_z, {
            .kind = BOX,
            .area = MUD_AREA,
            .box  = { .min = { offset, -1, 0 }, .max = { offset + STRIPE_WIDTH, 1, side } },
        })!!;
        Node* along_x = fixture.level.scene.add_node()!!;
        fixture.level.scene.add_nav_volume(along_x, {
            .kind = BOX,
            .area = MUD_AREA,
            .box  = { .min = { 0, -1, offset }, .max = { side, 1, offset + STRIPE_WIDTH } },
        })!!;
    }
}

fn bool linked(NavMesh* mesh, PolyRef from, PolyRef to) @private {
    TileAndPoly found = mesh.tile_and_poly(from)!!;
    for (uint link = found.poly.first_link; link != nav::NULL_LINK; link = found.tile.links[link].next) {
        if (found.tile.links[link].ref == to) return true;
    }
    return false;
}

fn bool connected_corridor(NavMesh* mesh, PolyRef[] corridor) @private {
    for (usz index = 1; index < corridor.len; index++) {
        if (!linked(mesh, corridor[index - 1], corridor[index])) return false;
    }
    return true;
}

fn bool same_refs(PolyRef[] first, PolyRef[] second) @private {
    if (first.len != second.len) return false;
    foreach (index, ref : first) {
        if (ref != second[index]) return false;
    }
    return true;
}

// Updates in slices of SLICE_ITERATIONS until the search is done; the total iterations.
fn uint run_sliced(NavQuery* query) @private {
    uint iterations;
    SlicedProgress progress = { .status = IN_PROGRESS };
    while (progress.status == IN_PROGRESS) {
        progress = query.update_sliced_find_path(SLICE_ITERATIONS)!!;
        assert(progress.iterations <= SLICE_ITERATIONS);
        iterations += progress.iterations;
    }
    return iterations;
}

fn void test_sliced_search_matches_find_path_over_several_updates() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    add_stripes(fixture, 2);
    build_level(fixture);
    float side = fixture.level.builder.tile_world_size * 2;
    Vec3 start = { 1, 0, 1 };
    Vec3 end = { side - 1, 0, side - 1 };
    NavQuery* query = &fixture.query;
    PolyRef start_ref = nearest(fixture, start).ref;
    PolyRef end_ref = nearest(fixture, end).ref;
    PolyRef[PATH_CAPACITY] sliced_path;

    query.init_sliced_find_path(
        start_ref: start_ref,
        end_ref:   end_ref,
        start:     start,
        end:       end,
        filter:    &fixture.filter,
    )!!;
    uint iterations = run_sliced(query);
    PathResult sliced = query.finalize_sliced_find_path(sliced_path[..])!!;
    PathResult direct = path_between(fixture, start, end, &fixture.filter);

    assert(iterations > SLICE_ITERATIONS && iterations <= QUERY_NODES);
    assert(!sliced.partial && !sliced.truncated);
    assert(same_refs(sliced_path[:sliced.count], fixture.path[:direct.count]));
    PathResult? again = query.finalize_sliced_find_path(sliced_path[..]);
    assert(@catch(again) == c3d::INVALID_ARGUMENT, "finalize ends the search");

    query.init_sliced_find_path(
        start_ref: start_ref,
        end_ref:   end_ref,
        start:     start,
        end:       end,
        filter:    &fixture.filter,
    )!!;
    query.update_sliced_find_path(1)!!;
    fixture.level.mesh.remove_tile(fixture.level.mesh.tile_ref_at(1, 1, 0))!!;

    assert(@catch(query.update_sliced_find_path(SLICE_ITERATIONS)) == nav::INVALID_REF);
    assert(@catch(query.finalize_sliced_find_path(sliced_path[..])) == c3d::INVALID_ARGUMENT);
}

fn void test_sliced_search_is_partial_when_the_goal_is_unreachable() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    add_platform(fixture);
    build_level(fixture);
    Vec3 start = { 1.5f, 0, 4.8f };
    Vec3 goal = { 6.5f, PLATFORM_SIZE.y, 4.8f };
    PathResult direct = path_between(fixture, start, goal, &fixture.filter);
    PolyRef nearest_to_goal = fixture.path[direct.count - 1];
    NavQuery* query = &fixture.query;
    PolyRef[PATH_CAPACITY] sliced_path;

    query.init_sliced_find_path(
        start_ref: fixture.path[0],
        end_ref:   nearest(fixture, goal).ref,
        start:     start,
        end:       goal,
        filter:    &fixture.filter,
    )!!;
    run_sliced(query);
    PathResult sliced = query.finalize_sliced_find_path(sliced_path[..])!!;

    assert(direct.partial && sliced.partial);
    assert(sliced_path[sliced.count - 1] == nearest_to_goal);
    assert(nearest_to_goal != nearest(fixture, goal).ref);
}

fn void test_finalize_partial_returns_the_furthest_visited_existing_polygon() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    add_stripes(fixture, 2);
    build_level(fixture);
    float side = fixture.level.builder.tile_world_size * 2;
    Vec3 start = { 1, 0, 1 };
    Vec3 end = { side - 1, 0, side - 1 };
    PathResult corridor = path_between(fixture, start, end, &fixture.filter);
    assert(corridor.count > EXISTING_CORRIDOR);
    PolyRef[EXISTING_CORRIDOR] existing;
    existing[..] = fixture.path[:EXISTING_CORRIDOR];
    PolyRef end_ref = fixture.path[corridor.count - 1];
    NavQuery* query = &fixture.query;
    PolyRef[PATH_CAPACITY] replanned;

    query.init_sliced_find_path(
        start_ref: existing[0],
        end_ref:   end_ref,
        start:     start,
        end:       end,
        filter:    &fixture.filter,
    )!!;
    SlicedProgress progress = query.update_sliced_find_path(PARTIAL_ITERATIONS)!!;
    sz furthest;
    SearchNode*[nav::MAX_NODE_STATES] visited;
    foreach (index, ref : existing) {
        if (query.nodes.find_nodes(ref, visited[..])) furthest = index;
    }
    PathResult result = query.finalize_sliced_find_path_partial(existing[..], replanned[..])!!;

    assert(progress.status == IN_PROGRESS && furthest > 0);
    assert(!result.partial);
    assert(replanned[0] == existing[0] && replanned[result.count - 1] == existing[furthest]);
    assert(connected_corridor(&fixture.level.mesh, replanned[:result.count]));
}

fn void test_any_angle_shortcuts_across_open_floor() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    add_stripes(fixture, 2);
    build_level(fixture);
    float side = fixture.level.builder.tile_world_size * 2;
    Vec3 start = { 1, 0, side * 0.5f };
    Vec3 end = { side - 1, 0, side - 2 };
    PathResult plain = path_between(fixture, start, end, &fixture.filter);
    PolyRef start_ref = fixture.path[0];
    PolyRef end_ref = fixture.path[plain.count - 1];
    NavQuery* query = &fixture.query;
    PolyRef[PATH_CAPACITY] any_angle;

    query.init_sliced_find_path(
        start_ref: start_ref,
        end_ref:   end_ref,
        start:     start,
        end:       end,
        filter:    &fixture.filter,
        options:   { .any_angle = true },
    )!!;
    run_sliced(query);
    bool shortcut;
    foreach (&node : query.nodes.nodes[:query.nodes.count]) {
        if (node.bits.parent_detached) shortcut = true;
    }
    PathResult result = query.finalize_sliced_find_path(any_angle[..])!!;

    assert(shortcut, "the search took a raycast shortcut");
    assert(!result.partial && result.count <= plain.count);
    assert(any_angle[0] == start_ref && any_angle[result.count - 1] == end_ref);
    assert(connected_corridor(&fixture.level.mesh, any_angle[:result.count]));
}

fn void test_sliced_search_in_flight_survives_shift_origin() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    add_stripes(fixture, 2);
    build_level(fixture);
    float side = fixture.level.builder.tile_world_size * 2;
    Vec3 start = { 1, 0, 1 };
    Vec3 end = { side - 1, 0, side - 1 };
    NavQuery* query = &fixture.query;
    PolyRef[PATH_CAPACITY] original_path;
    PathResult original = path_between(fixture, start, end, &fixture.filter);
    original_path[:original.count] = fixture.path[:original.count];
    PathResult original_straight = straight_between(fixture, start, end, original.count);
    StraightPoint[POINT_CAPACITY] original_points = fixture.points;

    query.init_sliced_find_path(
        start_ref: nearest(fixture, start).ref,
        end_ref:   nearest(fixture, end).ref,
        start:     start,
        end:       end,
        filter:    &fixture.filter,
    )!!;
    SlicedProgress progress = query.update_sliced_find_path(SLICE_ITERATIONS)!!;
    assert(progress.status == IN_PROGRESS);
    fixture.level.mesh.shift_origin(SHIFT_OFFSET);
    query.shift_origin(SHIFT_OFFSET);
    run_sliced(query);
    PolyRef[PATH_CAPACITY] sliced_path;
    PathResult sliced = query.finalize_sliced_find_path(sliced_path[..])!!;
    fixture.path[:sliced.count] = sliced_path[:sliced.count];
    PathResult straight = straight_between(fixture, start - SHIFT_OFFSET, end - SHIFT_OFFSET, sliced.count);

    assert(!sliced.partial && sliced.count == original.count);
    assert(same_refs(sliced_path[:sliced.count], original_path[:original.count]));
    assert(straight.count == original_straight.count);
    assert(points_match(fixture.points[:straight.count], original_points[:original_straight.count], SHIFT_OFFSET));
}
