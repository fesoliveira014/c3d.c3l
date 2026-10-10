module c3d::anim;

import c3d;
import std::math;

const double SCALE_ELIGIBILITY_REL_MARGIN @private = 0x1p-40; // Separates directed double bounds from binary32 cutoffs.
const double SCALE_MIN_NORMAL @local = 0x1p-126;
const double SCALE_MAX_FINITE @local = (double)float::max;
const uint ELIGIBILITY_EXP_TERMS @local = 20; // Fixed Taylor work after reduction to [-1/8,1/8].
const double ELIGIBILITY_EXP_REMAINDER @local = 0x1p-120; // Exceeds the absolute 21st-term tail bound 2^-127.
const double ELIGIBILITY_EXP_REDUCTION_LIMIT @local = 0.125;
const double ELIGIBILITY_EXP_OUTER_LIMIT @local = 1024; // Beyond this exp lies outside the binary64 finite range.
const uint SCALE_EXTREMA_NODE_BUDGET @local = 4095; // Same fixed subdivision budget as quaternion admission.
const uint SCALE_EXTREMA_MAX_DEPTH @local = 32; // 33 fixed 72-byte Bernstein nodes; no heap allocation.

enum ScaleEligibilityResult @private {
    ADMITTED,
    INVALID_ARGUMENT,
    UNSUPPORTED,
}

struct AdmittedScaleExtrema @private {
    MotionInterval minimum;
    MotionInterval maximum;
    float smallest_input;
    bool exhausted;
}

struct ScaleEligibilityInput @private {
    AdmittedScaleExtrema[] regular;
    float[3] base;
    double offset;
    double velocity;
    double duration;
}

struct ScaleEligibilityProof @private {
    ScaleEligibilityResult result;
    MotionInterval target_minimum;
    MotionInterval target_maximum;
    MotionInterval residual_minimum;
    MotionInterval residual_maximum;
    MotionInterval published_minimum;
    MotionInterval published_maximum;
    double lower_limit;
    bool exact_correction;
    bool extrema_exhausted;
}

struct ScaleExtremaNode @local {
    MotionInterval[4] coefficients;
    uint depth;
}

fn MotionInterval eligibility_product(MotionInterval left, MotionInterval right) @private {
    double[2] left_values = { left.lower, left.upper };
    double[2] right_values = { right.lower, right.upper };
    MotionInterval result = { .lower = double::max, .upper = -double::max };

    foreach (first : left_values) foreach (second : right_values) {
        double value = first == 0 || second == 0 ? 0 : first * second;
        double lower;
        double upper;

        if (first == 0 || second == 0) {
            lower = upper = 0;
        } else if (value == double::inf) {
            lower = double::max;
            upper = double::inf;
        } else if (value == -double::inf) {
            lower = -double::inf;
            upper = -double::max;
        } else {
            lower = motion_outward_lower(value);
            upper = motion_outward_upper(value);
        }

        result.lower = math::min(result.lower, lower);
        result.upper = math::max(result.upper, upper);
    }

    return result;
}

fn MotionInterval eligibility_divide_positive(MotionInterval value, uint divisor) @private {
    return {
        .lower = motion_outward_lower(value.lower / (double)divisor),
        .upper = motion_outward_upper(value.upper / (double)divisor),
    };
}

fn MotionInterval eligibility_exp(double value) @private {
    if (value == 0) return motion_interval_exact(1);
    if (value > ELIGIBILITY_EXP_OUTER_LIMIT) return { .lower = double::max, .upper = double::inf };
    if (value < -ELIGIBILITY_EXP_OUTER_LIMIT) return { .lower = 0, .upper = 0x1p-1074 };

    MotionInterval reduced = motion_interval_exact(value);
    uint squares;

    while (math::max(math::abs(reduced.lower), math::abs(reduced.upper)) > ELIGIBILITY_EXP_REDUCTION_LIMIT) {
        reduced = motion_interval_half(reduced);
        squares++;
    }

    MotionInterval sum = motion_interval_exact(1);
    MotionInterval term = motion_interval_exact(1);

    for (uint degree = 1; degree <= ELIGIBILITY_EXP_TERMS; degree++) {
        term = eligibility_divide_positive(eligibility_product(term, reduced), degree);
        sum = motion_interval_add(sum, term);
    }

    sum = motion_interval_add(
        left: sum,
        right: { .lower = -ELIGIBILITY_EXP_REMAINDER, .upper = ELIGIBILITY_EXP_REMAINDER },
    );

    for (uint square = 0; square < squares; square++) sum = eligibility_product(sum, sum);

    return sum;
}

