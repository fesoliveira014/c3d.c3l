module c3d::physics::fracture;

import std::math;
import std::time;

// CLI O4/O5 expose the maximum optimizer level as O3.
$assert env::COMPILER_OPT_LEVEL != O3 :
  "Outward-rounded fracture filters require strict floating point; build at O0-O3 with fp-math: strict.";

const int FILTER_UNCERTAIN @private = 2;
const ulong DOUBLE_SIGN_MASK @private = 0x8000000000000000;

struct Interval @private {
    double low;
    double high;
}

fn double round_down(double value) @private {
    if (math::is_nan(value) || value == -double::inf) return -double::inf;
    if (value == 0) return bitcast(DOUBLE_SIGN_MASK | 1, double);
    ulong bits = bitcast(value, ulong);
    if (value > 0) {
        bits--;
    } else {
        bits++;
    }
    return bitcast(bits, double);
}

fn double round_up(double value) @private {
    if (math::is_nan(value) || value == double::inf) return double::inf;
    if (value == 0) return bitcast((ulong)1, double);
    ulong bits = bitcast(value, ulong);
    if (value > 0) {
        bits++;
    } else {
        bits--;
    }
    return bitcast(bits, double);
}

fn Interval add_interval(Interval first, Interval second) @private {
    if (first.low == 0 && first.high == 0) return second;
    if (second.low == 0 && second.high == 0) return first;
    return { .low = round_down(first.low + second.low), .high = round_up(first.high + second.high) };
}

fn Interval negate_interval(Interval value) @private {
    return { .low = -value.high, .high = -value.low };
}

fn Interval multiply_interval(Interval first, Interval second) @private {
    if ((first.low == 0 && first.high == 0) || (second.low == 0 && second.high == 0)) return {};
    double[4] products = {
        first.low * second.low, first.low * second.high,
        first.high * second.low, first.high * second.high,
    };
    double low = products[0];
    double high = products[0];
    foreach (product : products) {
        if (math::is_nan(product)) return { .low = -double::inf, .high = double::inf };
        low = math::min(low, product);
        high = math::max(high, product);
    }
    return { .low = round_down(low), .high = round_up(high) };
}

fn int interval_sign(Interval value) @private {
    if (value.low > 0) return 1;
    if (value.high < 0) return -1;
    if (value.low == 0 && value.high == 0) return 0;
    return FILTER_UNCERTAIN;
}

fn Interval integer_interval(IntegerView value, uint scale) @private {
    Interval result;
    foreach (uint index, limb : value.limbs) {
        if (!limb) continue;
        double rounded = (double)limb;
        int exponent = (int)(index * INTEGER_LIMB_BITS) - (int)scale;
        Interval term = {
            .low = round_down(math::scalbn(round_down(rounded), exponent)),
            .high = round_up(math::scalbn(round_up(rounded), exponent)),
        };
        result = add_interval(result, term);
    }
    return value.negative ? negate_interval(result) : result;
}

fn Interval interval_determinant(Interval[] matrix, uint order) @private {
    uint[HOMOGENEOUS_COMPONENTS] permutation = { 0, 1, 2, 3 };
    Interval result;
    do {
        Interval term = matrix[permutation[0]];
        for (uint row = 1; row < order; row++) term = multiply_interval(term, matrix[row * order + permutation[row]]);
        bool reversed;
        for (uint row = 0; row < order; row++) {
            for (uint other = row + 1; other < order; other++) reversed ^= permutation[row] > permutation[other];
        }
        if (reversed) term = negate_interval(term);
        result = add_interval(result, term);
    } while (next_permutation(permutation[:order]));
    return result;
}

fn int filter_float_orientation(Vec3[HOMOGENEOUS_COMPONENTS] points) @private {
    Interval[SPACE_AXES * SPACE_AXES] matrix;
    for (uint row = 0; row < SPACE_AXES; row++) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            double value = points[row + 1][axis];
            double origin = points[0][axis];
            matrix[row * SPACE_AXES + axis] = add_interval(
                { .low = value, .high = value },
                { .low = -origin, .high = -origin },
            );
        }
    }
    return interval_sign(interval_determinant(matrix[..], SPACE_AXES));
}

