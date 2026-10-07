module c3d::physics::fracture;

import c3d;
import std::math;

<*
 Construct independent pieces from a solid Boolean operation.
 @param [&inout] workspace : "Exclusively borrowed for this call."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @return? INVALID_SOLID, NON_MANIFOLD_RESULT, NUMERICAL_FAILURE
*>
fn FractureResult? create_boolean(
    Allocator allocator,
    FractureWorkspace* workspace,
    SolidMeshView first,
    SolidMeshView second,
    BooleanOperation operation,
    CutSurface cut,
) {
    if (!(cut.uv_repeats_per_meter > 0 && math::is_finite(cut.uv_repeats_per_meter))) return c3d::INVALID_ARGUMENT~;
    SolidScratch scratch = begin_solid_scratch(workspace);
    PreparedGeneration prepared = prepare_generation_sources(&scratch, { first, second }, workspace.limits.resolution_m)!;
    SolidPartition partition = partition_boolean_cells(
        scratch: &scratch,
        first: &prepared.sources[0].solid.surface,
        first_source: &prepared.sources[0].constructions,
        second: &prepared.sources[1].solid.surface,
        second_source: &prepared.sources[1].constructions,
        operation: operation,
    )!;
    scratch.exact.statistics.final_leaf_count = partition.cell_count;
    scratch.exact.statistics.occupied_leaf_count = partition.occupied_count;
    SurfacePiece[] pieces = build_boolean_surface_pieces(
        scratch: &scratch,
        prepared: &prepared,
        partition: &partition,
        operation: operation,
        max_pieces: workspace.limits.max_pieces,
    )!;
    return publish_surface_pieces(
        allocator: allocator,
        scratch: &scratch,
        limits: workspace.limits,
        pieces: pieces,
        grid: &prepared.grid,
        cut: cut,
    );
}
