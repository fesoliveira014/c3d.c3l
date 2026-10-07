module c3d::physics::fracture;

import c3d;
import std::sort;
import std::math;

struct SurfaceAtlasRecord @local {
    PatchTriangles* shared;
    uint patch;
}

fn int compare_surface_atlas_records(SurfaceAtlasRecord first, SurfaceAtlasRecord second) @local {
    uptr left = (uptr)first.shared;
    uptr right = (uptr)second.shared;
    return left < right ? -1 : left > right ? 1 : 0;
}

fn int compare_surface_point_ids(uint first, uint second) @local {
    return first < second ? -1 : first > second ? 1 : 0;
}

fn int compare_surface_triangles(SurfaceTriangle first, SurfaceTriangle second) @private {
    for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
        if (first.points[corner] != second.points[corner]) return first.points[corner] < second.points[corner] ? -1 : 1;
    }
    if (first.material != second.material) return first.material < second.material ? -1 : 1;
    if (first.cut != second.cut) return first.cut ? 1 : -1;
    if (first.source_index != second.source_index) return first.source_index < second.source_index ? -1 : 1;
    for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
        if (first.source_key[corner] != second.source_key[corner]) return first.source_key[corner] < second.source_key[corner] ? -1 : 1;
    }
    return 0;
}

fn int compare_surface_prepared_pieces(SurfacePreparedPiece first, SurfacePreparedPiece second) @private {
    if (first.site_index != second.site_index) return first.site_index < second.site_index ? -1 : 1;
    usz count = first.triangles.len < second.triangles.len ? (usz)first.triangles.len : (usz)second.triangles.len;
    for (usz triangle = 0; triangle < count; triangle++) {
        int order = compare_surface_triangles(first.triangles[triangle], second.triangles[triangle]);
        if (order) return order;
    }
    return first.triangles.len < second.triangles.len ? -1 : first.triangles.len > second.triangles.len ? 1 : 0;
}

fn uint[TRIANGLE_CORNERS] canonical_surface_triangle(uint[TRIANGLE_CORNERS] vertices) @private {
    uint first;
    for (uint corner = 1; corner < TRIANGLE_CORNERS; corner++) if (vertices[corner] < vertices[first]) first = corner;
    return { vertices[first], vertices[(first + 1) % TRIANGLE_CORNERS], vertices[(first + 2) % TRIANGLE_CORNERS] };
}

fn uint surface_local_point(uint[] points, uint point) @private {
    uint first;
    uint end = (uint)points.len;
    while (first < end) {
        uint middle = first + (end - first) / 2;
        if (points[middle] < point) {
            first = middle + 1;
        } else {
            end = middle;
        }
    }
    return first;
}

fn SurfacePointMap? prepare_surface_atlas(SolidScratch* scratch, SurfacePatchRecord[] patches, QuantizationGrid* grid) @local {
    SurfaceAtlasRecord[] records = reserve_elements(scratch, SurfaceAtlasRecord, patches.len)!;
    foreach (uint index, patch : patches) records[index] = { .shared = patch.patch.triangulation.shared, .patch = index };
    sort::quicksort(records, &compare_surface_atlas_records);
    BoundaryPatch[] atlas = reserve_elements(scratch, BoundaryPatch, patches.len)!;
    PatchTriangles* previous = null;
    uint count;
    foreach (record : records) {
        SurfacePatchRecord* patch = &patches[record.patch];
        if (record.shared != previous) {
            atlas[count] = patch.patch.boundary;
            atlas[count].boundary.vertices = record.shared.vertices;
            count++;
            previous = record.shared;
        }
        patch.atlas_index = count - 1;
    }
    return map_surface_points(scratch, atlas[:count], grid);
}

fn void? prepare_surface_topology(SolidScratch* scratch, SurfacePreparedPiece* piece, SurfacePointMap* points) @local {
    usz corners = piece.triangles.len * TRIANGLE_CORNERS;
    if (!corners) return NON_MANIFOLD_RESULT~;
    if (corners > uint::max) return c3d::CAPACITY_EXCEEDED~;
    uint[] identities = reserve_elements(scratch, uint, corners)!;
    foreach (uint triangle, value : piece.triangles) {
        identities[triangle * TRIANGLE_CORNERS:TRIANGLE_CORNERS] = value.points[..];
    }
    sort::quicksort(identities, &compare_surface_point_ids);
    uint count;
    foreach (identity : identities) {
        if (!count || identities[count - 1] != identity) identities[count++] = identity;
    }
    piece.point_ids = identities[:count];
    piece.common = {
        .geometry = {
            .positions = reserve_elements(scratch, Vec3, count)!,
            .indices = reserve_elements(scratch, uint, corners)!,
        },
        .topology_vertices = reserve_elements(scratch, uint, count)!,
        .triangle_materials = reserve_elements(scratch, uint, piece.triangles.len)!,
    };
    foreach (uint index, point : piece.point_ids) {
        piece.common.geometry.positions[index] = points.positions[point];
        piece.common.topology_vertices[index] = index;
    }
    foreach (uint triangle, value : piece.triangles) {
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            piece.common.geometry.indices[triangle * TRIANGLE_CORNERS + corner] = surface_local_point(piece.point_ids, value.points[corner]);
        }
        piece.common.triangle_materials[triangle] = value.material;
    }
    return;
}

