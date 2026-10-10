module c3d::anim;

import c3d;
import c3d::maths;
import std::math;

const uint EXACT_SCALE_LIMBS @local = 256; // Fixed 8,192-bit admission scratch covers every binary32 Hermite input.
const uint EXACT_SCALE_LIMB_BITS @local = 32;
const uint EXACT_SCALE_COEFFICIENT_BOUND_BITS @local = 630;
const uint EXACT_SCALE_STURM_BOUND_BITS @local = 7 * EXACT_SCALE_COEFFICIENT_BOUND_BITS + 32;
const uint EXACT_SCALE_FLOAT_FRACTION_BITS @local = 23;
const uint EXACT_SCALE_FLOAT_UNIT_BITS @local = 149;
const uint EXACT_SCALE_FLOAT_EXPONENT_MASK @local = 0x7f800000;
const uint EXACT_SCALE_FLOAT_FRACTION_MASK @local = 0x7fffff;
const uint EXACT_SCALE_FLOAT_HIDDEN_BIT @local = 0x800000;
const uint EXACT_SCALE_FLOAT_SIGN_BIT @local = 0x80000000;
const ulong EXACT_SCALE_LIMB_MASK @local = 0xffffffffUL;
const ulong EXACT_SCALE_LIMB_BASE @local = 0x100000000UL;

$assert(EXACT_SCALE_LIMBS * EXACT_SCALE_LIMB_BITS > EXACT_SCALE_STURM_BOUND_BITS + 8);

struct ScaleInteger @local {
    uint[EXACT_SCALE_LIMBS] limbs;
    uint used;
    bool negative;
}

struct ScalePolynomial @local {
    ScaleInteger[4] coefficients;
    uint degree;
}

struct ScaleSturmSequence @local {
    ScalePolynomial[4] terms;
    uint count;
}

fn void? validate_multiplicative_scale(AnimationClip* clip) @private {
    foreach (&track : clip.tracks) {
        if (track.path != TargetPath.SCALE) continue;

        validate_multiplicative_scale_track(track)!;

        Vec3 reference = sample_multiplicative_scale_reference(track);
        if (!positive_scale_vector(reference)) return c3d::INVALID_ARGUMENT~;
    }
}

fn Vec3 sample_multiplicative_scale_reference(Track* track) @private {
    uint cursor;
    return sample_multiplicative_scale(track, 0, &cursor);
}

fn Vec3 sample_multiplicative_scale(Track* track, float time, uint* cursor) @private {
    uint last = (uint)track.times.len - 1;
    if (time <= track.times[0]) {
        *cursor = 0;
        return scale_key(track, 0, CUBIC_SLOT_VALUE);
    }

    if (time >= track.times[last]) {
        *cursor = last;
        return scale_key(track, last, CUBIC_SLOT_VALUE);
    }

    if (*cursor >= last || time < track.times[*cursor]) {
        uint low;
        uint high = last;
        while (high - low > 1) {
            uint middle = (low + high) / 2;
            if (track.times[middle] <= time) {
                low = middle;
            } else {
                high = middle;
            }
        }
        *cursor = low;
    } else {
        while (track.times[*cursor + 1] <= time) (*cursor)++;
    }

    uint key = *cursor;
    Vec3 start = scale_key(track, key, CUBIC_SLOT_VALUE);
    Vec3 end = scale_key(track, key + 1, CUBIC_SLOT_VALUE);
    double duration = (double)track.times[key + 1] - (double)track.times[key];
    double fraction = ((double)time - (double)track.times[key]) / duration;
    Vec3 result;

    switch (track.interpolation) {
        case STEP:
            return start;
        case LINEAR:
            for (uint component = 0; component < 3; component++) {
                result[component] = (float)((1 - fraction) * (double)start[component]
                  + fraction * (double)end[component]);
            }
        case CUBIC_SPLINE:
            Vec3 start_tangent = scale_key(track, key, CUBIC_SLOT_OUT_TANGENT);
            Vec3 end_tangent = scale_key(track, key + 1, CUBIC_SLOT_IN_TANGENT);
            double complement = 1 - fraction;
            double h00 = complement * complement * (1 + 2 * fraction);
            double h10 = fraction * complement * complement;
            double h01 = fraction * fraction * (3 - 2 * fraction);
            double h11 = -fraction * fraction * complement;

            for (uint component = 0; component < 3; component++) {
                result[component] = (float)(h00 * (double)start[component]
                  + h10 * duration * (double)start_tangent[component]
                  + h01 * (double)end[component]
                  + h11 * duration * (double)end_tangent[component]);
            }
    }

    return result;
}

