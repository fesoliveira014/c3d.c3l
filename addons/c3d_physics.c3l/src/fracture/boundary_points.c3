module c3d::physics::fracture;

import c3d;
import std::time;
import std::math;

struct BoundaryPoint @private {
    PlaneTriple vertex;
    IntegerView[HOMOGENEOUS_COMPONENTS] coordinates;
}

struct BoundaryPointBounds @private {
    uint[SPACE_AXES] lower;
    uint[SPACE_AXES] upper;
}

struct BoundaryPointNode @private {
    BoundaryPointBounds bounds;
    uint first;
    uint count;
    uint child;
    uint escape;
}

struct BoundaryPointIndex @private {
    BoundaryPoint[] points;
    uint[] order;
    BoundaryPointNode[] nodes;
}

fn BoundaryPoint? cache_boundary_point(SolidScratch* scratch, PlaneTriple vertex) @private {
    uint saved = scratch.exact.count;
    defer scratch.exact.count = saved;
    HomogeneousPoint coordinates;
    foreach (&coordinate : coordinates) *coordinate = scratch.exact.take()!;
    construct_point(scratch.exact, coordinates, vertex)!;
    BoundaryPoint point = { .vertex = vertex };
    foreach (uint axis, coordinate : coordinates) {
        ulong[] limbs = reserve_elements(scratch, ulong, coordinate.used)!;
        limbs[..] = coordinate.limbs[:coordinate.used];
        point.coordinates[axis] = { .limbs = limbs, .negative = coordinate.negative };
    }
    return point;
}

fn int? compare_boundary_coordinate(
    ExactScratch* scratch,
    BoundaryPoint* first,
    BoundaryPoint* second,
    uint axis,
) @private {
    scratch.predicate_count++;
    std::time::Clock started = clock::now();
    defer scratch.exact_nanoseconds += (ulong)started.to_now();
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* left = scratch.take()!;
    WideInteger* right = scratch.take()!;
    // Cached positive denominators preserve exact bounds without derived planes.
    multiply_integer(left, first.coordinates[axis], second.coordinates[SPACE_AXES])!;
    multiply_integer(right, second.coordinates[axis], first.coordinates[SPACE_AXES])!;
    return compare_integers(left.view(), right.view());
}

fn int? compare_boundary_points(ExactScratch* scratch, BoundaryPoint* first, BoundaryPoint* second) @local {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        int order = compare_boundary_coordinate(
            scratch: scratch,
            first: first,
            second: second,
            axis: axis,
        )!;
        if (order) return order;
    }
    return 0;
}

fn void? sort_boundary_points(SolidScratch* scratch, BoundaryPointIndex* index) @local {
    usz saved = scratch.used;
    defer scratch.used = saved;
    uint[] temporary = reserve_elements(scratch, uint, index.order.len)!;
    uint[] input = index.order;
    uint[] output = temporary;
    for (usz width = 1; width < input.len; width *= 2) {
        for (usz start = 0; start < input.len; start += 2 * width) {
            usz middle = math::min(start + width, (usz)input.len);
            usz end = math::min(start + 2 * width, (usz)input.len);
            usz left = start;
            usz right = middle;
            for (usz written = start; written < end; written++) {
                bool take_left = right == end;
                if (left < middle && right < end) take_left = compare_boundary_points(
                    scratch.exact, &index.points[input[left]], &index.points[input[right]],
                )! <= 0;
                output[written] = take_left ? input[left++] : input[right++];
            }
        }
        uint[] swap = input;
        input = output;
        output = swap;
    }
    if (input.ptr != index.order.ptr) index.order[..] = input[..];
    return;
}

fn BoundaryPointBounds? join_boundary_point_bounds(
    ExactScratch* scratch,
    BoundaryPoint[] points,
    BoundaryPointBounds first,
    BoundaryPointBounds second,
) @private {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        if (compare_boundary_coordinate(
            scratch: scratch,
            first: &points[second.lower[axis]],
            second: &points[first.lower[axis]],
            axis: axis,
        )! < 0) {
            first.lower[axis] = second.lower[axis];
        }
        if (compare_boundary_coordinate(
            scratch: scratch,
            first: &points[second.upper[axis]],
            second: &points[first.upper[axis]],
            axis: axis,
        )! > 0) {
            first.upper[axis] = second.upper[axis];
        }
    }
    return first;
}

