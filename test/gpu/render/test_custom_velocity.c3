module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::io::file;
import std::math;

const char[*] WAVE_SOURCE @private = $embed("wave.vert.glsl");
const char[*] BROKEN_PUSH_SOURCE @private = $embed("broken_push.vert.glsl");
const float PULSE_AMPLITUDE @private = 0.25f; // keeps the centre ray on the unit box's front face
const float PULSE_RATE @private = 4; // radians per second
const double TIME_STEP @private = 0.1;
const float MIN_VELOCITY_STEPS @private = 4; // well above the channel tolerance of one step
const Vec4 NEUTRAL_VELOCITY @private = { 0.5f, 0.5f, 0, 1 };
const float WAVE_AMPLITUDE @private = 0.25f; // 0.1 in world at the line's 0.4 scale, within an instance's half height
const float WAVE_RATE @private = 8; // radians per second
const float WAVE_INSTANCE_PHASE @private = 0.7f; // radians per source index
const float GLASS_STEP @private = 0.1f; // three steps stay inside the unit box's half width
const double OTHER_VIEW_TIME @private = 0.5; // only the second view renders at this time
const double RETURN_TIME @private = 0.6; // far enough from the other view's time to tell the two apart
const double FROZEN_TIME @private = 0.3;

fn String? load_pulse_vertex() @private {
    return (String)file::load(tmem, repository_path(PULSE_VERTEX))!;
}

fn char[]? compile_vertex_stage(Fixture* fixture, String source, String[] defines = {}) @private {
    return compile::compile_glsl(
        allocator: fixture.allocator,
        source:    source,
        stage:     ShaderStage.VERTEX,
        defines:   defines,
    );
}

fn CustomVertex? compile_vertex_forms(
    Fixture* fixture,
    String source,
    bool instanced,
    String velocity_source,
) @private {
    String[1] depth_only = { "DEPTH_ONLY" };
    String[1] velocity_only = { "VELOCITY" };
    String[1] instanced_only = { "INSTANCED" };
    String[2] instanced_depth = { "DEPTH_ONLY", "INSTANCED" };
    String[2] instanced_velocity = { "VELOCITY", "INSTANCED" };
    CustomVertex forms;
    defer catch free_vertex_forms(fixture, forms);
    forms.shaded = compile_vertex_stage(fixture, source)!;
    forms.depth = compile_vertex_stage(fixture, source, depth_only[..])!;
    forms.velocity = compile_vertex_stage(fixture, velocity_source, velocity_only[..])!;
    if (instanced) {
        forms.instanced_shaded = compile_vertex_stage(fixture, source, instanced_only[..])!;
        forms.instanced_depth = compile_vertex_stage(fixture, source, instanced_depth[..])!;
        forms.instanced_velocity = compile_vertex_stage(fixture, velocity_source, instanced_velocity[..])!;
    }
    return forms;
}

fn void free_vertex_forms(Fixture* fixture, CustomVertex forms) @private {
    alloc::free(fixture.allocator, forms.shaded.ptr);
    alloc::free(fixture.allocator, forms.depth.ptr);
    alloc::free(fixture.allocator, forms.velocity.ptr);
    alloc::free(fixture.allocator, forms.instanced_shaded.ptr);
    alloc::free(fixture.allocator, forms.instanced_depth.ptr);
    alloc::free(fixture.allocator, forms.instanced_velocity.ptr);
}

fn asset::ShaderDesc? pulse_forms_desc(Fixture* fixture, CustomVertex forms) @private {
    String fragment = (String)file::load(tmem, repository_path(PULSE_FRAGMENT))!;
    return {
        .fragment         = compile::compile_glsl(fixture.allocator, fragment, ShaderStage.FRAGMENT)!,
        .vertex           = forms,
        .param_block_size = PulseBlock::size,
    };
}

fn ShaderId? add_forms_shader(Fixture* fixture, CustomVertex forms) @private {
    defer free_vertex_forms(fixture, forms);
    asset::ShaderDesc desc = pulse_forms_desc(fixture, forms)!;
    defer alloc::free(fixture.allocator, desc.fragment.ptr);
    return fixture.assets.add_shader(&desc);
}

fn void? replace_forms_shader(Fixture* fixture, ShaderId shader, CustomVertex forms) @private {
    defer free_vertex_forms(fixture, forms);
    asset::ShaderDesc desc = pulse_forms_desc(fixture, forms)!;
    defer alloc::free(fixture.allocator, desc.fragment.ptr);
    return fixture.assets.replace_shader(shader, &desc);
}

