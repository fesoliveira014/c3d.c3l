module c3d::physics::fracture;

import c3d;
import std::math;

<*
 Partition a solid by ordered three-dimensional Voronoi sites.
 @param [&inout] workspace : "Exclusively borrowed for this call."
 @param sites : "Finite distinct points in the source frame."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @return? INVALID_SOLID, NON_MANIFOLD_RESULT, NUMERICAL_FAILURE
*>
fn FractureResult? create_voronoi_fracture(
    Allocator allocator,
    FractureWorkspace* workspace,
    SolidMeshView source,
    Vec3[] sites,
    CutSurface cut,
) {
    if (!(cut.uv_repeats_per_meter > 0 && math::is_finite(cut.uv_repeats_per_meter))) return c3d::INVALID_ARGUMENT~;
    SolidScratch scratch = begin_solid_scratch(workspace);
    PreparedGeneration prepared = prepare_generation_sources(&scratch, { source }, workspace.limits.resolution_m)!;
    GridPoint[] points = prepare_voronoi_sites(
        scratch: &scratch, grid: prepared.grid, sites: sites, max_sites: workspace.limits.max_sites,
    )!;
    PreparedSource* input = &prepared.sources[0];
    SolidPartition cells = partition_solid(&scratch, &input.solid.surface, &input.constructions)!;
    VoronoiPartition partition = partition_voronoi_cells(&scratch, &cells, points)!;
    foreach (site : partition.sites) {
        scratch.exact.statistics.final_leaf_count += site.cell_count;
        scratch.exact.statistics.occupied_leaf_count += site.occupied_count;
    }
    SurfacePiece[] pieces = build_voronoi_surface_pieces(
        scratch: &scratch, source: input, partition: &partition, max_pieces: workspace.limits.max_pieces,
    )!;
    SurfaceVolumeReference reference = { .coordinate_exponent = prepared.grid.step_exponent };
    foreach (&shell : input.solid.nesting.shells) accumulate_surface_volume(scratch.exact, &reference.six_volume, shell.six_volume.view())!;
    return publish_surface_pieces(
        allocator: allocator,
        scratch: &scratch,
        limits: workspace.limits,
        pieces: pieces,
        grid: &prepared.grid,
        cut: cut,
        reference: &reference,
    );
}
