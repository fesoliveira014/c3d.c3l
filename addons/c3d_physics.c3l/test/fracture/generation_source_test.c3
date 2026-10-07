module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_generation_sources_share_one_grid_and_preserve_raw_inputs() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture first;
    ContainmentFixture second;
    append_box_fixture(&first, { -2, -1, -1 }, { 1, 1, 1 });
    append_box_fixture(&second, { 0, -1, -1 }, { 3, 1, 1 });
    Vec3[8] first_positions;
    Vec3[8] second_positions;
    first_positions[..] = first.positions[:8];
    second_positions[..] = second.positions[:8];
    SolidScratch scratch = begin_solid_scratch(&workspace);
    PreparedGeneration prepared = prepare_generation_sources(&scratch, { first.mesh, second.mesh }, 0.001)!!;
    assert(prepared.count == 2);
    foreach (uint index, source : prepared.sources) {
        assert(source.solid.surface.validated && source.solid.surface.grid.len == 8 && source.constructions.faces.len == 12);
        for (uint point = 0; point < 8; point++) {
            Vec3 original = index ? second_positions[point] : first_positions[point];
            assert(source.solid.surface.grid[point] == quantize_point(scratch.exact, prepared.grid, original)!!);
            Vec3 current = index ? second.positions[point] : first.positions[point];
            for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(current[axis], uint) == bitcast(original[axis], uint));
        }
    }
    SolidPartition intersection = partition_boolean_cells(
        scratch: &scratch,
        first: &prepared.sources[0].solid.surface,
        first_source: &prepared.sources[0].constructions,
        second: &prepared.sources[1].solid.surface,
        second_source: &prepared.sources[1].constructions,
        operation: BooleanOperation.INTERSECTION,
    )!!;
    assert(intersection.occupied_count != 0 && scratch.exact.count == 0);
}

fn void test_generation_sources_validate_raw_geometry_before_quantization() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    fixture.positions[1] = fixture.positions[0];
    SolidScratch scratch = begin_solid_scratch(&workspace);
    usz saved = scratch.used;
    assert(@catch(prepare_generation_sources(&scratch, { fixture.mesh }, bitcast((uint)1, float))) == INVALID_SOLID);
    assert(scratch.used == saved && scratch.exact.count == 0);
    tetra_fixture(&fixture);
    foreach (&position : fixture.positions[:4]) *position *= 0.001f;
    assert(@catch(prepare_generation_sources(&scratch, { fixture.mesh }, 1.0)) == NUMERICAL_FAILURE);
    assert(scratch.used == saved && scratch.exact.count == 0);
    PreparedGeneration prepared = prepare_generation_sources(&scratch, { fixture.mesh }, 0.00001)!!;
    assert(prepared.sources[0].solid.surface.validated && scratch.exact.count == 0);
}

fn void test_generation_sites_distinguish_input_and_quantized_duplicates() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    QuantizationGrid grid = { .step_exponent = -2 };
    usz saved = scratch.used;
    assert(@catch(prepare_voronoi_sites(
        scratch: &scratch,
        grid: grid,
        sites: {},
        max_sites: 8,
    )) == c3d::INVALID_ARGUMENT);
    Vec3[2] duplicate = { {}, { -0.0, 0, 0 } };
    assert(@catch(prepare_voronoi_sites(
        scratch: &scratch,
        grid: grid,
        sites: duplicate[..],
        max_sites: 8,
    )) == c3d::INVALID_ARGUMENT);
    Vec3[2] invalid = { {}, { bitcast((uint)0x7f800000, float), 0, 0 } };
    assert(@catch(prepare_voronoi_sites(
        scratch: &scratch,
        grid: grid,
        sites: invalid[..],
        max_sites: 8,
    )) == c3d::INVALID_ARGUMENT);
    Vec3[3] ordered = { { 2, 3, 4 }, { -1, -2, -3 }, {} };
    assert(@catch(prepare_voronoi_sites(
        scratch: &scratch,
        grid: grid,
        sites: ordered[..],
        max_sites: 2,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == 0);
    GridPoint[] prepared = prepare_voronoi_sites(
        scratch: &scratch,
        grid: grid,
        sites: ordered[..],
        max_sites: 3,
    )!!;
    assert(prepared[0] == (GridPoint){ 8, 12, 16 } && prepared[1] == (GridPoint){ -4, -8, -12 } && prepared[2] == (GridPoint){});
    scratch.used = saved;
    Vec3[2] collapsed = { {}, { 0.01, 0, 0 } };
    prepared = prepare_voronoi_sites(
        scratch: &scratch,
        grid: grid,
        sites: collapsed[..],
        max_sites: 2,
    )!!;
    SolidPartition empty_source;
    assert(@catch(partition_voronoi_cells(&scratch, &empty_source, prepared)) == NUMERICAL_FAILURE);
    scratch.used = saved;
    GridPoint[] one = prepare_voronoi_sites(
        scratch: &scratch,
        grid: grid,
        sites: { { float::max, -float::max, float::max } },
        max_sites: 1,
    )!!;
    assert(one.len == 1 && one[0] == (GridPoint){});
}

fn void test_generation_source_capacity_restores_cursor_and_reuses_inputs() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 1);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    usz saved = scratch.used;
    PreparedGeneration prepared = prepare_generation_sources(&scratch, { fixture.mesh }, 0.001)!!;
    usz required = scratch.peak;
    assert(prepared.sources[0].solid.nesting.shells.len == 2);
    for (usz capacity = saved; capacity < required; capacity += 509) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(prepare_generation_sources(&scratch, { fixture.mesh }, 0.001)) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
    }
    scratch.used = saved;
    scratch.storage = workspace.storage[:required];
    prepared = prepare_generation_sources(&scratch, { fixture.mesh }, 0.001)!!;
    assert(prepared.sources[0].solid.nesting.shells.len == 2 && scratch.exact.count == 0);
}
