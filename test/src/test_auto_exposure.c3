module c3d::test::auto_exposure;

import c3d;
import c3d::pool;
import c3d::render @public;
import c3d::render::post;
import c3d::shader;
import gpu;
import std::math;

const float STOP_TOLERANCE @local = 1e-5f;
const ulong SCENE @local = 7;
const ulong OTHER_SCENE @local = 8;
const ExposureHistory COMMITTED @local = { .valid = true, .slot = 1, .time = 3, .scene = SCENE };

struct ExposureViews @local {
    Renderer*      renderer;
    ViewId         window;
    ViewId         texture;
    RenderTargetId target;
}

fn ExposureViews create_exposure_views() @local {
    Renderer* renderer = mem::new(Renderer);
    renderer.views = pool::create_pool{ViewRecord, ViewId}(mem, 2);
    renderer.targets = pool::create_pool{TargetRecord, RenderTargetId}(mem, 1);
    RenderTargetId target = renderer.targets.add({ .format = PixelFormat.RGBA16_FLOAT })!!;
    ViewDesc window = render::default_view_desc();
    window.post.auto_exposure = true;
    ViewDesc texture = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    texture.post.auto_exposure = true;
    ExposureViews views = {
        .renderer = renderer,
        .window   = renderer.views.add({ .live = true, .desc = window })!!,
        .texture  = renderer.views.add({ .live = true, .desc = texture })!!,
        .target   = target,
    };
    *history_of(&views, views.window) = COMMITTED;
    *history_of(&views, views.texture) = COMMITTED;
    return views;
}

fn void destroy_exposure_views(ExposureViews* views) @local {
    pool::destroy_pool{TargetRecord, RenderTargetId}(&views.renderer.targets);
    pool::destroy_pool{ViewRecord, ViewId}(&views.renderer.views);
    free(views.renderer);
}

fn ExposureHistory* history_of(ExposureViews* views, ViewId view) @local {
    return &views.renderer.views.get(view).auto_exposure.history;
}

fn bool kept(ExposureHistory* history) @local {
    return history.valid && history.slot == COMMITTED.slot && history.time == COMMITTED.time
        && history.scene == COMMITTED.scene;
}

fn MeteredLuminance metered(float log2_mean) @local {
    return { .log2_mean = log2_mean, .samples = 1 };
}

fn float mean_for_target(float target_ev) @local => math::log2(post::MID_GRAY) - target_ev;

fn float adapt_at_rate(
    AutoExposureParams* params,
    MeteredLuminance scene,
    float seconds,
    uint rate,
) @local {
    float elapsed = 1.0f / (float)rate;
    uint frames = (uint)math::round(seconds * (float)rate);
    float ev = 0;
    for (uint frame = 0; frame < frames; frame++) {
        ev = post::adapt_exposure_ev(
            params:          params,
            current_ev:      ev,
            current_samples: 1,
            metered:         scene,
            elapsed:         elapsed,
            snap:            false,
        );
    }
    return ev;
}

fn void test_default_post_stack_keeps_auto_exposure_off() @test {
    PostStack stack = post::default_post_stack();
    assert(!stack.auto_exposure);
    stack.auto_exposure = true;
    assert(post::post_stack_valid(&stack));
}

fn void test_auto_exposure_params_are_validated_only_when_enabled() @test {
    PostStack stack = post::default_post_stack();
    stack.auto_exposure_params.min_ev = 3;
    stack.auto_exposure_params.max_ev = 2;
    assert(post::post_stack_valid(&stack));
    stack.auto_exposure = true;
    assert(!post::post_stack_valid(&stack));

    AutoExposureParams[*] rejected = {
        { ...post::AUTO_EXPOSURE_DEFAULT, .compensation_ev = float::nan },
        { ...post::AUTO_EXPOSURE_DEFAULT, .max_ev = float::inf },
        { ...post::AUTO_EXPOSURE_DEFAULT, .brightening_time = -0.1f },
        { ...post::AUTO_EXPOSURE_DEFAULT, .darkening_time = -0.1f },
        { ...post::AUTO_EXPOSURE_DEFAULT, .low_percentile = -0.1f },
        { ...post::AUTO_EXPOSURE_DEFAULT, .low_percentile = 0.5f, .high_percentile = 0.5f },
        { ...post::AUTO_EXPOSURE_DEFAULT, .high_percentile = 1.1f },
        { ...post::AUTO_EXPOSURE_DEFAULT, .compensation_ev = -6 },
        { ...post::AUTO_EXPOSURE_DEFAULT, .compensation_ev = 7 },
    };
    foreach (params : rejected) {
        stack.auto_exposure_params = params;
        assert(!post::post_stack_valid(&stack));
    }
    AutoExposureParams[*] accepted = {
        { ...post::AUTO_EXPOSURE_DEFAULT, .brightening_time = 0, .darkening_time = 0 },
        { ...post::AUTO_EXPOSURE_DEFAULT, .low_percentile = 0, .high_percentile = 1 },
        { ...post::AUTO_EXPOSURE_DEFAULT, .min_ev = 2, .max_ev = 2 },
        { ...post::AUTO_EXPOSURE_DEFAULT, .compensation_ev = -5.5f },
        { ...post::AUTO_EXPOSURE_DEFAULT, .compensation_ev = 6.4f },
    };
    foreach (params : accepted) {
        stack.auto_exposure_params = params;
        assert(post::post_stack_valid(&stack));
    }

    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    ViewDesc desc = render::default_view_desc();
    desc.post = stack;
    desc.post.auto_exposure_params.compensation_ev = 7;
    fault excuse = @catch(render::validate_view_desc(renderer, &desc));
    assert(excuse == c3d::INVALID_ARGUMENT);
}

