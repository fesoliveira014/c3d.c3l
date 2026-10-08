module c3d_nav_test;

import std::math;
import c3d::nav @public;
import c3d::scene;

const uint  GRID_COLUMNS @private = 4;
const uint  GRID_ROWS @private = 5;
const uint  GRID_POOL @private = 128; // each item covers four cells
const float GRID_CELL @private = 1;
const float GRID_ITEM_PITCH @private = 2; // metres between item centres, so items never share a cell
const float GRID_ITEM_HALF @private = 0.5f;
const usz   GRID_QUERY_CAPACITY @private = 32;
const float AVOIDING_RADIUS @private = 0.5f;
const float AVOIDING_SPEED @private = 3.5f;
const Vec3  OBSTACLE_AHEAD @private = { 0, 0, 3 };
const usz   SAMPLE_CAPACITY @private = 128;
const float SIDEWAYS_SHARE @private = 0.1f; // of the speed; a smaller sideways part is not a detour
const uint  QUEUE_ITERATIONS @private = 100;
const uint  QUEUE_UPDATE_LIMIT @private = 100;
const uint  CROWD_AGENTS @private = 8;
const float CROWD_STEP @private = 1.0f / 60.0f;
const uint  ARRIVAL_UPDATES @private = 600;
const float STOPPED_SPEED @private = 0.05f; // metres per second
const float CROSSING_DISTANCE @private = 8;
const float RESOLVE_FACTOR @private = 0.7f; // mirrors the crowd's collision resolve factor
const uint  REPLAN_LEAD_UPDATES @private = 30;
const uint  SHIFT_UPDATES @private = 60;
const float STEP_TOLERANCE @private = 1.5f; // of one update's travel at full speed
const float ISLAND_EDGE_GAP @private = 1.5f; // metres; the eroded floor edge, a cell of rounding and one agent radius

fn float recorded_penalty(AvoidanceSample[] samples, Vec3 velocity) @private {
    float penalty = float::max;
    foreach (sample : samples) {
        if ((sample.velocity - velocity).length() < QUERY_TOLERANCE) penalty = math::min(penalty, sample.penalty);
    }
    return penalty;
}

fn Crowd create_test_crowd(QueryFixture* fixture) @private {
    return nav::create_crowd(
        allocator: mem,
        desc:      { .max_agents = CROWD_AGENTS, .max_agent_radius = nav::default_nav_agent_params().radius },
        mesh:      &fixture.level.mesh,
        scene:     &fixture.level.scene,
    )!!;
}

fn float xz_distance(Vec3 first, Vec3 second) @private {
    Vec3 offset = second - first;
    offset.y = 0;
    return offset.length();
}

fn bool arrived(CrowdAgent* agent, Vec3 target) @private {
    return xz_distance(agent.position, target) < agent.params.radius && agent.velocity.length() < STOPPED_SPEED;
}

fn void send_agent(Crowd* crowd, uint index, Vec3 target) @private {
    NearestPoly goal = crowd.query.find_nearest_poly(target, crowd.query_half_extents(), crowd.filter(0))!!;
    crowd.request_move_target(index, goal.ref, goal.point);
}

// Updates until the agent arrives or the limit passes; the updates taken.
fn uint walk_until_arrived(Crowd* crowd, CrowdAgent* agent, Vec3 target) @private {
    uint updates;
    while (updates < ARRIVAL_UPDATES && !arrived(agent, target)) {
        crowd.update(CROWD_STEP);
        updates++;
    }
    return updates;
}