fn ShaderId? add_pulse_velocity_shader(Fixture* fixture, bool broken_velocity = false) @private {
    ShaderId shader;
    @pool() {
        String pulse = load_pulse_vertex()!;
        CustomVertex forms = compile_vertex_forms(
            fixture:         fixture,
            source:          pulse,
            instanced:       false,
            velocity_source: broken_velocity ? (String)BROKEN_PUSH_SOURCE[..] : pulse,
        )!;
        shader = add_forms_shader(fixture, forms)!;
    };
    return shader;
}

fn DeformedScene? create_pulse_scene(Fixture* fixture, ShaderId shader) @private {
    PulseBlock pulse = { .color = { 1, 1, 1, 1 }, .motion = { PULSE_AMPLITUDE, PULSE_RATE, 0, 0 } };
    MaterialId custom = fixture.assets.add_material(material::custom(shader, material::@as_bytes(pulse)))!;
    return create_single_box_scene(fixture, fixture.box, custom, false);
}

fn uint? render_at(
    Fixture* fixture,
    DeformedScene* target,
    ViewId view,
    double time,
    Vec2 uv = CENTER_UV,
) @private {
    Renderer* renderer = &fixture.renderer;
    target.scene.update_world();
    renderer.begin_frame({ .time = time, .delta = (float)TIME_STEP })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&target.scene, target.camera, view)!;
    sample(fixture, render::read_view_color(view), uv)!;
    record_readback(fixture)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn uint? run_frames(Fixture* fixture, DeformedScene* target, double start) @private {
    uint pixel;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        pixel = render_at(
            fixture: fixture,
            target:  target,
            view:    fixture.view,
            time:    start + (double)frame * TIME_STEP,
        )!;
    }
    return pixel;
}

fn Vec2 projected_uv(CameraMatrices* matrices, Vec3 point) @private {
    Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
    return { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f };
}

fn Vec4 expected_velocity(DeformedScene* target, Vec3 current, Vec3 previous) @private {
    Camera* camera = target.scene.get(target.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, target.camera.world, { TARGET_SIZE, TARGET_SIZE });
    Vec2 motion = projected_uv(&matrices, current) - projected_uv(&matrices, previous);
    float scale = (float)TARGET_SIZE / (2 * (float)shader::TAA_DEBUG_VELOCITY_RANGE);
    return { 0.5f + motion.x * scale, 0.5f + motion.y * scale, 0, 1 };
}

fn float pulse_height(double time) @private {
    return PULSE_AMPLITUDE * math::sin((float)time * PULSE_RATE);
}

fn Vec4 expected_pulse(DeformedScene* target, double time, double previous_time) @private {
    Vec3 current = { 0, pulse_height(time), 0.5f };
    Vec3 previous = { 0, pulse_height(previous_time), 0.5f };
    return expected_velocity(target, current, previous);
}

fn void check_separated(Vec4 expected, Vec4 other) @private {
    float red_steps = math::abs(expected.x - other.x) * 255;
    float green_steps = math::abs(expected.y - other.y) * 255;
    assert(red_steps >= MIN_VELOCITY_STEPS || green_steps >= MIN_VELOCITY_STEPS);
}

fn int channel_difference(uint pixel, uint other, uint channel) @private {
    int value = (int)((pixel >> (8 * channel)) & 0xff);
    int other_value = (int)((other >> (8 * channel)) & 0xff);
    return math::abs(value - other_value);
}

fn uint? move_glass(Fixture* fixture, DeformedScene* target) @private {
    target.mesh.local.position.x = 0;
    uint pixel;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        target.mesh.local.position.x += GLASS_STEP;
        pixel = render_scene_and_sample(fixture, target)!;
    }
    return pixel;
}

fn MaterialId? add_glass_material(Fixture* fixture, AlphaMode alpha_mode) @private {
    PhysicalParams glass = material::PHYSICAL_PARAMS_DEFAULT;
    glass.transmission = 1;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = alpha_mode;
    return fixture.assets.add_material(material::physical(glass, common));
}

fn void test_velocity_form_moves_a_still_displaced_node() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ShaderId pulse = add_pulse_velocity_shader(&fixture)!!;
    DeformedScene target = create_pulse_scene(&fixture, pulse)!!;
    defer scene::destroy_scene(&target.scene);
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    uint displaced = run_frames(&fixture, &target, 0)!!;
    double last = (double)(SETTLE_FRAMES - 1) * TIME_STEP;
    Vec4 expected = expected_pulse(&target, last, last - TIME_STEP);
    check_separated(expected, NEUTRAL_VELOCITY);
    check_channels(displaced, expected);
    uint redrawn_draws = renderer.stats.draws;

    asset::ShaderDesc without_velocity = fixture.assets.shader(pulse).desc;
    without_velocity.vertex.velocity = {};
    without_velocity.vertex.instanced_velocity = {};
    fixture.assets.replace_shader(pulse, &without_velocity)!!;
    renderer.upload(pulse)!!;
    @pool() {
        foreach (key : renderer.pipelines.keys_of(tmem, pulse, 2)) {
            assert((key.vertex.flags & shader::SHADER_FLAG_VELOCITY) == 0);
        }
    };

    double resumed = last + TIME_STEP;
    uint undisplaced = run_frames(&fixture, &target, resumed)!!;
    assert(renderer.stats.draws == redrawn_draws - 1);
    uint background = render_at(
        fixture: &fixture,
        target:  &target,
        view:    fixture.view,
        time:    resumed + (double)SETTLE_FRAMES * TIME_STEP,
        uv:      BACKGROUND_UV,
    )!!;
    check_near_pixel(undisplaced, background);
    check_validation(renderer);
}