fn void test_histogram_excludes_black_nan_and_infinity_and_clamps_the_rest() @test {
    float epsilon = shader::EXPOSURE_LUMINANCE_EPSILON;
    float[*] excluded = { 0, -1, float::nan, float::inf, -float::inf, epsilon * 0.5f };
    foreach (luminance : excluded) assert(!post::exposure_metered(luminance));
    assert(post::exposure_metered(epsilon) && post::exposure_metered(float::max));

    assert(post::exposure_bin(epsilon) == 0);
    assert(post::exposure_bin(math::exp2(shader::EXPOSURE_LOG2_MIN)) == 0);
    assert(post::exposure_bin(1) == 144);
    assert(post::exposure_bin(math::exp2(shader::EXPOSURE_LOG2_MAX)) == shader::EXPOSURE_HISTOGRAM_BINS - 1);
    assert(post::exposure_bin(float::max) == shader::EXPOSURE_HISTOGRAM_BINS - 1);
    assert(post::exposure_bin_log2(144) == 0.0625f);
}

fn void test_sixteen_times_brighter_moves_every_bin_by_thirty_two() @test {
    float[*] luminances = { 1e-4f, 0.0040740967f, 0.18f, 0.26074219f, 3.7f };
    foreach (luminance : luminances) {
        assert(post::exposure_bin(16 * luminance) == post::exposure_bin(luminance) + 32);
    }
}

fn void test_histogram_mean_drops_the_darkest_and_brightest_tenth() @test {
    uint[shader::EXPOSURE_HISTOGRAM_BINS] bins;
    bins[0] = 50;
    bins[100] = 900;
    bins[255] = 50;
    MeteredLuminance mean = post::meter_histogram(bins[..], 0.1f, 0.9f);
    assert(mean.samples == 1000);
    assert(mean.log2_mean == post::exposure_bin_log2(100));
}

fn void test_histogram_mean_weighs_the_bins_the_window_overlaps() @test {
    uint[shader::EXPOSURE_HISTOGRAM_BINS] bins;
    bins[10] = 500;
    bins[20] = 300;
    bins[30] = 200;
    MeteredLuminance mean = post::meter_histogram(bins[..], 0.1f, 0.9f);
    float expected = (400 * post::exposure_bin_log2(10) + 300 * post::exposure_bin_log2(20)
      + 100 * post::exposure_bin_log2(30)) / 800;
    assert(math::abs(mean.log2_mean - expected) < STOP_TOLERANCE);
}

fn void test_empty_histogram_meters_no_samples() @test {
    uint[shader::EXPOSURE_HISTOGRAM_BINS] bins;
    MeteredLuminance mean = post::meter_histogram(bins[..], 0.1f, 0.9f);
    assert(mean.samples == 0 && mean.log2_mean == 0);
}

fn void test_exposure_target_brings_the_mean_to_mid_gray_inside_the_bounds() @test {
    AutoExposureParams params = post::AUTO_EXPOSURE_DEFAULT;
    assert(math::abs(post::exposure_target_ev(&params, mean_for_target(3)) - 3) < STOP_TOLERANCE);
    params.compensation_ev = 2;
    assert(math::abs(post::exposure_target_ev(&params, mean_for_target(3)) - 5) < STOP_TOLERANCE);
    params.max_ev = 4;
    assert(post::exposure_target_ev(&params, mean_for_target(3)) == 4);
    params.compensation_ev = -2;
    params.min_ev = 2;
    assert(post::exposure_target_ev(&params, mean_for_target(3)) == 2);
}