fn void test_proximity_grid_returns_overlapping_items_once() @test {
    ProximityGrid grid = nav::create_proximity_grid(mem, GRID_POOL, GRID_CELL)!!;
    defer nav::destroy_proximity_grid(&grid);
    for (uint row = 0; row < GRID_ROWS; row++) {
        for (uint column = 0; column < GRID_COLUMNS; column++) {
            float x = (column + 0.5f) * GRID_ITEM_PITCH;
            float z = (row + 0.5f) * GRID_ITEM_PITCH;
            grid.add_item(
                id:    (ushort)(column + row * GRID_COLUMNS),
                min_x: x - GRID_ITEM_HALF,
                min_z: z - GRID_ITEM_HALF,
                max_x: x + GRID_ITEM_HALF,
                max_z: z + GRID_ITEM_HALF,
            );
        }
    }
    ushort[GRID_QUERY_CAPACITY] ids;

    // Cells 2 to 5 along X and 2 to 7 along Z: columns 1 and 2 of rows 1 to 3.
    usz count = grid.query_items(
        min_x:   2.5f,
        min_z:   2.5f,
        max_x:   5.5f,
        max_z:   7.5f,
        out_ids: ids[..],
    );

    assert(count == 6);
    for (uint row = 1; row <= 3; row++) {
        for (uint column = 1; column <= 2; column++) {
            uint found;
            foreach (id : ids[:count]) {
                if (id == column + row * GRID_COLUMNS) found++;
            }
            assert(found == 1, "column %d row %d once", column, row);
        }
    }
}

fn void test_avoidance_adaptive_steers_around_a_circle() @test {
    ObstacleAvoidanceQuery avoidance = nav::create_obstacle_avoidance_query(mem, 1, 1)!!;
    defer nav::destroy_obstacle_avoidance_query(&avoidance);
    avoidance.add_circle(OBSTACLE_AHEAD, AVOIDING_RADIUS, {}, {});
    Vec3 forward = { 0, 0, AVOIDING_SPEED };
    ObstacleAvoidanceParams params = nav::default_obstacle_avoidance_params();
    // A full bias with one level samples only the desired velocity.
    ObstacleAvoidanceParams desired_only = params;
    desired_only.velocity_bias = 1;
    desired_only.adaptive_depth = 1;
    AvoidanceSample[SAMPLE_CAPACITY] samples;
    AvoidanceSample[1] desired;

    SampledVelocity avoided = avoidance.sample_velocity_adaptive(
        position:         {},
        radius:           AVOIDING_RADIUS,
        max_velocity:     AVOIDING_SPEED,
        velocity:         forward,
        desired_velocity: forward,
        params:           &params,
        out_samples:      samples[..],
    );
    SampledVelocity straight = avoidance.sample_velocity_adaptive(
        position:         {},
        radius:           AVOIDING_RADIUS,
        max_velocity:     AVOIDING_SPEED,
        velocity:         forward,
        desired_velocity: forward,
        params:           &desired_only,
        out_samples:      desired[..],
    );

    assert(straight.recorded == 1 && (desired[0].velocity - forward).length() < QUERY_TOLERANCE);
    assert(math::abs(avoided.velocity.x) > AVOIDING_SPEED * SIDEWAYS_SHARE, "steers sideways");
    assert(recorded_penalty(samples[:avoided.recorded], avoided.velocity) < desired[0].penalty);
}

