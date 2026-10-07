module c3d::physics::fracture;

import c3d;
import std::math;
import std::sort;

struct PatchTriangle @private {
    uint[TRIANGLE_CORNERS] vertices;
}

struct PatchTriangles @private {
    PlaneTriple[] vertices;
    PatchTriangle[] triangles;
}

struct OrientedPatchTriangles @private {
    PatchTriangles* shared;
    bool reversed;
}

struct PolygonCorner @local {
    uint vertex;
    uint previous;
    uint next;
}

struct PatchClipper @local {
    BoundaryPatch* patch;
    ExactScratch* exact;
    PolygonCorner[] corners;
    uint used;
    uint axis;
}

fn int? PatchClipper.side(
    &self,
    uint first,
    uint second,
    uint third,
) {
    return planar_orientation(
        scratch: self.exact,
        vertices: {
        self.patch.boundary.vertices[first], self.patch.boundary.vertices[second], self.patch.boundary.vertices[third],
    },
        dropped_axis: self.axis,
    );
}

fn bool? PatchClipper.edges_conflict(&self, uint[2] first, uint[2] second) {
    int start = self.side(first[0], first[1], second[0])!;
    int end = self.side(first[0], first[1], second[1])!;
    int before = self.side(second[0], second[1], first[0])!;
    int after = self.side(second[0], second[1], first[1])!;
    if (start && start == -end && before && before == -after) return true;
    if (!start && !end) {
        uint low = math::max(math::min(first[0], first[1]), math::min(second[0], second[1]));
        uint high = math::min(math::max(first[0], first[1]), math::max(second[0], second[1]));
        if (low < high) return true;
    }
    for (uint index = 0; index < 2; index++) {
        uint point = second[index];
        if (point != first[0] && point != first[1] && !(index ? end : start)
            && point > math::min(first[0], first[1]) && point < math::max(first[0], first[1])) return true;
        point = first[index];
        if (point != second[0] && point != second[1] && !(index ? after : before)
            && point > math::min(second[0], second[1]) && point < math::max(second[0], second[1])) return true;
    }
    return false;
}

fn bool? PatchClipper.locally_inside(&self, uint corner, uint point) {
    PolygonCorner current = self.corners[corner];
    uint previous = self.corners[current.previous].vertex;
    uint next = self.corners[current.next].vertex;
    int turn = self.side(previous, current.vertex, next)!;
    int incoming = self.side(previous, current.vertex, point)!;
    int outgoing = self.side(current.vertex, next, point)!;
    return turn >= 0 ? incoming >= 0 && outgoing >= 0 : incoming >= 0 || outgoing >= 0;
}

fn bool? PatchClipper.bridge_visible(&self, uint outer, uint hole) {
    uint[2] bridge = { self.corners[outer].vertex, self.corners[hole].vertex };
    if (!self.locally_inside(outer, bridge[1])! || !self.locally_inside(hole, bridge[0])!) return false;
    foreach (edge : self.patch.boundary.edges) {
        if (self.edges_conflict(bridge, { edge.first, edge.second })!) return false;
    }
    uint current = outer;
    do {
        uint next = self.corners[current].next;
        if (self.edges_conflict(bridge, { self.corners[current].vertex, self.corners[next].vertex })!) return false;
        current = next;
    } while (current != outer);
    return true;
}

fn void? PatchClipper.join_hole(&self, uint outer, uint hole) {
    uint chosen = NO_SOLID_INDEX;
    uint current = outer;
    do {
        if ((chosen == NO_SOLID_INDEX || self.corners[current].vertex < self.corners[chosen].vertex
            || (self.corners[current].vertex == self.corners[chosen].vertex && current < chosen))
            && self.bridge_visible(current, hole)!) chosen = current;
        current = self.corners[current].next;
    } while (current != outer);
    if (chosen == NO_SOLID_INDEX) return NUMERICAL_FAILURE~;
    uint hole_copy = self.used++;
    uint outer_copy = self.used++;
    uint next = self.corners[chosen].next;
    uint previous = self.corners[hole].previous;
    self.corners[hole_copy] = { .vertex = self.corners[hole].vertex, .previous = previous, .next = outer_copy };
    self.corners[outer_copy] = { .vertex = self.corners[chosen].vertex, .previous = hole_copy, .next = next };
    self.corners[previous].next = hole_copy;
    self.corners[next].previous = outer_copy;
    self.corners[chosen].next = hole;
    self.corners[hole].previous = chosen;
    return;
}