fn void test_adaptation_agrees_across_frame_rates() @test {
    AutoExposureParams params = post::AUTO_EXPOSURE_DEFAULT;
    MeteredLuminance brighter = metered(mean_for_target(-4));
    float target = post::exposure_target_ev(&params, brighter.log2_mean);
    float expected = target - target * math::exp(-2.0f / params.brightening_time);
    uint[*] rates = { 30, 60, 144 };
    foreach (rate : rates) {
        float ev = adapt_at_rate(
            params:  &params,
            scene:   brighter,
            seconds: 2,
            rate:    rate,
        );
        assert(math::abs(ev - expected) < STOP_TOLERANCE, "%d Hz ends at %f, expected %f", rate, ev, expected);
    }
}

fn void test_adaptation_never_overshoots_and_a_long_gap_lands_on_target() @test {
    AutoExposureParams params = post::AUTO_EXPOSURE_DEFAULT;
    MeteredLuminance brighter = metered(mean_for_target(-4));
    float target = post::exposure_target_ev(&params, brighter.log2_mean);
    float[*] gaps = { 1e-6f, 1e-3f, 0.1f, 1, 10, 1e4f, 1e30f, float::max };
    foreach (gap : gaps) {
        float ev = post::adapt_exposure_ev(
            params:          &params,
            current_ev:      3,
            current_samples: 1,
            metered:         brighter,
            elapsed:         gap,
            snap:            false,
        );
        assert(ev >= target && ev <= 3);
    }
    float landed = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      3,
        current_samples: 1,
        metered:         brighter,
        elapsed:         1e30f,
        snap:            false,
    );
    assert(landed == target);
}

fn void test_brighter_scene_uses_brightening_time() @test {
    AutoExposureParams params = post::AUTO_EXPOSURE_DEFAULT;
    float elapsed = 0.1f;
    MeteredLuminance brighter = metered(mean_for_target(-4));
    float down = post::exposure_target_ev(&params, brighter.log2_mean);
    float fallen = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      0,
        current_samples: 1,
        metered:         brighter,
        elapsed:         elapsed,
        snap:            false,
    );
    assert(math::abs(fallen - down * (1 - math::exp(-elapsed / params.brightening_time))) < STOP_TOLERANCE);

    MeteredLuminance darker = metered(mean_for_target(4));
    float up = post::exposure_target_ev(&params, darker.log2_mean);
    float risen = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      0,
        current_samples: 1,
        metered:         darker,
        elapsed:         elapsed,
        snap:            false,
    );
    assert(math::abs(risen - up * (1 - math::exp(-elapsed / params.darkening_time))) < STOP_TOLERANCE);
    assert(-fallen > 2 * risen);
}

fn void test_target_crossing_switches_time_constant_without_overshoot() @test {
    AutoExposureParams params = post::AUTO_EXPOSURE_DEFAULT;
    float elapsed = 0.25f;
    MeteredLuminance darker = metered(mean_for_target(4));
    MeteredLuminance brighter = metered(mean_for_target(-4));
    float risen = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      0,
        current_samples: 1,
        metered:         darker,
        elapsed:         elapsed,
        snap:            false,
    );
    float fallen = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      risen,
        current_samples: 1,
        metered:         brighter,
        elapsed:         elapsed,
        snap:            false,
    );
    float target = post::exposure_target_ev(&params, brighter.log2_mean);
    float expected = target + (risen - target) * math::exp(-elapsed / params.brightening_time);
    assert(risen > 0 && risen < 4);
    assert(fallen >= target && fallen < risen);
    assert(math::abs(fallen - expected) < STOP_TOLERANCE);
}

fn void test_zero_time_lands_on_target_at_any_elapsed_time() @test {
    AutoExposureParams params = { ...post::AUTO_EXPOSURE_DEFAULT, .brightening_time = 0, .darkening_time = 0 };
    MeteredLuminance darker = metered(mean_for_target(4));
    float target = post::exposure_target_ev(&params, darker.log2_mean);
    float[*] gaps = { 1.0f / 60, 0, -1 };
    foreach (gap : gaps) {
        float ev = post::adapt_exposure_ev(
            params:          &params,
            current_ev:      -1,
            current_samples: 1,
            metered:         darker,
            elapsed:         gap,
            snap:            false,
        );
        assert(ev == target);
    }
}

