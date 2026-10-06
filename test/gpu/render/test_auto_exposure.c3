module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::render::post @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::io;
import std::math;

const uint EXPOSURE_TARGET_SIZE @private = 32;
const uint EXPOSURE_INVARIANCE_TARGET_SIZE @private = 64;
const float EXPOSURE_TWIN_TOLERANCE @private = 1e-4f; // relative, on the adapted multiplier
const float EXPOSURE_INVARIANCE_TOLERANCE @private = 1e-3f; // per channel, relative above one and absolute below
const float EXPOSURE_CONVERGED_STOPS @private = 0.01f;
const float EXPOSURE_DIM_LUMINANCE @private = 0.2607421875f; // a half float; log2 -1.939 lies inside bin 128
const float EXPOSURE_BRIGHT_LUMINANCE @private = 16 * EXPOSURE_DIM_LUMINANCE; // four stops up: bin 160
const float EXPOSURE_DARK_LUMINANCE @private = 0.0040740966796875f; // a half float; log2 -7.939 lies inside bin 80
const float EXPOSURE_FIREFLY_RADIANCE @private = 60000; // below the half-float maximum of 65504
const float EXPOSURE_FIREFLY_SIZE @private = 0.2f; // about 6 x 6 of 32 x 32 pixels at one unit, inside the top tenth
const float EXPOSURE_LIGHT_STEP @private = 16;
const double EXPOSURE_FRAME_SECONDS @private = 1.0 / 60;
const uint EXPOSURE_SETTLE_FRAMES @private = 3;
const uint EXPOSURE_PATH_FRAMES @private = 128;
const uint EXPOSURE_SPARSE_CADENCE @private = 4;
const uint EXPOSURE_CADENCE_FRAMES @private = 24;
const uint EXPOSURE_DIM_FRAMES @private = 2;

struct ExposureScene @private {
    Fixture* fixture;
    Scene    scene;
    Node*    camera;
}

fn ExposureScene? exposure_create_scene(Fixture* fixture, float background) @private {
    ExposureScene result = { .fixture = fixture };
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_intensity = 0;
    exposure_set_background(&result, background);
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.scene.update_world();
    return result;
}

fn void exposure_set_background(ExposureScene* scene, float luminance) @private {
    scene.scene.background.color = { luminance, luminance, luminance, 1 };
}

fn RenderTargetId? exposure_target(Fixture* fixture, uint size = EXPOSURE_TARGET_SIZE) @private {
    return render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(size, size, PixelFormat.RGBA32_FLOAT),
    );
}

fn ViewDesc exposure_view_desc(RenderTargetId target, AutoExposureParams params) @private {
    ViewDesc desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.post.grade.tonemap = Tonemap.NONE;
    desc.post.auto_exposure = true;
    desc.post.auto_exposure_params = params;
    return desc;
}

fn ViewId? exposure_create_view(Fixture* fixture, AutoExposureParams params) @private {
    RenderTargetId target = exposure_target(fixture)!;
    return render::create_view(&fixture.renderer, exposure_view_desc(target, params));
}

fn void? exposure_render_frame(ExposureScene* scene, ViewId view, double time) @private {
    Renderer* renderer = &scene.fixture.renderer;
    renderer.begin_frame({ .time = time })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&scene.scene, scene.camera, view)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
}

fn double? exposure_render_frames(
    ExposureScene* scene,
    ViewId view,
    double time,
    uint frames,
) @private {
    for (uint frame = 0; frame < frames; frame++, time += EXPOSURE_FRAME_SECONDS) {
        exposure_render_frame(scene, view, time)!;
    }
    return time;
}