fn void? validate_multiplicative_scale_track(Track* track) @local {
    usz slots = track.interpolation == Interpolation.CUBIC_SPLINE ? CUBIC_SLOTS_PER_KEY : 1;
    if (track.times.len == 0 || track.times.len > uint::max
        || track.times.len > usz::max / (slots * 3)
        || track.values.len != track.times.len * slots * 3) return c3d::INVALID_ARGUMENT~;

    foreach (key, time : track.times) {
        if (!scale_float_finite(time)
            || (key && time <= track.times[key - 1])) return c3d::INVALID_ARGUMENT~;

        if (!positive_scale_vector(scale_key(track, (uint)key, CUBIC_SLOT_VALUE))) {
            return c3d::INVALID_ARGUMENT~;
        }
    }

    switch (track.interpolation) {
        case STEP:
        case LINEAR:
            return;
        case CUBIC_SPLINE:
            foreach (value : track.values) {
                if (!scale_float_finite(value)) return c3d::INVALID_ARGUMENT~;
            }

            uint key_count = (uint)track.times.len;

            for (uint key = 0; key + 1 < key_count; key++) {
                Vec3 start = scale_key(track, key, CUBIC_SLOT_VALUE);
                Vec3 end = scale_key(track, key + 1, CUBIC_SLOT_VALUE);
                Vec3 start_tangent = scale_key(track, key, CUBIC_SLOT_OUT_TANGENT);
                Vec3 end_tangent = scale_key(track, key + 1, CUBIC_SLOT_IN_TANGENT);
                ScaleInteger duration = scale_integer_subtract(
                    scale_float_integer(track.times[key + 1]), scale_float_integer(track.times[key]));

                for (uint component = 0; component < 3; component++) {
                    ScalePolynomial polynomial = exact_scale_hermite(
                        start: start[component],
                        end: end[component],
                        start_tangent: start_tangent[component],
                        end_tangent: end_tangent[component],
                        duration: duration,
                    );
                    if (!exact_scale_strict_positive(polynomial)) return c3d::INVALID_ARGUMENT~;
                }
            }
    }
}

fn Vec3 scale_key(Track* track, uint key, uint slot) @local {
    usz offset = track.interpolation == Interpolation.CUBIC_SPLINE
      ? ((usz)key * CUBIC_SLOTS_PER_KEY + slot) * 3 : (usz)key * 3;
    return { track.values[offset], track.values[offset + 1], track.values[offset + 2] };
}

fn bool positive_scale_vector(Vec3 scale) @local {
    return scale_float_finite(scale.x) && scale_float_finite(scale.y) && scale_float_finite(scale.z)
      && scale.x > 0 && scale.y > 0 && scale.z > 0;
}

fn ScaleInteger scale_integer_normalize(ScaleInteger value) @local {
    while (value.used && value.limbs[value.used - 1] == 0) value.used--;
    if (value.used == 0) value.negative = false;

    return value;
}

fn ScaleInteger scale_integer(ulong value) @local {
    ScaleInteger result;
    result.limbs[0] = (uint)(value & EXACT_SCALE_LIMB_MASK);
    result.limbs[1] = (uint)(value >> EXACT_SCALE_LIMB_BITS);
    result.used = 2;

    return scale_integer_normalize(result);
}

fn int scale_integer_sign(ScaleInteger value) @local => value.used == 0 ? 0 : (value.negative ? -1 : 1);

fn ScaleInteger scale_integer_negate(ScaleInteger value) @local {
    if (value.used) value.negative = !value.negative;

    return value;
}

fn int scale_integer_compare_magnitude(ScaleInteger left, ScaleInteger right) @local {
    if (left.used != right.used) return left.used < right.used ? -1 : 1;

    for (int index = (int)left.used - 1; index >= 0; index--) {
        if (left.limbs[index] != right.limbs[index]) return left.limbs[index] < right.limbs[index] ? -1 : 1;
    }

    return 0;
}

