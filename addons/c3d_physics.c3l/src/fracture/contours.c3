module c3d::physics::fracture;

struct PlanarContour @private {
    uint first;
    uint count;
    uint parent;
    bool hole;
}

struct BoundaryPatch @private {
    ExactPlane* plane;
    PlanarEdges boundary;
    PlanarContour[] contours;
    uint[] corners;
    uint source_face;
    uint[TRIANGLE_CORNERS] source_key;
    uint[TRIANGLE_CORNERS] source_corners;
    bool reversed;
    bool unchanged;
}

fn uint patch_projection(ExactPlane* plane) @private {
    uint axis;
    while (!plane.coefficients[axis].used) axis++;
    return axis;
}

fn bool? contour_contains(
    ExactScratch* scratch,
    BoundaryPatch* patch,
    PlanarContour contour,
    PlaneTriple point,
) @local {
    bool inside;
    uint axis = patch_projection(patch.plane);
    for (uint corner = 0; corner < contour.count; corner++) {
        PlaneTriple first = patch.boundary.vertices[patch.corners[contour.first + corner]];
        PlaneTriple second = patch.boundary.vertices[patch.corners[contour.first + (corner + 1) % contour.count]];
        int start = compare_planar_points(
            scratch: scratch,
            first: first,
            second: point,
            dropped_axis: axis,
        )!;
        int end = compare_planar_points(
            scratch: scratch,
            first: second,
            second: point,
            dropped_axis: axis,
        )!;
        if (!start || !end) return NON_MANIFOLD_RESULT~;
        if (start == end) continue;
        int side = planar_orientation(scratch, { first, second, point }, axis)!;
        if (!side) return NON_MANIFOLD_RESULT~;
        // Lexicographic sweep is an infinitesimal shear; orientation is unchanged.
        if ((side > 0) == (start > end)) inside = !inside;
    }
    return inside;
}

fn void? trace_patch_contours(SolidScratch* scratch, BoundaryPatch* patch) @private {
    PlanarEdges* graph = &patch.boundary;
    uint[] next = reserve_elements(scratch, uint, graph.vertices.len)!;
    uint[] previous = reserve_elements(scratch, uint, graph.vertices.len)!;
    next[..] = NO_SOLID_INDEX;
    previous[..] = NO_SOLID_INDEX;
    foreach (edge : graph.edges) {
        if (edge.weight != 1 && edge.weight != -1) return NON_MANIFOLD_RESULT~;
        uint first = edge.weight > 0 ? edge.first : edge.second;
        uint second = edge.weight > 0 ? edge.second : edge.first;
        if (next[first] != NO_SOLID_INDEX || previous[second] != NO_SOLID_INDEX) return NON_MANIFOLD_RESULT~;
        next[first] = second;
        previous[second] = first;
    }
    foreach (uint point, successor : next) {
        if (successor == NO_SOLID_INDEX || previous[point] == NO_SOLID_INDEX) return NON_MANIFOLD_RESULT~;
    }
    patch.corners = reserve_elements(scratch, uint, graph.vertices.len)!;
    patch.contours = reserve_elements(scratch, PlanarContour, graph.vertices.len / TRIANGLE_CORNERS)!;
    uint count;
    uint written;
    foreach (uint first, predecessor : previous) {
        if (predecessor == NO_SOLID_INDEX) continue;
        PlanarContour contour = { .first = written, .parent = NO_SOLID_INDEX };
        uint point = first;
        do {
            patch.corners[written++] = point;
            contour.count++;
            previous[point] = NO_SOLID_INDEX;
            point = next[point];
        } while (point != first);
        if (contour.count < TRIANGLE_CORNERS) return NON_MANIFOLD_RESULT~;
        int sign = planar_orientation(
            scratch: scratch.exact,
            vertices: { graph.vertices[patch.corners[written - 1]], graph.vertices[first], graph.vertices[next[first]] },
            dropped_axis: patch_projection(patch.plane),
        )!;
        if (!sign) return NON_MANIFOLD_RESULT~;
        contour.hole = (sign < 0) != patch.reversed;
        patch.contours[count++] = contour;
    }
    patch.contours = patch.contours[:count];
    foreach (uint index, &contour : patch.contours) {
        PlaneTriple point = graph.vertices[patch.corners[contour.first]];
        foreach (uint other, enclosing : patch.contours) {
            if (index == other || !contour_contains(
                scratch: scratch.exact,
                patch: patch,
                contour: enclosing,
                point: point,
            )!) continue;
            if (contour.parent == NO_SOLID_INDEX || contour_contains(
                scratch: scratch.exact,
                patch: patch,
                contour: patch.contours[contour.parent],
                point: graph.vertices[patch.corners[enclosing.first]],
            )!) contour.parent = other;
        }
    }
    foreach (contour : patch.contours) {
        bool hole;
        for (uint parent = contour.parent; parent != NO_SOLID_INDEX; parent = patch.contours[parent].parent) hole = !hole;
        if (hole != contour.hole) return NON_MANIFOLD_RESULT~;
    }
    return;
}

