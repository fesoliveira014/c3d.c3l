module c3d_nav_test;

import std::math;
import c3d::nav @public;

const usz   CORRIDOR_CAPACITY @private = 16;
const usz   CORNER_CAPACITY @private = 4;
const float BOUNDARY_RANGE @private = 3;
const float HALL_WALL_DISTANCE_SQR @private = 1; // the hall is 2 m wide, so its walls are 1 m from the centre line

fn PolyRef[4] hall_polys(HandLevel* level) @private {
    return { hand_ref(level, 0), hand_ref(level, 1), hand_ref(level, 2), hand_ref(level, 3) };
}

fn void test_merge_start_moved_handles_empty_input() @test {
    assert(nav::merge_corridor_start_moved({}, 0, {}) == 0);
}

fn void test_merge_start_moved_keeps_the_path_without_visited_polygons() @test {
    PolyRef[1] path = { (PolyRef)1 };

    usz count = nav::merge_corridor_start_moved(path[..], 1, {});

    PolyRef[1] expected = { (PolyRef)1 };
    assert(count == 1 && same_refs(path[..], expected[..]));
}

fn void test_merge_start_moved_handles_an_empty_path() @test {
    PolyRef[1] visited = { (PolyRef)1 };

    assert(nav::merge_corridor_start_moved({}, 0, visited[..]) == 0);
}

fn void test_merge_start_moved_strips_visited_polygons_except_the_last() @test {
    PolyRef[2] path = { (PolyRef)1, (PolyRef)2 };
    PolyRef[2] visited = { (PolyRef)1, (PolyRef)2 };

    usz count = nav::merge_corridor_start_moved(path[..], 2, visited[..]);

    PolyRef[2] expected = { (PolyRef)2, (PolyRef)2 };
    assert(count == 1 && same_refs(path[..], expected[..]));
}

fn void test_merge_start_moved_adds_new_visited_polygons_in_reverse_order() @test {
    PolyRef[3] path = { (PolyRef)1, (PolyRef)2, (PolyRef)0 };
    PolyRef[4] visited = { (PolyRef)1, (PolyRef)2, (PolyRef)3, (PolyRef)4 };

    usz count = nav::merge_corridor_start_moved(path[..], 2, visited[..]);

    PolyRef[3] expected = { (PolyRef)4, (PolyRef)3, (PolyRef)2 };
    assert(count == 3 && same_refs(path[..], expected[..]));
}

fn void test_merge_start_moved_adds_new_visited_polygons_up_to_capacity() @test {
    PolyRef[3] path = { (PolyRef)1, (PolyRef)2, (PolyRef)0 };
    PolyRef[5] visited = { (PolyRef)1, (PolyRef)2, (PolyRef)3, (PolyRef)4, (PolyRef)5 };

    usz count = nav::merge_corridor_start_moved(path[..], 2, visited[..]);

    PolyRef[3] expected = { (PolyRef)5, (PolyRef)4, (PolyRef)3 };
    assert(count == 3 && same_refs(path[..], expected[..]));
}

fn void test_merge_start_moved_keeps_a_path_that_shares_no_polygon() @test {
    PolyRef[2] path = { (PolyRef)1, (PolyRef)2 };
    PolyRef[2] visited = { (PolyRef)3, (PolyRef)4 };

    usz count = nav::merge_corridor_start_moved(path[..], 2, visited[..]);

    PolyRef[2] expected = { (PolyRef)1, (PolyRef)2 };
    assert(count == 2 && same_refs(path[..], expected[..]));
}

fn void test_merge_start_moved_keeps_unvisited_path_polygons() @test {
    PolyRef[3] path = { (PolyRef)1, (PolyRef)2, (PolyRef)0 };
    PolyRef[2] visited = { (PolyRef)1, (PolyRef)3 };

    usz count = nav::merge_corridor_start_moved(path[..], 2, visited[..]);

    PolyRef[3] expected = { (PolyRef)3, (PolyRef)1, (PolyRef)2 };
    assert(count == 3 && same_refs(path[..], expected[..]));
}

