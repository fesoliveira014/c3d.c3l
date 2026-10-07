module c3d::physics::fracture;

import c3d;
import std::math;

const uint INTEGER_LIMB_BITS @private = 64;
const uint EXACT_LIMBS @private = 128;
const uint PLANE_LIMBS @private = 14;
const uint EXACT_TEMPORARIES @private = 24;
const uint FLOAT_FRACTION_BITS @private = 23;
const uint FLOAT_EXPONENT_MASK @private = 255;
const uint FLOAT_SIGN_BIT @private = 31;
const uint FLOAT_FRACTION_MASK @private = 0x7fffff;

struct IntegerView @private {
    ulong[] limbs;
    bool negative;
}

struct WideInteger @private {
    ulong[EXACT_LIMBS] limbs;
    uint used;
    bool negative;
}

struct PlaneInteger @private {
    ulong[PLANE_LIMBS] limbs;
    uint used;
    bool negative;
}

struct FractureStatistics @private {
    usz scratch_peak;
    ulong cell_split_count;
    ulong final_leaf_count;
    ulong occupied_leaf_count;
    usz max_planar_segments;
    usz max_planar_points;
    usz max_patch_vertices;
    ulong max_patch_predicates;
    ulong max_patch_nanoseconds;
}

struct ExactScratch @private {
    WideInteger[EXACT_TEMPORARIES] values;
    uint count;
    uint peak;
    ulong predicate_count;
    ulong filtered_count;
    ulong exact_nanoseconds;
    uint measurement_depth;
    FractureStatistics statistics;
}

fn IntegerView WideInteger.view(&self) {
    return { .limbs = self.limbs[:self.used], .negative = self.negative };
}

fn IntegerView PlaneInteger.view(&self) {
    return { .limbs = self.limbs[:self.used], .negative = self.negative };
}

fn WideInteger*? ExactScratch.take(&self) {
    if (self.count == EXACT_TEMPORARIES) return c3d::CAPACITY_EXCEEDED~;
    WideInteger* value = &self.values[self.count++];
    self.peak = math::max(self.peak, self.count);
    value.used = 0;
    value.negative = false;
    return value;
}

fn uint integer_bits(IntegerView value) @private {
    if (!value.limbs.len) return 0;
    ulong high = value.limbs[^1];
    uint bits = (uint)(value.limbs.len - 1) * INTEGER_LIMB_BITS;
    while (high) {
        bits++;
        high >>= 1;
    }
    return bits;
}

fn int compare_magnitude(IntegerView first, IntegerView second) @private {
    if (first.limbs.len != second.limbs.len) return first.limbs.len < second.limbs.len ? -1 : 1;
    for (sz index = first.limbs.len; index > 0; index--) {
        ulong left = first.limbs[index - 1];
        ulong right = second.limbs[index - 1];
        if (left != right) return left < right ? -1 : 1;
    }
    return 0;
}

fn void normalize_integer(WideInteger* value) @private {
    while (value.used && value.limbs[value.used - 1] == 0) value.used--;
    if (!value.used) value.negative = false;
}

fn void copy_integer(WideInteger* output, IntegerView value) @private {
    output.used = (uint)value.limbs.len;
    output.negative = value.negative;
    output.limbs[:output.used] = value.limbs[..];
}

fn void set_integer(WideInteger* output, int128 value) @private {
    uint128 magnitude = value < 0 ? (uint128)(-(value + 1)) + 1 : (uint128)value;
    output.limbs[0] = (ulong)magnitude;
    output.limbs[1] = (ulong)(magnitude >> INTEGER_LIMB_BITS);
    output.used = output.limbs[1] ? 2 : output.limbs[0] ? 1 : 0;
    output.negative = value < 0;
}

fn void integer_from_float(WideInteger* output, float value) @private {
    uint bits = bitcast(value, uint);
    uint exponent = (bits >> FLOAT_FRACTION_BITS) & FLOAT_EXPONENT_MASK;
    ulong significand = bits & FLOAT_FRACTION_MASK;
    if (exponent) significand |= (ulong)1 << FLOAT_FRACTION_BITS;
    uint shift = exponent ? exponent - 1 : 0;
    uint first = shift / INTEGER_LIMB_BITS;
    uint offset = shift % INTEGER_LIMB_BITS;
    output.used = first + 2;
    output.limbs[:output.used] = 0;
    output.limbs[first] = significand << offset;
    if (offset) output.limbs[first + 1] = significand >> (INTEGER_LIMB_BITS - offset);
    output.negative = (bits >> FLOAT_SIGN_BIT) != 0;
    normalize_integer(output);
}

fn void subtract_magnitude(WideInteger* output, IntegerView first, IntegerView second) @private {
    uint128 borrow;
    uint length = (uint)first.limbs.len;
    for (uint index = 0; index < length; index++) {
        uint128 right = index < second.limbs.len ? second.limbs[index] : 0;
        uint128 value = (uint128)first.limbs[index] + ((uint128)1 << INTEGER_LIMB_BITS) - right - borrow;
        output.limbs[index] = (ulong)value;
        borrow = (value >> INTEGER_LIMB_BITS) == 0 ? 1 : 0;
    }
    output.used = length;
    output.negative = false;
    normalize_integer(output);
}

