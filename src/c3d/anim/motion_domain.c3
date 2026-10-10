module c3d::anim;

import c3d;
import std::math;

const uint MOTION_QUATERNION_NODE_BUDGET @local = 4095; // Bounds subdivisions without restricting curve magnitude.
const uint MOTION_QUATERNION_MAX_DEPTH @local = 32; // Depth-first stack: 33 nodes, 136 bytes each; no heap allocation.
const double MOTION_QUATERNION_WIDTH_BOUND @local = 0x1p-30; // Bounds accumulated normalized coefficient uncertainty.
const uint MOTION_SCALE_EPSILON_DENOMINATOR_BITS @local = 69;
const ulong MOTION_SCALE_EPSILON_NUMERATOR @local = 5902958103587057UL; // Exact binary64 relative tolerance 1e-5.
const uint MOTION_SCALE_FLOAT_UNIT_BITS @local = 149;

enum MotionDomainResult @local {
    PROVEN,
    INVALID,
    UNPROVEN,
}

enum ConsumedScaleDomain @private {
    ADMITTED,
    SAMPLING_UNPROVEN,
}

enum MotionRotationFailure @private {
    NONE,
    STORAGE,
    ZERO,
    CERTIFICATE_UNPROVEN,
}

enum MotionScaleFailure @private {
    NONE,
    STORAGE,
    NONPOSITIVE,
    NONUNIFORM,
    NONNEUTRAL,
}

struct MotionInterval @local {
    double lower;
    double upper;
}

struct MotionCubic @local {
    double[4] power;
}

struct MotionQuaternionCubic @local {
    MotionCubic[4] components;
}

struct MotionCertificateNode @local {
    MotionInterval[7] coefficients;
    uint depth;
    double begin;
    double end;
}

fn void? validate_motion_rotation_track(Track* track, MotionRotationFailure* failure = null) @private {
    if (failure) *failure = MotionRotationFailure.NONE;
    if (catch excuse = validate_motion_track_storage(track, TargetPath.ROTATION)) {
        if (failure) *failure = MotionRotationFailure.STORAGE;
        return excuse~;
    }

    uint key_count = (uint)track.times.len;
    for (uint key = 0; key < key_count; key++) {
        float[] value = motion_domain_key(track, (uint)key, CUBIC_SLOT_VALUE);
        bool nonzero;
        foreach (component : value) nonzero |= component != 0;
        if (!nonzero) {
            if (failure) *failure = MotionRotationFailure.ZERO;
            return c3d::INVALID_ARGUMENT~;
        }
    }

    switch (track.interpolation) {
        case STEP:
        case LINEAR:
            // Sign-corrected normalized endpoints have nonnegative dot, so their convex interpolation cannot vanish.
            return;
        case CUBIC_SPLINE:
            bool unsupported;

            for (uint key = 0; key + 1 < key_count; key++) {
                float[] start = motion_domain_key(track, key, CUBIC_SLOT_VALUE);
                float[] end = motion_domain_key(track, key + 1, CUBIC_SLOT_VALUE);
                float[] start_tangent = motion_domain_key(track, key, CUBIC_SLOT_OUT_TANGENT);
                float[] end_tangent = motion_domain_key(track, key + 1, CUBIC_SLOT_IN_TANGENT);
                MotionDomainResult result = motion_quaternion_hermite_domain(
                    start: { start[0], start[1], start[2], start[3] },
                    end: { end[0], end[1], end[2], end[3] },
                    start_tangents: { start_tangent[0], start_tangent[1], start_tangent[2], start_tangent[3] },
                    end_tangents: { end_tangent[0], end_tangent[1], end_tangent[2], end_tangent[3] },
                    start_time: track.times[key],
                    end_time: track.times[key + 1],
                );
                if (result == MotionDomainResult.INVALID) {
                    if (failure) *failure = MotionRotationFailure.ZERO;
                    return c3d::INVALID_ARGUMENT~;
                }
                unsupported |= result == MotionDomainResult.UNPROVEN;
            }

            if (unsupported) {
                if (failure) *failure = MotionRotationFailure.CERTIFICATE_UNPROVEN;
                return c3d::UNSUPPORTED~;
            }
    }
}

