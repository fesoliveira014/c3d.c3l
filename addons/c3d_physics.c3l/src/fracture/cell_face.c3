module c3d::physics::fracture;

struct FaceClipVertex @private {
    PlaneTriple point;
    ExactPlane*[2] incoming;
}

fn usz? clip_face_polygon(
    ExactScratch* scratch,
    FaceClipVertex[] input,
    FaceClipVertex[] output,
    ExactPlane* source,
    CellFace boundary,
) @private {
    usz count;
    FaceClipVertex previous = input[^1];
    int previous_side = plane_side(scratch, boundary.plane, previous.point)! * (boundary.reversed ? -1 : 1);
    foreach (current : input) {
        int side = plane_side(scratch, boundary.plane, current.point)! * (boundary.reversed ? -1 : 1);
        ExactPlane*[2] cut_line = { source, boundary.plane };
        if (side <= 0) {
            if (previous_side > 0) {
                if (side < 0) {
                    output[count++] = {
                        .point = { current.incoming[0], current.incoming[1], boundary.plane },
                        .incoming = cut_line,
                    };
                } else {
                    current.incoming = cut_line;
                }
            }
            output[count++] = current;
        } else if (previous_side < 0) {
            output[count++] = {
                .point = { current.incoming[0], current.incoming[1], boundary.plane },
                .incoming = current.incoming,
            };
        }
        previous_side = side;
    }
    return count;
}

fn bool? source_face_crosses_cell(
    SolidScratch* scratch,
    SolidSurface* surface,
    SourceConstructions* source,
    uint face,
    ConvexCell* cell,
) @private {
    ExactPlane* plane = &source.faces[face];
    bool negative;
    bool positive;
    PlaneTriple off_plane;
    foreach (point : cell.vertices) {
        int side = plane_side(scratch.exact, plane, point)!;
        negative |= side < 0;
        positive |= side > 0;
        if (side) off_plane = point;
    }
    if (!negative || !positive) return false;
    usz saved = scratch.used;
    defer scratch.used = saved;
    FaceClipVertex[] input = clip_source_face_to_cell(
        scratch: scratch,
        surface: surface,
        source: source,
        face: face,
        cell: cell,
    )!;
    usz count = input.len;
    for (usz index = 2; index < count; index++) {
        if (exact_vertex_orientation(scratch.exact, { input[0].point, input[index - 1].point, input[index].point, off_plane })!) return true;
    }
    return false;
}

fn FaceClipVertex[]? clip_source_face_to_cell(
    SolidScratch* scratch,
    SolidSurface* surface,
    SourceConstructions* source,
    uint face,
    ConvexCell* cell,
) @private {
    ExactPlane* plane = &source.faces[face];
    usz capacity = TRIANGLE_CORNERS + cell.faces.len;
    FaceClipVertex[] input = reserve_elements(scratch, FaceClipVertex, capacity)!;
    FaceClipVertex[] output = reserve_elements(scratch, FaceClipVertex, capacity)!;
    uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
    foreach (uint corner, vertex : triangle) {
        uint previous = face * TRIANGLE_CORNERS + (corner + TRIANGLE_CORNERS - 1) % TRIANGLE_CORNERS;
        SourceEdge* edge = &source.edges[source.corner_edges[previous]];
        input[corner] = {
            .point = source.vertices[vertex],
            .incoming = { &source.faces[edge.owner_corner / TRIANGLE_CORNERS], &edge.plane },
        };
    }
    usz count = TRIANGLE_CORNERS;
    foreach (boundary : cell.faces) {
        count = clip_face_polygon(
            scratch: scratch.exact, input: input[:count], output: output,
            source: plane, boundary: boundary,
        )!;
        if (count < TRIANGLE_CORNERS) return {};
        FaceClipVertex[] swap = input;
        input = output;
        output = swap;
    }
    return input[:count];
}
