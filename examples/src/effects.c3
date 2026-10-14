module effects_example;

import std::io;
import std::math;
import bench_loop;
import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::render::post;
import c3d::scene;
import imgui;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 1.0f;
const float ORBIT_DISTANCE_MAX @local = 50.0f;
const float SPIN_RADIANS_PER_SECOND @local = 4; // fast enough that one frame's rotation streaks visibly
const float SWEEP_RADIANS_PER_SECOND @local = 1.2f;
const float SWEEP_YAW_AMPLITUDE @local = 0.6f;
const float CUBE_ROLL_DEGREES @local = 30;
const float CUBE_SIZE @local = 1.6f;
const float SPHERE_RADIUS @local = 0.7f;
const float SPHERE_OFFSET @local = 1.9f;
const float FOCUS_SPHERE_RADIUS @local = 0.35f;
const float FOCUS_ROW_STEP @local = 1.5f;
const uint FOCUS_ROW_COUNT @local = 5;
const float FOCUS_ROW_X @local = -0.9f;
const float FOCUS_DISTANCE @local = 6; // the cube, with marbles on both sides of focus
const float APERTURE @local = 1.4f; // wide open, so a 50 mm lens blurs the near marbles at 1280x720
const float GROUND_SIZE @local = 30;
const float GROUND_Y @local = -1.2f;
const float SUN_INTENSITY @local = 6; // lit texels exceed one, so tone mapping has work to do
const float EMISSIVE_STRENGTH @local = 8; // well above the default bloom threshold
const float AMBIENT_INTENSITY @local = 0.1f;
const float EXPOSURE_MIN @local = 0.05f;
const float EXPOSURE_MAX @local = 8;
const uint LUT_SIZE @local = 32;
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 360, 180 };
const Vec2 POST_PANEL_POSITION @local = { 16, 212 };
const Vec2 POST_PANEL_SIZE @local = { 360, 496 };
const Vec2 STATS_PANEL_POSITION @local = { 900, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 660 };
const uint BENCHMARK_WARMUP_FRAMES @local = 30; // lets clocks and caches settle before the timed frames
const uint BENCHMARK_WIDTH @local = 1920;
const uint BENCHMARK_HEIGHT @local = 1080;
const float BENCHMARK_FRAMES_PER_SECOND @local = 60; // the benchmark loop's fixed frame time

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct Content @local {
    TextureId lut;
    Node*     cube;
    Node*     camera_node;
}

struct Options @local {
    bool gpu_timings;
    bool benchmark;
    uint benchmark_frames;
    bool auto_focus;
    bool focus_fixed;
    Vec2 focus_point;
}

fn Quat cube_rotation(float spin_angle) @local {
    Quat roll = quaternion::from_axis_angle{float}({ 0, 0, 1 }, math::deg_to_rad(CUBE_ROLL_DEGREES));
    Quat yaw = quaternion::from_axis_angle{float}({ 0, 1, 0 }, spin_angle);
    return yaw.mul(roll).normalize();
}

fn void enable_effects(ViewDesc* view_desc, Options* options) @local {
    view_desc.post.bloom = true;
    view_desc.post.depth_of_field = true;
    view_desc.post.dof_params.focus_distance = FOCUS_DISTANCE;
    view_desc.post.dof_params.aperture = APERTURE;
    view_desc.post.dof_params.focus_mode = options.auto_focus ? FocusMode.AUTO : FocusMode.MANUAL;
    if (options.focus_fixed) view_desc.post.dof_params.focus_point = options.focus_point;
    view_desc.post.motion_blur = true;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.LEFT)) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
                -ORBIT_PITCH_LIMIT, ORBIT_PITCH_LIMIT);
        }

        if (input.wheel != 0) {
            float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
            orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
        }
    }

    place_camera(orbit, camera_node);
}

fn void place_camera(Orbit* orbit, Node* camera_node) @local {
    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn Vec2 cursor_focus_point(platform::Window* window) @local {
    Vec2 position = window.input.mouse_position / (Vec2){ (float)window.width, (float)window.height };
    return { math::clamp(position.x, 0.0f, 1.0f), math::clamp(position.y, 0.0f, 1.0f) };
}

fn Vec2? parse_focus_point(String horizontal, String vertical) @local {
    float x = (float)horizontal.to_float()!;
    float y = (float)vertical.to_float()!;
    if (!(x >= 0 && x <= 1 && y >= 0 && y <= 1)) return c3d::INVALID_ARGUMENT~;

    return { x, y };
}

fn void? draw_gui_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    return renderer.end_frame();
}

