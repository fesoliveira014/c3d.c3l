module c3d_physics_cloth_test;

import std::math;
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth @public;
import c3d::scene;

const uint FLAG_STEPS @private = 120;
const float FLAG_WIND_SPEED @private = 1.5f; // m/s; below the speed at which the sheet starts to flutter
const float FLAG_MIDPOINT_TOLERANCE @private = 0.01f; // metres
const float FLAG_DISPLACEMENT_TOLERANCE @private = 0.01f; // fraction of the finer sheet's displacement
const float PLATE_ANGLE @private = 30; // degrees between the plate and the wind
const float PLATE_WIND_SPEED @private = 8;
const uint PLATE_CELLS @private = 4;
const float PLATE_TOLERANCE @private = 0.01f;
const uint MASS_CELLS @private = 4;
const Vec3 ORPHAN_POSITION @private = { 3, -3, 0 };
const float MASS_NODE_SCALE @private = 2; // the mass follows the world-space area, not the authored one
const float MASS_TOLERANCE @private = 1e-5f; // relative, for float inverse masses
const uint INTERIOR_TRIANGLES @private = 6; // triangles around a vertex of the regular grid
const uint EDGE_TRIANGLES @private = 3;
const uint ANTI_DIAGONAL_CORNER_TRIANGLES @private = 2; // the corners on the grid's split diagonal
const uint DIAGONAL_CORNER_TRIANGLES @private = 1;

fn uint adjacent_triangles(uint row, uint column, uint cells) @private {
    bool on_row_edge = row == 0 || row == cells;
    bool on_column_edge = column == 0 || column == cells;
    if (!on_row_edge && !on_column_edge) return INTERIOR_TRIANGLES;
    if (!on_row_edge || !on_column_edge) return EDGE_TRIANGLES;

    bool split_corner = (row == 0 && column == cells) || (row == cells && column == 0);
    return split_corner ? ANTI_DIAGONAL_CORNER_TRIANGLES : DIAGONAL_CORNER_TRIANGLES;
}

fn void test_cloth_mass_is_areal() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* node = add_cloth_node(&fixture, add_grid(&fixture, MASS_CELLS));
    node.local.scale = { MASS_NODE_SCALE, MASS_NODE_SCALE, MASS_NODE_SCALE };
    fixture.scene.update_world();
    ClothDesc desc = cloth::default_cloth_desc();
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    ClothState* state = state_of(&fixture, node);

    uint side = MASS_CELLS + 1;
    float triangle_area = 0.5f * (MASS_NODE_SCALE / MASS_CELLS) * (MASS_NODE_SCALE / MASS_CELLS);
    double total_mass;
    for (uint row = 0; row < side; row++) {
        for (uint column = 0; column < side; column++) {
            double mass = 1.0 / state.inverse_masses[row * side + column];
            double expected = (double)desc.density * adjacent_triangles(row, column, MASS_CELLS) * triangle_area / 3;
            assert(math::abs(mass - expected) <= MASS_TOLERANCE * expected);
            total_mass += mass;
        }
    }

    double sheet_area = MASS_NODE_SCALE * MASS_NODE_SCALE;
    assert(math::abs(total_mass - desc.density * sheet_area) <= MASS_TOLERANCE * total_mass);
}

fn void test_vertex_in_no_triangle_keeps_unit_mass() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    GeometryId geometry;
    @pool() {
        Geometry grid = hanging_grid(tmem, 1);
        Vec3[] positions = alloc::new_array(tmem, Vec3, grid.positions.len + 1);
        positions[:grid.positions.len] = grid.positions[..];
        positions[grid.positions.len] = ORPHAN_POSITION;
        grid.positions = positions;
        grid.finalize();
        geometry = fixture.assets.add_geometry(&grid)!!;
    };
    Node* node = add_cloth_node(&fixture, geometry);
    ClothDesc desc = cloth::default_cloth_desc();
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    ClothState* state = state_of(&fixture, node);

    uint orphan = (uint)state.positions.len - 1;
    assert(state.inverse_masses[orphan] == 1);
    assert(state.inverse_masses[0] != 1);
}

struct FlagPose @private {
    Vec3  edge_midpoint;
    float mean_edge_displacement;
}

fn FlagPose settled_flag(uint cells) @private {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_cloth_node(&fixture, add_grid(&fixture, cells));
    fixture.scene.add_cloth(&fixture.assets, node, pinned_desc(top_row(cells)))!!;
    fixture.scene.add(node, (Wind){ .velocity = { 0, 0, FLAG_WIND_SPEED } });
    ClothState* state = state_of(&fixture, node);
    for (uint update = 0; update < FLAG_STEPS; update++) step(&fixture, physics::DEFAULT_FIXED_DT);

    uint side = cells + 1;
    float total;
    for (uint column = 0; column < side; column++) {
        uint index = cells * side + column;
        total += (state.positions[index] - state.rest[index]).length();
    }
    return { .edge_midpoint = state.positions[cells * side + cells / 2], .mean_edge_displacement = total / side };
}

fn void test_flag_motion_matches_across_tessellations() @test {
    FlagPose coarse = settled_flag(8);
    FlagPose fine = settled_flag(16);
    assert((coarse.edge_midpoint - fine.edge_midpoint).length() <= FLAG_MIDPOINT_TOLERANCE);
    assert(math::abs(coarse.mean_edge_displacement - fine.mean_edge_displacement)
        <= FLAG_DISPLACEMENT_TOLERANCE * fine.mean_edge_displacement);
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
