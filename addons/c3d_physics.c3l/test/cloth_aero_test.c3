module c3d_physics_cloth_test;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth @public;
import c3d::scene;

const uint FLAG_STEPS @private = 240;
const float PLATE_ANGLE @private = 30; // degrees between the plate and the wind
const float PLATE_WIND_SPEED @private = 8;
const uint PLATE_CELLS @private = 4;
const float PLATE_TOLERANCE @private = 0.01f;

struct FlagRun @private {
    Vec3[FLAG_STEPS]  midpoints;
    float[FLAG_STEPS] displacements;
}

fn void run_flag(uint cells, uint iterations, float wind_speed, FlagRun* run) @private {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_cloth_node(&fixture, add_grid(&fixture, cells));
    ClothDesc desc = pinned_desc(top_row(cells));
    desc.iterations = iterations;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    fixture.scene.add(node, (Wind){ .velocity = { 0, 0, wind_speed } });
    ClothState* state = state_of(&fixture, node);
    uint side = cells + 1;
    for (uint update = 0; update < FLAG_STEPS; update++) {
        step(&fixture, physics::DEFAULT_FIXED_DT);
        float total;
        for (uint column = 0; column < side; column++) {
            uint index = cells * side + column;
            total += (state.positions[index] - state.rest[index]).length();
        }
        run.midpoints[update] = state.positions[cells * side + cells / 2];
        run.displacements[update] = total / side;
    }
}

fn Vec3 window_mean(FlagRun* run, uint first, uint last) @private {
    Vec3 sum;
    for (uint step = first; step <= last; step++) sum += run.midpoints[step - 1];
    return sum / (float)(last - first + 1);
}

fn void print_gap(String label, FlagRun* first, FlagRun* second) @private {
    float worst;
    float worst_to_120;
    float window_total;
    for (uint step = 31; step <= FLAG_STEPS; step++) {
        float gap = (first.midpoints[step - 1] - second.midpoints[step - 1]).length();
        worst = math::max(worst, gap);
        if (step <= 120) worst_to_120 = math::max(worst_to_120, gap);
        if (step > 60 && step <= 120) window_total += gap;
    }
    float mean_gap = (window_mean(first, 61, 120) - window_mean(second, 61, 120)).length();
    io::printfn(
        "%s gap@30 %.4f @60 %.4f @90 %.4f @120 %.4f @240 %.4f max31-120 %.4f max31-240 %.4f mean61-120 %.4f of-mean61-120 %.4f disp@120 %.4f %.4f",
        label,
        (first.midpoints[29] - second.midpoints[29]).length(),
        (first.midpoints[59] - second.midpoints[59]).length(),
        (first.midpoints[89] - second.midpoints[89]).length(),
        (first.midpoints[119] - second.midpoints[119]).length(),
        (first.midpoints[239] - second.midpoints[239]).length(),
        worst_to_120,
        worst,
        window_total / 60,
        mean_gap,
        first.displacements[119],
        second.displacements[119],
    );
}

fn void test_flag_motion_across_tessellations_measurement() @test {
    float[7] winds = { 1, 1.5f, 2, 2.5f, 3, 4, 6 };
    uint[3] iteration_counts = { 8, 16, 32 };
    uint[3] resolutions = { 8, 16, 32 };
    foreach (wind : winds) {
        foreach (iterations : iteration_counts) {
            FlagRun[3] runs;
            foreach (index, cells : resolutions) run_flag(cells, iterations, wind, &runs[index]);
            io::printfn("wind %.1f iterations %d midpoints@120 %.4f %.4f %.4f | %.4f %.4f %.4f | %.4f %.4f %.4f",
                wind, iterations,
                runs[0].midpoints[119].x, runs[0].midpoints[119].y, runs[0].midpoints[119].z,
                runs[1].midpoints[119].x, runs[1].midpoints[119].y, runs[1].midpoints[119].z,
                runs[2].midpoints[119].x, runs[2].midpoints[119].y, runs[2].midpoints[119].z);
            print_gap("  8v16", &runs[0], &runs[1]);
            print_gap(" 16v32", &runs[1], &runs[2]);
            print_gap("  8v32", &runs[0], &runs[2]);
        }
    }
}