fn ScaleInteger scale_integer_add_magnitude(ScaleInteger left, ScaleInteger right) @local {
    ScaleInteger result;
    result.used = left.used > right.used ? left.used : right.used;
    ulong carry;

    for (uint index = 0; index < result.used; index++) {
        ulong sum = (ulong)left.limbs[index] + right.limbs[index] + carry;
        result.limbs[index] = (uint)(sum & EXACT_SCALE_LIMB_MASK);
        carry = sum >> EXACT_SCALE_LIMB_BITS;
    }

    if (carry) result.limbs[result.used++] = (uint)carry;

    return result;
}

fn ScaleInteger scale_integer_subtract_magnitude(ScaleInteger left, ScaleInteger right) @local {
    ScaleInteger result;
    result.used = left.used;
    ulong borrow;

    for (uint index = 0; index < left.used; index++) {
        ulong minuend = left.limbs[index];
        ulong subtrahend = (ulong)right.limbs[index] + borrow;
        if (minuend < subtrahend) {
            result.limbs[index] = (uint)(minuend + EXACT_SCALE_LIMB_BASE - subtrahend);
            borrow = 1;
        } else {
            result.limbs[index] = (uint)(minuend - subtrahend);
            borrow = 0;
        }
    }

    return scale_integer_normalize(result);
}

fn ScaleInteger scale_integer_add(ScaleInteger left, ScaleInteger right) @local {
    ScaleInteger result;

    if (left.negative == right.negative) {
        result = scale_integer_add_magnitude(left, right);
        result.negative = left.negative && result.used != 0;
        return result;
    }

    int comparison = scale_integer_compare_magnitude(left, right);
    if (comparison >= 0) {
        result = scale_integer_subtract_magnitude(left, right);
        result.negative = left.negative && result.used != 0;
    } else {
        result = scale_integer_subtract_magnitude(right, left);
        result.negative = right.negative && result.used != 0;
    }

    return result;
}

fn ScaleInteger scale_integer_subtract(ScaleInteger left, ScaleInteger right) @local {
    return scale_integer_add(left, scale_integer_negate(right));
}

fn ScaleInteger scale_integer_multiply(ScaleInteger left, ScaleInteger right) @local {
    ScaleInteger result;
    if (left.used == 0 || right.used == 0) return result;

    result.used = left.used + right.used;
    result.negative = left.negative != right.negative;

    for (uint left_index = 0; left_index < left.used; left_index++) {
        ulong carry;
        for (uint right_index = 0; right_index < right.used; right_index++) {
            uint index = left_index + right_index;
            ulong product = (ulong)left.limbs[left_index] * right.limbs[right_index]
              + result.limbs[index] + carry;
            result.limbs[index] = (uint)(product & EXACT_SCALE_LIMB_MASK);
            carry = product >> EXACT_SCALE_LIMB_BITS;
        }

        result.limbs[left_index + right.used] = (uint)carry;
    }

    return scale_integer_normalize(result);
}

fn ScaleInteger scale_integer_shift_left(ScaleInteger value, uint bits) @local {
    if (value.used == 0 || bits == 0) return value;

    uint words = bits / EXACT_SCALE_LIMB_BITS;
    uint remainder = bits % EXACT_SCALE_LIMB_BITS;
    ScaleInteger result;
    result.negative = value.negative;
    result.used = value.used + words + (remainder != 0 ? 1 : 0);

    for (uint index = 0; index < value.used; index++) {
        ulong shifted = (ulong)value.limbs[index] << remainder;
        result.limbs[index + words] |= (uint)(shifted & EXACT_SCALE_LIMB_MASK);
        if (remainder) result.limbs[index + words + 1] |= (uint)(shifted >> EXACT_SCALE_LIMB_BITS);
    }

    return scale_integer_normalize(result);
}

fn ScaleInteger scale_integer_shift_right(ScaleInteger value, uint bits) @local {
    if (value.used == 0 || bits == 0) return value;

    uint words = bits / EXACT_SCALE_LIMB_BITS;
    uint remainder = bits % EXACT_SCALE_LIMB_BITS;
    ScaleInteger result;
    result.negative = value.negative;
    result.used = value.used - words;

    for (uint index = 0; index < result.used; index++) {
        ulong shifted = (ulong)value.limbs[index + words] >> remainder;
        if (remainder && index + words + 1 < value.used) {
            shifted |= (ulong)value.limbs[index + words + 1] << (EXACT_SCALE_LIMB_BITS - remainder);
        }
        result.limbs[index] = (uint)(shifted & EXACT_SCALE_LIMB_MASK);
    }

    return scale_integer_normalize(result);
}

