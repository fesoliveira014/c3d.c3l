module c3d::physics::fracture;

import std::time;

const uint RAW_POINT_NUMERATOR_BITS @local = 1953;
const uint RAW_POINT_DENOMINATOR_BITS @local = 1674;
const uint PROJECTED_ORIENTATION_BITS @private = 2 * RAW_POINT_NUMERATOR_BITS + RAW_POINT_DENOMINATOR_BITS + 3;
const uint PROJECTED_ORIENTATION_TEMPORARIES @private = TRIANGLE_CORNERS * HOMOGENEOUS_COMPONENTS + 1 + SPACE_AXES;
$assert PROJECTED_ORIENTATION_BITS == 5583 && PROJECTED_ORIENTATION_BITS <= EXACT_LIMBS * INTEGER_LIMB_BITS;
$assert PROJECTED_ORIENTATION_TEMPORARIES == 16 && PROJECTED_ORIENTATION_TEMPORARIES <= EXACT_TEMPORARIES;

fn int compare_integers(IntegerView first, IntegerView second) @private {
    if (first.negative != second.negative) return first.negative ? -1 : 1;
    int magnitude = compare_magnitude(first, second);
    return first.negative ? -magnitude : magnitude;
}

fn int compare_exact_planes(ExactPlane* first, ExactPlane* second) @private {
    for (uint axis = 0; axis < HOMOGENEOUS_COMPONENTS; axis++) {
        int order = compare_integers(first.coefficients[axis].view(), second.coefficients[axis].view());
        if (order) return order;
    }
    return 0;
}

fn bool? independent_plane_pair(ExactScratch* scratch, ExactPlane* first, ExactPlane* second) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* left = scratch.take()!;
    WideInteger* right = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint next = (axis + 1) % SPACE_AXES;
        multiply_integer(left, first.coefficients[axis].view(), second.coefficients[next].view())!;
        multiply_integer(right, second.coefficients[axis].view(), first.coefficients[next].view())!;
        if (compare_integers(left.view(), right.view())) return true;
    }
    return false;
}

fn int? exact_planar_orientation(
    ExactScratch* scratch,
    PlaneTriple[TRIANGLE_CORNERS] vertices,
    uint dropped_axis,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    HomogeneousPoint[TRIANGLE_CORNERS] points;
    foreach (&point : points) foreach (&coordinate : *point) *coordinate = scratch.take()!;
    WideInteger* result = scratch.take()!;
    IntegerView[TRIANGLE_CORNERS * TRIANGLE_CORNERS] matrix;
    foreach (uint row, point : points) {
        construct_point(scratch, point, vertices[row])!;
        matrix[row * TRIANGLE_CORNERS] = point[SPACE_AXES].view();
        for (uint axis = 1; axis < TRIANGLE_CORNERS; axis++) {
            matrix[row * TRIANGLE_CORNERS + axis] = point[(dropped_axis + axis) % SPACE_AXES].view();
        }
    }
    determinant(
        scratch: scratch,
        output: result,
        matrix: matrix[..],
        order: TRIANGLE_CORNERS,
    )!;
    return integer_sign(result.view());
}

fn int filter_planar_orientation(PlaneTriple[TRIANGLE_CORNERS] vertices, uint dropped_axis) @private {
    $if env::COMPILER_OPT_LEVEL == O3:
    return FILTER_UNCERTAIN;
    $else
    Interval[TRIANGLE_CORNERS * TRIANGLE_CORNERS] matrix;
    foreach (uint row, vertex : vertices) {
        Interval[HOMOGENEOUS_COMPONENTS] point;
        if (!interval_point(vertex, &point)) return FILTER_UNCERTAIN;
        matrix[row * TRIANGLE_CORNERS] = point[SPACE_AXES];
        for (uint axis = 1; axis < TRIANGLE_CORNERS; axis++) {
            matrix[row * TRIANGLE_CORNERS + axis] = point[(dropped_axis + axis) % SPACE_AXES];
        }
    }
    return interval_sign(interval_determinant(matrix[..], TRIANGLE_CORNERS));
    $endif
}

fn int? planar_orientation(
    ExactScratch* scratch,
    PlaneTriple[TRIANGLE_CORNERS] vertices,
    uint dropped_axis,
) @private {
    scratch.predicate_count++;
    int filtered = filter_planar_orientation(vertices, dropped_axis);
    if (filtered != FILTER_UNCERTAIN) {
        scratch.filtered_count++;
        return filtered;
    }
    Clock started = clock::now();
    defer scratch.exact_nanoseconds += (ulong)started.to_now();
    return exact_planar_orientation(scratch, vertices, dropped_axis);
}

fn int? exact_compare_planar_points(
    ExactScratch* scratch,
    PlaneTriple first,
    PlaneTriple second,
    uint dropped_axis,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    HomogeneousPoint left;
    HomogeneousPoint right;
    foreach (&coordinate : left) *coordinate = scratch.take()!;
    foreach (&coordinate : right) *coordinate = scratch.take()!;
    construct_point(scratch, left, first)!;
    construct_point(scratch, right, second)!;
    WideInteger* left_product = scratch.take()!;
    WideInteger* right_product = scratch.take()!;
    for (uint offset = 1; offset < SPACE_AXES; offset++) {
        uint axis = (dropped_axis + offset) % SPACE_AXES;
        multiply_integer(left_product, left[axis].view(), right[SPACE_AXES].view())!;
        multiply_integer(right_product, right[axis].view(), left[SPACE_AXES].view())!;
        int order = compare_integers(left_product.view(), right_product.view());
        if (order) return order;
    }
    return 0;
}

fn int filter_planar_order(PlaneTriple first, PlaneTriple second, uint dropped_axis) @private {
    $if env::COMPILER_OPT_LEVEL == O3:
    return FILTER_UNCERTAIN;
    $else
    Interval[HOMOGENEOUS_COMPONENTS] left;
    Interval[HOMOGENEOUS_COMPONENTS] right;
    if (!interval_point(first, &left) || !interval_point(second, &right)) return FILTER_UNCERTAIN;
    for (uint offset = 1; offset < SPACE_AXES; offset++) {
        uint axis = (dropped_axis + offset) % SPACE_AXES;
        Interval difference = add_interval(
            multiply_interval(left[axis], right[SPACE_AXES]),
            negate_interval(multiply_interval(right[axis], left[SPACE_AXES])),
        );
        int order = interval_sign(difference);
        if (order) return order;
    }
    return 0;
    $endif
}

fn int? compare_planar_points(
    ExactScratch* scratch,
    PlaneTriple first,
    PlaneTriple second,
    uint dropped_axis,
) @private {
    scratch.predicate_count++;
    int filtered = filter_planar_order(first, second, dropped_axis);
    if (filtered != FILTER_UNCERTAIN) {
        scratch.filtered_count++;
        return filtered;
    }
    Clock started = clock::now();
    defer scratch.exact_nanoseconds += (ulong)started.to_now();
    return exact_compare_planar_points(
        scratch: scratch,
        first: first,
        second: second,
        dropped_axis: dropped_axis,
    );
}
