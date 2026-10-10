module c3d::test::scale_eligibility;

import c3d;
import c3d::anim @public;
import std::math;

fn ScaleEligibilityInput constant_scale_eligibility(float scale, double velocity, double duration) @local {
    return { .base = { scale, scale, scale }, .velocity = velocity, .duration = duration };
}

fn void expect_scale_eligibility_fault(ScaleEligibilityInput* input, fault expected) @local {
    char[ScaleEligibilityInput::size] before;
    mem::copy(&before, input, ScaleEligibilityInput::size);
    ScaleEligibilityProof proof;
    bool caught;
    if (catch excuse = anim::validate_scale_eligibility(input, &proof)) {
        assert(excuse == expected);
        caught = true;
    }
    assert(caught);
    assert(mem::equals((char*)&before, (char*)input, ScaleEligibilityInput::size));
}

fn Track eligibility_scale_track(Interpolation interpolation, float[] times, float[] values) @local {
    return { .path = TargetPath.SCALE, .interpolation = interpolation, .times = times, .values = values };
}

fn void test_animation_scale_eligibility_step_linear_and_constant_cubic_have_exact_endpoints() @test {
    float[2] times = { 0, 1 };
    float[6] values = { 0.5f, 0.5f, 0.5f, 2, 2, 2 };
    Interpolation[2] modes = { Interpolation.STEP, Interpolation.LINEAR };
    foreach (mode : modes) {
        Track track = eligibility_scale_track(mode, times[..], values[..]);
        AdmittedScaleExtrema extrema = anim::collect_admitted_scale_extrema(&track);
        assert(extrema.minimum.lower == 0.5 && extrema.minimum.upper == 0.5);
        assert(extrema.maximum.lower == 2 && extrema.maximum.upper == 2);
        assert(extrema.smallest_input == 0.5f && !extrema.exhausted);
    }
    float[18] cubic_values = { 0, 0, 0, 2, 2, 2, 0, 0, 0, 0, 0, 0, 2, 2, 2, 0, 0, 0 };
    Track cubic = eligibility_scale_track(Interpolation.CUBIC_SPLINE, times[..], cubic_values[..]);
    AdmittedScaleExtrema constant = anim::collect_admitted_scale_extrema(&cubic);
    assert(constant.minimum.lower == 2 && constant.minimum.upper == 2);
    assert(constant.maximum.lower == 2 && constant.maximum.upper == 2 && !constant.exhausted);
}

fn void test_animation_scale_eligibility_cubic_extrema_enclose_literal_interior_minimum_and_maximum() @test {
    float[2] times = { 0, 1 };
    float[18] values = { 0, 0, 0, 2, 2, 2, -4, -4, -4, 4, 4, 4, 2, 2, 2, 0, 0, 0 };
    Track track = eligibility_scale_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    AdmittedScaleExtrema extrema = anim::collect_admitted_scale_extrema(&track);
    // 2-4u+4u^2 has minimum 1 at 1/2 and endpoint maximum 2.
    assert(extrema.minimum.lower <= 1 && extrema.minimum.upper >= 1);
    assert(extrema.minimum.lower > 1 - 1e-10 && extrema.minimum.upper < 1 + 1e-10);
    assert(extrema.maximum.lower <= 2 && extrema.maximum.upper >= 2);
    assert(extrema.maximum.upper < 2 + 1e-10 && extrema.smallest_input == 2);
    values = { 0, 0, 0, 1, 1, 1, 4, 4, 4, -4, -4, -4, 1, 1, 1, 0, 0, 0 };
    extrema = anim::collect_admitted_scale_extrema(&track);
    // 1+4u-4u^2 has maximum 2 at 1/2 and endpoint minimum 1.
    assert(extrema.minimum.lower <= 1 && extrema.minimum.upper >= 1);
    assert(extrema.maximum.lower <= 2 && extrema.maximum.upper >= 2);
    assert(extrema.maximum.lower > 2 - 1e-10 && extrema.maximum.upper < 2 + 1e-10);
    values = { 0, 0, 0, 0.5f, 0.5f, 0.5f, 1, 1, 1, 2, 2, 2, 2, 2, 2, 0, 0, 0 };
    extrema = anim::collect_admitted_scale_extrema(&track);
    assert(extrema.minimum.lower == 0.5 && extrema.minimum.upper == 0.5);
    assert(extrema.maximum.lower == 2 && extrema.maximum.upper == 2 && !extrema.exhausted);
}