fn void test_velocity_form_reads_the_view_previous_time() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ShaderId pulse = add_pulse_velocity_shader(&fixture)!!;
    DeformedScene target = create_pulse_scene(&fixture, pulse)!!;
    defer scene::destroy_scene(&target.scene);
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    render_at(
        fixture: &fixture,
        target:  &target,
        view:    fixture.view,
        time:    0,
    )!!;
    render_at(
        fixture: &fixture,
        target:  &target,
        view:    fixture.view,
        time:    TIME_STEP,
    )!!;
    render_at(
        fixture: &fixture,
        target:  &target,
        view:    fixture.second_view,
        time:    OTHER_VIEW_TIME,
    )!!;
    uint returned = render_at(
        fixture: &fixture,
        target:  &target,
        view:    fixture.view,
        time:    RETURN_TIME,
    )!!;

    Vec4 expected = expected_pulse(&target, RETURN_TIME, TIME_STEP);
    check_separated(expected, expected_pulse(&target, RETURN_TIME, OTHER_VIEW_TIME));
    check_separated(expected, NEUTRAL_VELOCITY);
    check_channels(returned, expected);
    check_validation(&fixture.renderer);
}

fn void test_velocity_form_at_frozen_time_matches_background() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ShaderId pulse = add_pulse_velocity_shader(&fixture)!!;
    DeformedScene target = create_pulse_scene(&fixture, pulse)!!;
    defer scene::destroy_scene(&target.scene);
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    uint frozen;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        frozen = render_at(
            fixture: &fixture,
            target:  &target,
            view:    fixture.view,
            time:    FROZEN_TIME,
        )!!;
    }
    uint background = render_at(
        fixture: &fixture,
        target:  &target,
        view:    fixture.view,
        time:    FROZEN_TIME,
        uv:      BACKGROUND_UV,
    )!!;
    assert(frozen == background);
    check_validation(&fixture.renderer);
}

fn void test_early_velocity_draws_the_velocity_form() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ShaderId pulse = add_pulse_velocity_shader(&fixture)!!;
    DeformedScene target = create_pulse_scene(&fixture, pulse)!!;
    defer scene::destroy_scene(&target.scene);
    ViewDesc desc = fixture.renderer.views.get(fixture.view).desc;
    desc.screen_space_gi = render::SCREEN_SPACE_GI_DEFAULT;
    render::configure_view(&fixture.renderer, fixture.view, desc)!!;
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    uint displaced = run_frames(&fixture, &target, 0)!!;
    double last = (double)(SETTLE_FRAMES - 1) * TIME_STEP;
    check_channels(displaced, expected_pulse(&target, last, last - TIME_STEP));
    check_validation(&fixture.renderer);
}

fn void test_culled_instanced_velocity_indexes_by_instance_source() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    CustomVertex wave_forms = compile_vertex_forms(
        fixture:         &fixture,
        source:          (String)WAVE_SOURCE[..],
        instanced:       true,
        velocity_source: (String)WAVE_SOURCE[..],
    )!!;
    ShaderId shader = add_forms_shader(&fixture, wave_forms)!!;
    PulseBlock motion = {
        .color  = { 1, 1, 1, 1 },
        .motion = { WAVE_AMPLITUDE, WAVE_RATE, 0, WAVE_INSTANCE_PHASE },
    };
    MaterialId custom = fixture.assets.add_material(material::custom(shader, material::@as_bytes(motion)))!!;
    DeformedScene line = create_line_scene(&fixture, custom)!!;
    defer scene::destroy_scene(&line.scene);
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    uint culled = run_frames(&fixture, &line, 0)!!;
    assert(renderer.stats.instances_visible < renderer.stats.instances_tested);
    set_view_culling(&fixture, false)!!;
    uint unculled = run_frames(&fixture, &line, 0)!!;
    check_near_pixel(culled, unculled);
    uint background = render_at(
        fixture: &fixture,
        target:  &line,
        view:    fixture.view,
        time:    0,
        uv:      BACKGROUND_UV,
    )!!;
    assert(channel_difference(culled, background, 1) > CHANNEL_TOLERANCE);
    check_validation(renderer);
}

