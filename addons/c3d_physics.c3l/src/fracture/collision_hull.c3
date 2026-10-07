module c3d::physics::fracture;

import c3d;
import std::math;
import std::sort;

struct CollisionHullSurface @private {
    Vec3[] points;
    uint[] indices;
}

struct HullTriangle @local {
    uint[TRIANGLE_CORNERS] vertices;
}

struct HullEdge @local {
    uint first;
    uint second;
}

fn CollisionHullSurface? build_collision_hull(SolidScratch* scratch, Vec3[] source) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;

    if (source.len > uint::max || source.len > usz::max / 6) return c3d::CAPACITY_EXCEEDED~;
    if (source.len < COLLISION_TETRAHEDRON_VERTICES) return NUMERICAL_FAILURE~;

    Vec3[] points = reserve_elements(scratch, Vec3, source.len)!;
    points[..] = source[..];
    sort::quicksort(points, &compare_hull_points);

    uint point_count;
    foreach (point : points) {
        if (!point_count || !same_position(points[point_count - 1], point)) points[point_count++] = point;
    }
    points = points[:point_count];
    if (point_count < COLLISION_TETRAHEDRON_VERTICES) return NUMERICAL_FAILURE~;

    uint[COLLISION_TETRAHEDRON_VERTICES] initial = { 0, 1, 2, 3 };
    while (initial[2] < point_count) {
        uint projection;
        while (projection < SPACE_AXES && !projected_orientation(
            scratch.exact, { points[initial[0]], points[initial[1]], points[initial[2]] }, projection,
        )!) projection++;
        if (projection != SPACE_AXES) break;
        initial[2]++;
    }
    if (initial[2] == point_count) return NUMERICAL_FAILURE~;

    initial[3] = initial[2] + 1;
    while (initial[3] < point_count && !float_orientation(
        scratch.exact, { points[initial[0]], points[initial[1]], points[initial[2]], points[initial[3]] },
    )!) initial[3]++;
    if (initial[3] == point_count) return NUMERICAL_FAILURE~;

    // A closed triangulated convex hull has at most 2V - 4 faces.
    usz face_capacity = 2 * (usz)point_count - 4;
    uint[] indices = reserve_elements(scratch, uint, face_capacity * TRIANGLE_CORNERS)!;

    usz retained = scratch.used;
    defer scratch.used = retained;
    HullTriangle[] faces = reserve_elements(scratch, HullTriangle, face_capacity)!;
    HullEdge[] edges = reserve_elements(scratch, HullEdge, face_capacity * TRIANGLE_CORNERS)!;
    int[] sides = reserve_elements(scratch, int, face_capacity)!;

    usz face_count = COLLISION_TETRAHEDRON_VERTICES;
    for (uint excluded = 0; excluded < COLLISION_TETRAHEDRON_VERTICES; excluded++) {
        uint corner;
        foreach (uint index, vertex : initial) if (index != excluded) faces[excluded].vertices[corner++] = vertex;
        uint[TRIANGLE_CORNERS]* vertices = &faces[excluded].vertices;
        if (float_orientation(scratch.exact, {
            points[(*vertices)[0]], points[(*vertices)[1]], points[(*vertices)[2]], points[initial[excluded]],
        })! > 0) {
            uint swap = (*vertices)[1];
            (*vertices)[1] = (*vertices)[2];
            (*vertices)[2] = swap;
        }
    }

    foreach (uint vertex, point : points) {
        if (vertex == initial[0] || vertex == initial[1] || vertex == initial[2] || vertex == initial[3]) continue;

        bool outside;
        foreach (usz face, triangle : faces[:face_count]) {
            sides[face] = float_orientation(scratch.exact, {
                points[triangle.vertices[0]], points[triangle.vertices[1]], points[triangle.vertices[2]], point,
            })!;
            outside |= sides[face] > 0;
        }
        if (!outside) continue;

        usz edge_count;
        usz kept;
        foreach (usz face, triangle : faces[:face_count]) {
            if (sides[face] < 0) {
                faces[kept++] = triangle;
                continue;
            }

            // Coplanar faces leave with visible faces, so every horizon cone is nondegenerate.
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                edges[edge_count++] = {
                    .first = triangle.vertices[corner],
                    .second = triangle.vertices[(corner + 1) % TRIANGLE_CORNERS],
                };
            }
        }

        sort::quicksort(edges[:edge_count], &compare_hull_edges);
        face_count = kept;
        for (usz edge = 0; edge < edge_count; edge++) {
            HullEdge current = edges[edge];
            if (edge + 1 < edge_count && same_hull_edge(current, edges[edge + 1])) {
                edge++;
                continue;
            }
            faces[face_count++] = { .vertices = { current.first, current.second, vertex } };
        }
    }

    foreach (&triangle : faces[:face_count]) {
        uint first;
        for (uint corner = 1; corner < TRIANGLE_CORNERS; corner++) {
            if (triangle.vertices[corner] < triangle.vertices[first]) first = corner;
        }

        uint[TRIANGLE_CORNERS] original = triangle.vertices;
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            triangle.vertices[corner] = original[(first + corner) % TRIANGLE_CORNERS];
        }
    }

    sort::quicksort(faces[:face_count], &compare_hull_triangles);
    foreach (usz face, triangle : faces[:face_count]) {
        indices[face * TRIANGLE_CORNERS:TRIANGLE_CORNERS] = triangle.vertices[..];
    }

    return { .points = points, .indices = indices[:face_count * TRIANGLE_CORNERS] };
}

fn long hull_coordinate_key(float value) @local {
    uint bits = bitcast(value, uint);
    long magnitude = bits & (uint::max >> 1);
    return bits >> FLOAT_SIGN_BIT ? -magnitude : magnitude;
}

fn int compare_hull_points(Vec3 first, Vec3 second) @local {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        long left = hull_coordinate_key(first[axis]);
        long right = hull_coordinate_key(second[axis]);
        if (left != right) return left < right ? -1 : 1;
    }
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint left = bitcast(first[axis], uint);
        uint right = bitcast(second[axis], uint);
        if (left != right) return left < right ? -1 : 1;
    }
    return 0;
}

fn bool same_hull_edge(HullEdge first, HullEdge second) @local {
    return math::min(first.first, first.second) == math::min(second.first, second.second)
        && math::max(first.first, first.second) == math::max(second.first, second.second);
}

fn int compare_hull_edges(HullEdge first, HullEdge second) @local {
    uint left = math::min(first.first, first.second);
    uint right = math::min(second.first, second.second);
    if (left != right) return left < right ? -1 : 1;
    left = math::max(first.first, first.second);
    right = math::max(second.first, second.second);
    return left < right ? -1 : left > right ? 1 : 0;
}

fn int compare_hull_triangles(HullTriangle first, HullTriangle second) @local {
    for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
        if (first.vertices[corner] != second.vertices[corner]) {
            return first.vertices[corner] < second.vertices[corner] ? -1 : 1;
        }
    }
    return 0;
}
