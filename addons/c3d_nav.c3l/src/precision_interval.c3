module c3d::nav;

import std::math;
import c3d;

const ulong PRECISION_SIGN_BIT @local = 1UL << 63;
const int PRECISION_MIN_PRODUCT_EXPONENT @local = math::DOUBLE_MIN_EXP - 1 + 2 * math::DOUBLE_MANT_DIG;

// Requires binary64 round-to-nearest with gradual underflow and --fp-math=strict.
struct PrecisionInterval @private {
    double min;
    double max;
}

fn PrecisionInterval? precision_point(double value) @private {
    if (!math::is_finite(value)) return c3d::CAPACITY_EXCEEDED~;
    return { .min = value, .max = value };
}

fn PrecisionInterval? precision_add(PrecisionInterval left, PrecisionInterval right) @private {
    precision_check(left)!;
    precision_check(right)!;
    PrecisionInterval lower = precision_sum(left.min, right.min)!;
    PrecisionInterval upper = precision_sum(left.max, right.max)!;
    return { .min = lower.min, .max = upper.max };
}

fn PrecisionInterval? precision_subtract(PrecisionInterval left, PrecisionInterval right) @private {
    precision_check(left)!;
    precision_check(right)!;
    PrecisionInterval lower = precision_sum(left.min, -right.max)!;
    PrecisionInterval upper = precision_sum(left.max, -right.min)!;
    return { .min = lower.min, .max = upper.max };
}

fn PrecisionInterval? precision_multiply(PrecisionInterval left, PrecisionInterval right) @private {
    precision_check(left)!;
    precision_check(right)!;
    PrecisionInterval[4] products = {
        precision_product(left.min, right.min)!,
        precision_product(left.min, right.max)!,
        precision_product(left.max, right.min)!,
        precision_product(left.max, right.max)!,
    };
    PrecisionInterval result = products[0];
    foreach (product : products[1..]) {
        result.min = math::min(result.min, product.min);
        result.max = math::max(result.max, product.max);
    }
    return result;
}

fn PrecisionInterval? precision_divide(PrecisionInterval left, PrecisionInterval right) @private {
    precision_check(left)!;
    precision_check(right)!;
    if (right.min <= 0 && right.max >= 0) return c3d::CAPACITY_EXCEEDED~;
    PrecisionInterval[4] quotients = {
        precision_quotient(left.min, right.min)!,
        precision_quotient(left.min, right.max)!,
        precision_quotient(left.max, right.min)!,
        precision_quotient(left.max, right.max)!,
    };
    PrecisionInterval result = quotients[0];
    foreach (quotient : quotients[1..]) {
        result.min = math::min(result.min, quotient.min);
        result.max = math::max(result.max, quotient.max);
    }
    return result;
}

fn PrecisionInterval? precision_square(PrecisionInterval value) @private {
    precision_check(value)!;
    PrecisionInterval first = precision_product(value.min, value.min)!;
    PrecisionInterval second = precision_product(value.max, value.max)!;
    return {
        .min = value.min <= 0 && value.max >= 0 ? 0 : math::min(first.min, second.min),
        .max = math::max(first.max, second.max),
    };
}

fn PrecisionInterval? precision_sqrt(PrecisionInterval value) @private {
    precision_check(value)!;
    if (value.min < 0) return c3d::CAPACITY_EXCEEDED~;
    PrecisionInterval lower = precision_root(value.min)!;
    PrecisionInterval upper = precision_root(value.max)!;
    return { .min = lower.min, .max = upper.max };
}

fn PrecisionInterval? precision_clamp(PrecisionInterval value, double lower, double upper) @private {
    precision_check(value)!;
    if (!math::is_finite(lower) || !math::is_finite(upper) || lower > upper) return c3d::CAPACITY_EXCEEDED~;
    return {
        .min = math::clamp(value.min, lower, upper),
        .max = math::clamp(value.max, lower, upper),
    };
}

