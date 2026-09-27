module c3d::nav;

import std::math;
import c3d;

const float PARALLEL_EPSILON @local = 0.000001f; // mirrors dtIntersectSegmentPoly2D's EPS
const float DEGENERATE_EPSILON @local = 1e-6f; // mirrors dtClosestHeightPointTriangle's and dtIntersectSegSeg2D's EPS
const float MIN_TRIANGLE_WEIGHT @local = 0.001f; // mirrors dtRandomPointInConvexPoly's floor on a triangle's area
const float EQUAL_POINT_DISTANCE @local = 1.0f / 16384.0f; // mirrors dtVequal's threshold
const float OVERLAP_EPSILON @local = 1e-4f; // mirrors dtOverlapPolyPoly2D's eps; touching polygons do not overlap

struct SegmentProjection @private {
    float distance_sqr;    // XZ
    float t;               // along the segment, clamped to 0..1
}

struct SegmentPolyHit @private {
    float t_min;
    float t_max;
    int   edge_min;        // -1 when the segment starts inside
    int   edge_max;        // -1 when the segment ends inside
}

<* Twice the signed area of the triangle projected on XZ; mirrors dtTriArea2D. *>
fn float tri_area_2d(Vec3 a, Vec3 b, Vec3 c) {
    float abx = b.x - a.x;
    float abz = b.z - a.z;
    float acx = c.x - a.x;
    float acz = c.z - a.z;
    return acx * abz - abx * acz;
}

<*
 Point in a convex polygon from two numbers in 0..1; mirrors dtRandomPointInConvexPoly.
 @param s : "Picks the fan triangle, weighted by area."
 @param t : "Picks the point inside the triangle."
 @require points.len >= 3, points.len <= MAX_VERTS_PER_POLY
*>
fn Vec3 random_point_in_convex_poly(Vec3[] points, float s, float t) {
    float[MAX_VERTS_PER_POLY] areas;
    float area_sum = 0;
    for (usz index = 2; index < points.len; index++) {
        areas[index] = tri_area_2d(points[0], points[index - 1], points[index]);
        area_sum += math::max(MIN_TRIANGLE_WEIGHT, areas[index]);
    }

    float threshold = s * area_sum;
    float accumulated = 0;
    float u = 1;
    usz triangle = points.len - 1;
    for (usz index = 2; index < points.len; index++) {
        float area = areas[index];
        if (threshold >= accumulated && threshold < accumulated + area) {
            u = (threshold - accumulated) / area;
            triangle = index;
            break;
        }
        accumulated += area;
    }

    float v = math::sqrt(t);
    float a = 1 - v;
    float b = (1 - u) * v;
    float c = u * v;
    return points[0] * a + points[triangle - 1] * b + points[triangle] * c;
}

fn float perp_2d(Vec3 u, Vec3 v) @private => u.z * v.x - u.x * v.z;

fn Vec3 lerp_point(Vec3 from, Vec3 to, float t) @private => from + (to - from) * t;

fn bool same_point(Vec3 first, Vec3 second) @private {
    Vec3 delta = second - first;
    return delta.dot(delta) < EQUAL_POINT_DISTANCE * EQUAL_POINT_DISTANCE;
}

fn float distance_sqr_2d(Vec3 first, Vec3 second) @private {
    float dx = second.x - first.x;
    float dz = second.z - first.z;
    return dx * dx + dz * dz;
}

fn SegmentProjection distance_pt_seg_sqr_2d(Vec3 point, Vec3 start, Vec3 end) @private {
    float pqx = end.x - start.x;
    float pqz = end.z - start.z;
    float dx = point.x - start.x;
    float dz = point.z - start.z;
    float length_sqr = pqx * pqx + pqz * pqz;
    float t = pqx * dx + pqz * dz;
    if (length_sqr > 0) t /= length_sqr;
    t = math::clamp(t, 0.0f, 1.0f);
    dx = start.x + t * pqx - point.x;
    dz = start.z + t * pqz - point.z;
    return { .distance_sqr = dx * dx + dz * dz, .t = t };
}

// c3d::INVALID_ARGUMENT when the point's XZ lies outside the triangle or the triangle is degenerate.
fn float? closest_height_point_triangle(
    Vec3 point,
    Vec3 a,
    Vec3 b,
    Vec3 c,
) @private {
    Vec3 v0 = c - a;
    Vec3 v1 = b - a;
    Vec3 v2 = point - a;
    float denominator = v0.x * v1.z - v0.z * v1.x;
    if (math::abs(denominator) < DEGENERATE_EPSILON) return c3d::INVALID_ARGUMENT~;

    float u = v1.z * v2.x - v1.x * v2.z;
    float v = v0.x * v2.z - v0.z * v2.x;
    if (denominator < 0) {
        denominator = -denominator;
        u = -u;
        v = -v;
    }
    if (u >= 0 && v >= 0 && u + v <= denominator) return a.y + (v0.y * u + v1.y * v) / denominator;
    return c3d::INVALID_ARGUMENT~;
}

