module c3d_nav_test;

import std::math;
import c3d::nav @public;

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

fn float recorded_penalty(AvoidanceSample[] samples, Vec3 velocity) @private {
    float penalty = float::max;
    foreach (sample : samples) {
        if ((sample.velocity - velocity).length() < QUERY_TOLERANCE) penalty = math::min(penalty, sample.penalty);
    }
    return penalty;
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