fn Geometry tilted_plate(Allocator allocator, uint cells, float angle_degrees, bool flipped) @private {
    uint side = cells + 1;
    float angle = angle_degrees * (float)math::PI / 180;
    Geometry plate = {
        .positions = alloc::new_array(allocator, Vec3, (sz)(side * side)),
        .indices   = alloc::new_array(allocator, uint, (sz)(6 * cells * cells)),
    };
    for (uint row = 0; row < side; row++) {
        for (uint column = 0; column < side; column++) {
            float slope = (float)row / cells;
            plate.positions[row * side + column] = {
                slope * (float)math::cos(angle),
                -slope * (float)math::sin(angle),
                (float)column / cells,
            };
        }
    }
    usz next;
    for (uint row = 0; row < cells; row++) {
        for (uint column = 0; column < cells; column++) {
            uint top_left = row * side + column;
            uint bottom_left = top_left + side;
            uint[6] corners = flipped
              ? (uint[6]){ top_left, top_left + 1, bottom_left, top_left + 1, bottom_left + 1, bottom_left }
              : (uint[6]){ top_left, bottom_left, top_left + 1, top_left + 1, bottom_left, bottom_left + 1 };
            plate.indices[next:6] = corners[..];
            next += 6;
        }
    }
    plate.finalize();
    return plate;
}

<*
 Acceleration of every free particle of a pinned plate after one substep, divided by the expected value.
*>
fn Vec3 plate_acceleration(ClothDesc desc, bool flipped) @private {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    GeometryId plate_geometry;
    @pool() {
        Geometry plate = tilted_plate(tmem, PLATE_CELLS, PLATE_ANGLE, flipped);
        plate_geometry = fixture.assets.add_geometry(&plate)!!;
    };
    Node* node = add_cloth_node(&fixture, plate_geometry);
    uint[] nose = alloc::new_array(tmem, uint, (sz)(PLATE_CELLS + 1));
    foreach (column, &pin : nose) *pin = (uint)column;
    desc.pins = nose;
    desc.substeps = 1;
    desc.damping = 0;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    fixture.scene.add(node, (Wind){ .velocity = { PLATE_WIND_SPEED, 0, 0 } });
    ClothState* state = state_of(&fixture, node);
    step(&fixture, physics::DEFAULT_FIXED_DT);

    Vec3 acceleration = state.accelerations[state.accelerations.len - 1];
    foreach (index, candidate : state.accelerations) {
        if (state.inverse_masses[index] == 0) continue;
        assert((candidate - acceleration).length() <= PLATE_TOLERANCE * acceleration.length());
    }
    return acceleration;
}

fn void test_lift_acts_across_the_wind() @test {
    ClothDesc desc = cloth::default_cloth_desc();
    desc.drag_coefficient = 0;
    float dynamic_pressure = 0.5f * cloth::AIR_DENSITY * PLATE_WIND_SPEED * PLATE_WIND_SPEED;
    float expected = dynamic_pressure * desc.lift_coefficient * (float)math::sin(2 * PLATE_ANGLE * (float)math::PI / 180) / desc.density;
    bool[2] windings = { false, true };
    foreach (flipped : windings) {
        Vec3 acceleration = plate_acceleration(desc, flipped);
        assert(acceleration.y > 0);
        assert(math::abs(acceleration.y - expected) <= PLATE_TOLERANCE * expected);
        assert(math::abs(acceleration.x) <= PLATE_TOLERANCE * expected);
    }
}

fn void test_drag_pushes_along_the_wind_side_of_the_normal() @test {
    ClothDesc desc = cloth::default_cloth_desc();
    desc.lift_coefficient = 0;
    float angle = PLATE_ANGLE * (float)math::PI / 180;
    float sine = (float)math::sin(angle);
    float cosine = (float)math::cos(angle);
    float dynamic_pressure = 0.5f * cloth::AIR_DENSITY * PLATE_WIND_SPEED * PLATE_WIND_SPEED;
    float scale = dynamic_pressure * desc.drag_coefficient * sine * sine / desc.density;
    Vec3 expected = { scale * sine, scale * cosine, 0 };
    bool[2] windings = { false, true };
    foreach (flipped : windings) {
        Vec3 acceleration = plate_acceleration(desc, flipped);
        assert((acceleration - expected).length() <= PLATE_TOLERANCE * expected.length());
    }
}
