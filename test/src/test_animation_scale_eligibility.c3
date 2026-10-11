module c3d::test::scale_eligibility;

import c3d;
import c3d::anim @public;
import std::math;

fn InertialScalarState sample_test_log_scale(
    InertialScalarState source,
    InertialScalarState target,
    double duration,
    double elapsed,
) @local {
    InertialScalarState onset = anim::inertial_onset_scale_residual(source, target);
    InertialScalarState residual = anim::inertial_scalar_residual(
        offset: onset.value,
        velocity: onset.rate,
        duration: duration,
        elapsed: elapsed,
    );
    return anim::inertial_correct_log_scale(residual, target);
}

fn ScaleEligibilityInput constant_scale_eligibility(float scale, double velocity, double duration) @local {
    return { .base = { scale, scale, scale }, .velocity = velocity, .duration = duration };
}

fn void expect_scale_eligibility_fault(ScaleEligibilityInput* input, fault expected) @local {
    char[ScaleEligibilityInput::size] before;
    mem::copy(&before, input, ScaleEligibilityInput::size);
    bool caught;
    if (catch excuse = anim::validate_scale_eligibility(input)) {
        assert(excuse == expected);
        caught = true;
    }
    assert(caught);
    assert(mem::equals((char*)&before, (char*)input, ScaleEligibilityInput::size));
}

fn Track eligibility_scale_track(Interpolation interpolation, float[] times, float[] values) @local {
    return { .path = TargetPath.SCALE, .interpolation = interpolation, .times = times, .values = values };
}

fn void test_animation_scale_eligibility_step_linear_extrema_are_exact_key_means() @test {
    float[2] times = { 0, 1 };
    float[6] values = { 0.5f, 0.5f, 0.5f, 2, 2, 2 };
    Interpolation[2] modes = { Interpolation.STEP, Interpolation.LINEAR };
    foreach (mode : modes) {
        Track track = eligibility_scale_track(mode, times[..], values[..]);
        AdmittedScaleExtrema extrema = anim::collect_admitted_scale_extrema(&track);
        assert(extrema.minimum.lower == 0.5 && extrema.minimum.upper == 0.5);
        assert(extrema.maximum.lower == 2 && extrema.maximum.upper == 2);
        assert(extrema.smallest_input == 0.5f);
    }
}

fn void test_animation_scale_eligibility_cubic_domains_reject_on_keys_or_are_unsupported() @test {
    float[2] times = { 0, 1 };
    float[18] values = { 0, 0, 0, 2, 2, 2, 0, 0, 0, 0, 0, 0, 2, 2, 2, 0, 0, 0 };
    Track track = eligibility_scale_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    AdmittedScaleExtrema[1] regular = { anim::collect_admitted_scale_extrema(&track) };
    ScaleEligibilityInput input = { .regular = regular[..], .base = { 2, 2, 2 }, .duration = 1 };
    expect_scale_eligibility_fault(&input, c3d::UNSUPPORTED);
    values[3] = values[4] = values[5] = values[12] = values[13] = values[14] = float::max;
    regular[0] = anim::collect_admitted_scale_extrema(&track);
    input.offset = math::ln(4.0);
    expect_scale_eligibility_fault(&input, c3d::INVALID_ARGUMENT);
}

fn void test_animation_scale_eligibility_long_counterexamples_reject_and_shorter_duration_admits() @test {
    foreach (double sign : { -1.0, 1.0 }) {
        ScaleEligibilityInput input = constant_scale_eligibility(0x1p-100f, sign * 1024, 1);
        InertialScalarState source = { .value = 0x1p-100, .rate = sign * 0x1p-90 };
        InertialScalarState target = { .value = 0x1p-100 };
        InertialScalarState residual = anim::inertial_scalar_residual(
            offset: 0,
            velocity: sign * 1024,
            duration: 1,
            elapsed: 0.25,
        );
        assert(residual.value == sign * 189);
        InertialScalarState published = sample_test_log_scale(
            source: source,
            target: target,
            duration: 1,
            elapsed: 0.25,
        );
        uint rounded = bitcast((float)published.value, uint);
        assert(rounded == (sign < 0 ? 0u : 0x7f800000u));
        expect_scale_eligibility_fault(&input, c3d::INVALID_ARGUMENT);
        input.duration = 0x1p-6;
        anim::validate_scale_eligibility(&input)!!;
    }
}

fn void test_animation_scale_eligibility_margin_and_uncertain_extrema_are_unsupported() @test {
    ScaleEligibilityInput upper = constant_scale_eligibility(float::max * 0.5f, 0, 1);
    upper.offset = math::ln(2.0);
    expect_scale_eligibility_fault(&upper, c3d::UNSUPPORTED);
    ScaleEligibilityInput lower = constant_scale_eligibility(0x1p-125f, 0, 1);
    lower.offset = -math::ln(2.0);
    expect_scale_eligibility_fault(&lower, c3d::UNSUPPORTED);
    float subnormal = 0x1p-140f;
    ScaleEligibilityInput exact = constant_scale_eligibility(subnormal, 0, 1);
    anim::validate_scale_eligibility(&exact)!!;
    AdmittedScaleExtrema[1] uncertain = { {
        .minimum = { .lower = anim::motion_outward_lower(subnormal), .upper = anim::motion_outward_upper(subnormal) },
        .maximum = { .lower = subnormal, .upper = subnormal },
        .smallest_input = subnormal,
    } };
    exact.regular = uncertain[..];
    expect_scale_eligibility_fault(&exact, c3d::UNSUPPORTED);
}

fn void test_animation_scale_eligibility_directed_exp_encloses_native_and_extreme_products_reject() @test {
    double[15] exponents = { -2000, -1024, -256, -193, -3.25, -0.125, 0, 0.125, 3.25, 100, 193, 256, 512, 1024, 2000 };
    foreach (exponent : exponents) {
        MotionInterval enclosed = anim::eligibility_exp(exponent);
        double native = math::exp(exponent);
        assert(enclosed.lower <= native && enclosed.upper >= native);
    }
    for (uint sample = 0; sample <= 1024; sample++) {
        double exponent = -194 + 388.0 * (double)sample / 1024;
        MotionInterval enclosed = anim::eligibility_exp(exponent);
        double native = math::exp(exponent);
        assert(enclosed.lower <= native && enclosed.upper >= native);
    }
    foreach (double sign : { -1.0, 1.0 }) {
        ScaleEligibilityInput input = constant_scale_eligibility(1, sign * double::max, double::max);
        expect_scale_eligibility_fault(&input, c3d::INVALID_ARGUMENT);
    }
    MotionInterval zero = anim::eligibility_product(
        left: anim::motion_interval_exact(0),
        right: { .lower = double::max, .upper = double::inf },
    );
    assert(zero.lower == 0 && zero.upper == 0);
}

fn void test_animation_scale_eligibility_base_mean_does_not_use_false_component_maximum_witness() @test {
    float previous = bitcast(0x7f7ffffeu, float);
    ScaleEligibilityInput input = {
        .base = { float::max, previous, previous },
        .offset = 1e-10,
        .duration = 1,
    };
    double mean = ((double)float::max + (double)previous + (double)previous) / 3;
    double published = mean * math::exp(input.offset);
    assert(published < (double)float::max && math::is_finite((float)published));
    anim::validate_scale_eligibility(&input)!!;
}
