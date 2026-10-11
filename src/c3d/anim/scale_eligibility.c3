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

enum ScaleEligibilityResult @private {
    ADMITTED,
    INVALID_ARGUMENT,
    UNSUPPORTED,
}

struct AdmittedScaleExtrema @private {
    MotionInterval minimum;
    MotionInterval maximum;
    float smallest_input;
}

struct ScaleEligibilityInput @private {
    AdmittedScaleExtrema[] regular;
    float[3] base;
    double offset;
    double velocity;
    double duration;
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

fn ScaleEligibilityResult scale_eligibility(ScaleEligibilityInput* input) @private {
    if (!math::is_finite(input.offset) || !math::is_finite(input.velocity)
      || !math::is_finite(input.duration) || input.duration < 0) return ScaleEligibilityResult.INVALID_ARGUMENT;

    double smallest = double::max;

    foreach (component : input.base) {
        if (!math::is_finite(component) || component <= 0) return ScaleEligibilityResult.INVALID_ARGUMENT;

        smallest = math::min(smallest, (double)component);
    }

    // The published uniform scalar is the mean; component maxima are not attainable scalar witnesses.
    MotionInterval target_minimum = scale_mean_components(input.base[..]);
    MotionInterval target_maximum = target_minimum;

    foreach (extrema : input.regular) {
        if (!math::is_finite(extrema.minimum.lower) || !math::is_finite(extrema.minimum.upper)
          || !math::is_finite(extrema.maximum.lower) || !math::is_finite(extrema.maximum.upper)
          || extrema.minimum.lower > extrema.minimum.upper || extrema.maximum.lower > extrema.maximum.upper
          || extrema.minimum.upper <= 0 || extrema.maximum.upper < extrema.minimum.lower
          || !math::is_finite(extrema.smallest_input) || extrema.smallest_input <= 0) {
            return ScaleEligibilityResult.INVALID_ARGUMENT;
        }

        smallest = math::min(smallest, (double)extrema.smallest_input);
        target_minimum.lower = math::min(target_minimum.lower, extrema.minimum.lower);
        target_minimum.upper = math::min(target_minimum.upper, extrema.minimum.upper);
        target_maximum.lower = math::max(target_maximum.lower, extrema.maximum.lower);
        target_maximum.upper = math::max(target_maximum.upper, extrema.maximum.upper);
    }

    double lower_limit = math::min(SCALE_MIN_NORMAL, smallest);

    if ((input.offset == 0 && input.velocity == 0) || input.duration == 0) {
        return eligibility_closed_limits(target_minimum, target_maximum, lower_limit);
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
    MotionInterval residual_minimum = motion_interval_add(minimum_offset, minimum_velocity);
    MotionInterval residual_maximum = motion_interval_add(maximum_offset, maximum_velocity);

    MotionInterval lower_exp = {
        .lower = eligibility_exp(residual_minimum.lower).lower,
        .upper = eligibility_exp(residual_minimum.upper).upper,
    };
    MotionInterval upper_exp = {
        .lower = eligibility_exp(residual_maximum.lower).lower,
        .upper = eligibility_exp(residual_maximum.upper).upper,
    };

    MotionInterval published_minimum = eligibility_product(target_minimum, lower_exp);
    MotionInterval published_maximum = eligibility_product(target_maximum, upper_exp);

    return eligibility_margined_limits(published_minimum, published_maximum, lower_limit);
}

fn void? validate_scale_eligibility(ScaleEligibilityInput* input) @private {
    switch (scale_eligibility(input)) {
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
            // Cubic interiors are not enclosed, so eligibility can reject on the keys but never admit.
            extrema.minimum.lower = -double::max;
            extrema.maximum.upper = double::max;
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
