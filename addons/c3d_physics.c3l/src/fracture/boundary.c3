module c3d::physics::fracture;

import std::sort;

fn PlanarSegment[]? collect_boundary_segments(
    SolidScratch* scratch,
    SolidPartition* partition,
    ExactPlane* plane,
    SolidSurface* surface = null,
    SourceConstructions* source = null,
    uint source_face = NO_SOLID_INDEX,
) @private {
    PlanarSegment[] segments;
    for (uint pass = 0; pass < 2; pass++) {
        usz count;
        for (PartitionCell* current = partition.first; current; current = current.next) {
            if (!current.occupied) continue;
            ConvexCell* cell = &current.cell;
            foreach (face : cell.faces) {
                if (compare_exact_planes(face.plane, plane)) continue;
                usz saved = scratch.used;
                defer scratch.used = saved;
                if (source_face == NO_SOLID_INDEX) {
                    if (pass) for (uint offset = 0; offset < face.count; offset++) {
                        uint corner = face.first + offset;
                        segments[count + offset] = {
                            .first = cell.vertices[cell.corners[corner].vertex],
                            .second = cell.vertices[cell.corners[next_cell_corner(cell, corner)].vertex],
                            .line = { plane, cell.faces[cell.corners[cell.corners[corner].twin].face].plane },
                        };
                    }
                    count += face.count;
                    continue;
                }
                FaceClipVertex[] polygon = clip_source_face_to_cell(
                    scratch: scratch,
                    surface: surface,
                    source: source,
                    face: source_face,
                    cell: cell,
                )!;
                if (polygon.len < TRIANGLE_CORNERS) continue;
                bool area;
                for (usz index = 2; index < polygon.len; index++) {
                    area |= planar_orientation(
                        scratch: scratch.exact,
                        vertices: { polygon[0].point, polygon[index - 1].point, polygon[index].point },
                        dropped_axis: patch_projection(plane),
                    )! != 0;
                }
                if (!area) continue;
                if (pass) foreach (usz index, point : polygon) {
                    FaceClipVertex next = polygon[(index + 1) % (usz)polygon.len];
                    bool reverse = face.reversed != source.reversed[source_face];
                    segments[count + index] = {
                        .first = reverse ? next.point : point.point, .second = reverse ? point.point : next.point,
                        .line = next.incoming,
                    };
                }
                count += polygon.len;
            }
        }
        if (!pass) segments = reserve_elements(scratch, PlanarSegment, count)!;
    }
    return segments;
}

fn int compare_boundary_patches(BoundaryPatch first, BoundaryPatch second) @private {
    int plane = compare_exact_planes(first.plane, second.plane);
    if (plane) return plane;
    for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
        if (first.source_key[corner] != second.source_key[corner]) return first.source_key[corner] < second.source_key[corner] ? -1 : 1;
    }
    return 0;
}

fn int compare_plane_pointers(ExactPlane* first, ExactPlane* second) @local {
    return compare_exact_planes(first, second);
}

<* @require found *>
fn void require_boundary_provenance(bool found) @local {}

fn void? check_boundary_provenance(
    SolidScratch* scratch,
    SolidPartition* partition,
    SourceConstructions* source,
    ExactPlane*[] cuts,
) @local {
    usz saved = scratch.used;
    defer scratch.used = saved;
    usz count;
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) if (cell.occupied) count += cell.cell.faces.len;
    ExactPlane*[] planes = reserve_elements(scratch, ExactPlane*, count)!;
    count = 0;
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
        if (cell.occupied) foreach (face : cell.cell.faces) planes[count++] = face.plane;
    }
    sort::quicksort(planes, &compare_plane_pointers);
    foreach (uint index, plane : planes) {
        if (index && !compare_exact_planes(planes[index - 1], plane)) continue;
        usz retained = scratch.used;
        defer scratch.used = retained;
        PlanarSegment[] segments = collect_boundary_segments(scratch, partition, plane)!;
        PlanarEdges boundary = normalize_planar_edges(scratch, plane, segments)!;
        if (!boundary.edges.len) continue;
        bool found;
        foreach (&original : source.faces) found |= compare_exact_planes(plane, original) == 0;
        foreach (cut : cuts) found |= compare_exact_planes(plane, cut) == 0;
        require_boundary_provenance(found);
    }
    return;
}

fn bool? unchanged_source_patch(
    ExactScratch* scratch,
    BoundaryPatch* patch,
    SourceConstructions* source,
    uint[TRIANGLE_CORNERS] triangle,
) @private {
    if (patch.contours.len != 1 || patch.corners.len != TRIANGLE_CORNERS) return false;
    uint first = NO_SOLID_INDEX;
    for (uint index = 0; index < TRIANGLE_CORNERS; index++) {
        if (same_vertex(scratch, patch.boundary.vertices[patch.corners[index]], source.vertices[triangle[0]])!) first = index;
    }
    if (first == NO_SOLID_INDEX) return false;
    for (uint index = 1; index < TRIANGLE_CORNERS; index++) {
        if (!same_vertex(
            scratch: scratch,
            first: patch.boundary.vertices[patch.corners[(first + index) % TRIANGLE_CORNERS]],
            second: source.vertices[triangle[index]],
        )!) return false;
    }
    return true;
}

fn BoundaryPatch[]? source_boundary_patches(
    SolidScratch* scratch,
    SolidSurface* surface,
    SourceConstructions* source,
    SolidPartition* partition,
    ExactPlane*[] cuts = {},
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    check_boundary_provenance(
        scratch: scratch,
        partition: partition,
        source: source,
        cuts: cuts,
    )!;
    BoundaryPatch[] patches = reserve_elements(scratch, BoundaryPatch, source.faces.len)!;
    uint count;
    foreach (uint face, &plane : source.faces) {
        PlanarSegment[] segments = collect_boundary_segments(
            scratch: scratch,
            partition: partition,
            plane: plane,
            surface: surface,
            source: source,
            source_face: face,
        )!;
        BoundaryPatch patch = create_boundary_patch(
            scratch: scratch,
            plane: plane,
            segments: segments,
            reversed: source.reversed[face],
        )!;
        if (!patch.boundary.edges.len) continue;
        patch.source_face = face;
        patch.source_corners[..] = surface.source.geometry.indices[face * TRIANGLE_CORNERS:TRIANGLE_CORNERS];
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
        uint first;
        for (uint corner = 1; corner < TRIANGLE_CORNERS; corner++) if (triangle[corner] < triangle[first]) first = corner;
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) patch.source_key[corner] = triangle[(first + corner) % TRIANGLE_CORNERS];
        patches[count++] = patch;
    }
    patches = patches[:count];
    sort::quicksort(patches, &compare_boundary_patches);
    reconcile_patch_boundaries(scratch, patches)!;
    foreach (&patch : patches) patch.unchanged = unchanged_source_patch(
        scratch: scratch.exact,
        patch: patch,
        source: source,
        triangle: surface_triangle(surface, patch.source_face),
    )!;
    return patches;
}