fn void? run_gui(
    platform::Window* window,
    render::Renderer* renderer,
    Scene* scene,
    Node* cube,
    Node* camera_node,
    TextureId lut,
    Options* options,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    Orbit orbit = { .distance = 6 };
    ViewDesc view_desc = render::default_view_desc();
    enable_effects(&view_desc, options);
    render::configure_view(renderer, renderer.default_view, view_desc)!;
    float spin_angle;
    float sweep_time;
    bool spin = true;
    bool sweep;
    bool orthographic;
    bool focus_follows_cursor = !options.focus_fixed;
    bool escape_captured;

    while (window.poll()) {
        bool keyboard_was_captured = window.input.keyboard_captured_by_gui;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        // Text editing can drop capture on Escape down before its release arrives.
        if (input.key_pressed(platform::Scancode.ESCAPE) || input.key_released(platform::Scancode.ESCAPE)) {
            escape_captured |= keyboard_was_captured || input.keyboard_captured_by_gui;
        }

        if (input.key_released(platform::Scancode.ESCAPE)) {
            bool quit = !escape_captured;
            escape_captured = false;
            if (quit) break;
        }

        camera::Camera* camera = scene.get(camera_node, camera::Camera);
        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Controls", null, {})) {
            imgui::checkbox("Spin", &spin);
            imgui::checkbox("Sweep", &sweep);
            if (imgui::checkbox("Orthographic", &orthographic)) {
                float exposure = camera.exposure;
                *camera = orthographic ? camera::orthographic(6, 0.1f, 100) : camera::perspective_deg(60, 0.1f);
                camera.exposure = exposure;
            }
            imgui::slider_float_ex(
                label:  "Camera exposure",
                v:      &camera.exposure,
                v_min:  EXPOSURE_MIN,
                v_max:  EXPOSURE_MAX,
                format: "%.2f",
                flags:  imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
            );
            imgui::checkbox("Focus follows cursor", &focus_follows_cursor);
            imgui::text("F toggles auto focus");
        }
        imgui::end();

        DofParams* dof = &view_desc.post.dof_params;
        bool focus_changed;
        if (input.key_pressed(platform::Scancode.F) && !input.keyboard_captured_by_gui) {
            dof.focus_mode = dof.focus_mode == FocusMode.AUTO ? FocusMode.MANUAL : FocusMode.AUTO;
            focus_changed = true;
        }

        bool follows = focus_follows_cursor && dof.focus_mode == FocusMode.AUTO && !input.mouse_captured_by_gui;
        Vec2 cursor = cursor_focus_point(window);
        if (follows && cursor != dof.focus_point) {
            dof.focus_point = cursor;
            focus_changed = true;
        }

        ViewStats stats = renderer.view_stats(renderer.default_view)!;
        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        bool changed = gui::post_panel(&view_desc, lut, &stats) || focus_changed;

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        if (spin) spin_angle += window.clock.delta * SPIN_RADIANS_PER_SECOND;
        cube.local.rotation = cube_rotation(spin_angle);
        if (sweep) sweep_time += window.clock.delta;
        apply_orbit(&orbit, input, camera_node);
        if (sweep) {
            float sweep_yaw = orbit.yaw + SWEEP_YAW_AMPLITUDE * math::sin(sweep_time * SWEEP_RADIANS_PER_SECOND);
            Orbit swept = { .target = orbit.target, .distance = orbit.distance, .yaw = sweep_yaw, .pitch = orbit.pitch };
            place_camera(&swept, camera_node);
        }

        scene.update_world();
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        if (changed) render::configure_view(renderer, renderer.default_view, view_desc)!;
        draw_gui_frame(
            renderer: renderer,
            scene: scene,
            camera_node: camera_node,
            gui_renderer: &gui_renderer,
            info: { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn Content build_content(AssetStore* assets, Scene* scene) @local {
    Image decoded = image::decode_image(mem, $embed("../assets/texture.png"))!!;
    defer image::destroy_image(&decoded);
    TextureId image_texture = assets.add_texture(
        material::texture_2d_desc(decoded.width, decoded.height, RGBA8_SRGB),
        decoded.pixels,
        "effects/texture",
    )!!;

    TextureId lut;
    @pool() {
        char[] lut_pixels = post::identity_lut(tmem, LUT_SIZE);
        lut = assets.add_texture(post::identity_lut_desc(LUT_SIZE), lut_pixels, "effects/identity_lut")!!;
    };

    GeometryId box;
    GeometryId ball;
    GeometryId marble;
    GeometryId ground;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, CUBE_SIZE, CUBE_SIZE, CUBE_SIZE);
        box = assets.add_geometry(&box_geometry, "effects/box")!!;

        Geometry ball_geometry = geometry::sphere(tmem, SPHERE_RADIUS);
        ball = assets.add_geometry(&ball_geometry, "effects/sphere")!!;

        Geometry marble_geometry = geometry::sphere(tmem, FOCUS_SPHERE_RADIUS);
        marble = assets.add_geometry(&marble_geometry, "effects/marble")!!;

        Geometry ground_geometry = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground = assets.add_geometry(&ground_geometry, "effects/ground")!!;
    };

    MaterialId textured = assets.add_material(
        material::basic({ .color = { 1, 1, 1, 1 }, .map = material::texture_slot(image_texture) }),
        "effects/textured",
    )!!;
    MaterialId chrome = assets.add_material(
        material::standard({ .base_color = { 0.9f, 0.9f, 0.9f, 1 }, .metallic = 1, .roughness = 0.25f }),
        "effects/chrome",
    )!!;
    MaterialId lamp = assets.add_material(
        material::standard({
            .base_color        = { 0.2f, 0.2f, 0.2f, 1 },
            .roughness         = 0.6f,
            .emissive          = { 1, 0.6f, 0.2f },
            .emissive_strength = EMISSIVE_STRENGTH,
        }),
        "effects/lamp",
    )!!;

    MaterialId matte = assets.add_material(
        material::standard({ .base_color = { 0.55f, 0.55f, 0.6f, 1 }, .roughness = 0.8f }),
        "effects/matte",
    )!!;

    scene.ambient_intensity = AMBIENT_INTENSITY;

    Node* floor = scene.add_mesh(ground, matte, name: "ground")!!;
    floor.local.position = { 0, GROUND_Y, 0 };
    for (uint index = 0; index < FOCUS_ROW_COUNT; index++) {
        Node* focus_sphere = scene.add_mesh(marble, textured, name: "focus")!!;
        focus_sphere.local.position = { FOCUS_ROW_X, GROUND_Y + FOCUS_SPHERE_RADIUS, 3 - FOCUS_ROW_STEP * (float)index };
    }
    Node* cube = scene.add_mesh(box, textured, name: "cube")!!;
    Node* chrome_sphere = scene.add_mesh(ball, chrome, name: "chrome")!!;
    chrome_sphere.local.position = { SPHERE_OFFSET, 0, 0 };
    Node* lamp_sphere = scene.add_mesh(ball, lamp, name: "lamp")!!;
    lamp_sphere.local.position = { -SPHERE_OFFSET, 0, 0 };
    Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, SUN_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0.4f, -0.7f, -0.6f }.normalize(), { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;

    return { .lut = lut, .cube = cube, .camera_node = camera_node };
}

fn void spin_cube(void* user, uint frame) @local {
    Node* cube = user;
    cube.local.rotation = cube_rotation((float)frame / BENCHMARK_FRAMES_PER_SECOND * SPIN_RADIANS_PER_SECOND);
}

fn void print_stage_means(FrameSample[] samples) @local {
    float bloom_ms;
    float depth_of_field_ms;
    float motion_blur_ms;
    float post_chain_ms;

    foreach (sample : samples) {
        bloom_ms += sample.gpu_post_stage_ms[PostStage.BLOOM.ordinal];
        depth_of_field_ms += sample.gpu_post_stage_ms[PostStage.DEPTH_OF_FIELD.ordinal];
        motion_blur_ms += sample.gpu_post_stage_ms[PostStage.MOTION_BLUR.ordinal];
        post_chain_ms += sample.gpu_ms[Pass.POST_CHAIN.ordinal];
    }

    float frames = (float)samples.len;
    io::printfn(
        "Bloom: %.4f ms, depth of field: %.4f ms, motion blur: %.4f ms, "
        "post chain: %.4f ms, mean over %d frames at %dx%d",
        bloom_ms / frames,
        depth_of_field_ms / frames,
        motion_blur_ms / frames,
        post_chain_ms / frames,
        samples.len,
        BENCHMARK_WIDTH,
        BENCHMARK_HEIGHT,
    );
}

fn void? run_benchmark(Options* options) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    Content content = build_content(&assets, &scene);
    Orbit orbit = { .distance = 6 };
    place_camera(&orbit, content.camera_node);

    BenchmarkFlags flags = bench_loop::default_flags();
    flags.frames = options.benchmark_frames;
    flags.warmup = BENCHMARK_WARMUP_FRAMES;
    flags.width = BENCHMARK_WIDTH;
    flags.height = BENCHMARK_HEIGHT;
    bench_loop::validate_flags(flags, ShadingPath.FORWARD)!;

    FrameSample[] samples = alloc::new_array(mem, FrameSample, flags.frames);
    defer alloc::free(mem, samples.ptr);

    render::Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      {
            .gpu_timings      = options.gpu_timings,
            .validation       = true,
            .application_name = "c3d_effects_benchmark",
        },
    )!;
    defer render::destroy_renderer(&renderer);

    if (!renderer.timestamps_enabled) {
        io::eprintn("GPU timestamps are unavailable on this device");
        return c3d::UNSUPPORTED~;
    }

    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc:     render::render_target_desc(flags.width, flags.height, PixelFormat.RGBA8_UNORM),
    )!;

    ViewDesc view_desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    enable_effects(&view_desc, options);
    ViewId view = render::create_view(&renderer, view_desc)!;

    BenchmarkRun run = {
        .renderer          = &renderer,
        .scene             = &scene,
        .camera_node       = content.camera_node,
        .view              = view,
        .before_frame      = &spin_cube,
        .before_frame_user = content.cube,
    };

    usz collected = bench_loop::run_frames(&run, flags, samples)!;
    print_stage_means(samples[:collected]);
}