fn ExposureGpu? exposure_submitted(Fixture* fixture, ViewId view) @private {
    Renderer* renderer = &fixture.renderer;
    render::wait_frames(renderer)!;
    ViewExposure* exposure = &renderer.views.get(view).auto_exposure;
    gpu::invalidate_mapped_span(&renderer.device, exposure.readback.span)!;
    uint slot = (uint)((renderer.frame_index + render::FRAMES_IN_FLIGHT - 1) % render::FRAMES_IN_FLIGHT);
    return ((ExposureGpu*)exposure.readback.bytes.ptr)[slot];
}

fn MeteredLuminance exposure_constant_meter(float luminance) @private {
    uint per_axis = (EXPOSURE_TARGET_SIZE + shader::EXPOSURE_METER_STRIDE - 1) / shader::EXPOSURE_METER_STRIDE;
    return {
        .log2_mean = post::exposure_bin_log2(post::exposure_bin(luminance)),
        .samples   = per_axis * per_axis,
    };
}

fn bool exposure_matches_twin(ExposureGpu adapted, float twin_ev) @private {
    float expected = math::exp2(twin_ev);
    return math::abs(adapted.scale - expected) <= EXPOSURE_TWIN_TOLERANCE * expected;
}

fn void test_auto_exposure_adapts_as_its_twin() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    ExposureScene scene = exposure_create_scene(&fixture, EXPOSURE_DIM_LUMINANCE)!!;
    defer scene::destroy_scene(&scene.scene);
    AutoExposureParams params = post::AUTO_EXPOSURE_DEFAULT;
    ViewId view = exposure_create_view(&fixture, params)!!;

    double[*] steps = { 0, 1.0 / 30, 1.0 / 144, 0, 1.0 / 60, 0.25, 1.0 / 30, 1.0 / 144, 0.5, 1.0 / 60 };
    float[*] luminances = { EXPOSURE_DIM_LUMINANCE, EXPOSURE_BRIGHT_LUMINANCE, EXPOSURE_DIM_LUMINANCE };
    float[steps.len * luminances.len] scales;
    uint frame;
    double time;
    float twin_ev;
    uint twin_samples;
    foreach (luminance : luminances) {
        exposure_set_background(&scene, luminance);
        foreach (step : steps) {
            time += step;
            exposure_render_frame(&scene, view, time)!!;
            ExposureGpu adapted = exposure_submitted(&fixture, view)!!;
            MeteredLuminance metered = exposure_constant_meter(luminance);
            twin_ev = post::adapt_exposure_ev(
                params:          &params,
                current_ev:      twin_ev,
                current_samples: twin_samples,
                metered:         metered,
                elapsed:         (float)step,
                snap:            frame == 0,
            );
            twin_samples = metered.samples;
            io::eprintfn("frame %d: ev %.6f, twin %.6f", frame, adapted.ev, twin_ev);
            assert(exposure_matches_twin(adapted, twin_ev));
            assert(adapted.samples == metered.samples);
            assert(math::abs(adapted.metered_log2 - metered.log2_mean) < 1e-5f);
            scales[frame] = adapted.scale;
            if (frame >= render::FRAMES_IN_FLIGHT) {
                float delayed = fixture.renderer.view_stats(view)!!.exposure;
                assert(delayed == scales[frame - render::FRAMES_IN_FLIGHT]);
            }
            frame++;
        }
    }
    check_validation(&fixture.renderer);
}

