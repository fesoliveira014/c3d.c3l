module c3d::anim;

import c3d;
import std::math;

const uint BLEND_LAYOUT_MAX_TRIANGLES @private = 2 * MAX_ACTIONS - 5;
const double BLEND_SPACE_AREA_RELATIVE_TOLERANCE @private = 1e-10; // bounds unstable area relative to extent squared
const double BLEND_SPACE_BOUNDARY_TOLERANCE @private = 1e-7; // bounds admitted barycentric roundoff
const double BLEND_SPACE_DISTANCE_RELATIVE_TOLERANCE @private = 1e-12; // bounds distance ties in squared-extent units

<* One authored triangle referencing the group's sample coordinates. *>
struct BlendTriangle {
    uint[3] indices;
}

struct BlendTriangleIndices @private {
    char[3] indices;
}

struct BlendHullIndices @private {
    char[2] indices;
}

struct BlendLayoutInfo @private {
    uint triangle_count;
    uint hull_count;
    double extent;
}

struct BlendLayoutView @private {
    Vec2[] points;
    BlendTriangleIndices[] triangles;
    BlendHullIndices[] hull;
    double extent;
}

struct BlendLayoutSelection @private {
    char[3] indices;
    float[3] weights;
    uint count;
}

struct BlendLayoutPrepared @private {
    BlendTriangleIndices[BLEND_LAYOUT_MAX_TRIANGLES] triangles;
    BlendHullIndices[MAX_ACTIONS] hull;
    BlendLayoutInfo info;
}

$assert BlendTriangleIndices::size == 3;
$assert BlendHullIndices::size == 2;
$assert BLEND_LAYOUT_MAX_TRIANGLES <= uint::size * 8;

<*
 Validate the topology and copy the authored triangles and hull only on success.
 @param prepared_triangles : "Owner-prepared destination; unchanged on faults."
 @param prepared_hull : "Owner-prepared destination; unchanged on faults."
 @return? c3d::INVALID_ARGUMENT
 @require capacity >= 1 && capacity <= MAX_ACTIONS
 @require prepared_triangles.len >= (sz)(capacity >= 3 ? 2 * capacity - 5 : 0)
 @require prepared_hull.len >= capacity
*>
fn BlendLayoutInfo? prepare_blend_layout(
    Vec2[] points,
    BlendTriangle[] triangles,
    uint capacity,
    BlendTriangleIndices[] prepared_triangles,
    BlendHullIndices[] prepared_hull,
) @private {
    if (points.len < 3 || points.len > capacity || !triangles.len
      || triangles.len > 2 * points.len - 5) return c3d::INVALID_ARGUMENT~;

    BlendLayoutPrepared prepared = validate_blend_layout(points, triangles)!;

    prepared_triangles[:prepared.info.triangle_count] = prepared.triangles[:prepared.info.triangle_count];
    prepared_hull[:prepared.info.hull_count] = prepared.hull[:prepared.info.hull_count];

    return prepared.info;
}

<*
 Locate a finite parameter in an admitted layout without allocation or retained state.
 @require math::is_finite(parameter.x) && math::is_finite(parameter.y)
*>
fn BlendLayoutSelection select_blend_layout(BlendLayoutView layout, Vec2 parameter) @private {
    foreach (uint sample, point : layout.points) {
        if (point.x == parameter.x && point.y == parameter.y) {
            return { .indices = { (char)sample, 0, 0 }, .weights = { 1, 0, 0 }, .count = 1 };
        }
    }

    // A sliver's points lie within the barycentric tolerance of its neighbor, so containment is exact first
    // and roundoff outside every triangle only goes to the nearest one.
    BlendTriangleIndices nearest = layout.triangles[0];
    double nearest_distance = -double::max;

    foreach (triangle : layout.triangles) {
        double distance = blend_edge_distance(layout.points, triangle, parameter);
        if (distance >= 0) return blend_triangle_selection(layout.points, triangle, parameter);

        if (distance > nearest_distance) {
            nearest = triangle;
            nearest_distance = distance;
        }
    }

    double[3] barycentric = blend_barycentric(layout.points, nearest, parameter);
    if (barycentric[0] >= -BLEND_SPACE_BOUNDARY_TOLERANCE && barycentric[1] >= -BLEND_SPACE_BOUNDARY_TOLERANCE
      && barycentric[2] >= -BLEND_SPACE_BOUNDARY_TOLERANCE) {
        return blend_triangle_selection(layout.points, nearest, parameter);
    }

    double[MAX_ACTIONS] distances;
    double[MAX_ACTIONS] fractions;
    double closest = double::max;

    foreach (uint index, edge : layout.hull) {
        Vec2 a = layout.points[edge.indices[0]];
        Vec2 b = layout.points[edge.indices[1]];
        double dx = (double)b.x - a.x;
        double dy = (double)b.y - a.y;
        double px = (double)parameter.x - a.x;
        double py = (double)parameter.y - a.y;
        double fraction = math::clamp((px * dx + py * dy) / (dx * dx + dy * dy), 0.0, 1.0);
        double error_x = px - fraction * dx;
        double error_y = py - fraction * dy;
        fractions[index] = fraction;
        distances[index] = error_x * error_x + error_y * error_y;
        closest = math::min(closest, distances[index]);
    }

    double tie = BLEND_SPACE_DISTANCE_RELATIVE_TOLERANCE * layout.extent * layout.extent;
    foreach (uint index, edge : layout.hull) {
        if (distances[index] > closest + tie) continue;

        return {
            .indices = { edge.indices[0], edge.indices[1], 0 },
            .weights = { (float)(1 - fractions[index]), (float)fractions[index], 0 },
            .count = 2,
        };
    }

    unreachable();
}