fn ScaleEligibilityResult eligibility_closed_limits(
    MotionInterval minimum,
    MotionInterval maximum,
    double lower_limit,
) @private {
    if (minimum.upper < lower_limit || maximum.lower > SCALE_MAX_FINITE) return ScaleEligibilityResult.INVALID_ARGUMENT;
    if (minimum.lower >= lower_limit && maximum.upper <= SCALE_MAX_FINITE) return ScaleEligibilityResult.ADMITTED;

    return ScaleEligibilityResult.UNSUPPORTED;
}

fn ScaleEligibilityResult eligibility_margined_limits(
    MotionInterval minimum,
    MotionInterval maximum,
    double lower_limit,
) @private {
    double lower_outside = motion_outward_lower(
        value: lower_limit * (1 - SCALE_ELIGIBILITY_REL_MARGIN),
    );
    double upper_outside = motion_outward_upper(
        value: SCALE_MAX_FINITE * (1 + SCALE_ELIGIBILITY_REL_MARGIN),
    );

    if (minimum.upper < lower_outside || maximum.lower > upper_outside) return ScaleEligibilityResult.INVALID_ARGUMENT;

    double lower_inside = motion_outward_upper(
        value: lower_limit * (1 + SCALE_ELIGIBILITY_REL_MARGIN),
    );
    double upper_inside = motion_outward_lower(
        value: SCALE_MAX_FINITE * (1 - SCALE_ELIGIBILITY_REL_MARGIN),
    );

    if (minimum.lower >= lower_inside && maximum.upper <= upper_inside) return ScaleEligibilityResult.ADMITTED;

    return ScaleEligibilityResult.UNSUPPORTED;
}

fn ScaleEligibilityProof scale_eligibility(ScaleEligibilityInput* input) @private {
    ScaleEligibilityProof proof = { .result = ScaleEligibilityResult.UNSUPPORTED };

    if (!math::is_finite(input.offset) || !math::is_finite(input.velocity)
      || !math::is_finite(input.duration) || input.duration < 0) {
        proof.result = ScaleEligibilityResult.INVALID_ARGUMENT;
        return proof;
    }

    double smallest = double::max;
    proof.target_minimum = motion_interval_exact(double::max);
    proof.target_maximum = motion_interval_exact(0);

    foreach (component : input.base) {
        if (!math::is_finite(component) || component <= 0) {
            proof.result = ScaleEligibilityResult.INVALID_ARGUMENT;
            return proof;
        }

        smallest = math::min(smallest, (double)component);
    }

    // The published uniform scalar is the mean; component maxima are not attainable scalar witnesses.
    MotionInterval base_mean = scale_mean_components(input.base[..]);
    proof.target_minimum = proof.target_maximum = base_mean;

    foreach (extrema : input.regular) {
        if (!math::is_finite(extrema.minimum.lower) || !math::is_finite(extrema.minimum.upper)
          || !math::is_finite(extrema.maximum.lower) || !math::is_finite(extrema.maximum.upper)
          || extrema.minimum.lower > extrema.minimum.upper || extrema.maximum.lower > extrema.maximum.upper
          || extrema.minimum.upper <= 0 || extrema.maximum.upper < extrema.minimum.lower
          || !math::is_finite(extrema.smallest_input) || extrema.smallest_input <= 0) {
            proof.result = ScaleEligibilityResult.INVALID_ARGUMENT;
            return proof;
        }

        proof.extrema_exhausted |= extrema.exhausted;
        smallest = math::min(smallest, (double)extrema.smallest_input);
        proof.target_minimum.lower = math::min(proof.target_minimum.lower, extrema.minimum.lower);
        proof.target_minimum.upper = math::min(proof.target_minimum.upper, extrema.minimum.upper);
        proof.target_maximum.lower = math::max(proof.target_maximum.lower, extrema.maximum.lower);
        proof.target_maximum.upper = math::max(proof.target_maximum.upper, extrema.maximum.upper);
    }

    proof.lower_limit = math::min(SCALE_MIN_NORMAL, smallest);
    proof.exact_correction = (input.offset == 0 && input.velocity == 0) || input.duration == 0;

    if (proof.exact_correction) {
        proof.residual_minimum = motion_interval_exact(0);
        proof.residual_maximum = motion_interval_exact(0);
        proof.published_minimum = proof.target_minimum;
        proof.published_maximum = proof.target_maximum;

        proof.result = eligibility_closed_limits(proof.published_minimum, proof.published_maximum, proof.lower_limit);
        return proof;
    }

    MotionInterval duration = motion_interval_exact(input.duration);
    MotionInterval velocity = motion_interval_exact(input.velocity);
    MotionInterval scaled_velocity = eligibility_product(duration, velocity);
    MotionInterval h1_range = { .lower = 0, .upper = motion_outward_upper(16.0 / 81.0) };
    MotionInterval velocity_range = eligibility_product(scaled_velocity, h1_range);
    MotionInterval minimum_offset = motion_interval_exact(math::min(0.0, input.offset));
    MotionInterval maximum_offset = motion_interval_exact(math::max(0.0, input.offset));
    MotionInterval minimum_velocity = motion_interval_exact(velocity_range.lower);
    MotionInterval maximum_velocity = motion_interval_exact(velocity_range.upper);
    proof.residual_minimum = motion_interval_add(minimum_offset, minimum_velocity);
    proof.residual_maximum = motion_interval_add(maximum_offset, maximum_velocity);

    MotionInterval lower_exp = {
        .lower = eligibility_exp(proof.residual_minimum.lower).lower,
        .upper = eligibility_exp(proof.residual_minimum.upper).upper,
    };
    MotionInterval upper_exp = {
        .lower = eligibility_exp(proof.residual_maximum.lower).lower,
        .upper = eligibility_exp(proof.residual_maximum.upper).upper,
    };

    proof.published_minimum = eligibility_product(proof.target_minimum, lower_exp);
    proof.published_maximum = eligibility_product(proof.target_maximum, upper_exp);

    proof.result = eligibility_margined_limits(proof.published_minimum, proof.published_maximum, proof.lower_limit);
    return proof;
}