// A deferred band result lets the request inspect every exact constraint before reporting UNSUPPORTED.
fn ConsumedScaleDomain? classify_consumed_scale_track(
    Track* track,
    bool additive,
    MotionScaleFailure* failure = null,
) @private {
    if (failure) *failure = MotionScaleFailure.NONE;
    if (catch excuse = validate_motion_track_storage(track, TargetPath.SCALE)) {
        if (failure) *failure = MotionScaleFailure.STORAGE;
        return excuse~;
    }
    float[] reference = motion_domain_key(track, 0, CUBIC_SLOT_VALUE);

    uint key_count = (uint)track.times.len;
    for (uint key = 0; key < key_count; key++) {
        float[] value = motion_domain_key(track, (uint)key, CUBIC_SLOT_VALUE);
        if (additive) {
            for (uint component = 0; component < 3; component++) {
                if (value[component] != reference[component]) {
                    if (failure) *failure = MotionScaleFailure.NONNEUTRAL;
                    return c3d::INVALID_ARGUMENT~;
                }
            }
        } else {
            ScalePolynomial[3] constants;
            for (uint component = 0; component < 3; component++) {
                if (!(value[component] > 0)) {
                    if (failure) *failure = MotionScaleFailure.NONPOSITIVE;
                    return c3d::INVALID_ARGUMENT~;
                }
                constants[component] = motion_constant_scale_polynomial(value[component]);
            }

            if (!motion_scale_uniform(constants)) {
                if (failure) *failure = MotionScaleFailure.NONUNIFORM;
                return c3d::INVALID_ARGUMENT~;
            }
        }
    }

    switch (track.interpolation) {
        case STEP:
        case LINEAR:
            return ConsumedScaleDomain.ADMITTED;
        case CUBIC_SPLINE:
            bool unsupported;

            for (uint key = 0; key + 1 < key_count; key++) {
                float[] start = motion_domain_key(track, key, CUBIC_SLOT_VALUE);
                float[] end = motion_domain_key(track, key + 1, CUBIC_SLOT_VALUE);
                float[] start_tangent = motion_domain_key(track, key, CUBIC_SLOT_OUT_TANGENT);
                float[] end_tangent = motion_domain_key(track, key + 1, CUBIC_SLOT_IN_TANGENT);
                ScaleInteger duration = scale_integer_subtract(
                    left: scale_float_integer(track.times[key + 1]),
                    right: scale_float_integer(track.times[key]),
                );
                ScalePolynomial[3] polynomials;

                for (uint component = 0; component < 3; component++) {
                    polynomials[component] = exact_scale_hermite(
                        start: start[component],
                        end: end[component],
                        start_tangent: start_tangent[component],
                        end_tangent: end_tangent[component],
                        duration: duration,
                    );
                    if (additive) {
                        if (!motion_scale_neutral(polynomials[component], reference[component])) {
                            if (failure) *failure = MotionScaleFailure.NONNEUTRAL;
                            return c3d::INVALID_ARGUMENT~;
                        }
                    } else if (!exact_scale_strict_positive(polynomials[component])) {
                        if (failure) *failure = MotionScaleFailure.NONPOSITIVE;
                        return c3d::INVALID_ARGUMENT~;
                    }
                }

                if (additive) continue;
                if (!motion_scale_uniform(polynomials)) {
                    if (failure) *failure = MotionScaleFailure.NONUNIFORM;
                    return c3d::INVALID_ARGUMENT~;
                }

                for (uint component = 0; component < 3; component++) {
                    ScaleInteger magnitude = exact_scale_segment_magnitude(
                        start: start[component],
                        end: end[component],
                        start_tangent: start_tangent[component],
                        end_tangent: end_tangent[component],
                        duration: duration,
                    );
                    ScalePolynomial guarded = exact_scale_sample_margin(polynomials[component], magnitude);
                    unsupported |= !exact_scale_nonnegative(guarded);
                }
            }

            return unsupported ? ConsumedScaleDomain.SAMPLING_UNPROVEN : ConsumedScaleDomain.ADMITTED;
    }
}

fn void? validate_motion_track_storage(Track* track, TargetPath path) @local {
    usz stride = path == TargetPath.ROTATION ? 4 : 3;
    usz slots = track.interpolation == Interpolation.CUBIC_SPLINE ? CUBIC_SLOTS_PER_KEY : 1;
    if (track.path != path || track.times.len == 0 || track.times.len > uint::max
        || track.times.len > usz::max / (slots * stride)
        || track.values.len != track.times.len * slots * stride) return c3d::INVALID_ARGUMENT~;

    foreach (key, time : track.times) {
        if (!math::is_finite(time) || (key && time <= track.times[key - 1])) return c3d::INVALID_ARGUMENT~;
    }

    foreach (value : track.values) {
        if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
    }
}

