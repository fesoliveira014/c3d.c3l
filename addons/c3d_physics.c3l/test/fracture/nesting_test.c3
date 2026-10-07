module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_nested_shells_assign_cavities_and_islands_independent_of_source_order() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureLimits limits = solid_limits();
    limits.scratch_bytes += 32768;
    FractureWorkspace workspace = create_fracture_workspace(&tracker, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint order = 0; order < 2; order++) {
        ContainmentFixture fixture;
        uint outer;
        uint cavity;
        uint island;
        if (order == 0) {
            outer = append_box_fixture(&fixture, { -3, -3, -3 }, { 3, 3, 3 });
            cavity = append_box_fixture(
                fixture: &fixture,
                lower: { -2, -2, -2 },
                upper: { 2, 2, 2 },
                reversed: true,
            );
            island = append_box_fixture(&fixture, { -1, -1, -1 }, { 1, 1, 1 });
        } else {
            island = append_box_fixture(&fixture, { -1, -1, -1 }, { 1, 1, 1 });
            outer = append_box_fixture(&fixture, { -3, -3, -3 }, { 3, 3, 3 });
            cavity = append_box_fixture(
                fixture: &fixture,
                lower: { -2, -2, -2 },
                upper: { 2, 2, 2 },
                reversed: true,
            );
        }
        for (uint domain = 0; domain < 2; domain++) {
            SolidScratch scratch = begin_solid_scratch(&workspace);
            SolidDiagnostic diagnostic;
            QuantizationGrid grid = { .step_exponent = -2, .center = { 5, -3, 7 } };
            ValidatedSolid solid = validate_solid(
                scratch: &scratch,
                source: fixture.mesh,
                grid: domain ? &grid : null,
                diagnostic: &diagnostic,
            )!!;
            uint outer_index = solid.nesting.root_to_shell[outer];
            uint cavity_index = solid.nesting.root_to_shell[cavity];
            uint island_index = solid.nesting.root_to_shell[island];
            assert(solid.nesting.shells[outer_index].parent == NO_SOLID_INDEX && solid.nesting.shells[outer_index].depth == 0);
            assert(solid.nesting.shells[cavity_index].parent == outer_index && solid.nesting.shells[cavity_index].depth == 1);
            assert(solid.nesting.shells[island_index].parent == cavity_index && solid.nesting.shells[island_index].depth == 2);
            assert(solid.raw_counts.shell_pairs == 6 && solid.raw_counts.containment_queries == 3);
            assert(solid.raw_counts.containment_faces > 0 && solid.raw_counts.containment_faces < 36);
            if (domain) {
                assert(solid.grid_counts.shell_pairs == 6 && solid.grid_counts.containment_queries == 3);
                assert(solid.grid_counts.containment_faces == solid.raw_counts.containment_faces);
            }
            assert(diagnostic.reason == SolidFailure.NONE && scratch.exact.count == 0);
        }
    }
    assert(tracker.total_allocation_count() == 1);
}

fn void test_shell_orientation_rejects_wrong_cavity_and_island_winding() @test {
    FractureLimits limits = solid_limits();
    limits.scratch_bytes += 32768;
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint wrong = 0; wrong < 3; wrong++) {
        ContainmentFixture fixture;
        append_box_fixture(
            fixture: &fixture,
            lower: { -3, -3, -3 },
            upper: { 3, 3, 3 },
            reversed: wrong == 0,
        );
        append_box_fixture(
            fixture: &fixture,
            lower: { -2, -2, -2 },
            upper: { 2, 2, 2 },
            reversed: wrong != 1,
        );
        append_box_fixture(
            fixture: &fixture,
            lower: { -1, -1, -1 },
            upper: { 1, 1, 1 },
            reversed: wrong == 2,
        );
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        assert(@catch(validate_solid(
            scratch: &scratch,
            source: fixture.mesh,
            grid: null,
            diagnostic: &diagnostic,
        )) == INVALID_SOLID);
        assert(diagnostic.reason == SolidFailure.WRONG_ORIENTATION && diagnostic.shell_index == wrong);
        assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES && scratch.exact.count == 0);
    }
}

fn void test_disconnected_shell_bounds_prune_containment_and_quantized_contact_faults() @test {
    FractureLimits limits = solid_limits();
    limits.scratch_bytes += 32768;
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    append_box_fixture(&fixture, { -2, -1, -1 }, { -0.0625, 1, 1 });
    append_box_fixture(&fixture, { 0.0625, -1, -1 }, { 2, 1, 1 });
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: &scratch,
        source: fixture.mesh,
        grid: null,
        diagnostic: &diagnostic,
    )!!;
    assert(solid.nesting.shells.len == 2);
    foreach (shell : solid.nesting.shells) assert(shell.depth == 0 && shell.parent == NO_SOLID_INDEX);
    assert(solid.raw_counts.shell_pairs == 2 && solid.raw_counts.containment_queries == 0);
    QuantizationGrid grid = { .step_exponent = 0 };
    scratch = begin_solid_scratch(&workspace);
    assert(@catch(validate_solid(
        scratch: &scratch,
        source: fixture.mesh,
        grid: &grid,
        diagnostic: &diagnostic,
    )) == NUMERICAL_FAILURE);
    assert(diagnostic.reason == SolidFailure.TRIANGLE_INTERSECTION);
    assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES && scratch.exact.count == 0);
}