fn void test_path_queue_answers_requests_over_updates() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    add_stripes(fixture, 2);
    build_level(fixture);
    PathQueue queue = nav::create_path_queue(mem, PATH_CAPACITY, QUERY_NODES, &fixture.level.mesh)!!;
    defer nav::destroy_path_queue(&queue);
    float side = fixture.level.builder.tile_world_size * 2;
    Vec3 start = { 1, 0, 1 };
    PolyRef start_ref = nearest(fixture, start).ref;
    Vec3[nav::MAX_PATH_QUEUE] goals;
    PathQueueRef[nav::MAX_PATH_QUEUE] requests;
    foreach (index, &goal : goals) {
        *goal = { side - 1, 0, 1 + index * (side - 2) / (nav::MAX_PATH_QUEUE - 1) };
        requests[index] = queue.request(
            start_ref: start_ref,
            end_ref:   nearest(fixture, *goal).ref,
            start:     start,
            end:       *goal,
            filter:    &fixture.filter,
        );
    }

    PathQueueRef overflow = queue.request(
        start_ref: start_ref,
        end_ref:   start_ref,
        start:     start,
        end:       start,
        filter:    &fixture.filter,
    );
    // Results are collected as they finish, since an uncollected result is dropped after two updates.
    bool[nav::MAX_PATH_QUEUE] collected;
    uint collected_count;
    uint updates;
    PolyRef[PATH_CAPACITY] queued_path;
    while (collected_count < nav::MAX_PATH_QUEUE && updates < QUEUE_UPDATE_LIMIT) {
        queue.update(QUEUE_ITERATIONS);
        updates++;
        foreach (index, ref : requests) {
            if (collected[index] || queue.request_state(ref) != DONE) continue;
            PathResult queued = queue.path_result(ref, queued_path[..])!!;
            PathResult direct = path_between(fixture, start, goals[index], &fixture.filter);
            assert(same_refs(queued_path[:queued.count], fixture.path[:direct.count]), "request %d", index);
            assert(queued.partial == direct.partial);
            collected[index] = true;
            collected_count++;
        }
    }

    assert(overflow == (PathQueueRef)0, "every slot was taken");
    assert(collected_count == nav::MAX_PATH_QUEUE);
    assert(updates > 1, "the iteration budget spreads the requests over updates");
    foreach (ref : requests) assert(queue.request_state(ref) == FAILED, "collected requests leave the queue");
}

fn void test_agent_reaches_its_target_and_stops() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    build_level(fixture);
    Crowd crowd = create_test_crowd(fixture);
    defer nav::destroy_crowd(&crowd);
    Vec3 target = { 14, 0, 4 };
    uint index = crowd.add_agent({ 4, 0, 4 }, nav::default_nav_agent_params())!!;
    send_agent(&crowd, index, target);

    uint updates = walk_until_arrived(&crowd, crowd.agent(index), target);

    assert(arrived(crowd.agent(index), target), "not arrived after %d updates", updates);
    assert(crowd.agent(index).target_state == VALID && !crowd.agent(index).partial);
}

fn void test_crowd_agent_reaches_its_target_after_shift_origin() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    build_level(fixture);
    Crowd crowd = create_test_crowd(fixture);
    defer nav::destroy_crowd(&crowd);
    Scene* scene = &fixture.level.scene;
    Vec3 target = { 14, 0, 4 };
    Node* node = add_agent_node(fixture, { 4, 0, 4 });
    scene.set_nav_target(node, target);
    float step_limit = nav::default_nav_agent_params().max_speed * CROWD_STEP * STEP_TOLERANCE;
    Vec3 travelled = {};
    uint agent_index;

    run_crowd(fixture, &crowd, SHIFT_UPDATES);
    agent_index = scene.get(node, CrowdAgentRuntime).index;
    Vec3 before = node.world_position();
    assert(xz_distance(before, target) > nav::default_nav_agent_params().radius, "still walking at the shift");
    scene.shift_origin(SHIFT_OFFSET);
    scene.update_world();
    fixture.level.mesh.shift_origin(SHIFT_OFFSET);
    crowd.shift_origin(SHIFT_OFFSET);
    scene.shift_navigation(SHIFT_OFFSET);
    travelled += SHIFT_OFFSET;
    Vec3 previous = node.world_position() + travelled;
    assert(xz_distance(previous, before) < step_limit);

    uint updates;
    while (updates < ARRIVAL_UPDATES && !arrived(crowd.agent(agent_index), target - travelled)) {
        run_crowd(fixture, &crowd, 1);
        Vec3 current = node.world_position() + travelled;
        assert(xz_distance(current, previous) < step_limit, "jumped at update %d", updates);
        previous = current;
        updates++;
    }

    CrowdAgent* agent = crowd.agent(agent_index);
    assert(arrived(agent, target - travelled), "not arrived after %d updates", updates);
    assert(agent.target_state == VALID && !agent.partial);
}