fn double[3] blend_barycentric(Vec2[] points, BlendTriangleIndices triangle, Vec2 parameter) @private {
    Vec2 a = points[triangle.indices[0]];
    Vec2 b = points[triangle.indices[1]];
    Vec2 c = points[triangle.indices[2]];
    double denominator = blend_orientation(a, b, c);

    return {
        blend_orientation(b, c, parameter) / denominator,
        blend_orientation(c, a, parameter) / denominator,
        blend_orientation(a, b, parameter) / denominator,
    };
}

fn BlendLayoutSelection blend_triangle_selection(
    Vec2[] points,
    BlendTriangleIndices triangle,
    Vec2 parameter,
) @private {
    double[3] barycentric = blend_barycentric(points, triangle, parameter);
    foreach (&weight : barycentric) *weight = math::max(*weight, 0.0);
    double sum = barycentric[0] + barycentric[1] + barycentric[2];

    return {
        .indices = triangle.indices,
        .weights = { (float)(barycentric[0] / sum), (float)(barycentric[1] / sum), (float)(barycentric[2] / sum) },
        .count = 3,
    };
}

fn double blend_edge_distance(Vec2[] points, BlendTriangleIndices triangle, Vec2 parameter) @private {
    Vec2 a = points[triangle.indices[0]];
    double winding = blend_orientation(a, points[triangle.indices[1]], points[triangle.indices[2]]) > 0 ? 1 : -1;
    double distance = double::max;

    for (uint edge = 0; edge < 3; edge++) {
        Vec2 from = points[triangle.indices[edge]];
        Vec2 to = points[triangle.indices[(edge + 1) % 3]];
        double dx = (double)to.x - from.x;
        double dy = (double)to.y - from.y;
        double length = math::sqrt(dx * dx + dy * dy);
        distance = math::min(distance, winding * blend_orientation(from, to, parameter) / length);
    }

    return distance;
}

fn double blend_orientation(Vec2 a, Vec2 b, Vec2 c) @private {
    return ((double)b.x - a.x) * ((double)c.y - a.y)
      - ((double)b.y - a.y) * ((double)c.x - a.x);
}

fn bool blend_on_open_edge(Vec2 point, Vec2 a, Vec2 b) @private {
    if (blend_orientation(a, b, point) != 0) return false;

    double dx = (double)b.x - a.x;
    double dy = (double)b.y - a.y;
    double projection = ((double)point.x - a.x) * dx + ((double)point.y - a.y) * dy;
    return projection > 0 && projection < dx * dx + dy * dy;
}

fn bool blend_strictly_inside(Vec2 point, BlendTriangleIndices triangle, Vec2[] points) @private {
    Vec2 a = points[triangle.indices[0]];
    Vec2 b = points[triangle.indices[1]];
    Vec2 c = points[triangle.indices[2]];
    return blend_orientation(a, b, point) > 0 && blend_orientation(b, c, point) > 0
      && blend_orientation(c, a, point) > 0;
}

