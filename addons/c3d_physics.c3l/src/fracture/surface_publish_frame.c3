module c3d::physics::fracture;

import c3d;
import std::math;
import std::sort;

const uint SURFACE_VOLUME_SUM_BITS @local = ROUNDING_VOLUME_BITS;
$assert SURFACE_VOLUME_SUM_BITS <= PLANE_LIMBS * INTEGER_LIMB_BITS;

fn void? check_surface_exact_topology(SolidScratch* scratch, SolidMeshView mesh) @private {
    usz saved = scratch.used;
    defer scratch.used = saved;
    if (catch failure = build_solid_topology(scratch, mesh)) {
        if (failure == INVALID_SOLID) return NON_MANIFOLD_RESULT~;
        return failure~;
    }
    return;
}

fn ValidatedSolid? validate_published_surface(SolidScratch* scratch, SolidMeshView mesh) @local {
    SolidDiagnostic diagnostic;
    ValidatedSolid? result = validate_solid(scratch: scratch, source: mesh, grid: null, diagnostic: &diagnostic);
    if (catch failure = result) {
        if (failure == INVALID_SOLID) return NUMERICAL_FAILURE~;
        return failure~;
    }
    return result;
}

fn void? accumulate_surface_volume(ExactScratch* scratch, PlaneInteger* sum, IntegerView value) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* accumulated = scratch.take()!;
    add_integer(accumulated, sum.view(), value)!;
    sum.used = accumulated.used;
    sum.negative = accumulated.negative;
    sum.limbs[:sum.used] = accumulated.limbs[:sum.used];
    return;
}

fn SurfaceVolumeMeasure? prepare_surface_piece_frame(
    SolidScratch* scratch,
    SurfacePreparedPiece* piece,
    SurfacePointMap* points,
    QuantizationGrid* grid,
    float resolution,
) @private {
    piece.local = piece.common;
    piece.local.geometry.positions = reserve_elements(scratch, Vec3, piece.point_ids.len)!;
    {
        usz saved = scratch.used;
        defer scratch.used = saved;
        ValidatedSolid solid = validate_published_surface(scratch, piece.common)!;
        piece.output.origin = rounded_surface_centroid(&solid.surface, resolution)!;
    }
    foreach (uint index, point : piece.point_ids) {
        Vec3 local = rounded_local_position(scratch.exact, points.positions[point], piece.output.origin)!;
        piece.local.geometry.positions[index] = local;
        check_frame_point_error(
            scratch: scratch.exact,
            vertex: points.exact[point],
            grid: grid,
            origin: piece.output.origin,
            local: local,
            resolution: resolution,
        )!;
    }
    SurfaceVolumeMeasure measured;
    {
        usz saved = scratch.used;
        defer scratch.used = saved;
        ValidatedSolid solid = validate_published_surface(scratch, piece.local)!;
        foreach (&shell : solid.nesting.shells) accumulate_surface_volume(scratch.exact, &measured.six_volume, shell.six_volume.view())!;
        measured.rounding_bound = float_rounding_volume_bound(&solid.surface, resolution)!;
    }
    piece.local.geometry.finalize();
    return measured;
}

fn int compare_surface_point_uses(SurfacePointUse first, SurfacePointUse second) @local {
    if (first.point != second.point) return first.point < second.point ? -1 : 1;
    return first.piece < second.piece ? -1 : first.piece > second.piece ? 1 : 0;
}

fn void? check_surface_point_copies(
    ExactScratch* scratch,
    SurfacePreparedPiece[] pieces,
    SurfacePointUse[] uses,
    float resolution,
) @private {
    sort::quicksort(uses, &compare_surface_point_uses);
    for (usz first = 0; first < uses.len;) {
        usz end = first + 1;
        while (end < uses.len && uses[end].point == uses[first].point) end++;
        for (usz left = first; left < end; left++) for (usz right = left + 1; right < end; right++) {
            SurfacePreparedPiece* first_piece = &pieces[uses[left].piece];
            SurfacePreparedPiece* second_piece = &pieces[uses[right].piece];
            check_shared_point_error(
                scratch: scratch,
                first_origin: first_piece.output.origin,
                first_local: first_piece.local.geometry.positions[uses[left].local],
                second_origin: second_piece.output.origin,
                second_local: second_piece.local.geometry.positions[uses[right].local],
                resolution: resolution,
            )!;
        }
        first = end;
    }
    return;
}

fn void? shift_surface_volume(WideInteger* output, IntegerView value, long shift) @local {
    if (!value.limbs.len) {
        set_integer(output, 0);
        return;
    }
    if (shift > EXACT_LIMBS * INTEGER_LIMB_BITS) return NUMERICAL_FAILURE~;
    return shift_integer(output, value, (uint)shift);
}

fn void? check_surface_volume_reference(
    ExactScratch* scratch,
    SurfaceVolumeReference* reference,
    IntegerView volume,
    IntegerView bound,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* original = scratch.take()!;
    WideInteger* result = scratch.take()!;
    WideInteger* difference = scratch.take()!;
    WideInteger* allowance = scratch.take()!;
    long source_exponent = (long)reference.coordinate_exponent * SPACE_AXES;
    long output_exponent = (long)FLOAT_UNIT_EXPONENT * SPACE_AXES;
    long unit = math::min(source_exponent, output_exponent);
    shift_surface_volume(original, reference.six_volume.view(), source_exponent - unit)!;
    shift_surface_volume(result, volume, output_exponent - unit)!;
    shift_surface_volume(allowance, bound, output_exponent - unit)!;
    add_integer(difference, original.view(), negate_integer(result.view()))!;
    difference.negative = false;
    if (compare_magnitude(difference.view(), allowance.view()) > 0) return NUMERICAL_FAILURE~;
    return;
}