fn void test_moving_glass_writes_geometry_velocity() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    MaterialId opaque_glass = add_glass_material(&fixture, AlphaMode.OPAQUE)!!;
    MaterialId blended_glass = add_glass_material(&fixture, AlphaMode.BLEND)!!;
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    DeformedScene opaque = create_single_box_scene(&fixture, fixture.box, opaque_glass, false)!!;
    defer scene::destroy_scene(&opaque.scene);
    uint opaque_velocity = move_glass(&fixture, &opaque)!!;
    uint redrawn_draws = renderer.stats.draws;
    float last_x = (float)SETTLE_FRAMES * GLASS_STEP;
    Vec4 expected = expected_velocity(&opaque, { last_x, 0, 0.5f }, { last_x - GLASS_STEP, 0, 0.5f });
    check_separated(expected, NEUTRAL_VELOCITY);
    check_channels(opaque_velocity, expected);

    DeformedScene blended = create_single_box_scene(&fixture, fixture.box, blended_glass, false)!!;
    defer scene::destroy_scene(&blended.scene);
    uint blended_velocity = move_glass(&fixture, &blended)!!;
    check_channels(blended_velocity, NEUTRAL_VELOCITY);
    assert(renderer.stats.draws == redrawn_draws - 1);
    check_validation(renderer);
}

fn void test_moving_glass_batch_matches_the_opaque_batch() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialId glass = add_glass_material(&fixture, AlphaMode.OPAQUE)!!;
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    DeformedScene glass_line = create_line_scene(&fixture, glass)!!;
    defer scene::destroy_scene(&glass_line.scene);
    uint glass_velocity = run_moving_line(&fixture, &glass_line)!!;
    uint background = render_scene_and_sample(&fixture, &glass_line, BACKGROUND_UV)!!;

    DeformedScene plain_line = create_line_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&plain_line.scene);
    uint plain_velocity = run_moving_line(&fixture, &plain_line)!!;
    check_near_pixel(glass_velocity, plain_velocity);
    assert(channel_difference(glass_velocity, background, 0) > CHANNEL_TOLERANCE);
    check_validation(&fixture.renderer);
}

fn void test_rejected_velocity_form_skips_its_velocity_draw() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ShaderId pulse = add_pulse_velocity_shader(&fixture, broken_velocity: true)!!;
    DeformedScene target = create_pulse_scene(&fixture, pulse)!!;
    defer scene::destroy_scene(&target.scene);
    target.scene.ambient_intensity = 1;
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    uint rejections;
    uint centre;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        centre = render_at(
            fixture: &fixture,
            target:  &target,
            view:    fixture.view,
            time:    (double)frame * TIME_STEP,
        )!!;
        rejections += renderer.stats.shader_rejections;
    }
    assert(rejections == 1);
    uint background = render_at(
        fixture: &fixture,
        target:  &target,
        view:    fixture.view,
        time:    (double)SETTLE_FRAMES * TIME_STEP,
        uv:      BACKGROUND_UV,
    )!!;
    check_near_pixel(centre, background);

    enable_taa(&fixture, fixture.view)!!;
    check_opaque_color(run_frames(&fixture, &target, 0)!!);
    check_validation(renderer);
}

fn void test_rejected_velocity_replacement_keeps_the_previous_form() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ShaderId pulse = add_pulse_velocity_shader(&fixture)!!;
    DeformedScene target = create_pulse_scene(&fixture, pulse)!!;
    defer scene::destroy_scene(&target.scene);
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    double last = (double)(SETTLE_FRAMES - 1) * TIME_STEP;
    Vec4 expected = expected_pulse(&target, last, last - TIME_STEP);
    check_channels(run_frames(&fixture, &target, 0)!!, expected);

    @pool() {
        CustomVertex broken = compile_vertex_forms(
            fixture:         &fixture,
            source:          load_pulse_vertex()!!,
            instanced:       false,
            velocity_source: (String)BROKEN_PUSH_SOURCE[..],
        )!!;
        replace_forms_shader(&fixture, pulse, broken)!!;
    };
    if (catch excuse = renderer.upload(pulse)) {
        assert(excuse == gpu::SHADER_INVALID);
    } else {
        assert(false, "a velocity form the backend rejects was accepted");
    }
    assert(renderer.stats.shader_rejections == 1);

    uint kept;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        kept = render_at(
            fixture: &fixture,
            target:  &target,
            view:    fixture.view,
            time:    (double)frame * TIME_STEP,
        )!!;
        assert(renderer.stats.shader_rejections == 0);
    }
    check_channels(kept, expected);
    check_validation(renderer);
}