fn PlanarSegment[]? patch_segments(SolidScratch* scratch, BoundaryPatch* patch, bool simplify) @private {
    PlanarSegment[] segments = reserve_elements(scratch, PlanarSegment, patch.corners.len)!;
    uint[] outgoing = reserve_elements(scratch, uint, patch.boundary.vertices.len)!;
    foreach (uint index, edge : patch.boundary.edges) outgoing[edge.weight > 0 ? edge.first : edge.second] = index;
    uint count;
    foreach (contour : patch.contours) {
        uint first = NO_SOLID_INDEX;
        uint previous;
        for (uint offset = 0; offset < contour.count; offset++) {
            uint point = patch.corners[contour.first + offset];
            uint before = patch.corners[contour.first + (offset + contour.count - 1) % contour.count];
            uint after = patch.corners[contour.first + (offset + 1) % contour.count];
            if (simplify && !planar_orientation(
                scratch: scratch.exact,
                vertices: { patch.boundary.vertices[before], patch.boundary.vertices[point], patch.boundary.vertices[after] },
                dropped_axis: patch_projection(patch.plane),
            )!) continue;
            if (first == NO_SOLID_INDEX) {
                first = point;
            } else {
                segments[count++] = {
                    .first = patch.boundary.vertices[previous], .second = patch.boundary.vertices[point],
                    .line = patch.boundary.edges[outgoing[previous]].line,
                };
            }
            previous = point;
        }
        segments[count++] = {
            .first = patch.boundary.vertices[previous], .second = patch.boundary.vertices[first],
            .line = patch.boundary.edges[outgoing[previous]].line,
        };
    }
    return segments[:count];
}

fn BoundaryPatch? create_boundary_patch(
    SolidScratch* scratch,
    ExactPlane* plane,
    PlanarSegment[] segments,
    bool reversed,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    BoundaryPatch patch = {
        .plane = plane, .reversed = reversed, .source_face = NO_SOLID_INDEX,
        .boundary = normalize_planar_edges(scratch, plane, segments)!,
    };
    if (!patch.boundary.edges.len) return patch;
    trace_patch_contours(scratch, &patch)!;
    PlanarSegment[] reduced = patch_segments(scratch, &patch, true)!;
    patch.boundary = normalize_planar_edges(scratch, plane, reduced)!;
    trace_patch_contours(scratch, &patch)!;
    return patch;
}

fn void? reconcile_patch_boundaries(SolidScratch* scratch, BoundaryPatch[] patches) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    usz count;
    foreach (patch : patches) count += patch.boundary.vertices.len;
    PlaneTriple[] points = reserve_elements(scratch, PlaneTriple, count)!;
    count = 0;
    foreach (patch : patches) foreach (point : patch.boundary.vertices) points[count++] = point;
    BoundaryPatch[] staged = reserve_elements(scratch, BoundaryPatch, patches.len)!;
    staged[..] = patches[..];
    foreach (&patch : staged) {
        PlanarSegment[] segments = patch_segments(scratch, patch, false)!;
        patch.boundary = normalize_planar_edges(
            scratch: scratch,
            plane: patch.plane,
            segments: segments,
            constraints: points,
        )!;
        trace_patch_contours(scratch, patch)!;
        patch.unchanged &= patch.corners.len == TRIANGLE_CORNERS;
    }
    patches[..] = staged[..];
    return;
}