fn void test_auto_exposure_keeps_a_scene_under_sixteen_times_the_light() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ExposureScene lit = exposure_create_scene(&fixture, 0)!!;
    defer scene::destroy_scene(&lit.scene);
    GeometryId plane;
    GeometryId ball;
    @pool() {
        Geometry plane_shape = geometry::plane(tmem, 4, 4);
        Geometry ball_shape = geometry::sphere(tmem, 0.3f);
        plane = fixture.assets.add_geometry(&plane_shape)!!;
        ball = fixture.assets.add_geometry(&ball_shape)!!;
    };
    MaterialId grey = fixture.assets.add_material(material::standard({
        .base_color = { 0.5f, 0.5f, 0.5f, 1 },
        .roughness  = 0.7f,
    }))!!;
    MaterialId lamp = fixture.assets.add_material(material::standard({
        .base_color        = { 0.1f, 0.1f, 0.1f, 1 },
        .roughness         = 0.5f,
        .emissive          = { 1, 0.7f, 0.4f },
        .emissive_strength = 8,
    }))!!;
    Node* floor = lit.scene.add_mesh(plane, grey, name: "floor")!!;
    floor.local.position = { 0, -0.5f, -2 };
    Node* glow = lit.scene.add_mesh(ball, lamp, name: "lamp")!!;
    glow.local.position = { 0.4f, 0, -2 };
    Node* sun = lit.scene.add_light(light::directional({ 1, 1, 1 }, 3, shadow: false), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0.3f, -1, -0.4f }.normalize(), { 0, 1, 0 });
    lit.scene.update_world();

    RenderTargetId target = exposure_target(&fixture, EXPOSURE_INVARIANCE_TARGET_SIZE)!!;
    AutoExposureParams params = { ...post::AUTO_EXPOSURE_DEFAULT, .brightening_time = 0, .darkening_time = 0 };
    ViewDesc desc = exposure_view_desc(target, params);
    desc.post.grade.tonemap = Tonemap.ACES;
    desc.post.bloom = true;
    desc.post.bloom_params.intensity = 0.25f;
    ViewId view = render::create_view(&fixture.renderer, desc)!!;
    fixture.renderer.prepare_scene(&lit.scene)!!;

    double time = exposure_render_frames(
        scene:  &lit,
        view:   view,
        time:   0,
        frames: EXPOSURE_SETTLE_FRAMES,
    )!!;
    ExposureGpu before = exposure_submitted(&fixture, view)!!;
    Vec4[] reference = read_float_target(&fixture, target)!!;
    defer free(reference);
    lit.scene.get(sun, Light).intensity *= EXPOSURE_LIGHT_STEP;
    fixture.assets.material(lamp).data.standard.emissive_strength *= EXPOSURE_LIGHT_STEP;
    fixture.assets.mark_material_dirty(lamp);
    exposure_render_frames(
        scene:  &lit,
        view:   view,
        time:   time,
        frames: EXPOSURE_SETTLE_FRAMES,
    )!!;
    ExposureGpu after = exposure_submitted(&fixture, view)!!;
    Vec4[] brighter = read_float_target(&fixture, target)!!;
    defer free(brighter);

    io::eprintfn("sixteen times the light: ev %.6f -> %.6f", before.ev, after.ev);
    assert(math::abs(after.ev - (before.ev - 4)) < 1e-4f);
    float largest;
    foreach (index, pixel : reference) {
        for (usz channel = 0; channel < 3; channel++) {
            float difference = math::abs(brighter[index][channel] - pixel[channel]);
            largest = math::max(largest, difference);
            assert(difference <= EXPOSURE_INVARIANCE_TOLERANCE * math::max(pixel[channel], 1.0f));
        }
    }
    io::eprintfn("largest channel difference %.6f", largest);
    check_validation(&fixture.renderer);
}