fn void? validate_scale_eligibility(ScaleEligibilityInput* input, ScaleEligibilityProof* out_proof = null) @private {
    ScaleEligibilityProof proof = scale_eligibility(input);
    if (out_proof) *out_proof = proof;

    switch (proof.result) {
        case ADMITTED:
            return;
        case INVALID_ARGUMENT:
            return c3d::INVALID_ARGUMENT~;
        case UNSUPPORTED:
            return c3d::UNSUPPORTED~;
    }
}

<* @require track.path == TargetPath.SCALE && track.times.len > 0 *>
fn AdmittedScaleExtrema collect_admitted_scale_extrema(Track* track) @private {
    AdmittedScaleExtrema extrema = {
        .minimum = { .lower = double::max, .upper = double::max },
        .maximum = { .lower = -double::max, .upper = -double::max },
        .smallest_input = float::max,
    };
    uint key_count = (uint)track.times.len;

    for (uint key = 0; key < key_count; key++) {
        float[] value = analytic_key_values(track, key, CUBIC_SLOT_VALUE);
        foreach (component : value) extrema.smallest_input = math::min(extrema.smallest_input, component);
        MotionInterval mean = scale_mean_key(track, key, CUBIC_SLOT_VALUE);
        include_scale_extrema(&extrema, mean, mean);
    }

    switch (track.interpolation) {
        case STEP:
        case LINEAR:
            return extrema;
        case CUBIC_SPLINE:
            for (uint key = 0; key + 1 < key_count; key++) {
                MotionInterval start = scale_mean_key(track, key, CUBIC_SLOT_VALUE);
                MotionInterval end = scale_mean_key(track, key + 1, CUBIC_SLOT_VALUE);
                if (scale_componentwise_constant_segment(track, key)) {
                    include_scale_extrema(&extrema, start, start);
                    continue;
                }

                MotionInterval duration = motion_interval_add(
                    left: motion_interval_exact((double)track.times[key + 1]),
                    right: motion_interval_exact(-(double)track.times[key]),
                );
                MotionInterval start_tangent = eligibility_divide_positive(
                    value: eligibility_product(duration, scale_mean_key(track, key, CUBIC_SLOT_OUT_TANGENT)),
                    divisor: 3,
                );
                MotionInterval end_tangent = eligibility_divide_positive(
                    value: eligibility_product(duration, scale_mean_key(track, key + 1, CUBIC_SLOT_IN_TANGENT)),
                    divisor: 3,
                );
                MotionInterval negative_end_tangent = { .lower = -end_tangent.upper, .upper = -end_tangent.lower };
                ScaleExtremaNode initial = { .coefficients = {
                    start,
                    motion_interval_add(start, start_tangent),
                    motion_interval_add(end, negative_end_tangent),
                    end,
                } };

                enclose_scale_cubic_extrema(&extrema, initial);
            }

            return extrema;
    }
}

fn MotionInterval scale_mean_key(Track* track, uint key, uint slot) @local {
    float[] value = analytic_key_values(track, key, slot);
    return scale_mean_components(value);
}

