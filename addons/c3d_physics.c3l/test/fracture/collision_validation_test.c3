module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_collision_validation_distinguishes_convex_and_concave_surfaces() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 5; shape++) {
        ContainmentFixture fixture;
        partition_fixture(&fixture, shape);
        SolidScratch scratch = begin_solid_scratch(&workspace);
        usz saved = scratch.used;
        CollisionMeshValidation checked = validate_collision_mesh(
            scratch: &scratch, mesh: fixture.mesh, single_shell: shape == 0 || shape == 4, resolution: 0.001f,
        )!!;
        assert(checked.six_volume.used && !checked.six_volume.negative);
        assert(checked.rounding_bound.used && !checked.rounding_bound.negative);
        assert(checked.convex == (shape == 0));
        assert(scratch.used == saved && scratch.exact.count == 0);
        check_collision_volume(
            scratch: scratch.exact, first: checked.six_volume, second: checked.six_volume, bound: {},
        )!!;
        assert(@catch(check_collision_volume(
            scratch: scratch.exact, first: checked.six_volume, second: {}, bound: {},
        )) == NUMERICAL_FAILURE);
    }
}

fn void test_collision_validation_rejects_cone_inversion_collapse_and_new_zero_cone_volume() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ConvexCell cell = collision_test_box(
        scratch: &scratch, lower: { -1, -1, -1 }, upper: { 1, 1, 1 }, quantized: false,
    );
    PlaneTriple[4] exact = { cell.vertices[0], cell.vertices[4], cell.vertices[6], cell.vertices[1] };
    Vec3[4] positions;
    foreach (index, point : exact) positions[index] = rounded_source_position(scratch.exact, point)!!;
    check_collision_cone(scratch.exact, exact, positions)!!;
    positions[3].x = -1;
    assert(@catch(check_collision_cone(scratch.exact, exact, positions)) == NUMERICAL_FAILURE);
    positions[3].x = -2;
    assert(@catch(check_collision_cone(scratch.exact, exact, positions)) == NUMERICAL_FAILURE);
    exact[3] = cell.vertices[2];
    positions[3] = rounded_source_position(scratch.exact, exact[3])!!;
    check_collision_cone(scratch.exact, exact, positions)!!;
    positions[3].x = 0;
    assert(@catch(check_collision_cone(scratch.exact, exact, positions)) == NUMERICAL_FAILURE);
    assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
}

fn void test_collision_validation_restores_scratch_after_invalid_geometry() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 0);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    usz saved = scratch.used;
    uint swap = fixture.indices[0];
    fixture.indices[0] = fixture.indices[1];
    fixture.indices[1] = swap;
    assert(@catch(validate_collision_mesh(
        scratch: &scratch, mesh: fixture.mesh, single_shell: true, resolution: 0.001f,
    )) == INVALID_SOLID);
    assert(scratch.used == saved && scratch.exact.count == 0);
    fixture = {};
    partition_fixture(&fixture, 0);
    CollisionMeshValidation recovered = validate_collision_mesh(
        scratch: &scratch, mesh: fixture.mesh, single_shell: true, resolution: 0.001f,
    )!!;
    assert(recovered.convex && scratch.used == saved && scratch.exact.count == 0);
}