fn void test_two_crossing_agents_do_not_overlap_beyond_radius() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    build_level(fixture);
    Crowd crowd = create_test_crowd(fixture);
    defer nav::destroy_crowd(&crowd);
    NavAgentParams params = nav::default_nav_agent_params();
    float middle = fixture.level.builder.tile_world_size;
    Vec3 west = { middle - CROSSING_DISTANCE * 0.5f, 0, middle };
    Vec3 east = { middle + CROSSING_DISTANCE * 0.5f, 0, middle };
    uint westward = crowd.add_agent(east, params)!!;
    uint eastward = crowd.add_agent(west, params)!!;
    send_agent(&crowd, westward, west);
    send_agent(&crowd, eastward, east);
    CrowdAgent* first = crowd.agent(westward);
    CrowdAgent* second = crowd.agent(eastward);
    float allowed = 2 * params.radius - params.radius * (1 - RESOLVE_FACTOR);

    uint updates;
    while (updates < ARRIVAL_UPDATES && !(arrived(first, west) && arrived(second, east))) {
        crowd.update(CROWD_STEP);
        updates++;
        float distance = xz_distance(first.position, second.position);
        assert(distance > allowed, "%f apart at update %d", distance, updates);
    }

    assert(arrived(first, west) && arrived(second, east), "not arrived after %d updates", updates);
}

fn void test_agent_replans_when_its_corridor_is_invalidated() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    build_level(fixture);
    Crowd crowd = create_test_crowd(fixture);
    defer nav::destroy_crowd(&crowd);
    Vec3 target = { 17, 0, 17 };
    uint index = crowd.add_agent({ 2, 0, 2 }, nav::default_nav_agent_params())!!;
    send_agent(&crowd, index, target);
    for (uint update = 0; update < REPLAN_LEAD_UPDATES; update++) crowd.update(CROWD_STEP);
    CrowdAgent* agent = crowd.agent(index);
    PolyRef before = agent.corridor.first_poly();

    fixture.level.scene.@each(NavSource; entity, source) {
        source.mark_changed();
    };
    NavSyncResult rebuilt = build_everything(fixture.level);
    crowd.update(CROWD_STEP);
    bool replanned = agent.target_replan;
    uint updates = walk_until_arrived(&crowd, agent, target);

    assert(rebuilt.installed > 0, "the reinstall ran");
    assert(!fixture.level.mesh.is_valid_ref(before), "the reinstall retired the corridor's refs");
    assert(replanned, "the reinstall raised a replan");
    assert(arrived(agent, target), "not arrived after %d updates", updates);
}

fn void test_partial_target_walks_to_the_closest_polygon() @test {
    QueryFixture* fixture = floor_level(1);
    defer destroy_level(fixture);
    add_platform(fixture);
    build_level(fixture);
    Crowd crowd = create_test_crowd(fixture);
    defer nav::destroy_crowd(&crowd);
    Vec3 island = { PLATFORM_CENTRE.x, PLATFORM_SIZE.y, PLATFORM_CENTRE.z };
    NearestPoly top = crowd.query.find_nearest_poly(island, crowd.query_half_extents(), crowd.filter(0))!!;
    uint index = crowd.add_agent({ 1.5f, 0, PLATFORM_CENTRE.z }, nav::default_nav_agent_params())!!;
    crowd.request_move_target(index, top.ref, top.point);
    CrowdAgent* agent = crowd.agent(index);

    uint updates;
    while (updates < ARRIVAL_UPDATES && !(agent.target_state == VALID && arrived(agent, agent.corridor.target))) {
        crowd.update(CROWD_STEP);
        updates++;
    }

    Vec3 offset = agent.position - PLATFORM_CENTRE;
    float gap = math::max(math::abs(offset.x), math::abs(offset.z)) - PLATFORM_SIZE.x * 0.5f;
    assert(agent.partial, "the island is unreachable");
    assert(agent.corridor.last_poly() != top.ref && agent.position.y < PLATFORM_SIZE.y * 0.5f, "on the floor");
    assert(arrived(agent, agent.corridor.target), "not arrived after %d updates", updates);
    assert(gap < ISLAND_EDGE_GAP, "%f m from the island", gap);
}