fn SurfacePublication? prepare_surface_publication(
    SolidScratch* scratch,
    FractureLimits limits,
    SurfacePiece[] pieces,
    QuantizationGrid* grid,
    CutSurface cut,
) @private {
    if (pieces.len > limits.max_pieces) return c3d::CAPACITY_EXCEEDED~;
    usz patch_count;
    usz triangle_count;
    usz shared_count;
    foreach (piece : pieces) {
        patch_count += piece.patches.len;
        foreach (patch : piece.patches) {
            usz count = patch.selection.len ? (usz)patch.selection.len : (usz)patch.triangulation.shared.triangles.len;
            if (count > limits.max_triangles - triangle_count) return c3d::CAPACITY_EXCEEDED~;
            triangle_count += count;
            if (patch.cut && patch.shared_cut) shared_count += count;
        }
    }
    if (patch_count > uint::max) return c3d::CAPACITY_EXCEEDED~;
    SurfacePublication publication = {
        .patches = reserve_elements(scratch, SurfacePatchRecord, patch_count)!,
        .pieces = reserve_elements(scratch, SurfacePreparedPiece, pieces.len)!,
        .shared = reserve_elements(scratch, SurfaceSharedTriangle, shared_count)!,
    };
    uint patch_index;
    foreach (piece : pieces) foreach (patch : piece.patches) publication.patches[patch_index++] = { .patch = patch };
    publication.points = prepare_surface_atlas(scratch, publication.patches, grid)!;
    patch_index = 0;
    usz shared_index;
    foreach (uint owner, input : pieces) {
        SurfacePreparedPiece* piece = &publication.pieces[owner];
        *piece = { .site_index = input.site_index };
        usz count;
        foreach (patch : input.patches) count += patch.selection.len ? (usz)patch.selection.len : (usz)patch.triangulation.shared.triangles.len;
        piece.triangles = reserve_elements(scratch, SurfaceTriangle, count)!;
        usz written;
        foreach (patch : input.patches) {
            SurfacePatchRecord record = publication.patches[patch_index];
            usz selected = patch.selection.len ? (usz)patch.selection.len : (usz)patch.triangulation.shared.triangles.len;
            uint point_offset = selected ? publication.points.patch_offsets[record.atlas_index] : 0;
            if (selected) {
                if (patch.cut) {
                    piece.uv0 = true;
                    piece.tangents = true;
                } else {
                    piece.uv0 |= patch.source.source.geometry.uv0.len != 0;
                    piece.uv1 |= patch.source.source.geometry.uv1.len != 0;
                    piece.colors |= patch.source.source.geometry.colors.len != 0;
                    piece.tangents |= patch.source.source.geometry.tangents.len != 0;
                }
            }
            for (usz slot = 0; slot < selected; slot++) {
                uint index = patch.selection.len ? patch.selection[slot] : (uint)slot;
                uint[TRIANGLE_CORNERS] vertices = oriented_patch_triangle(patch.triangulation, index);
                SurfaceTriangle triangle = {
                    .patch = patch_index,
                    .source_index = patch.cut ? 0 : patch.source_index,
                    .material = patch.cut ? cut.material_slot : patch.source.source.triangle_materials[patch.boundary.source_face],
                    .cut = patch.cut,
                };
                foreach (uint corner, vertex : vertices) triangle.points[corner] = publication.points.vertices[point_offset + vertex];
                triangle.points = canonical_surface_triangle(triangle.points);
                if (!patch.cut) triangle.source_key = canonical_surface_triangle(patch.boundary.source_corners);
                piece.triangles[written++] = triangle;
                if (patch.cut && patch.shared_cut) publication.shared[shared_index++] = {
                    .shared = patch.triangulation.shared, .triangle = index, .piece = owner, .reversed = patch.triangulation.reversed,
                };
            }
            patch_index++;
        }
        sort::quicksort(piece.triangles, &compare_surface_triangles);
        prepare_surface_topology(scratch, piece, &publication.points)!;
    }
    return publication;
}

fn int compare_surface_shared_triangles(SurfaceSharedTriangle first, SurfaceSharedTriangle second) @local {
    uptr left = (uptr)first.shared;
    uptr right = (uptr)second.shared;
    if (left != right) return left < right ? -1 : 1;
    return first.triangle < second.triangle ? -1 : first.triangle > second.triangle ? 1 : 0;
}

fn void? check_surface_shared_triangles(SurfaceSharedTriangle[] uses) @private {
    sort::quicksort(uses, &compare_surface_shared_triangles);
    for (usz first = 0; first < uses.len;) {
        usz end = first + 1;
        while (end < uses.len && !compare_surface_shared_triangles(uses[first], uses[end])) end++;
        if (end - first != 2 || uses[first].piece == uses[first + 1].piece || uses[first].reversed == uses[first + 1].reversed) {
            return NON_MANIFOLD_RESULT~;
        }
        first = end;
    }
    return;
}
