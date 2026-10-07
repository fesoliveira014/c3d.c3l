module c3d::physics::fracture;

import c3d;
import std::sort;

struct BooleanSurfaceFace @private {
    ExactPlane* plane;
    uint face;
    bool reversed;
}

struct BooleanPatchOwner @local {
    uint piece;
    uint source;
    bool cut;
}

fn int compare_boolean_surface_faces(BooleanSurfaceFace first, BooleanSurfaceFace second) @local {
    int plane = compare_exact_planes(first.plane, second.plane);
    if (plane) return plane;
    if (first.reversed != second.reversed) return first.reversed ? 1 : -1;
    return first.face < second.face ? -1 : first.face > second.face ? 1 : 0;
}

fn SurfacePiece[]? build_boolean_surface_pieces(
    SolidScratch* scratch,
    PreparedGeneration* prepared,
    SolidPartition* partition,
    BooleanOperation operation,
    uint max_pieces,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;

    SolidPartition[] components = partition_material_components(scratch, partition)!;
    if (components.len > max_pieces) return c3d::CAPACITY_EXCEEDED~;
    if (!components.len) return {};

    PreparedSource* first = &prepared.sources[0];
    PreparedSource* second = &prepared.sources[1];
    bool generated = operation != BooleanOperation.UNION;
    bool difference = operation == BooleanOperation.DIFFERENCE;
    ExactPlane*[] cuts = reserve_elements(scratch, ExactPlane*, second.constructions.faces.len)!;
    BooleanSurfaceFace[] second_faces = reserve_elements(scratch, BooleanSurfaceFace, cuts.len)!;
    foreach (uint face, &plane : second.constructions.faces) {
        cuts[face] = plane;
        second_faces[face] = { .plane = plane, .face = face, .reversed = second.constructions.reversed[face] != difference };
    }
    sort::quicksort(second_faces, &compare_boolean_surface_faces);

    usz capacity = components.len * (first.constructions.faces.len + second.constructions.faces.len);
    BoundaryPatch[] boundaries = reserve_elements(scratch, BoundaryPatch, capacity)!;
    BooleanPatchOwner[] owners = reserve_elements(scratch, BooleanPatchOwner, capacity)!;
    uint[] counts = reserve_elements(scratch, uint, components.len)!;
    counts[..] = 0;
    usz written;

    foreach (uint owner, &component : components) {
        BoundaryCellFace[] faces = index_boundary_cell_faces(scratch, component)!;
        BoundaryPatch[] authored = source_boundary_patches(
            scratch: scratch, surface: &first.solid.surface, source: &first.constructions,
            partition: component, cuts: cuts, faces: faces,
        )!;
        foreach (patch : authored) {
            boundaries[written] = patch;
            owners[written++] = { .piece = owner };
            counts[owner]++;
        }

        for (usz start = 0; start < second_faces.len;) {
            usz end = start + 1;
            if (generated) {
                while (end < second_faces.len
                    && second_faces[start].reversed == second_faces[end].reversed
                    && !compare_exact_planes(second_faces[start].plane, second_faces[end].plane)) end++;
            }

            PlanarSegment[] segments = collect_boolean_surface_segments(
                scratch: scratch, first: first, second: second,
                sources: second_faces[start:end - start], faces: faces,
            )!;
            BoundaryPatch patch = create_boundary_patch(
                scratch: scratch, plane: second_faces[start].plane,
                segments: segments, reversed: second_faces[start].reversed,
            )!;

            if (patch.boundary.edges.len) {
                if (!generated) {
                    uint face = second_faces[start].face;
                    patch.source_face = face;
                    patch.source_corners[..] = second.solid.surface.source.geometry.indices[face * TRIANGLE_CORNERS:TRIANGLE_CORNERS];
                    patch.source_key = canonical_surface_triangle(surface_triangle(&second.solid.surface, face));
                }

                boundaries[written] = patch;
                owners[written++] = { .piece = owner, .source = 1, .cut = generated };
                counts[owner]++;
            }
            start = end;
        }
    }

    boundaries = boundaries[:written];
    reconcile_patch_boundaries(scratch, boundaries)!;

    SurfacePiece[] pieces = reserve_elements(scratch, SurfacePiece, components.len)!;
    foreach (uint owner, &piece : pieces) {
        *piece = { .patches = reserve_elements(scratch, SurfacePatch, counts[owner])! };
        counts[owner] = 0;
    }

    foreach (usz index, &boundary : boundaries) {
        BooleanPatchOwner owner = owners[index];
        PreparedSource* source = &prepared.sources[owner.source];
        if (!owner.cut) {
            boundary.unchanged = unchanged_source_patch(
                scratch: scratch.exact, patch: boundary, source: &source.constructions,
                triangle: surface_triangle(&source.solid.surface, boundary.source_face),
            )!;
        }

        PatchTriangles* triangles = &reserve_elements(scratch, PatchTriangles, 1)![0];
        *triangles = triangulate_boundary_patch(scratch, boundary)!;
        pieces[owner.piece].patches[counts[owner.piece]++] = {
            .boundary = *boundary,
            .triangulation = { .shared = triangles, .reversed = boundary.reversed },
            .source = owner.cut ? null : &source.solid.surface,
            .source_index = owner.source,
            .cut = owner.cut,
        };
    }

    return pieces;
}