fn float[] motion_domain_key(Track* track, uint key, uint slot) @local {
    usz stride = track.stride();
    usz offset = track.interpolation == Interpolation.CUBIC_SPLINE
      ? ((usz)key * CUBIC_SLOTS_PER_KEY + slot) * stride : (usz)key * stride;

    return track.values[offset : stride];
}

fn ScalePolynomial motion_constant_scale_polynomial(float value) @local {
    ScalePolynomial polynomial;
    polynomial.coefficients[0] = scale_integer_shift_left(scale_float_integer(value), MOTION_SCALE_FLOAT_UNIT_BITS);

    return polynomial;
}

fn ScalePolynomial motion_scale_uniform_difference(ScalePolynomial left, ScalePolynomial right) @local {
    ScaleInteger denominator = scale_integer_shift_left(scale_integer(1), MOTION_SCALE_EPSILON_DENOMINATOR_BITS);
    ScaleInteger factor = scale_integer_subtract(denominator, scale_integer(MOTION_SCALE_EPSILON_NUMERATOR));
    ScalePolynomial result;

    for (uint index = 0; index < 4; index++) {
        result.coefficients[index] = scale_integer_subtract(
            left: scale_integer_multiply(left.coefficients[index], denominator),
            right: scale_integer_multiply(right.coefficients[index], factor),
        );
    }

    return scale_polynomial_normalize_degree(result);
}

fn bool motion_scale_polynomial_equal(ScalePolynomial left, ScalePolynomial right) @local {
    for (uint index = 0; index < 4; index++) {
        if (left.coefficients[index].negative != right.coefficients[index].negative
            || scale_integer_compare_magnitude(left.coefficients[index], right.coefficients[index]) != 0) return false;
    }

    return true;
}

fn bool motion_scale_uniform(ScalePolynomial[3] polynomials) @local {
    for (uint left = 0; left < 3; left++) {
        for (uint right = 0; right < 3; right++) {
            if (left == right || motion_scale_polynomial_equal(polynomials[left], polynomials[right])) continue;
            if (!exact_scale_nonnegative(motion_scale_uniform_difference(polynomials[left], polynomials[right]))) {
                return false;
            }
        }
    }

    return true;
}

fn bool motion_scale_neutral(ScalePolynomial polynomial, float reference) @local {
    if (polynomial.degree != 0) return false;
    ScaleInteger expected = scale_integer_shift_left(scale_float_integer(reference), MOTION_SCALE_FLOAT_UNIT_BITS);

    return polynomial.coefficients[0].negative == expected.negative
      && scale_integer_compare_magnitude(polynomial.coefficients[0], expected) == 0;
}

fn double motion_outward_lower(double value) @local {
    if (!math::is_finite(value)) return value;
    if (value == 0) return -0x1p-1074;
    ulong bits = bitcast(value, ulong);
    bits += value < 0 ? 1 : -1;

    return bitcast(bits, double);
}

fn double motion_outward_upper(double value) @local {
    if (!math::is_finite(value)) return value;
    if (value == 0) return 0x1p-1074;
    ulong bits = bitcast(value, ulong);
    bits += value < 0 ? -1 : 1;

    return bitcast(bits, double);
}

fn MotionInterval motion_interval_exact(double value) @local => { .lower = value, .upper = value };

fn MotionInterval motion_interval_add(MotionInterval left, MotionInterval right) @local => {
    .lower = motion_outward_lower(left.lower + right.lower),
    .upper = motion_outward_upper(left.upper + right.upper),
};

fn MotionInterval motion_interval_multiply(MotionInterval left, MotionInterval right) @local {
    double[4] products = {
        left.lower * right.lower,
        left.lower * right.upper,
        left.upper * right.lower,
        left.upper * right.upper,
    };
    double lower = products[0];
    double upper = lower;

    foreach (product : products) {
        lower = math::min(lower, product);
        upper = math::max(upper, product);
    }

    return { .lower = motion_outward_lower(lower), .upper = motion_outward_upper(upper) };
}

fn MotionInterval motion_interval_half(MotionInterval value) @local => {
    .lower = motion_outward_lower(value.lower * 0.5),
    .upper = motion_outward_upper(value.upper * 0.5),
};

fn uint motion_binomial(uint degree, uint index) @local {
    uint result = 1;
    for (uint factor = 1; factor <= index; factor++) result = result * (degree + 1 - factor) / factor;

    return result;
}

fn bool motion_exact_sum(double left, double right, double* result) @local {
    *result = left + right;
    double displacement = *result - left;
    double error = (left - (*result - displacement)) + (right - displacement);

    return error == 0;
}

