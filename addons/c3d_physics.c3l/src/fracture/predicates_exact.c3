module c3d::physics::fracture;

import std::time;
import std::math;

const uint SPACE_AXES @private = 3;
const uint HOMOGENEOUS_COMPONENTS @private = 4;

struct ExactPlane @private {
    PlaneInteger[HOMOGENEOUS_COMPONENTS] coefficients;
}

fn int integer_sign(IntegerView value) @private {
    return value.limbs.len ? value.negative ? -1 : 1 : 0;
}

fn IntegerView negate_integer(IntegerView value) @private {
    if (value.limbs.len) value.negative = !value.negative;
    return value;
}

fn bool next_permutation(uint[] permutation) @private {
    sz pivot = permutation.len - 2;
    while (pivot >= 0 && permutation[pivot] >= permutation[pivot + 1]) pivot--;
    if (pivot < 0) return false;
    sz last = permutation.len - 1;
    while (permutation[last] <= permutation[pivot]) last--;
    uint saved = permutation[pivot];
    permutation[pivot] = permutation[last];
    permutation[last] = saved;
    sz first = pivot + 1;
    last = permutation.len - 1;
    while (first < last) {
        saved = permutation[first];
        permutation[first] = permutation[last];
        permutation[last] = saved;
        first++;
        last--;
    }
    return true;
}

fn void? determinant(
    ExactScratch* scratch,
    WideInteger* output,
    IntegerView[] matrix,
    uint order,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* first = scratch.take()!;
    WideInteger* second = scratch.take()!;
    WideInteger* sum = scratch.take()!;
    uint[HOMOGENEOUS_COMPONENTS] permutation = { 0, 1, 2, 3 };
    set_integer(output, 0);
    do {
        copy_integer(first, matrix[permutation[0]]);
        for (uint row = 1; row < order; row++) {
            multiply_integer(second, first.view(), matrix[row * order + permutation[row]])!;
            WideInteger* swap = first;
            first = second;
            second = swap;
        }
        bool reversed;
        for (uint row = 0; row < order; row++) {
            for (uint other = row + 1; other < order; other++) reversed ^= permutation[row] > permutation[other];
        }
        IntegerView term = first.view();
        if (reversed) term = negate_integer(term);
        add_integer(sum, output.view(), term)!;
        copy_integer(output, sum.view());
    } while (next_permutation(permutation[:order]));
    return;
}

fn bool? normalize_plane(
    ExactScratch* scratch,
    ExactPlane* output,
    WideInteger*[HOMOGENEOUS_COMPONENTS] coefficients,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    uint pivot;
    while (pivot < SPACE_AXES && !coefficients[pivot].used) pivot++;
    if (pivot == SPACE_AXES) return NUMERICAL_FAILURE~;
    bool reversed = coefficients[pivot].negative;
    WideInteger* divisor = scratch.take()!;
    set_integer(divisor, 0);
    foreach (coefficient : coefficients) {
        gcd_integer(
            scratch: scratch,
            output: divisor,
            first: divisor.view(),
            second: coefficient.view(),
        )!;
    }
    WideInteger* quotient = scratch.take()!;
    WideInteger* remainder = scratch.take()!;
    foreach (index, coefficient : coefficients) {
        divide_magnitude(
            scratch: scratch,
            quotient: quotient,
            remainder: remainder,
            numerator: coefficient.view(),
            denominator: divisor.view(),
        )!;
        if (quotient.used > PLANE_LIMBS) return NUMERICAL_FAILURE~;
        PlaneInteger* target = &output.coefficients[index];
        target.used = quotient.used;
        target.negative = quotient.used && (coefficient.negative != reversed);
        target.limbs[:target.used] = quotient.limbs[:quotient.used];
    }
    return reversed;
}

fn bool? plane_from_float(
    ExactScratch* scratch,
    ExactPlane* output,
    Vec3[SPACE_AXES] points,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS] coefficients;
    foreach (&coefficient : coefficients) *coefficient = scratch.take()!;
    WideInteger*[SPACE_AXES][SPACE_AXES] vertices;
    foreach (uint vertex, point : points) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            vertices[vertex][axis] = scratch.take()!;
            integer_from_float(vertices[vertex][axis], point[axis]);
        }
    }
    WideInteger*[SPACE_AXES][2] edges;
    for (uint edge = 0; edge < 2; edge++) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            edges[edge][axis] = scratch.take()!;
            add_integer(edges[edge][axis], vertices[edge + 1][axis].view(), negate_integer(vertices[0][axis].view()))!;
        }
    }
    WideInteger* first = scratch.take()!;
    WideInteger* second = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint next = (axis + 1) % SPACE_AXES;
        uint last = (axis + 2) % SPACE_AXES;
        multiply_integer(first, edges[0][next].view(), edges[1][last].view())!;
        multiply_integer(second, edges[0][last].view(), edges[1][next].view())!;
        add_integer(coefficients[axis], first.view(), negate_integer(second.view()))!;
    }
    set_integer(coefficients[SPACE_AXES], 0);
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        multiply_integer(first, coefficients[axis].view(), vertices[0][axis].view())!;
        add_integer(second, coefficients[SPACE_AXES].view(), negate_integer(first.view()))!;
        copy_integer(coefficients[SPACE_AXES], second.view());
    }
    scratch.count = saved + HOMOGENEOUS_COMPONENTS;
    return normalize_plane(scratch, output, coefficients);
}