fn void test_path_traced_exposure_settles_on_the_converged_image() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);
    ExposureScene room = exposure_create_scene(&fixture, 0)!!;
    defer scene::destroy_scene(&room.scene);
    GeometryId plane;
    @pool() {
        Geometry plane_shape = geometry::plane(tmem, 4, 4);
        plane = fixture.assets.add_geometry(&plane_shape)!!;
    };
    MaterialId grey = fixture.assets.add_material(material::standard({
        .base_color = { 0.6f, 0.6f, 0.6f, 1 },
        .roughness  = 0.8f,
    }))!!;
    Node* floor = room.scene.add_mesh(plane, grey, name: "floor")!!;
    floor.local.position = { 0, -0.5f, -2 };
    Node* lamp = room.scene.add_light(light::point({ 1, 1, 1 }, 4), name: "lamp")!!;
    lamp.local.position = { 0, 0.5f, -2 };
    room.scene.update_world();

    AutoExposureParams params = { ...post::AUTO_EXPOSURE_DEFAULT, .brightening_time = 0.1f, .darkening_time = 0.1f };
    ViewDesc desc = exposure_view_desc(exposure_target(&fixture)!!, params);
    desc.shading = ShadingPath.PATH_TRACED;
    desc.path_trace = { .max_bounces = 2, .samples_per_frame = 1 };
    ViewId view = render::create_view(&fixture.renderer, desc)!!;
    fixture.renderer.prepare_scene(&room.scene)!!;

    double time = exposure_render_frames(
        scene:  &room,
        view:   view,
        time:   0,
        frames: EXPOSURE_PATH_FRAMES,
    )!!;
    ExposureGpu settled = exposure_submitted(&fixture, view)!!;
    float target_ev = post::exposure_target_ev(&params, settled.metered_log2);
    io::eprintfn("path traced: ev %.5f, converged target %.5f", settled.ev, target_ev);
    assert(fixture.renderer.view_stats(view)!!.accumulated_samples == EXPOSURE_PATH_FRAMES);
    assert(math::abs(settled.ev - target_ev) < EXPOSURE_CONVERGED_STOPS);

    room.camera.local.position.x += 0.05f;
    room.scene.update_world();
    exposure_render_frame(&room, view, time)!!;
    ExposureGpu moved = exposure_submitted(&fixture, view)!!;
    float stepped = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      settled.ev,
        current_samples: settled.samples,
        metered:         { .log2_mean = moved.metered_log2, .samples = moved.samples },
        elapsed:         (float)EXPOSURE_FRAME_SECONDS,
        snap:            false,
    );
    assert(fixture.renderer.view_stats(view)!!.accumulated_samples == 1);
    assert(exposure_matches_twin(moved, stepped));
    check_validation(&fixture.renderer);
}

fn void test_linear_output_records_no_exposure_work() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ExposureScene scene = exposure_create_scene(&fixture, EXPOSURE_DIM_LUMINANCE)!!;
    defer scene::destroy_scene(&scene.scene);
    RenderTargetId target = exposure_target(&fixture)!!;
    uint[2] linear_dispatches;
    uint[2] display_dispatches;
    foreach (enabled, &dispatches : linear_dispatches) {
        ViewDesc linear = render::texture_view_desc(target);
        linear.post.auto_exposure = enabled == 1;
        ViewId linear_view = render::create_view(&fixture.renderer, linear)!!;
        exposure_render_frame(&scene, linear_view, (double)enabled)!!;
        *dispatches = fixture.renderer.stats.post_dispatches;
        ExposureHistory* history = &fixture.renderer.views.get(linear_view).auto_exposure.history;
        assert(!history.valid && !history.pending);
        render::destroy_view(&fixture.renderer, linear_view)!!;

        ViewDesc display = exposure_view_desc(target, post::AUTO_EXPOSURE_DEFAULT);
        display.post.auto_exposure = enabled == 1;
        ViewId display_view = render::create_view(&fixture.renderer, display)!!;
        exposure_render_frame(&scene, display_view, (double)enabled)!!;
        display_dispatches[enabled] = fixture.renderer.stats.post_dispatches;
        render::destroy_view(&fixture.renderer, display_view)!!;
    }
    assert(linear_dispatches[1] == linear_dispatches[0]);
    assert(display_dispatches[1] == display_dispatches[0] + 2);
    check_validation(&fixture.renderer);
}