fn bool interval_point(ExactPlane*[SPACE_AXES] planes, Interval[HOMOGENEOUS_COMPONENTS]* output) @private {
    Interval[HOMOGENEOUS_COMPONENTS][SPACE_AXES] coefficients;
    foreach (uint row, plane : planes) {
        uint scale;
        foreach (&coefficient : plane.coefficients) scale = math::max(scale, integer_bits(coefficient.view()));
        foreach (uint column, &coefficient : plane.coefficients) {
            coefficients[row][column] = integer_interval(coefficient.view(), scale);
        }
    }
    Interval[SPACE_AXES * SPACE_AXES] matrix;
    for (uint column = 0; column < HOMOGENEOUS_COMPONENTS; column++) {
        for (uint row = 0; row < SPACE_AXES; row++) {
            for (uint axis = 0; axis < SPACE_AXES; axis++) {
                matrix[row * SPACE_AXES + axis] = axis == column
                    ? negate_interval(coefficients[row][SPACE_AXES]) : coefficients[row][axis];
            }
        }
        (*output)[column] = interval_determinant(matrix[..], SPACE_AXES);
    }
    double largest;
    foreach (value : *output) largest = math::max(largest, math::max(math::abs(value.low), math::abs(value.high)));
    if (!math::is_finite(largest) || largest == 0) return false;
    int exponent;
    (void)math::frexp(largest, &exponent);
    foreach (&value : *output) {
        if (value.low == 0 && value.high == 0) continue;
        value.low = round_down(math::scalbn(value.low, -exponent));
        value.high = round_up(math::scalbn(value.high, -exponent));
    }
    int denominator = interval_sign((*output)[SPACE_AXES]);
    if (denominator == FILTER_UNCERTAIN || denominator == 0) return false;
    if (denominator < 0) foreach (&value : *output) *value = negate_interval(*value);
    return true;
}

fn int filter_vertex_orientation(ExactPlane*[SPACE_AXES][HOMOGENEOUS_COMPONENTS] planes) @private {
    Interval[HOMOGENEOUS_COMPONENTS * HOMOGENEOUS_COMPONENTS] matrix;
    foreach (uint index, vertex : planes) {
        Interval[HOMOGENEOUS_COMPONENTS] point;
        if (!interval_point(vertex, &point)) return FILTER_UNCERTAIN;
        matrix[index * HOMOGENEOUS_COMPONENTS] = point[SPACE_AXES];
        for (uint axis = 0; axis < SPACE_AXES; axis++) matrix[index * HOMOGENEOUS_COMPONENTS + axis + 1] = point[axis];
    }
    return interval_sign(interval_determinant(matrix[..], HOMOGENEOUS_COMPONENTS));
}

fn int filter_same_vertex(ExactPlane*[SPACE_AXES] first, ExactPlane*[SPACE_AXES] second) @private {
    Interval[HOMOGENEOUS_COMPONENTS] left;
    Interval[HOMOGENEOUS_COMPONENTS] right;
    if (!interval_point(first, &left) || !interval_point(second, &right)) return FILTER_UNCERTAIN;
    bool uncertain;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        Interval difference = add_interval(
            multiply_interval(left[axis], right[SPACE_AXES]),
            negate_interval(multiply_interval(right[axis], left[SPACE_AXES])),
        );
        int sign = interval_sign(difference);
        if (sign != 0 && sign != FILTER_UNCERTAIN) return 0;
        uncertain |= sign == FILTER_UNCERTAIN;
    }
    return uncertain ? FILTER_UNCERTAIN : 1;
}

fn int? float_orientation(ExactScratch* scratch, Vec3[HOMOGENEOUS_COMPONENTS] points) @private {
    scratch.predicate_count++;
    int filtered = filter_float_orientation(points);
    if (filtered != FILTER_UNCERTAIN) {
        scratch.filtered_count++;
        return filtered;
    }
    Clock started = clock::now();
    defer scratch.exact_nanoseconds += (ulong)started.to_now();
    return exact_float_orientation(scratch, points);
}

fn int? vertex_orientation(
    ExactScratch* scratch,
    ExactPlane*[SPACE_AXES][HOMOGENEOUS_COMPONENTS] planes,
) @private {
    scratch.predicate_count++;
    int filtered = filter_vertex_orientation(planes);
    if (filtered != FILTER_UNCERTAIN) {
        scratch.filtered_count++;
        return filtered;
    }
    Clock started = clock::now();
    defer scratch.exact_nanoseconds += (ulong)started.to_now();
    return exact_vertex_orientation(scratch, planes);
}

fn bool? same_vertex(
    ExactScratch* scratch,
    ExactPlane*[SPACE_AXES] first,
    ExactPlane*[SPACE_AXES] second,
) @private {
    scratch.predicate_count++;
    int filtered = filter_same_vertex(first, second);
    if (filtered != FILTER_UNCERTAIN) {
        scratch.filtered_count++;
        return filtered == 1;
    }
    Clock started = clock::now();
    defer scratch.exact_nanoseconds += (ulong)started.to_now();
    return exact_same_vertex(scratch, first, second);
}