fn BoundaryPointBounds? boundary_point_bounds(
    ExactScratch* scratch,
    BoundaryPoint[] points,
    uint first,
    uint count,
) @private {
    BoundaryPointBounds bounds;
    bounds.lower[..] = first;
    bounds.upper[..] = first;
    for (uint offset = 1; offset < count; offset++) {
        BoundaryPointBounds next;
        next.lower[..] = first + offset;
        next.upper[..] = first + offset;
        bounds = join_boundary_point_bounds(
            scratch: scratch,
            points: points,
            first: bounds,
            second: next,
        )!;
    }
    return bounds;
}

fn BoundaryPointIndex? index_boundary_points(SolidScratch* scratch, BoundaryPatch[] patches) @private {
    usz count;
    foreach (patch : patches) count += patch.boundary.vertices.len;
    if (count > uint::max / 2) return c3d::CAPACITY_EXCEEDED~;
    BoundaryPointIndex index = {
        .points = reserve_elements(scratch, BoundaryPoint, count)!,
        .order = reserve_elements(scratch, uint, count)!,
    };
    count = 0;
    foreach (patch : patches) foreach (vertex : patch.boundary.vertices) {
        index.points[count] = cache_boundary_point(scratch, vertex)!;
        index.order[count] = (uint)count;
        count++;
    }
    if (!count) return index;
    sort_boundary_points(scratch, &index)!;
    index.nodes = reserve_elements(scratch, BoundaryPointNode, count * 2 - 1)!;
    index.nodes[0] = { .count = (uint)count, .escape = NO_SOLID_INDEX };
    uint written = 1;
    for (uint node_index = 0; node_index < written; node_index++) {
        BoundaryPointNode* node = &index.nodes[node_index];
        if (node.count == 1) {
            node.bounds.lower[..] = index.order[node.first];
            node.bounds.upper[..] = index.order[node.first];
            continue;
        }
        uint left = node.count / 2;
        node.child = written;
        index.nodes[written] = { .first = node.first, .count = left, .escape = written + 1 };
        index.nodes[written + 1] = { .first = node.first + left, .count = node.count - left, .escape = node.escape };
        written += 2;
    }
    for (uint node_index = written; node_index > 0; node_index--) {
        BoundaryPointNode* node = &index.nodes[node_index - 1];
        if (node.count == 1) continue;
        node.bounds = join_boundary_point_bounds(
            scratch: scratch.exact,
            points: index.points,
            first: index.nodes[node.child].bounds,
            second: index.nodes[node.child + 1].bounds,
        )!;
    }
    return index;
}

fn bool? overlapping_boundary_point_bounds(
    ExactScratch* scratch,
    BoundaryPoint[] points,
    BoundaryPointBounds first,
    BoundaryPointBounds second,
) @local {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        if (compare_boundary_coordinate(
            scratch: scratch,
            first: &points[first.upper[axis]],
            second: &points[second.lower[axis]],
            axis: axis,
        )! < 0) return false;
        if (compare_boundary_coordinate(
            scratch: scratch,
            first: &points[second.upper[axis]],
            second: &points[first.lower[axis]],
            axis: axis,
        )! < 0) return false;
    }
    return true;
}

fn PlaneTriple[]? query_boundary_points(
    ExactScratch* scratch,
    BoundaryPointIndex* index,
    BoundaryPointBounds bounds,
    PlaneTriple[] output,
) @private {
    uint count;
    uint current = index.nodes.len ? 0 : NO_SOLID_INDEX;
    while (current != NO_SOLID_INDEX) {
        BoundaryPointNode* node = &index.nodes[current];
        if (!overlapping_boundary_point_bounds(
            scratch: scratch,
            points: index.points,
            first: bounds,
            second: node.bounds,
        )!) {
            current = node.escape;
        } else if (node.count != 1) {
            current = node.child;
        } else {
            output[count++] = index.points[index.order[node.first]].vertex;
            current = node.escape;
        }
    }
    return output[:count];
}
