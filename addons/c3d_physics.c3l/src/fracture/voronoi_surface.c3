module c3d::physics::fracture;

import c3d;

struct SurfacePatchLink @local {
    SurfacePatch value;
    SurfacePatchLink* next;
}

struct VoronoiPieceBuilder @local {
    SolidPartition* cells;
    BoundaryCellFace[] faces;
    BoundaryPatch[] authored;
    SurfacePatchLink* first;
    SurfacePatchLink* last;
    uint site;
    uint patch_count;
    uint patch_offset;
}

struct VoronoiCap @local {
    BoundaryPatch boundary;
    VoronoiCap* next;
    uint first_piece;
    uint opposite_site;
    uint patch_offset;
}

fn void? append_voronoi_patch(SolidScratch* scratch, VoronoiPieceBuilder* piece, SurfacePatch patch) @local {
    SurfacePatchLink* link = &reserve_elements(scratch, SurfacePatchLink, 1)![0];
    *link = { .value = patch };
    if (piece.last) {
        piece.last.next = link;
    } else {
        piece.first = link;
    }
    piece.last = link;
    piece.patch_count++;
    return;
}

fn PlanarSegment[]? voronoi_cap_segments(
    SolidScratch* scratch,
    VoronoiPieceBuilder* piece,
    ExactPlane* plane,
) @local {
    PlanarSegment[] native = collect_boundary_segments(
        scratch: scratch,
        partition: piece.cells,
        plane: plane,
        faces: piece.faces,
    )!;
    usz count = native.len;
    foreach (patch : piece.authored) if (!compare_exact_planes(patch.plane, plane)) count += patch.boundary.edges.len;
    PlanarSegment[] segments = reserve_elements(scratch, PlanarSegment, count)!;
    segments[:native.len] = native[..];
    count = native.len;
    foreach (patch : piece.authored) {
        if (compare_exact_planes(patch.plane, plane)) continue;
        foreach (edge : patch.boundary.edges) segments[count++] = {
            .first = patch.boundary.vertices[edge.weight > 0 ? edge.second : edge.first],
            .second = patch.boundary.vertices[edge.weight > 0 ? edge.first : edge.second],
            .line = edge.line,
        };
    }
    return segments;
}

fn uint? opposite_voronoi_piece(
    ExactScratch* scratch,
    VoronoiPieceBuilder[] pieces,
    uint site,
    PatchTriangles* surface,
    PatchTriangle triangle,
) @local {
    uint saved = scratch.count;
    defer scratch.count = saved;
    HomogeneousPoint point;
    foreach (&coordinate : point) *coordinate = scratch.take()!;
    mean_cell_vertices(scratch, point, {
        surface.vertices[triangle.vertices[0]], surface.vertices[triangle.vertices[1]],
        surface.vertices[triangle.vertices[2]], surface.vertices[triangle.vertices[2]],
    })!;
    uint found = NO_SOLID_INDEX;
    foreach (uint index, piece : pieces) {
        if (piece.site != site) continue;
        for (PartitionCell* cell = piece.cells.first; cell; cell = cell.next) {
            bool inside = true;
            foreach (face : cell.cell.faces) {
                int side = homogeneous_plane_side(scratch, face.plane, point)!;
                if (face.reversed ? side < 0 : side > 0) {
                    inside = false;
                    break;
                }
            }
            if (!inside) continue;
            if (found != NO_SOLID_INDEX && found != index) return NON_MANIFOLD_RESULT~;
            found = index;
            break;
        }
    }
    if (found == NO_SOLID_INDEX) return NON_MANIFOLD_RESULT~;
    return found;
}

