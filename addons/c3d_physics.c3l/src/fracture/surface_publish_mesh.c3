module c3d::physics::fracture;

import c3d::geometry;
import std::sort;
import std::math;

enum SurfaceVertexKind @local {
    CORNER,
    EDGE,
    FACE,
    CUT,
}

struct SurfaceRenderCorner @local {
    SurfaceAttributes attributes;
    ExactPlane* plane;
    uint[TRIANGLE_CORNERS] provenance;
    uint point;
    uint source_index;
    uint slot;
    SurfaceVertexKind kind;
    bool reversed;
}

fn int compare_surface_render_corners(SurfaceRenderCorner first, SurfaceRenderCorner second) @local {
    if (first.point != second.point) return first.point < second.point ? -1 : 1;
    if (first.kind != second.kind) return first.kind < second.kind ? -1 : 1;
    if (first.source_index != second.source_index) return first.source_index < second.source_index ? -1 : 1;
    for (uint index = 0; index < TRIANGLE_CORNERS; index++) {
        if (first.provenance[index] != second.provenance[index]) return first.provenance[index] < second.provenance[index] ? -1 : 1;
    }
    if (!first.plane || !second.plane) return first.plane ? 1 : second.plane ? -1 : 0;
    int plane = compare_exact_planes(first.plane, second.plane);
    if (plane) return plane;
    return first.reversed == second.reversed ? 0 : first.reversed ? 1 : -1;
}

fn SurfaceRenderCorner? sample_surface_render_corner(
    SurfacePatch* patch,
    SurfacePointMap* points,
    ExactScratch* scratch,
    CutSurface cut,
    uint point,
    uint slot,
) @local {
    SurfaceRenderCorner corner = { .point = point, .slot = slot };
    if (patch.cut) {
        corner.attributes = cut_surface_attributes(
            scratch: scratch,
            plane: patch.boundary.plane,
            reversed: patch.triangulation.reversed,
            position: points.positions[point],
            uv_density: cut.uv_repeats_per_meter,
        )!;
        corner.kind = SurfaceVertexKind.CUT;
        corner.plane = patch.boundary.plane;
        corner.reversed = patch.triangulation.reversed;
        return corner;
    }
    corner.source_index = patch.source_index;
    corner.attributes = source_surface_attributes(
        surface: patch.source,
        face: patch.boundary.source_face,
        vertex: points.exact[point],
        plane: patch.boundary.plane,
        reversed: patch.triangulation.reversed,
    )!;
    if (!patch.source.source.geometry.normals.len) {
        corner.plane = patch.boundary.plane;
        corner.reversed = patch.triangulation.reversed;
    }
    if (corner.attributes.corner != NO_SOLID_INDEX) {
        corner.kind = SurfaceVertexKind.CORNER;
        corner.provenance[0] = corner.attributes.corner;
    } else if (corner.attributes.edge[0] != NO_SOLID_INDEX) {
        corner.kind = SurfaceVertexKind.EDGE;
        corner.provenance[0] = corner.attributes.edge[0];
        corner.provenance[1] = corner.attributes.edge[1];
    } else {
        corner.kind = SurfaceVertexKind.FACE;
        corner.provenance = canonical_surface_triangle(patch.boundary.source_corners);
    }
    return corner;
}

fn void? build_surface_render_mesh(
    SolidScratch* scratch,
    SurfacePreparedPiece* piece,
    SurfacePatchRecord[] patches,
    SurfacePointMap* points,
    CutSurface cut,
) @private {
    usz count = piece.triangles.len * TRIANGLE_CORNERS;
    SurfaceRenderCorner[] corners = reserve_elements(scratch, SurfaceRenderCorner, count)!;
    foreach (uint index, triangle : piece.triangles) {
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            uint slot = index * TRIANGLE_CORNERS + corner;
            corners[slot] = sample_surface_render_corner(
                patch: &patches[triangle.patch].patch,
                points: points,
                scratch: scratch.exact,
                cut: cut,
                point: triangle.points[corner],
                slot: slot,
            )!;
        }
    }
    sort::quicksort(corners, &compare_surface_render_corners);
    uint vertices;
    foreach (uint index, corner : corners) {
        if (!index || compare_surface_render_corners(corners[index - 1], corner)) vertices++;
    }
    SolidMeshView mesh = {
        .geometry = {
            .positions = reserve_elements(scratch, Vec3, vertices)!,
            .normals = reserve_elements(scratch, Vec3, vertices)!,
            .indices = reserve_elements(scratch, uint, count)!,
            .bounds = piece.local.geometry.bounds,
        },
        .topology_vertices = reserve_elements(scratch, uint, vertices)!,
        .triangle_materials = piece.common.triangle_materials,
    };
    if (piece.uv0) mesh.geometry.uv0 = reserve_elements(scratch, Vec2, vertices)!;
    if (piece.uv1) mesh.geometry.uv1 = reserve_elements(scratch, Vec2, vertices)!;
    if (piece.colors) mesh.geometry.colors = reserve_elements(scratch, Vec4, vertices)!;
    if (piece.tangents) mesh.geometry.tangents = reserve_elements(scratch, Vec4, vertices)!;
    uint written;
    foreach (uint index, corner : corners) {
        if (!index || compare_surface_render_corners(corners[index - 1], corner)) {
            uint local = surface_local_point(piece.point_ids, corner.point);
            mesh.geometry.positions[written] = piece.local.geometry.positions[local];
            mesh.topology_vertices[written] = local;
            mesh.geometry.normals[written] = corner.attributes.normal;
            if (piece.uv0) mesh.geometry.uv0[written] = corner.attributes.uv0;
            if (piece.uv1) mesh.geometry.uv1[written] = corner.attributes.uv1;
            if (piece.colors) mesh.geometry.colors[written] = corner.attributes.color;
            written++;
        }
        mesh.geometry.indices[corner.slot] = written - 1;
    }
    piece.output.mesh = mesh;
    return;
}
