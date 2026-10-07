module c3d::physics::fracture;

import std::time;

fn void test_fracture_statistics_count_work_and_reset_for_reuse() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, {
        .scratch_bytes = 8 * 1024 * 1024,
        .max_vertices = 4096, .max_triangles = 8192,
        .max_pieces = 8, .max_sites = 8, .max_hulls = 1024,
        .resolution_m = 0.0001f,
    })!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 0);
    SolidSurface surface = partition_surface(&scratch, &fixture, false);
    SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
    SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
    ExactPlane cut;
    plane_from_integers(scratch.exact, &cut, { 1, 0, 0, 0 })!!;
    CellSplit split = split_convex_cell(&scratch, &partition.first.cell, &cut)!!;
    partition.first.cell = split.negative;
    BoundaryCellFace[] faces = index_boundary_cell_faces(&scratch, &partition)!!;
    PlanarSegment[] segments = collect_boundary_segments(
        scratch: &scratch, partition: &partition, plane: &cut, faces: faces,
    )!!;
    BoundaryPatch patch = create_boundary_patch(
        scratch: &scratch, plane: &cut, segments: segments, reversed: false,
    )!!;
    PatchTriangles triangles = triangulate_boundary_patch(&scratch, &patch)!!;
    assert(triangles.triangles.len == 2);
    assert(scratch.exact.statistics.cell_split_count == 1);
    assert(scratch.exact.statistics.scratch_peak == scratch.peak);
    assert(scratch.exact.statistics.max_planar_segments >= 4);
    assert(scratch.exact.statistics.max_planar_points >= 4);
    assert(scratch.exact.statistics.max_patch_vertices == 4);
    assert(scratch.exact.statistics.max_patch_predicates > 0);
    assert(scratch.exact.statistics.max_patch_nanoseconds > 0);
    scratch = begin_solid_scratch(&workspace);
    assert(scratch.exact.statistics.scratch_peak == MIN_FRACTURE_SCRATCH_BYTES);
    assert(!scratch.exact.statistics.cell_split_count && !scratch.exact.statistics.max_patch_vertices);
    assert(!scratch.exact.exact_nanoseconds && !scratch.exact.measurement_depth);
    Clock outer = begin_exact_measurement(scratch.exact);
    Clock inner = begin_exact_measurement(scratch.exact);
    assert(scratch.exact.measurement_depth == 2);
    finish_exact_measurement(scratch.exact, inner);
    assert(scratch.exact.measurement_depth == 1 && !scratch.exact.exact_nanoseconds);
    finish_exact_measurement(scratch.exact, outer);
    assert(!scratch.exact.measurement_depth);
}
