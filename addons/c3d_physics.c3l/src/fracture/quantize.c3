module c3d::physics::fracture;

import std::math;
import std::time;

alias GridPoint @private = long[SPACE_AXES];

const ulong GRID_COORDINATE_LIMIT @private = (ulong)1 << 30;
const int FLOAT_UNIT_EXPONENT @private = -149;
const int FLOAT_EXPONENT_BIAS @private = 127;
const int GRID_RESOLUTION_SHIFT @private = 4;

struct QuantizationGrid @private {
    Vec3 anchor;
    GridPoint center;
    int step_exponent;
}

fn int grid_step_exponent(float resolution) @private {
    uint bits = bitcast(resolution, uint);
    uint exponent = (bits >> FLOAT_FRACTION_BITS) & FLOAT_EXPONENT_MASK;
    if (exponent) return (int)exponent - FLOAT_EXPONENT_BIAS - GRID_RESOLUTION_SHIFT;
    uint fraction = bits & FLOAT_FRACTION_MASK;
    int result = FLOAT_UNIT_EXPONENT - GRID_RESOLUTION_SHIFT;
    while (fraction > 1) {
        fraction >>= 1;
        result++;
    }
    return result;
}

fn long? quantize_axis(
    ExactScratch* scratch,
    float position,
    float anchor,
    int step_exponent,
    long center,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* value = scratch.take()!;
    WideInteger* origin = scratch.take()!;
    WideInteger* difference = scratch.take()!;
    WideInteger* one = scratch.take()!;
    WideInteger* denominator = scratch.take()!;
    WideInteger* quotient = scratch.take()!;
    WideInteger* remainder = scratch.take()!;
    WideInteger* twice_remainder = scratch.take()!;
    integer_from_float(value, position);
    integer_from_float(origin, anchor);
    add_integer(difference, value.view(), negate_integer(origin.view()))!;
    set_integer(one, 1);
    if (step_exponent >= FLOAT_UNIT_EXPONENT) {
        shift_integer(denominator, one.view(), (uint)(step_exponent - FLOAT_UNIT_EXPONENT))!;
    } else {
        shift_integer(value, difference.view(), (uint)(FLOAT_UNIT_EXPONENT - step_exponent))!;
        copy_integer(difference, value.view());
        set_integer(denominator, 1);
    }
    set_integer(value, center);
    multiply_integer(origin, value.view(), denominator.view())!;
    add_integer(difference, difference.view(), negate_integer(origin.view()))!;
    divide_magnitude(
        scratch: scratch,
        quotient: quotient,
        remainder: remainder,
        numerator: difference.view(),
        denominator: denominator.view(),
    )!;
    shift_integer(twice_remainder, remainder.view(), 1)!;
    int comparison = compare_magnitude(twice_remainder.view(), denominator.view());
    bool odd = quotient.used && (quotient.limbs[0] & 1) != 0;
    if (comparison > 0 || (comparison == 0 && odd)) {
        add_integer(value, quotient.view(), one.view())!;
        copy_integer(quotient, value.view());
    }
    if (quotient.used > 1 || (quotient.used && quotient.limbs[0] >= GRID_COORDINATE_LIMIT)) {
        return NUMERICAL_FAILURE~;
    }
    long result = quotient.used ? (long)quotient.limbs[0] : 0;
    return difference.negative ? -result : result;
}

fn GridPoint? quantize_point(ExactScratch* scratch, QuantizationGrid grid, Vec3 point) @private {
    GridPoint result;
    for (uint axis = 0; axis < SPACE_AXES; axis++) result[axis] = quantize_axis(
        scratch: scratch,
        position: point[axis],
        anchor: grid.anchor[axis],
        step_exponent: grid.step_exponent,
        center: grid.center[axis],
    )!;
    return result;
}

fn QuantizationGrid? create_quantization_grid(
    ExactScratch* scratch,
    Vec3 lower,
    Vec3 upper,
    float resolution,
) @private {
    QuantizationGrid grid = { .anchor = lower, .step_exponent = grid_step_exponent(resolution) };
    for (uint axis = 0; axis < SPACE_AXES; axis++) grid.center[axis] = quantize_axis(
        scratch: scratch,
        position: upper[axis],
        anchor: lower[axis],
        step_exponent: grid.step_exponent + 1,
        center: 0,
    )!;
    quantize_point(scratch, grid, lower)!;
    quantize_point(scratch, grid, upper)!;
    return grid;
}

fn int exact_grid_orientation(GridPoint[HOMOGENEOUS_COMPONENTS] points) @private {
    int128[SPACE_AXES][SPACE_AXES] edges;
    for (uint row = 0; row < SPACE_AXES; row++) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            edges[row][axis] = (int128)points[row + 1][axis] - points[0][axis];
        }
    }
    int128 value = edges[0][0] * (edges[1][1] * edges[2][2] - edges[1][2] * edges[2][1])
        - edges[0][1] * (edges[1][0] * edges[2][2] - edges[1][2] * edges[2][0])
        + edges[0][2] * (edges[1][0] * edges[2][1] - edges[1][1] * edges[2][0]);
    return value > 0 ? 1 : value < 0 ? -1 : 0;
}

fn bool? plane_from_grid(ExactScratch* scratch, ExactPlane* output, GridPoint[SPACE_AXES] points) @private {
    int128[SPACE_AXES][2] edges;
    for (uint row = 0; row < 2; row++) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            edges[row][axis] = (int128)points[row + 1][axis] - points[0][axis];
        }
    }
    int128[HOMOGENEOUS_COMPONENTS] values;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint next = (axis + 1) % SPACE_AXES;
        uint last = (axis + 2) % SPACE_AXES;
        values[axis] = edges[0][next] * edges[1][last] - edges[0][last] * edges[1][next];
        values[SPACE_AXES] -= values[axis] * points[0][axis];
    }
    return plane_from_integers(scratch, output, values);
}

fn bool? bisector_plane(
    ExactScratch* scratch,
    ExactPlane* output,
    GridPoint first,
    GridPoint second,
) @private {
    int128[HOMOGENEOUS_COMPONENTS] values;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        values[axis] = 2 * ((int128)second[axis] - first[axis]);
        values[SPACE_AXES] += (int128)first[axis] * first[axis] - (int128)second[axis] * second[axis];
    }
    return plane_from_integers(scratch, output, values);
}

fn int grid_orientation(ExactScratch* scratch, GridPoint[HOMOGENEOUS_COMPONENTS] points) @private {
    scratch.predicate_count++;
    Interval[SPACE_AXES * SPACE_AXES] matrix;
    for (uint row = 0; row < SPACE_AXES; row++) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            double value = (double)points[row + 1][axis];
            double origin = (double)points[0][axis];
            matrix[row * SPACE_AXES + axis] = add_interval(
                { .low = value, .high = value },
                { .low = -origin, .high = -origin },
            );
        }
    }
    int filtered = interval_sign(interval_determinant(matrix[..], SPACE_AXES));
    if (filtered != FILTER_UNCERTAIN) {
        scratch.filtered_count++;
        return filtered;
    }
    Clock started = clock::now();
    defer scratch.exact_nanoseconds += (ulong)started.to_now();
    return exact_grid_orientation(points);
}