fn void test_snap_without_samples_stays_pending() @test {
    AutoExposureParams params = post::AUTO_EXPOSURE_DEFAULT;
    MeteredLuminance black;
    MeteredLuminance darker = metered(mean_for_target(4));
    float blank = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      3,
        current_samples: 1,
        metered:         black,
        elapsed:         0,
        snap:            true,
    );
    assert(blank == 0);
    float lit = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      blank,
        current_samples: 0,
        metered:         darker,
        elapsed:         1.0f / 60,
        snap:            false,
    );
    assert(lit == post::exposure_target_ev(&params, darker.log2_mean));
    float stepped = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      blank,
        current_samples: 1,
        metered:         darker,
        elapsed:         1.0f / 60,
        snap:            false,
    );
    assert(stepped > blank && stepped < lit);
}

fn void test_empty_frame_holds_exposure() @test {
    AutoExposureParams params = { ...post::AUTO_EXPOSURE_DEFAULT, .min_ev = 1, .max_ev = 5 };
    MeteredLuminance black;
    float held = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      3,
        current_samples: 1,
        metered:         black,
        elapsed:         0.5f,
        snap:            false,
    );
    assert(held == 3);
    float fresh = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      3,
        current_samples: 1,
        metered:         black,
        elapsed:         0.5f,
        snap:            true,
    );
    assert(fresh == 1);
}

fn void test_narrowed_bounds_clamp_the_committed_exposure() @test {
    AutoExposureParams params = { ...post::AUTO_EXPOSURE_DEFAULT, .max_ev = 1 };
    MeteredLuminance darker = metered(mean_for_target(4));
    float[*] gaps = { 0, 1.0f / 60, 10 };
    foreach (gap : gaps) {
        float ev = post::adapt_exposure_ev(
            params:          &params,
            current_ev:      3,
            current_samples: 1,
            metered:         darker,
            elapsed:         gap,
            snap:            false,
        );
        assert(ev == 1);
    }
}

fn void test_snap_repeats_while_time_stands_still() @test {
    AutoExposureParams params = post::AUTO_EXPOSURE_DEFAULT;
    ExposureHistory history;
    float ev;
    float[*] targets = { 2, -1, 0.5f, 3 };
    foreach (target : targets) {
        ExposureStep step = history.commit(0, SCENE);
        assert(step.snap);
        ev = post::adapt_exposure_ev(
            params:          &params,
            current_ev:      ev,
            current_samples: 1,
            metered:         metered(mean_for_target(target)),
            elapsed:         step.elapsed,
            snap:            step.snap,
        );
        history.publish();
    }
    assert(math::abs(ev - 3) < STOP_TOLERANCE);
    assert(history.valid && history.snapped);
}

fn void test_only_the_first_rendering_snaps_when_time_advances() @test {
    ExposureHistory history;
    assert(history.commit(0, SCENE).snap);
    history.publish();
    ExposureStep second = history.commit(1.0 / 60, SCENE);
    assert(!second.snap && math::abs(second.elapsed - 1.0f / 60) < 1e-7f);
    history.publish();
    assert(!history.snapped);
    ExposureStep still = history.commit(1.0 / 60, SCENE);
    assert(!still.snap && still.elapsed == 0);
}

fn void test_parameter_changes_keep_exposure_history() @test {
    ExposureViews views = create_exposure_views();
    defer destroy_exposure_views(&views);
    ViewDesc desc = views.renderer.views.get(views.window).desc;
    desc.post.auto_exposure_params.compensation_ev = 1;
    desc.post.auto_exposure_params.max_ev = 4;
    render::configure_view(views.renderer, views.window, desc)!!;
    assert(kept(history_of(&views, views.window)));
}

fn void test_resize_keeps_exposure_history() @test {
    ExposureViews views = create_exposure_views();
    defer destroy_exposure_views(&views);
    render::resize_view(views.renderer, views.renderer.views.get(views.window))!!;
    assert(kept(history_of(&views, views.window)));
}

fn void test_camera_cut_invalidates_exposure_history() @test {
    ExposureViews views = create_exposure_views();
    defer destroy_exposure_views(&views);
    render::reset_view_history(views.renderer, views.window)!!;
    ExposureHistory* history = history_of(&views, views.window);
    assert(!history.valid && history.time == 0);
    ExposureStep step = history.commit(5, SCENE);
    assert(step.snap && step.elapsed == 0);
}

fn void test_scene_change_snaps_exposure() @test {
    ExposureHistory history = COMMITTED;
    ExposureStep step = history.commit(4, OTHER_SCENE);
    assert(step.snap && step.elapsed == 0);
    assert(history.scene == SCENE && history.time == 3);
    history.publish();
    assert(history.scene == OTHER_SCENE && history.snapped);
}