fn void test_merge_start_moved_keeps_unvisited_path_polygons_up_to_capacity() @test {
    PolyRef[2] path = { (PolyRef)1, (PolyRef)2 };
    PolyRef[2] visited = { (PolyRef)1, (PolyRef)3 };

    usz count = nav::merge_corridor_start_moved(path[..], 2, visited[..]);

    PolyRef[2] expected = { (PolyRef)3, (PolyRef)1 };
    assert(count == 2 && same_refs(path[..], expected[..]));
}

fn void test_corridor_move_position_merges_visited_polygons() @test {
    HandLevel* level = hall_level();
    defer destroy_hand_level(level);
    PathCorridor corridor = nav::create_path_corridor(mem, CORRIDOR_CAPACITY)!!;
    defer nav::destroy_path_corridor(&corridor);
    PolyRef[4] hall = hall_polys(level);
    Vec3 second_quad = { 1, 0, 7.5f };
    corridor.reset(hall[0], { 1, 0, 2.5f });
    corridor.set_corridor({ 1, 0, 17.5f }, hall[..]);

    corridor.move_position(second_quad, &level.query, &level.filter)!!;

    assert(corridor.first_poly() == hall[1]);
    assert(corridor.count == 3 && corridor.last_poly() == hall[3]);
    assert(same_xz(corridor.position, second_quad));
}

fn void test_corridor_find_corners_drops_near_corners() @test {
    HandLevel* level = hall_level();
    defer destroy_hand_level(level);
    PathCorridor corridor = nav::create_path_corridor(mem, CORRIDOR_CAPACITY)!!;
    defer nav::destroy_path_corridor(&corridor);
    PolyRef[4] hall = hall_polys(level);
    Vec3 start = { 1, 0, 2.5f };
    Vec3 target = { 1, 0, 17.5f };
    corridor.reset(hall[0], start);
    corridor.set_corridor(target, hall[..]);
    StraightPoint[CORNER_CAPACITY] corners;
    StraightPoint[CORNER_CAPACITY] straight;

    usz count = corridor.find_corners(corners[..], &level.query);
    PathResult pulled = level.query.straight_path(start, target, hall[..], straight[..])!!;

    assert(pulled.count == 2 && same_xz(straight[0].position, start), "the straight path starts at the position");
    assert(count == 1, "the start, at the position, is dropped");
    assert(corners[0].flags.end && same_xz(corners[0].position, target));
}

fn void test_local_boundary_gathers_nearest_walls() @test {
    HandLevel* level = hall_level();
    defer destroy_hand_level(level);
    Vec3 centre = { HALL_WIDTH * 0.5f, 0, 7.5f };
    LocalBoundary boundary;
    boundary.reset();

    boundary.update(
        ref:                   hand_ref(level, 1),
        position:              centre,
        collision_query_range: BOUNDARY_RANGE,
        query:                 &level.query,
        filter:                &level.filter,
    );

    uint near_walls;
    float previous = 0;
    foreach (segment : boundary.segments[:boundary.segment_count]) {
        assert(segment.distance_sqr >= previous, "nearest first");
        assert(segment.distance_sqr <= BOUNDARY_RANGE * BOUNDARY_RANGE);
        previous = segment.distance_sqr;
        if (segment.distance_sqr > HALL_WALL_DISTANCE_SQR + WALL_TOLERANCE) continue;
        bool along_wall = math::abs(segment.start.x - segment.end.x) <= WALL_TOLERANCE;
        bool at_side = math::abs(segment.start.x) <= WALL_TOLERANCE || math::abs(segment.start.x - HALL_WIDTH) <= WALL_TOLERANCE;
        assert(along_wall && at_side, "a side wall of the hall");
        near_walls++;
    }
    assert(near_walls == 2, "the two walls beside the centre");
    assert(boundary.segment_count > 2, "walls of the neighbouring quads within range");
}
