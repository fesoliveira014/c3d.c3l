module c3d::physics::fracture;

import c3d;
import std::sort;

struct CollisionSurface @private {
    ConvexCell* cell;
    OrientedPatchTriangles[] faces;
}

struct CollisionSurfaceSet @private {
    BoundaryPatch[] patches;
    PatchTriangles[] triangles;
    CollisionSurface[] cells;
}

struct CollisionTet @private {
    PlaneTriple[HOMOGENEOUS_COMPONENTS] vertices;
}

struct CollisionTetrahedra @private {
    PlaneTriple anchor;
    CollisionTet[] tetrahedra;
}

struct CollisionPolygon @local {
    FaceClipVertex[] vertices;
    CollisionPolygon* next;
}

struct CollisionSurfaceFace @local {
    ConvexCell* cell;
    ExactPlane* plane;
    FaceClipVertex[] polygon;
    CollisionPolygon* remaining;
    uint owner;
    uint face;
}

struct CollisionPatch @local {
    BoundaryPatch patch;
    uint first;
    uint second;
    bool first_reversed;
    bool second_reversed;
    CollisionPatch* next;
}

struct CollisionPatchList @local {
    CollisionPatch* first;
    CollisionPatch* last;
    usz count;
}

fn int compare_collision_surface_faces(CollisionSurfaceFace first, CollisionSurfaceFace second) @local {
    int plane = compare_exact_planes(first.plane, second.plane);
    if (plane) return plane;
    if (first.owner != second.owner) return first.owner < second.owner ? -1 : 1;
    return first.face < second.face ? -1 : first.face > second.face ? 1 : 0;
}

fn int compare_collision_clip_faces(CellFace first, CellFace second) @local {
    int plane = compare_exact_planes(first.plane, second.plane);
    if (plane) return plane;
    return first.reversed == second.reversed ? 0 : first.reversed ? 1 : -1;
}

fn bool? collision_polygon_has_area(ExactScratch* scratch, ExactPlane* plane, FaceClipVertex[] polygon) @local {
    for (usz corner = 2; corner < polygon.len; corner++) {
        if (planar_orientation(
            scratch: scratch,
            vertices: { polygon[0].point, polygon[corner - 1].point, polygon[corner].point },
            dropped_axis: patch_projection(plane),
        )!) return true;
    }
    return false;
}

fn CollisionPolygon*? copy_collision_polygon(SolidScratch* scratch, FaceClipVertex[] vertices) @local {
    CollisionPolygon* polygon = &reserve_elements(scratch, CollisionPolygon, 1)![0];
    *polygon = { .vertices = reserve_elements(scratch, FaceClipVertex, vertices.len)! };
    polygon.vertices[..] = vertices[..];
    return polygon;
}

fn FaceClipVertex[]? collision_face_polygon(SolidScratch* scratch, ConvexCell* cell, uint face_index) @local {
    CellFace face = cell.faces[face_index];
    FaceClipVertex[] polygon = reserve_elements(scratch, FaceClipVertex, face.count)!;
    for (uint offset = 0; offset < face.count; offset++) {
        uint corner = face.first + offset;
        uint previous = face.first + (offset + face.count - 1) % face.count;
        uint adjacent = cell.corners[cell.corners[previous].twin].face;
        polygon[offset] = {
            .point = cell.vertices[cell.corners[corner].vertex],
            .incoming = { face.plane, cell.faces[adjacent].plane },
        };
    }
    return polygon;
}

fn FaceClipVertex[]? intersect_collision_face(
    SolidScratch* scratch,
    ExactPlane* plane,
    FaceClipVertex[] polygon,
    CellFace[] boundaries,
) @local {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    usz capacity = polygon.len + boundaries.len;
    FaceClipVertex[] output = reserve_elements(scratch, FaceClipVertex, capacity)!;
    FaceClipVertex[] spare = reserve_elements(scratch, FaceClipVertex, capacity)!;
    foreach (boundary : boundaries) {
        usz count = clip_face_polygon(
            scratch: scratch.exact, input: polygon, output: output,
            source: plane, boundary: boundary,
        )!;
        if (count < TRIANGLE_CORNERS) {
            scratch.used = saved;
            return {};
        }
        polygon = output[:count];
        FaceClipVertex[] swap = output;
        output = spare;
        spare = swap;
    }
    if (!collision_polygon_has_area(scratch.exact, plane, polygon)!) {
        scratch.used = saved;
        return {};
    }
    return polygon;
}