fn SurfacePiece[]? build_voronoi_surface_pieces(
    SolidScratch* scratch,
    PreparedSource* source,
    VoronoiPartition* partition,
    uint max_pieces,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    SolidPartition[][] components = reserve_elements(scratch, SolidPartition[], partition.sites.len)!;
    uint count;
    foreach (uint site, &cells : partition.sites) {
        components[site] = partition_material_components(scratch, cells)!;
        if ((usz)components[site].len > (usz)max_pieces - count) return c3d::CAPACITY_EXCEEDED~;
        count += (uint)components[site].len;
    }
    if (!count) {
        scratch.used = saved;
        return {};
    }
    VoronoiPieceBuilder[] builders = reserve_elements(scratch, VoronoiPieceBuilder, count)!;
    uint index;
    uint patch_count;
    foreach (uint site, cells : components) {
        ExactPlane*[] cuts = reserve_elements(scratch, ExactPlane*, partition.sites.len - 1)!;
        uint cut_count;
        foreach (&bisector : partition.bisectors) {
            if (bisector.first == site || bisector.second == site) cuts[cut_count++] = &bisector.plane;
        }
        foreach (&component : cells) {
            VoronoiPieceBuilder* builder = &builders[index++];
            *builder = { .cells = component, .site = site, .faces = index_boundary_cell_faces(scratch, component)! };
            builder.authored = source_boundary_patches(
                scratch: scratch,
                surface: &source.solid.surface,
                source: &source.constructions,
                partition: component,
                cuts: cuts,
                faces: builder.faces,
            )!;
            if ((usz)builder.authored.len > (usz)uint::max - patch_count) return c3d::CAPACITY_EXCEEDED~;
            patch_count += (uint)builder.authored.len;
        }
    }
    VoronoiCap* first_cap;
    foreach (&bisector : partition.bisectors) foreach (uint piece, &builder : builders) {
        if (builder.site != bisector.first) continue;
        usz temporary = scratch.used;
        PlanarSegment[] segments = voronoi_cap_segments(scratch, builder, &bisector.plane)!;
        BoundaryPatch boundary = create_boundary_patch(
            scratch: scratch,
            plane: &bisector.plane,
            segments: segments,
            reversed: bisector.first_reversed,
        )!;
        if (!boundary.boundary.edges.len) {
            scratch.used = temporary;
            continue;
        }
        if (patch_count == uint::max) return c3d::CAPACITY_EXCEEDED~;
        patch_count++;
        VoronoiCap* cap = &reserve_elements(scratch, VoronoiCap, 1)![0];
        *cap = { .boundary = boundary, .first_piece = piece, .opposite_site = bisector.second, .next = first_cap };
        first_cap = cap;
    }
    BoundaryPatch[] patches = reserve_elements(scratch, BoundaryPatch, patch_count)!;
    index = 0;
    foreach (&builder : builders) {
        builder.patch_offset = index;
        patches[index:builder.authored.len] = builder.authored[..];
        index += (uint)builder.authored.len;
    }
    for (VoronoiCap* cap = first_cap; cap; cap = cap.next) {
        cap.patch_offset = index;
        patches[index++] = cap.boundary;
    }
    reconcile_patch_boundaries(scratch, patches)!;
    foreach (&builder : builders) {
        builder.authored = patches[builder.patch_offset:builder.authored.len];
        foreach (boundary : builder.authored) {
            PatchTriangles* triangulation = &reserve_elements(scratch, PatchTriangles, 1)![0];
            *triangulation = triangulate_boundary_patch(scratch, &boundary)!;
            append_voronoi_patch(scratch, builder, {
                .boundary = boundary,
                .triangulation = { .shared = triangulation, .reversed = boundary.reversed },
                .source = &source.solid.surface,
            })!;
        }
    }
    for (VoronoiCap* cap = first_cap; cap; cap = cap.next) {
        cap.boundary = patches[cap.patch_offset];
        OrientedPatchTriangles[2] views = triangulate_shared_cut(scratch, &cap.boundary)!;
        append_voronoi_patch(scratch, &builders[cap.first_piece], {
            .boundary = cap.boundary, .triangulation = views[0], .cut = true, .shared_cut = true,
        })!;
        uint[] owners = reserve_elements(scratch, uint, views[0].shared.triangles.len)!;
        foreach (uint triangle, value : views[0].shared.triangles) owners[triangle] = opposite_voronoi_piece(
            scratch: scratch.exact,
            pieces: builders,
            site: cap.opposite_site,
            surface: views[0].shared,
            triangle: value,
        )!;
        foreach (uint piece, &builder : builders) {
            if (builder.site != cap.opposite_site) continue;
            uint selected;
            foreach (owner : owners) selected += owner == piece ? 1 : 0;
            if (!selected) continue;
            uint[] selection = reserve_elements(scratch, uint, selected)!;
            selected = 0;
            foreach (uint triangle, owner : owners) if (owner == piece) selection[selected++] = triangle;
            append_voronoi_patch(scratch, builder, {
                .boundary = cap.boundary, .triangulation = views[1], .cut = true, .shared_cut = true, .selection = selection,
            })!;
        }
    }
    SurfacePiece[] result = reserve_elements(scratch, SurfacePiece, builders.len)!;
    foreach (uint piece, builder : builders) {
        result[piece] = { .site_index = builder.site, .patches = reserve_elements(scratch, SurfacePatch, builder.patch_count)! };
        index = 0;
        for (SurfacePatchLink* link = builder.first; link; link = link.next) result[piece].patches[index++] = link.value;
    }
    return result;
}