fn bool? PatchClipper.is_ear(&self, uint corner) {
    PolygonCorner current = self.corners[corner];
    uint first = self.corners[current.previous].vertex;
    uint last = self.corners[current.next].vertex;
    if (self.side(first, current.vertex, last)! <= 0) return false;
    uint other = self.corners[current.next].next;
    while (other != current.previous) {
        uint point = self.corners[other].vertex;
        if (point != first && point != current.vertex && point != last
            && self.side(first, current.vertex, point)! >= 0
            && self.side(current.vertex, last, point)! >= 0
            && self.side(last, first, point)! >= 0) return false;
        other = self.corners[other].next;
    }
    return true;
}

fn int compare_patch_triangles(PatchTriangle first, PatchTriangle second) @local {
    for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
        if (first.vertices[corner] != second.vertices[corner]) return first.vertices[corner] < second.vertices[corner] ? -1 : 1;
    }
    return 0;
}

fn PatchTriangles? triangulate_boundary_patch(SolidScratch* scratch, BoundaryPatch* patch) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    if (!patch.corners.len) return {};
    uint holes;
    foreach (contour : patch.contours) holes += contour.hole ? 1 : 0;
    usz capacity = patch.corners.len + 2 * (usz)holes;
    if (capacity > uint::max) return c3d::CAPACITY_EXCEEDED~;
    uint triangle_count = (uint)capacity - 2 * ((uint)patch.contours.len - holes);
    PatchTriangles result = {
        .vertices = patch.boundary.vertices,
        .triangles = reserve_elements(scratch, PatchTriangle, triangle_count)!,
    };
    usz retained = scratch.used;
    defer scratch.used = retained;
    PatchClipper clipper = {
        .patch = patch, .exact = scratch.exact, .axis = patch_projection(patch.plane),
        .corners = reserve_elements(scratch, PolygonCorner, capacity)!,
    };
    uint[] starts = reserve_elements(scratch, uint, patch.contours.len)!;
    foreach (uint index, contour : patch.contours) {
        starts[index] = clipper.used;
        for (uint offset = 0; offset < contour.count; offset++) {
            uint order = patch.reversed && offset ? contour.count - offset : offset;
            clipper.corners[clipper.used++] = {
                .vertex = patch.corners[contour.first + order],
                .previous = starts[index] + (offset + contour.count - 1) % contour.count,
                .next = starts[index] + (offset + 1) % contour.count,
            };
        }
    }
    uint written;
    foreach (uint index, contour : patch.contours) {
        if (contour.hole) continue;
        uint first = starts[index];
        uint remaining = contour.count;
        foreach (uint other, hole : patch.contours) {
            if (!hole.hole || hole.parent != index) continue;
            clipper.join_hole(first, starts[other])!;
            remaining += hole.count + 2;
        }
        while (remaining > 2) {
            uint chosen = NO_SOLID_INDEX;
            uint current = first;
            do {
                if ((chosen == NO_SOLID_INDEX || clipper.corners[current].vertex < clipper.corners[chosen].vertex
                    || (clipper.corners[current].vertex == clipper.corners[chosen].vertex && current < chosen))
                    && clipper.is_ear(current)!) chosen = current;
                current = clipper.corners[current].next;
            } while (current != first);
            if (chosen == NO_SOLID_INDEX) return NUMERICAL_FAILURE~;
            PolygonCorner ear = clipper.corners[chosen];
            uint[TRIANGLE_CORNERS] triangle = {
                clipper.corners[ear.previous].vertex, ear.vertex, clipper.corners[ear.next].vertex,
            };
            uint lowest;
            for (uint corner = 1; corner < TRIANGLE_CORNERS; corner++) if (triangle[corner] < triangle[lowest]) lowest = corner;
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) result.triangles[written].vertices[corner] = triangle[(lowest + corner) % TRIANGLE_CORNERS];
            written++;
            clipper.corners[ear.previous].next = ear.next;
            clipper.corners[ear.next].previous = ear.previous;
            if (chosen == first) first = ear.next;
            remaining--;
        }
    }
    sort::quicksort(result.triangles, &compare_patch_triangles);
    return result;
}

fn OrientedPatchTriangles[2]? triangulate_shared_cut(SolidScratch* scratch, BoundaryPatch* patch) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    PatchTriangles* shared = &reserve_elements(scratch, PatchTriangles, 1)![0];
    *shared = triangulate_boundary_patch(scratch, patch)!;
    return { { .shared = shared, .reversed = patch.reversed }, { .shared = shared, .reversed = !patch.reversed } };
}

fn uint[TRIANGLE_CORNERS] oriented_patch_triangle(OrientedPatchTriangles view, uint index) @private {
    uint[TRIANGLE_CORNERS] vertices = view.shared.triangles[index].vertices;
    return view.reversed ? (uint[TRIANGLE_CORNERS]){ vertices[0], vertices[2], vertices[1] } : vertices;
}