fn CollisionPolygon*? subtract_collision_faces(
    SolidScratch* scratch,
    ExactPlane* plane,
    CollisionPolygon* polygons,
    CellFace[] boundaries,
) @local {
    CollisionPolygon* first;
    CollisionPolygon* last;
    for (CollisionPolygon* original = polygons; original; original = original.next) {
        FaceClipVertex[] polygon = original.vertices;
        usz capacity = polygon.len + boundaries.len;
        FaceClipVertex[] output = reserve_elements(scratch, FaceClipVertex, capacity)!;
        FaceClipVertex[] spare = reserve_elements(scratch, FaceClipVertex, capacity)!;
        foreach (boundary : boundaries) {
            if (!compare_exact_planes(plane, boundary.plane)) continue;
            CellFace outside = boundary;
            outside.reversed = !outside.reversed;
            usz outside_count = clip_face_polygon(
                scratch: scratch.exact, input: polygon, output: output,
                source: plane, boundary: outside,
            )!;
            if (collision_polygon_has_area(scratch.exact, plane, output[:outside_count])!) {
                CollisionPolygon* remainder = copy_collision_polygon(scratch, output[:outside_count])!;
                if (last) {
                    last.next = remainder;
                } else {
                    first = remainder;
                }
                last = remainder;
            }
            usz inside_count = clip_face_polygon(
                scratch: scratch.exact, input: polygon, output: output,
                source: plane, boundary: boundary,
            )!;
            if (inside_count < TRIANGLE_CORNERS) break;
            polygon = output[:inside_count];
            FaceClipVertex[] swap = output;
            output = spare;
            spare = swap;
        }
    }
    return first;
}

fn void? append_collision_patch(
    SolidScratch* scratch,
    CollisionPatchList* patches,
    CollisionSurfaceFace first,
    CollisionSurfaceFace* second,
    FaceClipVertex[] polygon,
) @local {
    bool reversed = first.cell.faces[first.face].reversed;
    PlanarSegment[] segments = reserve_elements(scratch, PlanarSegment, polygon.len)!;
    foreach (usz corner, current : polygon) {
        FaceClipVertex next = polygon[(corner + 1) % (usz)polygon.len];
        segments[corner] = {
            .first = reversed ? next.point : current.point,
            .second = reversed ? current.point : next.point,
            .line = next.incoming,
        };
    }
    CollisionPatch* entry = &reserve_elements(scratch, CollisionPatch, 1)![0];
    *entry = {
        .patch = create_boundary_patch(scratch: scratch, plane: first.plane, segments: segments, reversed: false)!,
        .first = first.owner,
        .second = second ? second.owner : NO_SOLID_INDEX,
        .first_reversed = reversed,
        .second_reversed = second ? second.cell.faces[second.face].reversed : false,
    };
    if (patches.last) {
        patches.last.next = entry;
    } else {
        patches.first = entry;
    }
    patches.last = entry;
    patches.count++;
    return;
}

