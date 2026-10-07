module c3d::physics::fracture;

struct SolidValidationCounts @private {
    ulong triangle_pairs;
    ulong shell_pairs;
    ulong containment_queries;
    ulong containment_faces;
}

struct ValidatedSolid @private {
    SolidSurface surface;
    SolidNesting nesting;
    SolidValidationCounts raw_counts;
    SolidValidationCounts grid_counts;
}

fn SolidValidationCounts solid_validation_counts(ValidatedSolid* solid) @private {
    return {
        .triangle_pairs = solid.surface.candidate_pairs,
        .shell_pairs = solid.nesting.pairs,
        .containment_queries = solid.nesting.queries,
        .containment_faces = solid.nesting.candidate_faces,
    };
}

fn void? recheck_quantized_solid(ValidatedSolid* solid, SolidDiagnostic* diagnostic) @private {
    check_surface_geometry(&solid.surface, diagnostic)!;
    check_solid_nesting(&solid.surface, &solid.nesting, diagnostic)!;
    solid.grid_counts = solid_validation_counts(solid);
    return;
}

fn ValidatedSolid? validate_solid(
    SolidScratch* scratch,
    SolidMeshView source,
    QuantizationGrid* grid,
    SolidDiagnostic* diagnostic,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    ValidatedSolid solid = { .surface = build_solid_surface(scratch, source, diagnostic)! };
    solid.nesting = build_solid_nesting(scratch, &solid.surface, diagnostic)!;
    solid.raw_counts = solid_validation_counts(&solid);
    if (!grid) return solid;
    solid.surface.grid = reserve_elements(scratch, GridPoint, solid.surface.topology.vertices.len)!;
    foreach (uint identity, vertex : solid.surface.topology.vertices) {
        if (!vertex.degree) continue;
        solid.surface.grid[identity] = quantize_point(scratch.exact, *grid, surface_position(&solid.surface, identity))!;
    }
    if (catch failure = recheck_quantized_solid(&solid, diagnostic)) {
        if (failure == INVALID_SOLID) return NUMERICAL_FAILURE~;
        return failure~;
    }
    return solid;
}
