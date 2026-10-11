module c3d::anim;

import c3d;
import std::math;

const uint MOTION_QUATERNION_NODE_BUDGET @local = 4095; // Bounds subdivisions without restricting curve magnitude.
const uint MOTION_QUATERNION_MAX_DEPTH @local = 32; // Depth-first stack: 33 nodes, 136 bytes each; no heap allocation.
const double MOTION_QUATERNION_WIDTH_BOUND @local = 0x1p-30; // Bounds accumulated normalized coefficient uncertainty.
const double MOTION_SCALE_EPSILON @local = 1e-5; // Relative component tolerance of a uniform scale.

enum MotionDomainResult @local {
    PROVEN,
    INVALID,
    UNPROVEN,
}

enum ConsumedScaleDomain @private {
    ADMITTED,
    SAMPLING_UNPROVEN,
}

struct MotionInterval @private {
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

fn void? validate_motion_rotation_track(Track* track) @private {
    validate_motion_track_storage(track, TargetPath.ROTATION)!;

    uint key_count = (uint)track.times.len;
    for (uint key = 0; key < key_count; key++) {
        float[] value = motion_domain_key(track, (uint)key, CUBIC_SLOT_VALUE);
        bool nonzero;
        foreach (component : value) nonzero |= component != 0;
        if (!nonzero) return c3d::INVALID_ARGUMENT~;
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
                if (result == MotionDomainResult.INVALID) return c3d::INVALID_ARGUMENT~;
                unsupported |= result == MotionDomainResult.UNPROVEN;
            }

            if (unsupported) return c3d::UNSUPPORTED~;
    }
}

// A result rather than a fault lets the caller check every track for INVALID_ARGUMENT first.
fn ConsumedScaleDomain? classify_consumed_scale_track(Track* track, bool additive) @private {
    validate_motion_track_storage(track, TargetPath.SCALE)!;

    float[] reference = motion_domain_key(track, 0, CUBIC_SLOT_VALUE);

    uint key_count = (uint)track.times.len;
    for (uint key = 0; key < key_count; key++) {
        float[] value = motion_domain_key(track, (uint)key, CUBIC_SLOT_VALUE);
        if (additive) {
            for (uint component = 0; component < 3; component++) {
                if (value[component] != reference[component]) return c3d::INVALID_ARGUMENT~;
            }
        } else {
            for (uint component = 0; component < 3; component++) {
                if (!(value[component] > 0)) return c3d::INVALID_ARGUMENT~;
            }

            if (!motion_scale_uniform(value)) return c3d::INVALID_ARGUMENT~;
        }
    }

    switch (track.interpolation) {
        case STEP:
        case LINEAR:
            return ConsumedScaleDomain.ADMITTED;
        case CUBIC_SPLINE:
            return ConsumedScaleDomain.SAMPLING_UNPROVEN;
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

fn bool motion_scale_uniform(float[] value) @local {
    foreach (smaller : value) foreach (larger : value) {
        if (smaller >= larger) continue;
        if ((double)smaller < (double)larger * 0.5) return false;

        // Within a factor of two the difference is exact, and the single fma rounding keeps its sign.
        if (math::fma((double)larger, MOTION_SCALE_EPSILON, (double)smaller - (double)larger) < 0) return false;
    }

    return true;
}

fn double motion_outward_lower(double value) @private {
    if (!math::is_finite(value)) return value;
    if (value == 0) return -0x1p-1074;
    ulong bits = bitcast(value, ulong);
    bits += value < 0 ? 1 : -1;

    return bitcast(bits, double);
}

fn double motion_outward_upper(double value) @private {
    if (!math::is_finite(value)) return value;
    if (value == 0) return 0x1p-1074;
    ulong bits = bitcast(value, ulong);
    bits += value < 0 ? -1 : 1;

    return bitcast(bits, double);
}

fn MotionInterval motion_interval_exact(double value) @private => { .lower = value, .upper = value };

fn MotionInterval motion_interval_add(MotionInterval left, MotionInterval right) @private => {
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

fn MotionInterval motion_interval_half(MotionInterval value) @private => {
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
        motion_split_certificate(
            node: node,
            left: &left,
            right: &right,
            midpoint: midpoint,
        );
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