fn void test_animation_scale_eligibility_bounds_the_mean_of_three_components() @test {
    float[2] times = { 0, 1 };
    float[18] values = { 0, 0, 0, 2, 2, 2, -0x1p-17, 0, 0x1p-17,
        0x1p-17, 0, -0x1p-17, 2, 2, 2, 0, 0, 0 };
    Track track = eligibility_scale_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    // The three distinct quadratic components average to the constant 2.
    AdmittedScaleExtrema extrema = anim::collect_admitted_scale_extrema(&track);
    assert(extrema.minimum.lower <= 2 && extrema.minimum.upper >= 2);
    assert(extrema.maximum.lower <= 2 && extrema.maximum.upper >= 2);
    assert(extrema.minimum.lower > 2 - 1e-10 && extrema.maximum.upper < 2 + 1e-10);
    assert(extrema.exhausted);
    AdmittedScaleExtrema[1] regular = { extrema };
    ScaleEligibilityInput input = { .regular = regular[..], .base = { 2, 2, 2 }, .duration = 1 };
    assert(anim::scale_eligibility(&input).result == ScaleEligibilityResult.ADMITTED);
}

fn void test_animation_scale_eligibility_counterexamples_reject_without_input_mutation() @test {
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
        InertialScalarState published = anim::inertial_log_scale(
            source: source,
            target: target,
            duration: 1,
            elapsed: 0.25,
        );
        uint rounded = bitcast((float)published.value, uint);
        assert(rounded == (sign < 0 ? 0u : 0x7f800000u));
        assert(anim::scale_eligibility(&input).result == ScaleEligibilityResult.INVALID_ARGUMENT);
        expect_scale_eligibility_fault(&input, c3d::INVALID_ARGUMENT);
    }
}

fn void test_animation_scale_eligibility_same_histories_accept_shorter_duration_with_exact_formula() @test {
    foreach (double sign : { -1.0, 1.0 }) {
        double duration = 0x1p-6;
        ScaleEligibilityInput input = constant_scale_eligibility(0x1p-100f, sign * 1024, duration);
        ScaleEligibilityProof proof;
        anim::validate_scale_eligibility(&input, &proof)!!;
        assert(proof.result == ScaleEligibilityResult.ADMITTED);
        InertialScalarState source = { .value = 0x1p-100, .rate = sign * 0x1p-90 };
        InertialScalarState target = { .value = 0x1p-100 };
        for (uint sample = 0; sample <= 256; sample++) {
            double elapsed = duration * (double)sample / 256;
            double fraction = elapsed / duration;
            double h1 = (((-3 * fraction + 8) * fraction - 6) * fraction * fraction + 1) * fraction;
            double expected = target.value * math::exp(duration * input.velocity * h1);
            InertialScalarState published = anim::inertial_log_scale(
                source: source,
                target: target,
                duration: duration,
                elapsed: elapsed,
            );
            assert(math::abs(published.value / expected - 1) < 1e-12);
            assert(math::is_finite((float)published.value) && (float)published.value > 0);
            assert(published.value >= proof.published_minimum.lower);
            assert(published.value <= proof.published_maximum.upper);
        }
    }
}

