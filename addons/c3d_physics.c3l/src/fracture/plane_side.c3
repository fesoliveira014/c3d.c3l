module c3d::physics::fracture;

import std::math;
import std::time;

alias PlaneTriple @private = ExactPlane*[SPACE_AXES];

fn bool? independent_plane_normals(ExactScratch* scratch, PlaneTriple planes) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* result = scratch.take()!;
    IntegerView[SPACE_AXES * SPACE_AXES] matrix;
    for (uint row = 0; row < SPACE_AXES; row++) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) matrix[row * SPACE_AXES + axis] = planes[row].coefficients[axis].view();
    }
    determinant(
        scratch: scratch,
        output: result,
        matrix: matrix[..],
        order: SPACE_AXES,
    )!;
    return result.used != 0;
}

fn int? exact_plane_side(ExactScratch* scratch, ExactPlane* plane, PlaneTriple vertex) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS] point;
    foreach (&coordinate : point) *coordinate = scratch.take()!;
    construct_point(scratch, point, vertex)!;
    WideInteger* result = scratch.take()!;
    WideInteger* product = scratch.take()!;
    WideInteger* sum = scratch.take()!;
    for (uint axis = 0; axis < HOMOGENEOUS_COMPONENTS; axis++) {
        multiply_integer(product, plane.coefficients[axis].view(), point[axis].view())!;
        add_integer(sum, result.view(), product.view())!;
        copy_integer(result, sum.view());
    }
    return integer_sign(result.view());
}

fn int filter_plane_side(ExactPlane* plane, PlaneTriple vertex) @private {
    $if env::COMPILER_OPT_LEVEL == O3:
    return FILTER_UNCERTAIN;
    $else
    Interval[HOMOGENEOUS_COMPONENTS] point;
    if (!interval_point(vertex, &point)) return FILTER_UNCERTAIN;
    uint scale;
    foreach (&coefficient : plane.coefficients) scale = math::max(scale, integer_bits(coefficient.view()));
    Interval result;
    for (uint axis = 0; axis < HOMOGENEOUS_COMPONENTS; axis++) {
        result = add_interval(result, multiply_interval(integer_interval(plane.coefficients[axis].view(), scale), point[axis]));
    }
    return interval_sign(result);
    $endif
}

fn int? plane_side(ExactScratch* scratch, ExactPlane* plane, PlaneTriple vertex) @private {
    scratch.predicate_count++;
    int filtered = filter_plane_side(plane, vertex);
    if (filtered != FILTER_UNCERTAIN) {
        scratch.filtered_count++;
        return filtered;
    }
    Clock started = clock::now();
    defer scratch.exact_nanoseconds += (ulong)started.to_now();
    return exact_plane_side(scratch, plane, vertex);
}