fn CollisionSurfaceSet? build_collision_surfaces(SolidScratch* scratch, ConvexCell*[] cells) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    usz face_count;
    foreach (cell : cells) face_count += cell.faces.len;
    CollisionSurfaceFace[] faces = reserve_elements(scratch, CollisionSurfaceFace, face_count)!;
    CellFace[][] boundaries = reserve_elements(scratch, CellFace[], cells.len)!;
    usz written;
    foreach (uint owner, cell : cells) {
        boundaries[owner] = reserve_elements(scratch, CellFace, cell.faces.len)!;
        boundaries[owner][..] = cell.faces[..];
        sort::quicksort(boundaries[owner], &compare_collision_clip_faces);
        foreach (uint face, boundary : cell.faces) {
            CollisionPolygon* polygon = &reserve_elements(scratch, CollisionPolygon, 1)![0];
            *polygon = { .vertices = collision_face_polygon(scratch, cell, face)! };
            faces[written++] = { .cell = cell, .plane = boundary.plane, .polygon = polygon.vertices, .remaining = polygon, .owner = owner, .face = face };
        }
    }
    sort::quicksort(faces, &compare_collision_surface_faces);
    CollisionPatchList patches;
    for (usz first = 0; first < faces.len; first++) {
        CollisionSurfaceFace* left = &faces[first];
        for (usz second = first + 1; second < faces.len; second++) {
            CollisionSurfaceFace* right = &faces[second];
            if (compare_exact_planes(left.plane, right.plane)) break;
            if (left.cell.faces[left.face].reversed == right.cell.faces[right.face].reversed) continue;
            FaceClipVertex[] contact = intersect_collision_face(
                scratch: scratch, plane: left.plane, polygon: left.polygon, boundaries: boundaries[right.owner],
            )!;
            if (!contact.len) continue;
            append_collision_patch(
                scratch: scratch, patches: &patches, first: *left, second: right, polygon: contact,
            )!;
            left.remaining = subtract_collision_faces(
                scratch: scratch, plane: left.plane, polygons: left.remaining, boundaries: boundaries[right.owner],
            )!;
            right.remaining = subtract_collision_faces(
                scratch: scratch, plane: right.plane, polygons: right.remaining, boundaries: boundaries[left.owner],
            )!;
        }
    }
    foreach (face : faces) {
        for (CollisionPolygon* polygon = face.remaining; polygon; polygon = polygon.next) {
            append_collision_patch(
                scratch: scratch, patches: &patches, first: face, second: null, polygon: polygon.vertices,
            )!;
        }
    }
    CollisionSurfaceSet result = {
        .patches = reserve_elements(scratch, BoundaryPatch, patches.count)!,
        .triangles = reserve_elements(scratch, PatchTriangles, patches.count)!,
        .cells = reserve_elements(scratch, CollisionSurface, cells.len)!,
    };
    usz[] counts = reserve_elements(scratch, usz, cells.len)!;
    counts[..] = 0;
    written = 0;
    for (CollisionPatch* patch = patches.first; patch; patch = patch.next) {
        result.patches[written++] = patch.patch;
        counts[patch.first]++;
        if (patch.second != NO_SOLID_INDEX) counts[patch.second]++;
    }
    reconcile_patch_boundaries(scratch, result.patches)!;
    foreach (uint owner, cell : cells) {
        result.cells[owner] = { .cell = cell, .faces = reserve_elements(scratch, OrientedPatchTriangles, counts[owner])! };
    }
    counts[..] = 0;
    written = 0;
    for (CollisionPatch* patch = patches.first; patch; patch = patch.next) {
        PatchTriangles* triangles = &result.triangles[written];
        *triangles = triangulate_boundary_patch(scratch, &result.patches[written++])!;
        result.cells[patch.first].faces[counts[patch.first]++] = { .shared = triangles, .reversed = patch.first_reversed };
        if (patch.second != NO_SOLID_INDEX) {
            result.cells[patch.second].faces[counts[patch.second]++] = { .shared = triangles, .reversed = patch.second_reversed };
        }
    }
    return result;
}

fn CollisionTetrahedra? tetrahedralize_collision_surface(SolidScratch* scratch, CollisionSurface* surface) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    CollisionTetrahedra result = { .anchor = surface.faces[0].shared.vertices[0] };
    foreach (face : surface.faces) foreach (vertex : face.shared.vertices) {
        if (compare_collision_vertices(scratch.exact, vertex, result.anchor)! < 0) result.anchor = vertex;
    }
    for (uint pass = 0; pass < 2; pass++) {
        usz count;
        foreach (face : surface.faces) {
            foreach (uint index, unused : face.shared.triangles) {
                uint[TRIANGLE_CORNERS] triangle = oriented_patch_triangle(face, index);
                CollisionTet tetrahedron = { .vertices = {
                    result.anchor, face.shared.vertices[triangle[0]],
                    face.shared.vertices[triangle[1]], face.shared.vertices[triangle[2]],
                } };
                int orientation = exact_vertex_orientation(scratch.exact, tetrahedron.vertices)!;
                if (!orientation) continue;
                if (pass) {
                    if (orientation < 0) {
                        PlaneTriple swap = tetrahedron.vertices[1];
                        tetrahedron.vertices[1] = tetrahedron.vertices[2];
                        tetrahedron.vertices[2] = swap;
                    }
                    result.tetrahedra[count] = tetrahedron;
                }
                count++;
            }
        }
        if (!pass) result.tetrahedra = reserve_elements(scratch, CollisionTet, count)!;
    }
    return result;
}