fn int? precision_compare_products(
    PrecisionInterval first,
    PrecisionInterval second,
    PrecisionInterval third,
    PrecisionInterval fourth,
) @private {
    PrecisionInterval difference = precision_subtract(
        precision_multiply(first, second)!,
        precision_multiply(third, fourth)!,
    )!;
    if (difference.min > 0) return 1;
    if (difference.max < 0) return -1;
    if (difference.min == 0 && difference.max == 0) return 0;
    if (first.min != first.max || second.min != second.max
        || third.min != third.max || fourth.min != fourth.max) return c3d::CAPACITY_EXCEEDED~;

    double left = first.min * second.min;
    double right = third.min * fourth.min;
    double[4] terms = {
        math::fma(first.min, second.min, -left),
        -math::fma(third.min, fourth.min, -right),
        left,
        -right,
    };
    double[4] expansion;
    uint count;
    foreach (term : terms) {
        double[4] next;
        uint next_count;
        double carry = term;
        for (uint index = 0; index < count; index++) {
            double sum = carry + expansion[index];
            if (!math::is_finite(sum)) return c3d::CAPACITY_EXCEEDED~;
            double virtual_right = sum - carry;
            double residual = (carry - (sum - virtual_right)) + (expansion[index] - virtual_right);
            if (residual != 0) next[next_count++] = residual;
            carry = sum;
        }
        if (carry != 0 || next_count == 0) next[next_count++] = carry;
        expansion = next;
        count = next_count;
    }
    return expansion[count - 1] > 0 ? 1 : expansion[count - 1] < 0 ? -1 : 0;
}

fn void? precision_check(PrecisionInterval value) @local {
    if (!math::is_finite(value.min) || !math::is_finite(value.max) || value.min > value.max) {
        return c3d::CAPACITY_EXCEEDED~;
    }
}

fn PrecisionInterval? precision_sum(double left, double right) @local {
    double sum = left + right;
    if (!math::is_finite(sum)) return c3d::CAPACITY_EXCEEDED~;
    double virtual_right = sum - left;
    double virtual_left = sum - virtual_right;
    double residual = (left - virtual_left) + (right - virtual_right);
    return precision_enclose(sum, residual);
}

fn PrecisionInterval? precision_product(double left, double right) @local {
    if (left == 0 || right == 0) return precision_point(0);
    precision_product_lattice(left, right)!;
    double product = left * right;
    if (!math::is_finite(product)) return c3d::CAPACITY_EXCEEDED~;
    return precision_enclose(product, math::fma(left, right, -product));
}

fn PrecisionInterval? precision_quotient(double numerator, double denominator) @local {
    if (numerator == 0) return precision_point(0);
    double quotient = numerator / denominator;
    if (!math::is_finite(quotient) || math::abs(quotient) < math::DOUBLE_MIN) return c3d::CAPACITY_EXCEEDED~;
    precision_product_lattice(quotient, denominator)!;
    double residual = math::fma(-quotient, denominator, numerator);
    return precision_enclose(quotient, denominator < 0 ? -residual : residual);
}

fn PrecisionInterval? precision_root(double value) @local {
    if (value == 0) return precision_point(0);
    double root = math::sqrt(value);
    if (!math::is_finite(root)) return c3d::CAPACITY_EXCEEDED~;
    precision_product_lattice(root, root)!;
    return precision_enclose(root, math::fma(-root, root, value));
}

fn void? precision_product_lattice(double left, double right) @local {
    int left_exponent;
    int right_exponent;
    (void)math::frexp(left, &left_exponent);
    (void)math::frexp(right, &right_exponent);
    // The product lattice is 2^(left_exponent + right_exponent - 2p); keep its nonzero residuals normal.
    if (left_exponent + right_exponent < PRECISION_MIN_PRODUCT_EXPONENT) return c3d::CAPACITY_EXCEEDED~;
}

fn PrecisionInterval? precision_enclose(double value, double residual) @local {
    if (!math::is_finite(value) || !math::is_finite(residual)) return c3d::CAPACITY_EXCEEDED~;
    PrecisionInterval result = { .min = value, .max = value };
    if (residual < 0) result.min = precision_adjacent(value, false)!;
    if (residual > 0) result.max = precision_adjacent(value, true)!;
    return result;
}

fn double? precision_adjacent(double value, bool upward) @local {
    ulong bits = bitcast(value, ulong);
    if (value == 0) {
        bits = upward ? 1UL : PRECISION_SIGN_BIT | 1UL;
    } else if ((value > 0) == upward) {
        bits++;
    } else {
        bits--;
    }
    double adjacent = bitcast(bits, double);
    if (!math::is_finite(adjacent)) return c3d::CAPACITY_EXCEEDED~;
    return adjacent;
}
