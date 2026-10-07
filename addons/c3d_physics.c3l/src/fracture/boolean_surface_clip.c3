module c3d::physics::fracture;

fn bool? boolean_polygon_has_area(ExactScratch* scratch, FaceClipVertex[] polygon, ExactPlane* plane) @local {
    for (usz corner = 2; corner < polygon.len; corner++) {
        if (planar_orientation(
            scratch: scratch, vertices: { polygon[0].point, polygon[corner - 1].point, polygon[corner].point },
            dropped_axis: patch_projection(plane),
        )!) return true;
    }
    return false;
}

fn void emit_boolean_polygon(
    FaceClipVertex[] polygon,
    bool reversed,
    PlanarSegment[] output,
    usz* count,
) @local {
    if (output.len) foreach (usz index, point : polygon) {
        FaceClipVertex next = polygon[(index + 1) % (usz)polygon.len];
        output[*count + index] = {
            .first = reversed ? next.point : point.point,
            .second = reversed ? point.point : next.point,
            .line = next.incoming,
        };
    }
    *count += polygon.len;
}

fn FaceClipVertex[]? intersect_boolean_source_triangle(
    SolidScratch* scratch,
    FaceClipVertex[] polygon,
    ExactPlane* plane,
    PreparedSource* source,
    uint face,
) @local {
    usz capacity = polygon.len + TRIANGLE_CORNERS;
    FaceClipVertex[] input = reserve_elements(scratch, FaceClipVertex, capacity)!;
    FaceClipVertex[] output = reserve_elements(scratch, FaceClipVertex, capacity)!;
    input[:polygon.len] = polygon[..];
    usz count = polygon.len;
    uint[TRIANGLE_CORNERS] triangle = surface_triangle(&source.solid.surface, face);
    for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
        SourceEdge* edge = &source.constructions.edges[source.constructions.corner_edges[face * TRIANGLE_CORNERS + corner]];
        PlaneTriple opposite = source.constructions.vertices[triangle[(corner + 2) % TRIANGLE_CORNERS]];
        ExactPlane* support = &source.constructions.faces[edge.owner_corner / TRIANGLE_CORNERS];
        int side = plane_side(scratch.exact, support, opposite)!;
        if (!side) {
            support = &edge.plane;
            side = plane_side(scratch.exact, support, opposite)!;
        }
        count = clip_face_polygon(
            scratch: scratch.exact, input: input[:count], output: output, source: plane,
            boundary: { .plane = support, .reversed = side > 0 },
        )!;
        if (count < TRIANGLE_CORNERS) return {};
        FaceClipVertex[] swap = input;
        input = output;
        output = swap;
    }
    if (!boolean_polygon_has_area(scratch.exact, input[:count], plane)!) return {};
    return input[:count];
}

fn PlanarSegment[]? collect_boolean_surface_segments(
    SolidScratch* scratch,
    PreparedSource* first,
    PreparedSource* second,
    BooleanSurfaceFace[] sources,
    BoundaryCellFace[] faces,
) @private {
    PlanarSegment[] segments;
    for (uint pass = 0; pass < 2; pass++) {
        usz count;
        foreach (source : sources) {
            foreach (entry : boundary_plane_faces(faces, source.plane)) {
                usz saved = scratch.used;
                defer scratch.used = saved;
                FaceClipVertex[] polygon = clip_source_face_to_cell(
                    scratch: scratch, surface: &second.solid.surface, source: &second.constructions,
                    face: source.face, cell: entry.cell,
                )!;
                if (!boolean_polygon_has_area(scratch.exact, polygon, source.plane)!) continue;
                bool reversed = entry.cell.faces[entry.face].reversed != second.constructions.reversed[source.face];
                emit_boolean_polygon(polygon: polygon, reversed: reversed, output: segments, count: &count);
                uint current;
                while (current != NO_SOLID_INDEX) {
                    SolidBvhNode* node = &first.solid.surface.nodes[current];
                    if (!overlapping_solid_bounds(node.bounds, second.solid.surface.bounds[source.face])) {
                        current = node.escape;
                    } else if (node.count != 1) {
                        current = node.child;
                    } else {
                        uint face = first.solid.surface.order[node.first];
                        if (!compare_exact_planes(source.plane, &first.constructions.faces[face])) {
                            usz retained = scratch.used;
                            defer scratch.used = retained;
                            FaceClipVertex[] overlap = intersect_boolean_source_triangle(
                                scratch: scratch, polygon: polygon, plane: source.plane, source: first, face: face,
                            )!;
                            emit_boolean_polygon(polygon: overlap, reversed: !reversed, output: segments, count: &count);
                        }
                        current = node.escape;
                    }
                }
            }
        }
        if (!pass) segments = reserve_elements(scratch, PlanarSegment, count)!;
    }
    return segments;
}