fn void test_auto_exposure_at_unit_scale_matches_manual_output_with_bloom() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ManualExposureScene manual = manual_exposure_create_scene(&fixture)!!;
    defer scene::destroy_scene(&manual.scene);
    RenderTargetId target = exposure_target(&fixture, EXPOSURE_INVARIANCE_TARGET_SIZE)!!;
    ViewDesc desc = manual_exposure_view_desc(target);
    ViewId view = render::create_view(&fixture.renderer, desc)!!;
    manual_exposure_render_frame(&fixture, &manual, view)!!;
    Vec4[] reference = read_float_target(&fixture, target)!!;
    defer free(reference);

    desc.post.auto_exposure = true;
    desc.post.auto_exposure_params = { ...post::AUTO_EXPOSURE_DEFAULT, .min_ev = 0, .max_ev = 0 };
    render::configure_view(&fixture.renderer, view, desc)!!;
    manual_exposure_render_frame(&fixture, &manual, view)!!;
    assert(exposure_submitted(&fixture, view)!!.scale == 1);
    Vec4[] unit = read_float_target(&fixture, target)!!;
    defer free(unit);
    foreach (index, pixel : reference) assert(unit[index] == pixel);
    check_validation(&fixture.renderer);
}

fn void test_narrowed_max_ev_bounds_the_next_exposure() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ExposureScene scene = exposure_create_scene(&fixture, EXPOSURE_DARK_LUMINANCE)!!;
    defer scene::destroy_scene(&scene.scene);
    ViewDesc desc = exposure_view_desc(exposure_target(&fixture)!!, post::AUTO_EXPOSURE_DEFAULT);
    ViewId view = render::create_view(&fixture.renderer, desc)!!;
    exposure_render_frame(&scene, view, 0)!!;
    assert(exposure_submitted(&fixture, view)!!.ev > 5);

    desc.post.auto_exposure_params.max_ev = 2;
    render::configure_view(&fixture.renderer, view, desc)!!;
    assert(fixture.renderer.views.get(view).auto_exposure.history.valid);
    exposure_render_frame(&scene, view, EXPOSURE_FRAME_SECONDS)!!;
    assert(exposure_submitted(&fixture, view)!!.ev == 2);
    check_validation(&fixture.renderer);
}

fn void test_views_of_one_camera_adapt_exposure_independently() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ExposureScene scene = exposure_create_scene(&fixture, EXPOSURE_DIM_LUMINANCE)!!;
    defer scene::destroy_scene(&scene.scene);
    AutoExposureParams every_params = post::AUTO_EXPOSURE_DEFAULT;
    AutoExposureParams sparse_params = { ...post::AUTO_EXPOSURE_DEFAULT, .compensation_ev = 2 };
    ViewId every = exposure_create_view(&fixture, every_params)!!;
    ViewId sparse = exposure_create_view(&fixture, sparse_params)!!;
    Renderer* renderer = &fixture.renderer;

    float every_ev;
    float sparse_ev;
    uint every_samples;
    uint sparse_samples;
    double sparse_time;
    for (uint frame = 0; frame < EXPOSURE_CADENCE_FRAMES; frame++) {
        double time = frame * EXPOSURE_FRAME_SECONDS;
        bool sparse_frame = frame % EXPOSURE_SPARSE_CADENCE == 0;
        float luminance = frame < EXPOSURE_DIM_FRAMES ? EXPOSURE_DIM_LUMINANCE : EXPOSURE_BRIGHT_LUMINANCE;
        exposure_set_background(&scene, luminance);
        renderer.begin_frame({ .time = time })!!;
        renderer.render_view(&scene.scene, scene.camera, every)!!;
        renderer.finish_view(every)!!;
        if (sparse_frame) {
            renderer.render_view(&scene.scene, scene.camera, sparse)!!;
            renderer.finish_view(sparse)!!;
        }
        renderer.end_frame()!!;

        every_ev = post::adapt_exposure_ev(
            params:          &every_params,
            current_ev:      every_ev,
            current_samples: every_samples,
            metered:         exposure_constant_meter(luminance),
            elapsed:         (float)EXPOSURE_FRAME_SECONDS,
            snap:            frame == 0,
        );
        every_samples = exposure_constant_meter(luminance).samples;
        assert(exposure_matches_twin(exposure_submitted(&fixture, every)!!, every_ev));
        if (!sparse_frame) continue;
        sparse_ev = post::adapt_exposure_ev(
            params:          &sparse_params,
            current_ev:      sparse_ev,
            current_samples: sparse_samples,
            metered:         exposure_constant_meter(luminance),
            elapsed:         (float)(time - sparse_time),
            snap:            frame == 0,
        );
        sparse_time = time;
        sparse_samples = exposure_constant_meter(luminance).samples;
        assert(exposure_matches_twin(exposure_submitted(&fixture, sparse)!!, sparse_ev));
    }
    ExposureHistory kept = renderer.views.get(sparse).auto_exposure.history;
    render::reset_view_history(renderer, every)!!;
    ExposureHistory* after = &renderer.views.get(sparse).auto_exposure.history;
    assert(after.valid && after.slot == kept.slot && after.time == kept.time);
    check_validation(renderer);
}

