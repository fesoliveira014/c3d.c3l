module c3d::physics::fracture;

import std::math;

const uint FRAME_ERROR_BITS @private = 2 * (1953 + GRID_RESOLUTION_SHIFT + 1) + 2;
const uint FRAME_CONVERSION_TEMPORARIES @private = HOMOGENEOUS_COMPONENTS + FLOAT_ROUND_TEMPORARIES;
$assert FRAME_ERROR_BITS <= EXACT_LIMBS * INTEGER_LIMB_BITS;
$assert FRAME_CONVERSION_TEMPORARIES <= EXACT_TEMPORARIES;

fn int? construct_source_point(
    ExactScratch* scratch,
    HomogeneousPoint output,
    PlaneTriple vertex,
    QuantizationGrid* grid,
) @private {
    construct_point(scratch, output, vertex)!;
    if (!grid) return FLOAT_UNIT_EXPONENT;
    int unit = math::min(FLOAT_UNIT_EXPONENT, grid.step_exponent);
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* coordinate = scratch.take()!;
    WideInteger* first = scratch.take()!;
    WideInteger* second = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        set_integer(coordinate, grid.center[axis]);
        multiply_integer(first, coordinate.view(), output[SPACE_AXES].view())!;
        add_integer(second, first.view(), output[axis].view())!;
        shift_integer(first, second.view(), (uint)(grid.step_exponent - unit))!;
        integer_from_float(second, grid.anchor[axis]);
        shift_integer(coordinate, second.view(), (uint)(FLOAT_UNIT_EXPONENT - unit))!;
        multiply_integer(second, coordinate.view(), output[SPACE_AXES].view())!;
        add_integer(output[axis], first.view(), second.view())!;
    }
    return unit;
}

fn Vec3? rounded_source_position(
    ExactScratch* scratch,
    PlaneTriple vertex,
    QuantizationGrid* grid = null,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    HomogeneousPoint point;
    foreach (&coordinate : point) *coordinate = scratch.take()!;
    int unit = construct_source_point(
        scratch: scratch,
        output: point,
        vertex: vertex,
        grid: grid,
    )!;
    Vec3 position;
    for (uint axis = 0; axis < SPACE_AXES; axis++) position[axis] = round_float_ratio(
        scratch: scratch,
        numerator: point[axis].view(),
        denominator: point[SPACE_AXES].view(),
        unit_exponent: unit,
    )!;
    return position;
}

fn Vec3? rounded_local_position(ExactScratch* scratch, Vec3 position, Vec3 origin) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* first = scratch.take()!;
    WideInteger* second = scratch.take()!;
    WideInteger* difference = scratch.take()!;
    WideInteger* one = scratch.take()!;
    set_integer(one, 1);
    Vec3 local;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        integer_from_float(first, position[axis]);
        integer_from_float(second, origin[axis]);
        add_integer(difference, first.view(), negate_integer(second.view()))!;
        local[axis] = round_float_ratio(
            scratch: scratch,
            numerator: difference.view(),
            denominator: one.view(),
            unit_exponent: FLOAT_UNIT_EXPONENT,
        )!;
    }
    return local;
}

fn void? check_frame_point_error(
    ExactScratch* scratch,
    PlaneTriple vertex,
    QuantizationGrid* grid,
    Vec3 origin,
    Vec3 local,
    float resolution,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    HomogeneousPoint point;
    foreach (&coordinate : point) *coordinate = scratch.take()!;
    int unit = construct_source_point(
        scratch: scratch,
        output: point,
        vertex: vertex,
        grid: grid,
    )!;
    WideInteger* sum = scratch.take()!;
    WideInteger* first = scratch.take()!;
    WideInteger* second = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        integer_from_float(first, origin[axis]);
        integer_from_float(second, local[axis]);
        add_integer(first, first.view(), second.view())!;
        shift_integer(second, first.view(), (uint)(FLOAT_UNIT_EXPONENT - unit))!;
        multiply_integer(first, second.view(), point[SPACE_AXES].view())!;
        add_integer(second, first.view(), negate_integer(point[axis].view()))!;
        multiply_integer(first, second.view(), second.view())!;
        add_integer(sum, sum.view(), first.view())!;
    }
    integer_from_float(first, resolution);
    shift_integer(second, first.view(), (uint)(FLOAT_UNIT_EXPONENT - unit))!;
    multiply_integer(first, second.view(), point[SPACE_AXES].view())!;
    multiply_integer(second, first.view(), first.view())!;
    if (compare_magnitude(sum.view(), second.view()) > 0) return NUMERICAL_FAILURE~;
    return;
}

fn void? check_shared_point_error(
    ExactScratch* scratch,
    Vec3 first_origin,
    Vec3 first_local,
    Vec3 second_origin,
    Vec3 second_local,
    float resolution,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* sum = scratch.take()!;
    WideInteger* first = scratch.take()!;
    WideInteger* second = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        integer_from_float(first, first_origin[axis]);
        integer_from_float(second, first_local[axis]);
        add_integer(first, first.view(), second.view())!;
        integer_from_float(second, second_origin[axis]);
        add_integer(first, first.view(), negate_integer(second.view()))!;
        integer_from_float(second, second_local[axis]);
        add_integer(first, first.view(), negate_integer(second.view()))!;
        multiply_integer(second, first.view(), first.view())!;
        add_integer(sum, sum.view(), second.view())!;
    }
    integer_from_float(first, resolution);
    multiply_integer(second, first.view(), first.view())!;
    if (compare_magnitude(sum.view(), second.view()) > 0) return NUMERICAL_FAILURE~;
    return;
}