fn void test_enabling_auto_exposure_invalidates_history() @test {
    ExposureViews views = create_exposure_views();
    defer destroy_exposure_views(&views);
    ViewDesc desc = views.renderer.views.get(views.window).desc;
    desc.post.auto_exposure = false;
    render::configure_view(views.renderer, views.window, desc)!!;
    assert(kept(history_of(&views, views.window)));
    desc.post.auto_exposure = true;
    render::configure_view(views.renderer, views.window, desc)!!;
    ExposureHistory* history = history_of(&views, views.window);
    assert(!history.valid && history.time == 0);

    *history = COMMITTED;
    desc.post.anti_aliasing = AntiAliasing.TAA;
    desc.post.taa_params.debug = TaaDebug.VELOCITY;
    render::configure_view(views.renderer, views.window, desc)!!;
    assert(kept(history) && !post::auto_exposure_active(&desc));
    desc.post.taa_params.debug = TaaDebug.NONE;
    render::configure_view(views.renderer, views.window, desc)!!;
    assert(!history.valid);
}

fn void test_disabling_auto_exposure_keeps_history() @test {
    ExposureViews views = create_exposure_views();
    defer destroy_exposure_views(&views);
    ViewExposure* exposure = &views.renderer.views.get(views.window).auto_exposure;
    exposure.readback_pending = { true, true };
    ViewDesc desc = views.renderer.views.get(views.window).desc;
    desc.post.auto_exposure = false;
    render::configure_view(views.renderer, views.window, desc)!!;
    assert(kept(history_of(&views, views.window)));
    assert(!exposure.readback_pending[0] && !exposure.readback_pending[1]);
}

fn void test_switch_to_display_output_with_auto_exposure_invalidates_history() @test {
    ExposureViews views = create_exposure_views();
    defer destroy_exposure_views(&views);
    ViewDesc desc = views.renderer.views.get(views.texture).desc;
    desc.color = OutputMode.LINEAR_HDR;
    render::configure_view(views.renderer, views.texture, desc)!!;
    desc.color = OutputMode.DISPLAY_LDR;
    render::configure_view(views.renderer, views.texture, desc)!!;
    assert(!history_of(&views, views.texture).valid);
}

fn void test_switch_to_linear_output_keeps_history() @test {
    ExposureViews views = create_exposure_views();
    defer destroy_exposure_views(&views);
    ViewDesc desc = views.renderer.views.get(views.texture).desc;
    desc.color = OutputMode.LINEAR_HDR;
    render::configure_view(views.renderer, views.texture, desc)!!;
    assert(kept(history_of(&views, views.texture)));
    assert(!post::auto_exposure_active(&views.renderer.views.get(views.texture).desc));
}

fn void test_abort_leaves_committed_exposure_unchanged() @test {
    ExposureHistory history = COMMITTED;
    history.commit(4, SCENE);
    history.discard();
    assert(kept(&history) && !history.pending);
    ExposureStep next = history.commit(5, SCENE);
    assert(next.read_slot == COMMITTED.slot && next.write_slot != COMMITTED.slot);
    assert(!next.snap && next.elapsed == 2);
}

fn void test_skipped_renderings_fold_their_time_into_the_next_step() @test {
    ExposureHistory history = COMMITTED;
    ExposureStep step = history.commit(7.5, SCENE);
    assert(!step.snap && step.elapsed == 4.5f);
}

fn void test_two_renderings_in_one_frame_publish_one_flip() @test {
    ExposureHistory history = COMMITTED;
    ExposureStep first = history.commit(4, SCENE);
    ExposureStep second = history.commit(4, SCENE);
    assert(first.read_slot == second.read_slot && first.write_slot == second.write_slot);
    assert(first.elapsed == second.elapsed);
    history.publish();
    assert(history.slot == first.write_slot && history.time == 4);
    history.publish();
    assert(history.slot == first.write_slot);
}

fn void test_view_not_rendered_changes_nothing() @test {
    ExposureHistory history = COMMITTED;
    history.publish();
    history.discard();
    assert(kept(&history) && !history.pending);
}

fn void test_views_of_one_camera_keep_separate_exposure_history() @test {
    ExposureViews views = create_exposure_views();
    defer destroy_exposure_views(&views);
    render::reset_view_history(views.renderer, views.window)!!;
    assert(!history_of(&views, views.window).valid);
    assert(kept(history_of(&views, views.texture)));
}