fn MotionInterval scale_mean_components(float[] value) @local {
    if (value[0] == value[1] && value[1] == value[2]) return motion_interval_exact(value[0]);

    MotionInterval sum = motion_interval_add(motion_interval_exact(value[0]), motion_interval_exact(value[1]));
    sum = motion_interval_add(sum, motion_interval_exact(value[2]));

    return eligibility_divide_positive(sum, 3);
}

fn bool scale_componentwise_constant_segment(Track* track, uint key) @local {
    float[] start = analytic_key_values(track, key, CUBIC_SLOT_VALUE);
    float[] end = analytic_key_values(track, key + 1, CUBIC_SLOT_VALUE);
    float[] outgoing = analytic_key_values(track, key, CUBIC_SLOT_OUT_TANGENT);
    float[] incoming = analytic_key_values(track, key + 1, CUBIC_SLOT_IN_TANGENT);

    for (uint component = 0; component < 3; component++) {
        if (start[component] != end[component] || outgoing[component] != 0 || incoming[component] != 0) return false;
    }

    return true;
}

fn void include_scale_extrema(
    AdmittedScaleExtrema* extrema,
    MotionInterval minimum,
    MotionInterval maximum,
) @local {
    extrema.minimum.lower = math::min(extrema.minimum.lower, minimum.lower);
    extrema.minimum.upper = math::min(extrema.minimum.upper, minimum.upper);
    extrema.maximum.lower = math::max(extrema.maximum.lower, maximum.lower);
    extrema.maximum.upper = math::max(extrema.maximum.upper, maximum.upper);
}

fn void include_scale_bernstein_hull(AdmittedScaleExtrema* extrema, ScaleExtremaNode node) @local {
    double lower = double::max;
    double upper = -double::max;

    foreach (coefficient : node.coefficients) {
        lower = math::min(lower, coefficient.lower);
        upper = math::max(upper, coefficient.upper);
    }

    MotionInterval minimum = {
        .lower = lower,
        .upper = math::min(node.coefficients[0].upper, node.coefficients[3].upper),
    };
    MotionInterval maximum = {
        .lower = math::max(node.coefficients[0].lower, node.coefficients[3].lower),
        .upper = upper,
    };
    include_scale_extrema(extrema, minimum, maximum);
}

fn void split_scale_extrema_node(ScaleExtremaNode node, ScaleExtremaNode* left, ScaleExtremaNode* right) @local {
    MotionInterval[4] temporary = node.coefficients;
    left.depth = right.depth = node.depth + 1;
    left.coefficients[0] = temporary[0];
    right.coefficients[3] = temporary[3];

    for (uint row = 1; row <= 3; row++) {
        for (uint index = 0; index <= 3 - row; index++) {
            temporary[index] = motion_interval_half(motion_interval_add(temporary[index], temporary[index + 1]));
        }
        left.coefficients[row] = temporary[0];
        right.coefficients[3 - row] = temporary[3 - row];
    }
}

fn void enclose_scale_cubic_extrema(AdmittedScaleExtrema* extrema, ScaleExtremaNode initial) @local {
    ScaleExtremaNode[SCALE_EXTREMA_MAX_DEPTH + 1] pending;
    uint pending_count = 1;
    uint visits;
    pending[0] = initial;

    while (pending_count) {
        if (visits == SCALE_EXTREMA_NODE_BUDGET) {
            for (uint index = 0; index < pending_count; index++) include_scale_bernstein_hull(extrema, pending[index]);
            extrema.exhausted = true;
            return;
        }

        ScaleExtremaNode node = pending[--pending_count];
        visits++;
        bool increasing = true;
        bool decreasing = true;

        for (uint index = 0; index < 3; index++) {
            MotionInterval negative = {
                .lower = -node.coefficients[index].upper,
                .upper = -node.coefficients[index].lower,
            };
            MotionInterval difference = motion_interval_add(node.coefficients[index + 1], negative);
            increasing &= difference.lower >= 0;
            decreasing &= difference.upper <= 0;
        }

        if (increasing) {
            include_scale_extrema(extrema, node.coefficients[0], node.coefficients[3]);
            continue;
        }

        if (decreasing) {
            include_scale_extrema(extrema, node.coefficients[3], node.coefficients[0]);
            continue;
        }

        if (node.depth == SCALE_EXTREMA_MAX_DEPTH) {
            include_scale_bernstein_hull(extrema, node);
            extrema.exhausted = true;
            continue;
        }

        ScaleExtremaNode left;
        ScaleExtremaNode right;
        split_scale_extrema_node(node, &left, &right);
        pending[pending_count++] = right;
        pending[pending_count++] = left;
    }
}

