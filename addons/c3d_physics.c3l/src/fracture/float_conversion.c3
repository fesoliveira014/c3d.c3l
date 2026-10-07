module c3d::physics::fracture;

import std::time;
import std::math;

const uint FLOAT_ROUND_TEMPORARIES @private = 5;
const int FLOAT_MIN_NORMAL_EXPONENT @private = -126;
const int FLOAT_MAX_NORMAL_EXPONENT @private = 127;
$assert FLOAT_ROUND_TEMPORARIES <= EXACT_TEMPORARIES;

<* @require denominator.limbs.len > 0 && !denominator.negative *>
fn float? round_float_ratio(
    ExactScratch* scratch,
    IntegerView numerator,
    IntegerView denominator,
    int unit_exponent,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    uint sign = numerator.negative ? (uint)1 << FLOAT_SIGN_BIT : 0;
    uint numerator_bits = integer_bits(numerator);
    if (!numerator_bits) return bitcast(sign, float);
    WideInteger* scaled = scratch.take()!;
    int exponent = (int)numerator_bits - (int)integer_bits(denominator);
    int comparison;
    if (exponent >= 0) {
        shift_integer(scaled, denominator, (uint)exponent)!;
        comparison = compare_magnitude(numerator, scaled.view());
    } else {
        shift_integer(scaled, numerator, (uint)-exponent)!;
        comparison = compare_magnitude(scaled.view(), denominator);
    }
    if (comparison < 0) exponent--;
    long result_exponent = (long)exponent + unit_exponent;
    if (result_exponent > FLOAT_MAX_NORMAL_EXPONENT) return NUMERICAL_FAILURE~;
    if (result_exponent < FLOAT_UNIT_EXPONENT - 1) return bitcast(sign, float);
    if (result_exponent == FLOAT_UNIT_EXPONENT - 1) {
        return bitcast(sign | (comparison == 0 ? 0 : 1), float);
    }
    int quantum = (int)math::max(result_exponent - FLOAT_FRACTION_BITS, (long)FLOAT_UNIT_EXPONENT);
    int shift = (int)((long)unit_exponent - quantum);
    WideInteger* quotient = scratch.take()!;
    WideInteger* remainder = scratch.take()!;
    WideInteger* complement = scratch.take()!;
    IntegerView divisor = denominator;
    uint significand;
    if (shift >= 0 && (uint)shift > EXACT_LIMBS * INTEGER_LIMB_BITS - numerator_bits) {
        divide_magnitude(
            scratch: scratch,
            quotient: quotient,
            remainder: remainder,
            numerator: numerator,
            denominator: denominator,
        )!;
        significand = quotient.used ? (uint)quotient.limbs[0] : 0;
        for (int bit = 0; bit < shift; bit++) {
            subtract_magnitude(complement, divisor, remainder.view());
            significand <<= 1;
            if (compare_magnitude(remainder.view(), complement.view()) >= 0) {
                subtract_magnitude(remainder, remainder.view(), complement.view());
                significand |= 1;
            } else {
                shift_integer(scaled, remainder.view(), 1)!;
                copy_integer(remainder, scaled.view());
            }
        }
    } else {
        IntegerView dividend = numerator;
        if (shift >= 0) {
            shift_integer(scaled, numerator, (uint)shift)!;
            dividend = scaled.view();
        } else {
            shift_integer(scaled, denominator, (uint)-shift)!;
            divisor = scaled.view();
        }
        divide_magnitude(
            scratch: scratch,
            quotient: quotient,
            remainder: remainder,
            numerator: dividend,
            denominator: divisor,
        )!;
        significand = quotient.used ? (uint)quotient.limbs[0] : 0;
    }
    subtract_magnitude(complement, divisor, remainder.view());
    int rounding = compare_magnitude(remainder.view(), complement.view());
    if (rounding > 0 || (rounding == 0 && (significand & 1))) significand++;
    if (significand == (uint)1 << (FLOAT_FRACTION_BITS + 1)) {
        significand >>= 1;
        result_exponent++;
    }
    if (result_exponent > FLOAT_MAX_NORMAL_EXPONENT) return NUMERICAL_FAILURE~;
    uint bits = significand;
    if (result_exponent >= FLOAT_MIN_NORMAL_EXPONENT) {
        bits = ((uint)(result_exponent + FLOAT_EXPONENT_BIAS) << FLOAT_FRACTION_BITS)
          | (significand & FLOAT_FRACTION_MASK);
    }
    return bitcast(sign | bits, float);
}
