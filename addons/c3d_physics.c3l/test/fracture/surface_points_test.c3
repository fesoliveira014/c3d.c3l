module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_surface_point_map_welds_exact_points_and_survives_patch_permutations() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        ContainmentFixture fixture;
        SolidScratch scratch = begin_solid_scratch(&workspace);
        BoundaryPatch[] patches = point_map_fixture(&scratch, &fixture, domain != 0);
        QuantizationGrid grid = { .step_exponent = -2 };
        QuantizationGrid* coordinate_grid = domain ? &grid : null;
        SurfacePointMap first = map_surface_points(&scratch, patches, coordinate_grid)!!;
        assert(first.exact.len == 12 && first.positions.len == 12 && first.patch_offsets.len == patches.len + 1);
        foreach (uint patch_index, patch : patches) foreach (uint point, vertex : patch.boundary.vertices) {
            uint identity = first.vertices[first.patch_offsets[patch_index] + point];
            assert(same_vertex(scratch.exact, vertex, first.exact[identity])!!);
            Vec3 expected = rounded_source_position(scratch.exact, vertex, coordinate_grid)!!;
            for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(expected[axis], uint) == bitcast(first.positions[identity][axis], uint));
        }
        BoundaryPatch[] reversed = reserve_elements(&scratch, BoundaryPatch, patches.len)!!;
        foreach (uint index, patch : patches) reversed[patches.len - index - 1] = patch;
        SurfacePointMap second = map_surface_points(&scratch, reversed, coordinate_grid)!!;
        assert(first.exact.len == second.exact.len);
        foreach (uint index, point : first.exact) {
            assert(same_vertex(scratch.exact, point, second.exact[index])!!);
            for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(first.positions[index][axis], uint) == bitcast(second.positions[index][axis], uint));
        }
        foreach (uint index, patch : patches) foreach (uint point, vertex : patch.boundary.vertices) {
            uint other = (uint)patches.len - index - 1;
            assert(first.vertices[first.patch_offsets[index] + point] == second.vertices[second.patch_offsets[other] + point]);
        }
        assert(scratch.exact.count == 0);
    }
}

fn void test_surface_point_map_empty_and_capacity_recovery_preserve_inputs() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    usz initial = scratch.used;
    SurfacePointMap empty = map_surface_points(&scratch, {})!!;
    assert(!empty.exact.len && !empty.positions.len && scratch.used == initial);
    ContainmentFixture fixture;
    BoundaryPatch[] patches = point_map_fixture(&scratch, &fixture, false);
    PlaneTriple first = patches[0].boundary.vertices[0];
    usz saved = scratch.used;
    scratch.peak = saved;
    SurfacePointMap complete = map_surface_points(&scratch, patches)!!;
    usz required = scratch.peak;
    assert(complete.positions.len == 12 && scratch.used < required);
    for (usz capacity = saved; capacity < required; capacity += 137) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(map_surface_points(&scratch, patches)) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
        foreach (uint axis, plane : first) assert(plane == patches[0].boundary.vertices[0][axis]);
    }
    scratch.used = saved;
    scratch.storage = workspace.storage[:required];
    uint held = EXACT_TEMPORARIES - FRAME_CONVERSION_TEMPORARIES + 1;
    for (uint index = 0; index < held; index++) (void)scratch.exact.take()!!;
    assert(@catch(map_surface_points(&scratch, patches)) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == held);
    scratch.exact.count = 0;
    complete = map_surface_points(&scratch, patches)!!;
    assert(complete.positions.len == 12 && scratch.exact.count == 0);
}

fn BoundaryPatch[] point_map_fixture(SolidScratch* scratch, ContainmentFixture* fixture, bool quantized) @local {
    partition_fixture(fixture, 0);
    SolidSurface surface = partition_surface(scratch, fixture, quantized);
    SourceConstructions source = build_source_constructions(scratch, &surface)!!;
    SolidPartition partition = partition_solid(scratch, &surface, &source)!!;
    ExactPlane* cut = &reserve_elements(scratch, ExactPlane, 1)!![0];
    plane_from_integers(scratch.exact, cut, { 1, 0, 0, 0 })!!;
    CellSplit split = split_convex_cell(scratch, &partition.first.cell, cut)!!;
    partition.first.cell = split.negative;
    BoundaryCellFace[] faces = index_boundary_cell_faces(scratch, &partition)!!;
    BoundaryPatch[] source_patches = source_boundary_patches(
        scratch: scratch,
        surface: &surface,
        source: &source,
        partition: &partition,
        cuts: { cut },
        faces: faces,
    )!!;
    PlanarSegment[] segments = collect_boundary_segments(
        scratch: scratch,
        partition: &partition,
        plane: cut,
        faces: faces,
    )!!;
    BoundaryPatch[] patches = reserve_elements(scratch, BoundaryPatch, source_patches.len + 1)!!;
    patches[:source_patches.len] = source_patches[..];
    patches[^1] = create_boundary_patch(
        scratch: scratch,
        plane: cut,
        segments: segments,
        reversed: false,
    )!!;
    reconcile_patch_boundaries(scratch, patches)!!;
    return patches;
}