fn uint scale_integer_trailing_bits(ScaleInteger value) @local {
    uint bits;
    uint index;

    while (value.limbs[index] == 0) {
        bits += EXACT_SCALE_LIMB_BITS;
        index++;
    }

    uint word = value.limbs[index];
    while ((word & 1) == 0) {
        bits++;
        word >>= 1;
    }

    return bits;
}

fn bool scale_float_finite(float value) @local {
    return (bitcast(value, uint) & EXACT_SCALE_FLOAT_EXPONENT_MASK) != EXACT_SCALE_FLOAT_EXPONENT_MASK;
}

fn ScaleInteger scale_float_integer(float value) @local {
    uint bits = bitcast(value, uint);
    uint exponent = (bits & EXACT_SCALE_FLOAT_EXPONENT_MASK) >> EXACT_SCALE_FLOAT_FRACTION_BITS;
    uint significand = bits & EXACT_SCALE_FLOAT_FRACTION_MASK;
    if (exponent) significand |= EXACT_SCALE_FLOAT_HIDDEN_BIT;

    ScaleInteger result = scale_integer(significand);
    if (exponent) result = scale_integer_shift_left(result, exponent - 1);
    result.negative = result.used != 0 && (bits & EXACT_SCALE_FLOAT_SIGN_BIT) != 0;

    return result;
}

fn ScalePolynomial scale_polynomial_normalize_degree(ScalePolynomial value) @local {
    value.degree = 3;
    while (value.degree && value.coefficients[value.degree].used == 0) value.degree--;

    return value;
}

fn bool scale_polynomial_zero(ScalePolynomial value) @local => value.degree == 0 && value.coefficients[0].used == 0;

fn ScalePolynomial scale_polynomial_reduce_binary_content(ScalePolynomial value) @local {
    if (scale_polynomial_zero(value)) return value;

    uint common_bits = EXACT_SCALE_LIMBS * EXACT_SCALE_LIMB_BITS;

    for (uint index = 0; index <= value.degree; index++) {
        if (value.coefficients[index].used == 0) continue;
        uint bits = scale_integer_trailing_bits(value.coefficients[index]);
        if (bits < common_bits) common_bits = bits;
    }

    for (uint index = 0; index <= value.degree; index++) {
        value.coefficients[index] = scale_integer_shift_right(value.coefficients[index], common_bits);
    }

    return value;
}

fn ScalePolynomial exact_scale_hermite(
    float start,
    float end,
    float start_tangent,
    float end_tangent,
    ScaleInteger duration,
) @local {
    ScaleInteger start_value = scale_integer_shift_left(scale_float_integer(start), EXACT_SCALE_FLOAT_UNIT_BITS);
    ScaleInteger end_value = scale_integer_shift_left(scale_float_integer(end), EXACT_SCALE_FLOAT_UNIT_BITS);
    ScaleInteger start_velocity = scale_integer_multiply(scale_float_integer(start_tangent), duration);
    ScaleInteger end_velocity = scale_integer_multiply(scale_float_integer(end_tangent), duration);
    ScaleInteger difference = scale_integer_subtract(end_value, start_value);

    ScalePolynomial result;
    result.coefficients[0] = start_value;
    result.coefficients[1] = start_velocity;
    ScaleInteger three_differences = scale_integer_multiply(difference, scale_integer(3));
    ScaleInteger two_start_velocities = scale_integer_multiply(start_velocity, scale_integer(2));
    ScaleInteger quadratic = scale_integer_subtract(three_differences, two_start_velocities);
    result.coefficients[2] = scale_integer_subtract(quadratic, end_velocity);
    ScaleInteger negative_two_differences = scale_integer_negate(scale_integer_multiply(difference, scale_integer(2)));
    ScaleInteger cubic = scale_integer_add(negative_two_differences, start_velocity);
    result.coefficients[3] = scale_integer_add(cubic, end_velocity);

    return scale_polynomial_normalize_degree(result);
}

fn ScalePolynomial scale_polynomial_derivative(ScalePolynomial value) @local {
    ScalePolynomial result;

    for (uint index = 1; index <= value.degree; index++) {
        result.coefficients[index - 1] = scale_integer_multiply(value.coefficients[index], scale_integer(index));
    }

    return scale_polynomial_normalize_degree(result);
}