fn bool motion_exact_product(double left, double right, double* product) @local {
    *product = left * right;
    if (left != 0 && right != 0 && math::abs(*product) < 0x1p-1022) return false;

    return math::is_finite(*product) && math::fma(left, right, -*product) == 0;
}

fn bool motion_exact_cubic_zero(MotionCubic cubic, double time) @local {
    double value = cubic.power[3];

    for (int coefficient = 2; coefficient >= 0; coefficient--) {
        double product = value * time;
        if (value != 0 && time != 0 && math::abs(product) < 0x1p-1022) return false;
        if (math::fma(value, time, -product) != 0) return false;
        if (!motion_exact_sum(product, cubic.power[coefficient], &value)) return false;
    }

    return value == 0;
}

fn bool motion_exact_quaternion_zero(MotionQuaternionCubic cubic, double time) @local {
    foreach (component : cubic.components) {
        if (!motion_exact_cubic_zero(component, time)) return false;
    }

    return true;
}

fn void motion_split_certificate(
    MotionCertificateNode node,
    MotionCertificateNode* left,
    MotionCertificateNode* right,
    double midpoint,
) @local {
    MotionInterval[7] temporary = node.coefficients;
    left.depth = right.depth = node.depth + 1;
    left.begin = node.begin;
    left.end = right.begin = midpoint;
    right.end = node.end;
    left.coefficients[0] = temporary[0];
    right.coefficients[6] = temporary[6];

    for (uint row = 1; row <= 6; row++) {
        for (uint index = 0; index <= 6 - row; index++) {
            temporary[index] = motion_interval_half(motion_interval_add(temporary[index], temporary[index + 1]));
        }
        left.coefficients[row] = temporary[0];
        right.coefficients[6 - row] = temporary[6 - row];
    }
}

fn MotionDomainResult motion_quaternion_certificate(
    MotionQuaternionCubic input,
    MotionInterval[4][4] source_bounds,
    bool exact_coefficients,
) @local {
    double maximum;

    foreach (component_index, component : input.components) {
        foreach (coefficient_index, coefficient : component.power) {
            if (!math::is_finite(coefficient)) return MotionDomainResult.INVALID;
            maximum = math::max(maximum, math::abs(coefficient));
            MotionInterval bound = source_bounds[component_index][coefficient_index];
            if (!math::is_finite(bound.lower) || !math::is_finite(bound.upper)) return MotionDomainResult.INVALID;
            maximum = math::max(maximum, math::max(math::abs(bound.lower), math::abs(bound.upper)));
        }
    }

    if (maximum == 0) return MotionDomainResult.INVALID;
    int exponent;
    (void)math::frexp(maximum, &exponent);
    MotionQuaternionCubic normalized = input;
    MotionInterval[7] power;
    bool scaling_exact = exact_coefficients;

    foreach (component_index, &component : normalized.components) {
        MotionInterval[4] coefficients;
        foreach (index, &coefficient : component.power) {
            double original = *coefficient;
            *coefficient = math::scalbn(*coefficient, -exponent);
            bool exact = math::scalbn(*coefficient, exponent) == original;
            scaling_exact &= exact;
            MotionInterval source_bound = source_bounds[component_index][index];
            coefficients[index] = motion_interval_exact(*coefficient);
            if (!exact || source_bound.lower != original || source_bound.upper != original) {
                coefficients[index] = {
                    .lower = motion_outward_lower(math::scalbn(source_bound.lower, -exponent)),
                    .upper = motion_outward_upper(math::scalbn(source_bound.upper, -exponent)),
                };
            }
        }

        for (uint left = 0; left < 4; left++) {
            for (uint right = 0; right < 4; right++) {
                power[left + right] = motion_interval_add(
                    left: power[left + right],
                    right: motion_interval_multiply(coefficients[left], coefficients[right]),
                );
            }
        }
    }

    if (scaling_exact && (motion_exact_quaternion_zero(normalized, 0)
        || motion_exact_quaternion_zero(normalized, 1))) return MotionDomainResult.INVALID;

    MotionCertificateNode initial = { .begin = 0, .end = 1 };
    for (uint index = 0; index < 7; index++) {
        for (uint coefficient = 0; coefficient <= index; coefficient++) {
            double ratio = (double)motion_binomial(index, coefficient) / (double)motion_binomial(6, coefficient);
            MotionInterval weight = { .lower = motion_outward_lower(ratio), .upper = motion_outward_upper(ratio) };
            initial.coefficients[index] = motion_interval_add(
                left: initial.coefficients[index],
                right: motion_interval_multiply(power[coefficient], weight),
            );
        }
    }

    MotionCertificateNode[MOTION_QUATERNION_MAX_DEPTH + 1] pending;
    uint pending_count = 1;
    uint visits;
    double maximum_interval_width;
    pending[0] = initial;

    while (pending_count) {
        if (visits == MOTION_QUATERNION_NODE_BUDGET) return MotionDomainResult.UNPROVEN;
        MotionCertificateNode node = pending[--pending_count];
        visits++;
        bool positive = true;

        foreach (coefficient : node.coefficients) {
            positive &= coefficient.lower > 0;
            maximum_interval_width = math::max(maximum_interval_width, coefficient.upper - coefficient.lower);
        }

        if (maximum_interval_width > MOTION_QUATERNION_WIDTH_BOUND) return MotionDomainResult.UNPROVEN;
        if (positive) continue;
        double midpoint = (node.begin + node.end) * 0.5;
        if (scaling_exact && motion_exact_quaternion_zero(normalized, midpoint)) return MotionDomainResult.INVALID;
        if (node.depth == MOTION_QUATERNION_MAX_DEPTH) return MotionDomainResult.UNPROVEN;

        MotionCertificateNode left;
        MotionCertificateNode right;
        motion_split_certificate(node: node, left: &left, right: &right, midpoint: midpoint);
        pending[pending_count++] = right;
        pending[pending_count++] = left;
    }

    return MotionDomainResult.PROVEN;
}

