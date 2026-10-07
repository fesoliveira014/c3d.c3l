module c3d::physics::fracture;

import c3d;
import c3d::geometry;
import std::math;
import std::sort;

<* Material and UV density of generated interior surfaces. *>
struct CutSurface {
    uint material_slot;
    float uv_repeats_per_meter;
}

struct SurfacePatch @private {
    BoundaryPatch boundary;
    OrientedPatchTriangles triangulation;
    SolidSurface* source;
    uint source_index;
    bool cut;
    bool shared_cut;
    uint[] selection;
}

struct SurfacePiece @private {
    SurfacePatch[] patches;
    uint site_index;
}

struct SurfaceVolumeReference @private {
    PlaneInteger six_volume;
    int coordinate_exponent;
}

struct SurfaceTriangle @private {
    uint[TRIANGLE_CORNERS] points;
    uint[TRIANGLE_CORNERS] source_key;
    uint patch;
    uint source_index;
    uint material;
    bool cut;
}

struct SurfacePreparedPiece @private {
    SurfaceTriangle[] triangles;
    uint[] point_ids;
    SolidMeshView common;
    SolidMeshView local;
    FracturePieceView output;
    uint site_index;
    bool uv0;
    bool uv1;
    bool colors;
    bool tangents;
}

struct SurfacePatchRecord @private {
    SurfacePatch patch;
    uint atlas_index;
}

struct SurfacePointUse @private {
    uint point;
    uint piece;
    uint local;
}

struct SurfaceSharedTriangle @private {
    PatchTriangles* shared;
    uint triangle;
    uint piece;
    bool reversed;
}

struct SurfacePublication @private {
    SurfacePatchRecord[] patches;
    SurfacePreparedPiece[] pieces;
    SurfaceSharedTriangle[] shared;
    SurfacePointMap points;
}

struct SurfaceVolumeMeasure @private {
    PlaneInteger six_volume;
    PlaneInteger rounding_bound;
}

fn FractureResult? publish_surface_pieces(
    Allocator allocator,
    SolidScratch* scratch,
    FractureLimits limits,
    SurfacePiece[] pieces,
    QuantizationGrid* grid,
    CutSurface cut,
    SurfaceVolumeReference* reference = null,
) @private {
    usz saved = scratch.used;
    defer scratch.used = saved;
    SurfacePublication publication = prepare_surface_publication(
        scratch: scratch, limits: limits, pieces: pieces, grid: grid, cut: cut,
    )!;
    check_surface_shared_triangles(publication.shared)!;
    foreach (&piece : publication.pieces) check_surface_exact_topology(scratch, piece.common)!;
    sort::quicksort(publication.pieces, &compare_surface_prepared_pieces);
    usz point_count;
    foreach (piece : publication.pieces) point_count += piece.point_ids.len;
    SurfacePointUse[] uses = reserve_elements(scratch, SurfacePointUse, point_count)!;
    usz point_offset;
    usz render_vertices;
    PlaneInteger volume;
    PlaneInteger bound;
    foreach (uint owner, &piece : publication.pieces) {
        SurfaceVolumeMeasure measured = prepare_surface_piece_frame(
            scratch: scratch,
            piece: piece,
            points: &publication.points,
            grid: grid,
            resolution: limits.resolution_m,
        )!;
        accumulate_surface_volume(scratch.exact, &volume, measured.six_volume.view())!;
        accumulate_surface_volume(scratch.exact, &bound, measured.rounding_bound.view())!;
        build_surface_render_mesh(
            scratch: scratch,
            piece: piece,
            patches: publication.patches,
            points: &publication.points,
            cut: cut,
        )!;
        render_vertices += piece.output.mesh.geometry.positions.len;
        if (render_vertices > limits.max_vertices) return c3d::CAPACITY_EXCEEDED~;
        if (piece.tangents) {
            Geometry geometry = piece.output.mesh.geometry;
            usz retained = scratch.used;
            defer scratch.used = retained;
            if (!geometry.uv0.len) {
                geometry.uv0 = reserve_elements(scratch, Vec2, geometry.positions.len)!;
                geometry.uv0[..] = {};
            }
            regenerate_surface_tangents(scratch, &geometry)!;
        }
        foreach (uint local, point : piece.point_ids) uses[point_offset++] = { .point = point, .piece = owner, .local = local };
    }
    check_surface_point_copies(scratch.exact, publication.pieces, uses, limits.resolution_m)!;
    if (reference) check_surface_volume_reference(
        scratch: scratch.exact, reference: reference, volume: volume.view(), bound: bound.view(),
    )!;
    FracturePieceView[] output = reserve_elements(scratch, FracturePieceView, publication.pieces.len)!;
    foreach (uint index, piece : publication.pieces) output[index] = piece.output;
    return copy_fracture_result(allocator, output);
}