fn ScalePolynomial scale_polynomial_pseudo_remainder(ScalePolynomial dividend, ScalePolynomial divisor) @local {
    ScalePolynomial remainder = dividend;
    ScaleInteger leading = divisor.coefficients[divisor.degree];
    bool negative_leading = leading.negative;
    leading.negative = false;

    while (!scale_polynomial_zero(remainder) && remainder.degree >= divisor.degree) {
        uint offset = remainder.degree - divisor.degree;
        ScaleInteger highest = remainder.coefficients[remainder.degree];
        if (negative_leading) highest = scale_integer_negate(highest);

        for (uint index = 0; index <= remainder.degree; index++) {
            remainder.coefficients[index] = scale_integer_multiply(remainder.coefficients[index], leading);
        }

        for (uint index = 0; index <= divisor.degree; index++) {
            remainder.coefficients[index + offset] = scale_integer_subtract(remainder.coefficients[index + offset],
              scale_integer_multiply(highest, divisor.coefficients[index]));
        }

        remainder = scale_polynomial_normalize_degree(remainder);
    }

    return scale_polynomial_reduce_binary_content(remainder);
}

fn ScaleSturmSequence scale_sturm_sequence(ScalePolynomial polynomial) @local {
    ScaleSturmSequence result;
    if (scale_polynomial_zero(polynomial)) return result;

    result.terms[0] = scale_polynomial_reduce_binary_content(polynomial);
    result.count = 1;

    ScalePolynomial derivative = scale_polynomial_derivative(result.terms[0]);
    if (scale_polynomial_zero(derivative)) return result;
    result.terms[result.count++] = scale_polynomial_reduce_binary_content(derivative);

    while (result.terms[result.count - 1].degree != 0) {
        ScalePolynomial remainder = scale_polynomial_pseudo_remainder(
            result.terms[result.count - 2], result.terms[result.count - 1]);
        if (scale_polynomial_zero(remainder)) break;

        for (uint index = 0; index <= remainder.degree; index++) {
            remainder.coefficients[index] = scale_integer_negate(remainder.coefficients[index]);
        }

        result.terms[result.count++] = remainder;
    }

    return result;
}

fn int scale_polynomial_endpoint_sign(ScalePolynomial polynomial, bool end) @local {
    if (!end) return scale_integer_sign(polynomial.coefficients[0]);

    ScaleInteger sum;

    for (uint index = 0; index <= polynomial.degree; index++) {
        sum = scale_integer_add(sum, polynomial.coefficients[index]);
    }

    return scale_integer_sign(sum);
}

fn int scale_polynomial_interior_limit_sign(ScalePolynomial polynomial, bool end) @local {
    if (!end) {
        for (uint index = 0; index <= polynomial.degree; index++) {
            int sign = scale_integer_sign(polynomial.coefficients[index]);
            if (sign) return sign;
        }

        return 0;
    }

    for (uint order = 0; order <= polynomial.degree; order++) {
        ScaleInteger derivative;

        for (uint index = order; index <= polynomial.degree; index++) {
            uint factor = 1;
            for (uint falling = 0; falling < order; falling++) factor *= index - falling;
            derivative = scale_integer_add(derivative,
              scale_integer_multiply(polynomial.coefficients[index], scale_integer(factor)));
        }

        int sign = scale_integer_sign(derivative);
        if (sign) return (order & 1) != 0 ? -sign : sign;
    }

    return 0;
}

fn uint scale_sturm_variations(ScaleSturmSequence sequence, bool end) @local {
    int previous;
    uint variations;

    for (uint index = 0; index < sequence.count; index++) {
        int sign = scale_polynomial_interior_limit_sign(sequence.terms[index], end);
        if (sign == 0) continue;
        if (previous != 0 && sign != previous) variations++;
        previous = sign;
    }

    return variations;
}

fn uint scale_sturm_interior_roots(ScaleSturmSequence sequence) @local {
    uint begin = scale_sturm_variations(sequence, false);
    uint end = scale_sturm_variations(sequence, true);

    return begin - end;
}

fn bool exact_scale_strict_positive(ScalePolynomial polynomial) @local {
    if (scale_polynomial_endpoint_sign(polynomial, false) <= 0
        || scale_polynomial_endpoint_sign(polynomial, true) <= 0) return false;

    // Endpoint positivity and an exact root count also reject an interior zero touch.
    return scale_sturm_interior_roots(scale_sturm_sequence(polynomial)) == 0;
}