fn MotionDomainResult motion_quaternion_hermite_domain(
    double[4] start,
    double[4] end,
    double[4] start_tangents,
    double[4] end_tangents,
    float start_time,
    float end_time,
) @local {
    MotionQuaternionCubic cubic;
    MotionInterval[4][4] bounds;
    double duration;
    bool exact = motion_exact_sum((double)end_time, -(double)start_time, &duration);
    MotionInterval duration_bound = motion_interval_add(
        left: motion_interval_exact((double)end_time),
        right: motion_interval_exact(-(double)start_time),
    );

    for (uint component = 0; component < 4; component++) {
        double start_tangent;
        double end_tangent;
        double difference;
        double scaled_difference;
        double doubled_start_tangent;
        double partial;
        double quadratic;
        double cubic_coefficient;
        exact &= motion_exact_product(start_tangents[component], duration, &start_tangent);
        exact &= motion_exact_product(end_tangents[component], duration, &end_tangent);
        exact &= motion_exact_sum(end[component], -start[component], &difference);
        exact &= motion_exact_product(difference, 3, &scaled_difference);
        exact &= motion_exact_product(start_tangent, 2, &doubled_start_tangent);
        exact &= motion_exact_sum(scaled_difference, -doubled_start_tangent, &partial);
        exact &= motion_exact_sum(partial, -end_tangent, &quadratic);
        exact &= motion_exact_product(difference, -2, &scaled_difference);
        exact &= motion_exact_sum(scaled_difference, start_tangent, &partial);
        exact &= motion_exact_sum(partial, end_tangent, &cubic_coefficient);
        cubic.components[component].power = { start[component], start_tangent, quadratic, cubic_coefficient };

        MotionInterval start_bound = motion_interval_exact(start[component]);
        MotionInterval end_bound = motion_interval_exact(end[component]);
        MotionInterval tangent_start = motion_interval_multiply(
            left: motion_interval_exact(start_tangents[component]),
            right: duration_bound,
        );
        MotionInterval tangent_end = motion_interval_multiply(
            left: motion_interval_exact(end_tangents[component]),
            right: duration_bound,
        );
        MotionInterval negative_start = { .lower = -start_bound.upper, .upper = -start_bound.lower };
        MotionInterval difference_bound = motion_interval_add(end_bound, negative_start);
        MotionInterval negative_tangent_end = { .lower = -tangent_end.upper, .upper = -tangent_end.lower };
        bounds[component][0] = start_bound;
        bounds[component][1] = tangent_start;
        bounds[component][2] = motion_interval_add(
            left: motion_interval_add(
                left: motion_interval_multiply(difference_bound, motion_interval_exact(3)),
                right: motion_interval_multiply(tangent_start, motion_interval_exact(-2)),
            ),
            right: negative_tangent_end,
        );
        bounds[component][3] = motion_interval_add(
            left: motion_interval_add(
                left: motion_interval_multiply(difference_bound, motion_interval_exact(-2)),
                right: tangent_start,
            ),
            right: tangent_end,
        );
    }

    return motion_quaternion_certificate(cubic, bounds, exact);
}