fn void test_aborted_frame_leaves_adapted_exposure_unchanged() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ExposureScene scene = exposure_create_scene(&fixture, EXPOSURE_DIM_LUMINANCE)!!;
    defer scene::destroy_scene(&scene.scene);
    AutoExposureParams params = post::AUTO_EXPOSURE_DEFAULT;
    ViewId view = exposure_create_view(&fixture, params)!!;
    double time = exposure_render_frames(
        scene:  &scene,
        view:   view,
        time:   0,
        frames: EXPOSURE_SETTLE_FRAMES,
    )!!;
    ExposureGpu committed = exposure_submitted(&fixture, view)!!;
    Renderer* renderer = &fixture.renderer;
    ExposureHistory before = renderer.views.get(view).auto_exposure.history;

    exposure_set_background(&scene, EXPOSURE_BRIGHT_LUMINANCE);
    renderer.begin_frame({ .time = time })!!;
    renderer.render_view(&scene.scene, scene.camera, view)!!;
    renderer.finish_view(view)!!;
    render::abort_frame(renderer);
    ViewExposure* exposure = &renderer.views.get(view).auto_exposure;
    assert(!exposure.history.pending && exposure.history.valid);
    assert(exposure.history.slot == before.slot && exposure.history.time == before.time);
    assert(!exposure.readback_pending[renderer.recording_slot]);

    exposure_render_frame(&scene, view, time + EXPOSURE_FRAME_SECONDS)!!;
    float expected = post::adapt_exposure_ev(
        params:          &params,
        current_ev:      committed.ev,
        current_samples: committed.samples,
        metered:         exposure_constant_meter(EXPOSURE_BRIGHT_LUMINANCE),
        elapsed:         (float)(time + EXPOSURE_FRAME_SECONDS - before.time),
        snap:            false,
    );
    assert(exposure_matches_twin(exposure_submitted(&fixture, view)!!, expected));
    check_validation(renderer);
}