fn BlendLayoutPrepared? validate_blend_layout(Vec2[] points, BlendTriangle[] triangles) @private {
    uint count = (uint)points.len;
    uint triangle_count = (uint)triangles.len;
    double min_x = double::max;
    double max_x = -double::max;
    double min_y = double::max;
    double max_y = -double::max;

    foreach (uint sample, point : points) {
        if (!math::is_finite(point.x) || !math::is_finite(point.y)) return c3d::INVALID_ARGUMENT~;

        for (uint prior = 0; prior < sample; prior++) {
            Vec2 other = points[prior];
            if (point.x == other.x && point.y == other.y) return c3d::INVALID_ARGUMENT~;
        }

        min_x = math::min(min_x, (double)point.x);
        max_x = math::max(max_x, (double)point.x);
        min_y = math::min(min_y, (double)point.y);
        max_y = math::max(max_y, (double)point.y);
    }

    double extent = math::max(max_x - min_x, max_y - min_y);
    if (extent == 0) return c3d::INVALID_ARGUMENT~;

    double area_limit = BLEND_SPACE_AREA_RELATIVE_TOLERANCE * extent * extent;
    BlendLayoutPrepared prepared = { .info = { .triangle_count = triangle_count, .extent = extent } };
    BlendTriangleIndices[BLEND_LAYOUT_MAX_TRIANGLES] oriented;
    uint reversed;
    bool[MAX_ACTIONS] used;
    bool[MAX_ACTIONS][MAX_ACTIONS] directed;

    foreach (uint index, input : triangles) {
        uint a = input.indices[0];
        uint b = input.indices[1];
        uint c = input.indices[2];
        if (a >= count || b >= count || c >= count || a == b || b == c || c == a) {
            return c3d::INVALID_ARGUMENT~;
        }

        double area = blend_orientation(points[a], points[b], points[c]);
        if (math::abs(area) <= area_limit) return c3d::INVALID_ARGUMENT~;

        BlendTriangleIndices triangle = { .indices = { (char)a, (char)b, (char)c } };
        prepared.triangles[index] = triangle;
        if (area < 0) {
            @swap(triangle.indices[1], triangle.indices[2]);
            reversed |= 1u << index;
        }

        oriented[index] = triangle;

        for (uint edge = 0; edge < 3; edge++) {
            uint from = triangle.indices[edge];
            uint to = triangle.indices[(edge + 1) % 3];
            if (directed[from][to]) return c3d::INVALID_ARGUMENT~;

            directed[from][to] = true;
            used[from] = true;

            foreach (uint sample, point : points) {
                if (sample != from && sample != to && blend_on_open_edge(point, points[from], points[to])) {
                    return c3d::INVALID_ARGUMENT~;
                }
            }
        }

        for (uint prior = 0; prior < index; prior++) {
            BlendTriangleIndices other = oriented[prior];
            uint shared;
            for (uint corner = 0; corner < 3; corner++) {
                uint sample = triangle.indices[corner];
                bool matches = sample == other.indices[0] || sample == other.indices[1] || sample == other.indices[2];
                shared += matches ? 1 : 0;
                if (blend_strictly_inside(points[sample], other, points)
                  || blend_strictly_inside(points[other.indices[corner]], triangle, points)) {
                    return c3d::INVALID_ARGUMENT~;
                }
            }

            if (shared == 3) return c3d::INVALID_ARGUMENT~;

            for (uint first = 0; first < 3; first++) {
                Vec2 first_a = points[triangle.indices[first]];
                Vec2 first_b = points[triangle.indices[(first + 1) % 3]];
                for (uint second = 0; second < 3; second++) {
                    Vec2 second_a = points[other.indices[second]];
                    Vec2 second_b = points[other.indices[(second + 1) % 3]];
                    double c_side = blend_orientation(first_a, first_b, second_a);
                    double d_side = blend_orientation(first_a, first_b, second_b);
                    double a_side = blend_orientation(second_a, second_b, first_a);
                    double b_side = blend_orientation(second_a, second_b, first_b);
                    if (((c_side < 0 && d_side > 0) || (c_side > 0 && d_side < 0))
                      && ((a_side < 0 && b_side > 0) || (a_side > 0 && b_side < 0))) {
                        return c3d::INVALID_ARGUMENT~;
                    }
                }
            }
        }
    }

    for (uint sample = 0; sample < count; sample++) {
        if (!used[sample]) return c3d::INVALID_ARGUMENT~;
    }

    uint[MAX_ACTIONS] next;
    next[..] = uint::max;
    uint[MAX_ACTIONS] incoming;
    foreach (uint triangle, input : triangles) {
        for (uint edge = 0; edge < 3; edge++) {
            uint a = input.indices[edge];
            uint b = input.indices[(edge + 1) % 3];
            if (directed[a][b] && directed[b][a]) continue;

            if (prepared.info.hull_count == count) return c3d::INVALID_ARGUMENT~;
            if (reversed & (1u << triangle)) @swap(a, b);
            if (next[a] != uint::max || incoming[b] != 0) return c3d::INVALID_ARGUMENT~;

            next[a] = b;
            incoming[b]++;
            prepared.hull[prepared.info.hull_count++] = { .indices = { (char)a, (char)b } };
        }
    }

    uint hull_count = prepared.info.hull_count;
    if (hull_count < 3 || triangle_count != 2 * count - hull_count - 2) return c3d::INVALID_ARGUMENT~;

    uint start = prepared.hull[0].indices[0];
    uint current = start;
    bool[MAX_ACTIONS] boundary_seen;
    for (uint step = 0; step < hull_count; step++) {
        if (current >= count || boundary_seen[current] || next[current] == uint::max || incoming[current] != 1) {
            return c3d::INVALID_ARGUMENT~;
        }

        boundary_seen[current] = true;
        uint following = next[current];
        if (next[following] == uint::max
          || blend_orientation(points[current], points[following], points[next[following]]) < 0) {
            return c3d::INVALID_ARGUMENT~;
        }

        current = following;
    }

    if (current != start) return c3d::INVALID_ARGUMENT~;

    foreach (edge : prepared.hull[:hull_count]) {
        foreach (point : points) {
            if (blend_orientation(points[edge.indices[0]], points[edge.indices[1]], point) < 0) {
                return c3d::INVALID_ARGUMENT~;
            }
        }
    }

    return prepared;
}