fn bool? plane_from_integers(
    ExactScratch* scratch,
    ExactPlane* output,
    int128[HOMOGENEOUS_COMPONENTS] values,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS] coefficients;
    foreach (index, value : values) {
        coefficients[index] = scratch.take()!;
        set_integer(coefficients[index], value);
    }
    return normalize_plane(scratch, output, coefficients);
}

fn void? construct_point(
    ExactScratch* scratch,
    WideInteger*[HOMOGENEOUS_COMPONENTS] output,
    ExactPlane*[SPACE_AXES] planes,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    IntegerView[SPACE_AXES * SPACE_AXES] matrix;
    for (uint column = 0; column < HOMOGENEOUS_COMPONENTS; column++) {
        for (uint row = 0; row < SPACE_AXES; row++) {
            for (uint axis = 0; axis < SPACE_AXES; axis++) {
                matrix[row * SPACE_AXES + axis] = axis == column
                    ? negate_integer(planes[row].coefficients[SPACE_AXES].view())
                    : planes[row].coefficients[axis].view();
            }
        }
        determinant(
            scratch: scratch,
            output: output[column],
            matrix: matrix[..],
            order: SPACE_AXES,
        )!;
    }
    if (!output[SPACE_AXES].used) return NUMERICAL_FAILURE~;
    if (output[SPACE_AXES].negative) {
        foreach (value : output) if (value.used) value.negative = !value.negative;
    }
    return;
}

fn int? exact_float_orientation(ExactScratch* scratch, Vec3[HOMOGENEOUS_COMPONENTS] points) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* one = scratch.take()!;
    WideInteger* result = scratch.take()!;
    set_integer(one, 1);
    IntegerView[HOMOGENEOUS_COMPONENTS * HOMOGENEOUS_COMPONENTS] matrix;
    foreach (uint index, point : points) {
        matrix[index * HOMOGENEOUS_COMPONENTS] = one.view();
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            WideInteger* value = scratch.take()!;
            integer_from_float(value, point[axis]);
            matrix[index * HOMOGENEOUS_COMPONENTS + axis + 1] = value.view();
        }
    }
    determinant(
        scratch: scratch,
        output: result,
        matrix: matrix[..],
        order: HOMOGENEOUS_COMPONENTS,
    )!;
    return integer_sign(result.view());
}

fn int? exact_vertex_orientation(
    ExactScratch* scratch,
    ExactPlane*[SPACE_AXES][HOMOGENEOUS_COMPONENTS] planes,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS][HOMOGENEOUS_COMPONENTS] points;
    foreach (&point : points) foreach (&coordinate : point) *coordinate = scratch.take()!;
    WideInteger* result = scratch.take()!;
    IntegerView[HOMOGENEOUS_COMPONENTS * HOMOGENEOUS_COMPONENTS] matrix;
    foreach (uint index, point : points) {
        construct_point(scratch, point, planes[index])!;
        matrix[index * HOMOGENEOUS_COMPONENTS] = point[SPACE_AXES].view();
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            matrix[index * HOMOGENEOUS_COMPONENTS + axis + 1] = point[axis].view();
        }
    }
    determinant(
        scratch: scratch,
        output: result,
        matrix: matrix[..],
        order: HOMOGENEOUS_COMPONENTS,
    )!;
    return integer_sign(result.view());
}

fn bool? exact_same_vertex(
    ExactScratch* scratch,
    ExactPlane*[SPACE_AXES] first,
    ExactPlane*[SPACE_AXES] second,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS] left;
    WideInteger*[HOMOGENEOUS_COMPONENTS] right;
    foreach (&value : left) *value = scratch.take()!;
    foreach (&value : right) *value = scratch.take()!;
    construct_point(scratch, left, first)!;
    construct_point(scratch, right, second)!;
    WideInteger* first_product = scratch.take()!;
    WideInteger* second_product = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        multiply_integer(first_product, left[axis].view(), right[SPACE_AXES].view())!;
        multiply_integer(second_product, right[axis].view(), left[SPACE_AXES].view())!;
        if (first_product.negative != second_product.negative
            || compare_magnitude(first_product.view(), second_product.view()) != 0) return false;
    }
    return true;
}