// c3d::INVALID_ARGUMENT when the segment misses the polygon.
fn SegmentPolyHit? intersect_segment_poly_2d(Vec3 start, Vec3 end, Vec3[] verts) @private {
    SegmentPolyHit hit = { .t_min = 0, .t_max = 1, .edge_min = -1, .edge_max = -1 };
    Vec3 direction = end - start;
    usz previous = verts.len - 1;
    for (usz current = 0; current < verts.len; previous = current++) {
        Vec3 edge = verts[current] - verts[previous];
        Vec3 offset = start - verts[previous];
        float numerator = perp_2d(edge, offset);
        float denominator = perp_2d(direction, edge);
        if (math::abs(denominator) < PARALLEL_EPSILON) {
            if (numerator < 0) return c3d::INVALID_ARGUMENT~;
            continue;
        }
        float t = numerator / denominator;
        if (denominator < 0) {
            if (t > hit.t_min) {
                hit.t_min = t;
                hit.edge_min = (int)previous;
                if (hit.t_min > hit.t_max) return c3d::INVALID_ARGUMENT~;
            }
        } else {
            if (t < hit.t_max) {
                hit.t_max = t;
                hit.edge_max = (int)previous;
                if (hit.t_max < hit.t_min) return c3d::INVALID_ARGUMENT~;
            }
        }
    }
    return hit;
}

// Parameters along both segments; c3d::INVALID_ARGUMENT when they are parallel.
fn float[<2>]? intersect_seg_seg_2d(
    Vec3 first_start,
    Vec3 first_end,
    Vec3 second_start,
    Vec3 second_end,
) @private {
    Vec3 u = first_end - first_start;
    Vec3 v = second_end - second_start;
    Vec3 w = first_start - second_start;
    float denominator = perp_2d(u, v);
    if (math::abs(denominator) < DEGENERATE_EPSILON) return c3d::INVALID_ARGUMENT~;
    return { perp_2d(v, w) / denominator, perp_2d(u, w) / denominator };
}

fn bool crosses_ray(Vec3 point, Vec3 current, Vec3 previous) @private {
    return (current.z > point.z) != (previous.z > point.z)
        && point.x < (previous.x - current.x) * (point.z - current.z) / (previous.z - current.z) + current.x;
}

fn bool point_in_polygon(Vec3 point, Vec3[] verts) @private {
    bool inside;
    usz previous = verts.len - 1;
    for (usz current = 0; current < verts.len; previous = current++) {
        if (crosses_ray(point, verts[current], verts[previous])) inside = !inside;
    }
    return inside;
}

// Fills one distance and parameter per edge, edge i starting at vertex i.
fn bool distance_pt_poly_edges_sqr(
    Vec3 point,
    Vec3[] verts,
    float[] edge_distances,
    float[] edge_t,
) @private {
    bool inside;
    usz previous = verts.len - 1;
    for (usz current = 0; current < verts.len; previous = current++) {
        if (crosses_ray(point, verts[current], verts[previous])) inside = !inside;
        SegmentProjection projection = distance_pt_seg_sqr_2d(point, verts[previous], verts[current]);
        edge_distances[previous] = projection.distance_sqr;
        edge_t[previous] = projection.t;
    }
    return inside;
}

// Mirrors dtOverlapPolyPoly2D: separating axes in XZ.
fn bool overlap_poly_poly_2d(Vec3[] first, Vec3[] second) @private {
    return !has_separating_edge(first, second) && !has_separating_edge(second, first);
}

fn bool has_separating_edge(Vec3[] edges_of, Vec3[] other) @local {
    usz previous = edges_of.len - 1;
    for (usz current = 0; current < edges_of.len; previous = current++) {
        Vec3 axis = {
            edges_of[current].z - edges_of[previous].z,
            0,
            -(edges_of[current].x - edges_of[previous].x),
        };
        float[<2>] own = project_poly_2d(axis, edges_of);
        float[<2>] projected = project_poly_2d(axis, other);
        if (own[0] + OVERLAP_EPSILON > projected[1] || own[1] - OVERLAP_EPSILON < projected[0]) return true;
    }
    return false;
}

// Mirrors projectPoly.
fn float[<2>] project_poly_2d(Vec3 axis, Vec3[] verts) @local {
    float[<2>] range = { float::max, -float::max };
    foreach (vertex : verts) {
        float distance = axis.x * vertex.x + axis.z * vertex.z;
        range[0] = math::min(range[0], distance);
        range[1] = math::max(range[1], distance);
    }
    return range;
}

fn bool overlap_quant_bounds(
    ushort[3] first_min,
    ushort[3] first_max,
    ushort[3] second_min,
    ushort[3] second_max,
) @private {
    for (usz axis = 0; axis < 3; axis++) {
        if (first_min[axis] > second_max[axis] || first_max[axis] < second_min[axis]) return false;
    }
    return true;
}

fn uint next_pow2(uint value) @private {
    value--;
    value |= value >> 1;
    value |= value >> 2;
    value |= value >> 4;
    value |= value >> 8;
    value |= value >> 16;
    return value + 1;
}

fn int opposite_tile(int side) @private => (side + 4) & 0x7;