fn void test_black_frames_and_isolated_bright_pixels_keep_exposure_finite() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ExposureScene scene = exposure_create_scene(&fixture, EXPOSURE_DIM_LUMINANCE)!!;
    defer scene::destroy_scene(&scene.scene);
    ViewId view = exposure_create_view(&fixture, post::AUTO_EXPOSURE_DEFAULT)!!;
    exposure_render_frame(&scene, view, 0)!!;
    ExposureGpu dim = exposure_submitted(&fixture, view)!!;

    exposure_set_background(&scene, 0);
    exposure_render_frame(&scene, view, EXPOSURE_FRAME_SECONDS)!!;
    ExposureGpu black = exposure_submitted(&fixture, view)!!;
    assert(black.samples == dim.samples && black.metered_log2 == dim.metered_log2);
    assert(black.ev == dim.ev && math::is_finite(black.scale));

    exposure_set_background(&scene, EXPOSURE_DIM_LUMINANCE);
    GeometryId quad;
    @pool() {
        Geometry quad_shape = geometry::plane(tmem, EXPOSURE_FIREFLY_SIZE, EXPOSURE_FIREFLY_SIZE);
        quad = fixture.assets.add_geometry(&quad_shape)!!;
    };
    MaterialId hot = fixture.assets.add_material(material::basic({
        .color = { EXPOSURE_FIREFLY_RADIANCE, EXPOSURE_FIREFLY_RADIANCE, EXPOSURE_FIREFLY_RADIANCE, 1 },
    }))!!;
    Node* firefly = scene.scene.add_mesh(quad, hot, name: "firefly")!!;
    firefly.local.position = { 0, 0, -1 };
    firefly.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::PI / 2);
    scene.scene.update_world();
    fixture.renderer.prepare_scene(&scene.scene)!!;
    exposure_render_frame(&scene, view, 2 * EXPOSURE_FRAME_SECONDS)!!;
    ExposureGpu speckled = exposure_submitted(&fixture, view)!!;
    io::eprintfn("fireflies: metered %.6f, dim %.6f", speckled.metered_log2, dim.metered_log2);
    assert(speckled.samples == dim.samples);
    assert(math::abs(speckled.metered_log2 - dim.metered_log2) < 1e-6f);
    assert(math::is_finite(speckled.ev) && math::is_finite(speckled.scale));
    check_validation(&fixture.renderer);
}

fn void test_exposure_state_lives_with_the_view() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    RenderTargetId target = exposure_target(&fixture)!!;
    gpu::Device* device = &fixture.renderer.device;
    ulong baseline = gpu::get_memory_stats(device)!!.live_allocation_count;
    ViewDesc desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    ViewId view = render::create_view(&fixture.renderer, desc)!!;
    assert(fixture.renderer.views.get(view).auto_exposure.allocation.is_valid());
    ulong created = gpu::get_memory_stats(device)!!.live_allocation_count;

    desc.post.auto_exposure = true;
    render::configure_view(&fixture.renderer, view, desc)!!;
    desc.post.auto_exposure = false;
    render::configure_view(&fixture.renderer, view, desc)!!;
    assert(gpu::get_memory_stats(device)!!.live_allocation_count == created);

    render::destroy_view(&fixture.renderer, view)!!;
    assert(gpu::get_memory_stats(device)!!.live_allocation_count == baseline);
    check_validation(&fixture.renderer);
}

fn void test_exposure_cut_into_black_snaps_on_the_first_lit_frame() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ExposureScene scene = exposure_create_scene(&fixture, EXPOSURE_DIM_LUMINANCE)!!;
    defer scene::destroy_scene(&scene.scene);
    AutoExposureParams params = post::AUTO_EXPOSURE_DEFAULT;
    ViewId view = exposure_create_view(&fixture, params)!!;
    exposure_render_frame(&scene, view, 0)!!;

    render::reset_view_history(&fixture.renderer, view)!!;
    exposure_set_background(&scene, 0);
    exposure_render_frame(&scene, view, EXPOSURE_FRAME_SECONDS)!!;
    ExposureGpu black = exposure_submitted(&fixture, view)!!;
    assert(black.samples == 0 && black.ev == 0);

    exposure_set_background(&scene, EXPOSURE_DARK_LUMINANCE);
    exposure_render_frame(&scene, view, 2 * EXPOSURE_FRAME_SECONDS)!!;
    ExposureGpu lit = exposure_submitted(&fixture, view)!!;
    float target = post::exposure_target_ev(&params, exposure_constant_meter(EXPOSURE_DARK_LUMINANCE).log2_mean);
    io::eprintfn("cut into black: lit ev %.6f, target %.6f", lit.ev, target);
    assert(math::abs(lit.ev - target) < 1e-5f);
    check_validation(&fixture.renderer);
}