fn void? add_integer(WideInteger* output, IntegerView first, IntegerView second) @private {
    if (first.negative != second.negative) {
        if (compare_magnitude(first, second) >= 0) {
            subtract_magnitude(output, first, second);
            output.negative = output.used && first.negative;
        } else {
            subtract_magnitude(output, second, first);
            output.negative = output.used && second.negative;
        }
        return;
    }
    uint length = (uint)math::max(first.limbs.len, second.limbs.len);
    uint128 carry;
    for (uint index = 0; index < length; index++) {
        uint128 value = carry;
        if (index < first.limbs.len) value += first.limbs[index];
        if (index < second.limbs.len) value += second.limbs[index];
        output.limbs[index] = (ulong)value;
        carry = value >> INTEGER_LIMB_BITS;
    }
    if (carry) {
        if (length == EXACT_LIMBS) return NUMERICAL_FAILURE~;
        output.limbs[length++] = (ulong)carry;
    }
    output.used = length;
    output.negative = length && first.negative;
    return;
}

fn void? multiply_integer(WideInteger* output, IntegerView first, IntegerView second) @private {
    uint length = (uint)math::min(first.limbs.len + second.limbs.len, (sz)EXACT_LIMBS);
    output.limbs[:length] = 0;
    output.used = length;
    output.negative = first.negative != second.negative;
    foreach (uint first_index, left : first.limbs) {
        uint128 carry;
        foreach (uint second_index, right : second.limbs) {
            uint index = first_index + second_index;
            uint128 value = (uint128)left * right + carry;
            if (index >= EXACT_LIMBS) {
                if (value) return NUMERICAL_FAILURE~;
                continue;
            }
            value += output.limbs[index];
            output.limbs[index] = (ulong)value;
            carry = value >> INTEGER_LIMB_BITS;
        }
        uint index = first_index + (uint)second.limbs.len;
        if (index >= EXACT_LIMBS) {
            if (carry) return NUMERICAL_FAILURE~;
        } else {
            output.limbs[index] = (ulong)carry;
        }
    }
    normalize_integer(output);
    return;
}

fn void? shift_integer(WideInteger* output, IntegerView value, uint shift) @private {
    uint bits = integer_bits(value);
    if (!bits) {
        output.used = 0;
        output.negative = false;
        return;
    }
    if (shift > EXACT_LIMBS * INTEGER_LIMB_BITS - bits) return NUMERICAL_FAILURE~;
    uint first = shift / INTEGER_LIMB_BITS;
    uint offset = shift % INTEGER_LIMB_BITS;
    output.used = (bits + shift + INTEGER_LIMB_BITS - 1) / INTEGER_LIMB_BITS;
    output.limbs[:output.used] = 0;
    foreach (uint index, limb : value.limbs) {
        output.limbs[first + index] |= limb << offset;
        if (offset && first + index + 1 < output.used) {
            output.limbs[first + index + 1] |= limb >> (INTEGER_LIMB_BITS - offset);
        }
    }
    output.negative = value.negative;
    return;
}

fn void halve_integer(WideInteger* value) @private {
    for (uint index = 0; index < value.used; index++) {
        ulong high = index + 1 < value.used ? value.limbs[index + 1] : 0;
        value.limbs[index] = (value.limbs[index] >> 1) | (high << (INTEGER_LIMB_BITS - 1));
    }
    normalize_integer(value);
}

fn void? divide_magnitude(
    ExactScratch* scratch,
    WideInteger* quotient,
    WideInteger* remainder,
    IntegerView numerator,
    IntegerView denominator,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    quotient.used = 0;
    quotient.negative = false;
    copy_integer(remainder, numerator);
    remainder.negative = false;
    if (compare_magnitude(numerator, denominator) < 0) return;
    uint shift = integer_bits(numerator) - integer_bits(denominator);
    WideInteger* divisor = scratch.take()!;
    shift_integer(divisor, denominator, shift)!;
    quotient.used = shift / INTEGER_LIMB_BITS + 1;
    quotient.limbs[:quotient.used] = 0;
    for (uint remaining = shift + 1; remaining > 0; remaining--) {
        uint bit = remaining - 1;
        if (compare_magnitude(remainder.view(), divisor.view()) >= 0) {
            subtract_magnitude(remainder, remainder.view(), divisor.view());
            quotient.limbs[bit / INTEGER_LIMB_BITS] |= (ulong)1 << (bit % INTEGER_LIMB_BITS);
        }
        halve_integer(divisor);
    }
    normalize_integer(quotient);
    return;
}

fn void? gcd_integer(
    ExactScratch* scratch,
    WideInteger* output,
    IntegerView first,
    IntegerView second,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* left = scratch.take()!;
    WideInteger* right = scratch.take()!;
    WideInteger* quotient = scratch.take()!;
    WideInteger* remainder = scratch.take()!;
    copy_integer(left, first);
    copy_integer(right, second);
    while (right.used) {
        divide_magnitude(
            scratch: scratch,
            quotient: quotient,
            remainder: remainder,
            numerator: left.view(),
            denominator: right.view(),
        )!;
        copy_integer(left, right.view());
        copy_integer(right, remainder.view());
    }
    copy_integer(output, left.view());
    output.negative = false;
    return;
}