fn int main(String[] args) {
    Options options;

    for (usz index = 1; index < args.len; index++) {
        String argument = args[index];
        if (argument == "--auto-focus") {
            options.auto_focus = true;
        } else if (argument == "--focus-point" && index + 2 < args.len) {
            Vec2? point = parse_focus_point(args[index + 1], args[index + 2]);
            if (catch excuse = point) {
                io::printfn("Bad --focus-point: %s", excuse);
                return 1;
            }

            options.focus_point = point;
            options.focus_fixed = true;
            index += 2;
        } else if (argument == "--gpu-timings") {
            $if $feat(C3D_PROFILE_GPU):
                options.gpu_timings = true;
            $else
                io::eprintfn(
                    "--gpu-timings needs GPU profiling: c3c build <target> --path examples --lib c3d_profile "
                    "-D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL"
                );
                return 1;
            $endif
        } else if (argument == "--benchmark" && index + 1 < args.len) {
            uint? frames = args[++index].to_uint();
            if (catch excuse = frames) {
                io::printfn("Bad --benchmark: %s", excuse);
                return 1;
            }

            options.benchmark = true;
            options.benchmark_frames = frames;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    if (options.benchmark) {
        if (!options.gpu_timings) {
            io::eprintn("--benchmark FRAMES needs --gpu-timings");
            return 1;
        }

        fault excuse = @catch(run_benchmark(&options));
        if (excuse) {
            io::eprintfn("effects benchmark failed: %s", excuse);
            return 1;
        }

        return 0;
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d effects", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = options.gpu_timings, .validation = true, .application_name = "c3d_effects" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    Content content = build_content(&assets, &scene);
    renderer.prepare_scene(&scene)!!;

    if (catch excuse = run_gui(
        window: &window,
        renderer: &renderer,
        scene: &scene,
        cube: content.cube,
        camera_node: content.camera_node,
        lut: content.lut,
        options: &options,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }

    return 0;
}