fn void test_animation_scale_eligibility_margin_and_uncertain_cache_are_unsupported() @test {
    ScaleEligibilityInput upper = constant_scale_eligibility(float::max * 0.5f, 0, 1);
    upper.offset = math::ln(2.0);
    expect_scale_eligibility_fault(&upper, c3d::UNSUPPORTED);
    ScaleEligibilityInput lower = constant_scale_eligibility(0x1p-125f, 0, 1);
    lower.offset = -math::ln(2.0);
    expect_scale_eligibility_fault(&lower, c3d::UNSUPPORTED);
    float subnormal = 0x1p-140f;
    ScaleEligibilityInput exact = constant_scale_eligibility(subnormal, 0, 1);
    ScaleEligibilityProof proof = anim::scale_eligibility(&exact);
    assert(proof.result == ScaleEligibilityResult.ADMITTED && proof.exact_correction);
    assert(proof.lower_limit == (double)subnormal);
    AdmittedScaleExtrema[1] uncertain = { {
        .minimum = { .lower = anim::motion_outward_lower(subnormal), .upper = anim::motion_outward_upper(subnormal) },
        .maximum = { .lower = subnormal, .upper = subnormal },
        .smallest_input = subnormal,
        .exhausted = true,
    } };
    exact.regular = uncertain[..];
    proof = anim::scale_eligibility(&exact);
    assert(proof.extrema_exhausted && proof.result == ScaleEligibilityResult.UNSUPPORTED);
    expect_scale_eligibility_fault(&exact, c3d::UNSUPPORTED);
}

fn void test_animation_scale_eligibility_directed_exp_and_extreme_products_match_frozen_gate() @test {
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
        anim::motion_interval_exact(0),
        { .lower = double::max, .upper = double::inf },
    );
    assert(zero.lower == 0 && zero.upper == 0);
}

fn void test_animation_scale_eligibility_cached_domains_and_base_cover_all_convex_controls() @test {
    float[2] times = { 0, 1 };
    float[18] values = { 0, 0, 0, 0.5f, 0.5f, 0.5f, 1, 1, 1, 2, 2, 2, 2, 2, 2, 0, 0, 0 };
    Track track = eligibility_scale_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    AdmittedScaleExtrema[2] regular = {
        anim::collect_admitted_scale_extrema(&track),
        { .minimum = { .lower = 4, .upper = 4 }, .maximum = { .lower = 4, .upper = 4 }, .smallest_input = 4 },
    };
    ScaleEligibilityInput input = {
        .regular = regular[..],
        .base = { 1.5f, 1.5f, 1.5f },
        .offset = math::ln(2.0),
        .velocity = -0.8,
        .duration = 0.25,
    };
    ScaleEligibilityProof proof = anim::scale_eligibility(&input);
    assert(proof.result == ScaleEligibilityResult.ADMITTED);
    double[4] weights = { 0, 0.25, 1, 64 };
    foreach (first : weights) foreach (second : weights) {
        for (uint target_sample = 0; target_sample <= 16; target_sample++) {
            double target_fraction = (double)target_sample / 16;
            double curve = 0.5 + target_fraction + 0.5 * target_fraction * target_fraction;
            double total = first + second;
            double target = (curve * first + 4 * second + 1.5 * math::max(0.0, 1 - total)) / math::max(1.0, total);
            for (uint sample = 0; sample <= 32; sample++) {
                double fraction = (double)sample / 32;
                double h0 = 1 + fraction * fraction * fraction * (-10 + fraction * (15 - 6 * fraction));
                double h1 = (((-3 * fraction + 8) * fraction - 6) * fraction * fraction + 1) * fraction;
                double published = target * math::exp(input.offset * h0 + input.duration * input.velocity * h1);
                assert(published >= proof.published_minimum.lower && published <= proof.published_maximum.upper);
            }
        }
    }
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
    ScaleEligibilityProof proof = anim::scale_eligibility(&input);
    assert(proof.result == ScaleEligibilityResult.ADMITTED);
    assert(proof.target_minimum.lower <= mean && proof.target_minimum.upper >= mean);
    assert(proof.target_maximum.lower <= mean && proof.target_maximum.upper >= mean);
}
