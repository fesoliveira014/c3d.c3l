module many_lights_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import bench_loop;
import gpu;
import imgui;
import std::io;
import std::math;
import std::time;
import std::time::clock;

const uint MAX_POINT_LIGHTS @local = 4096; // 320 KiB of packed lights per view; caps this workload
const uint SCENE_NODE_CAPACITY @local = MAX_POINT_LIGHTS + 128; // fixed hall meshes and camera fit beside every light
const float HALL_WIDTH @local = 40; // fixes receiver area independently of the light count
const float HALL_LENGTH @local = 64; // enough depth to expose slice occupancy
const float LIGHT_HEIGHT @local = 2.5f; // lights reach the floor and column sides
const float LIGHT_INTENSITY @local = 8; // fixed across counts so workload changes remain explicit
const float RANGE_MIN @local = 1; // positive finite coverage for every workload light
const float RANGE_MAX @local = 32; // dense overlap can deliberately overflow the fixed segments
const uint PILLAR_COLUMNS @local = 5; // fixed geometry count isolates light selection cost
const uint PILLAR_ROWS @local = 8;
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f; // balances precise orbit control against pointer travel
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the look-rotation up-axis degeneracy
const float ORBIT_ZOOM_STEP @local = 0.9f; // useful scale change per wheel step
const float ORBIT_DISTANCE_MIN @local = 2; // allows examining individual light pools
const float ORBIT_DISTANCE_MAX @local = 100; // covers the complete hall
const uint[4] LIGHT_COUNTS @local = { 64, 256, 1024, 4096 };
const ZString[4] LIGHT_COUNT_LABELS @local = { "64 lights", "256 lights", "1024 lights", "4096 lights" };
const uint[4] CELL_CAPACITIES @local = { 1, 16, 64, 256 };
const ZString[4] CAPACITY_LABELS @local = { "1 per cell", "16 per cell", "64 per cell", "256 per cell" };
const Vec3[6] LIGHT_COLORS @local = {
    { 1, 0.25f, 0.12f }, { 0.15f, 0.5f, 1 }, { 0.2f, 1, 0.4f },
    { 1, 0.65f, 0.2f }, { 0.65f, 0.25f, 1 }, { 0.15f, 0.9f, 1 },
};

struct Workload @local {
    uint light_count;
    float light_range;
}

struct Orbit @local {
    Vec3 target;
    float distance;
    float yaw;
    float pitch;
}

struct HallView @local {
    Node*[MAX_POINT_LIGHTS] lights;
    Node* camera_node;
}

struct BenchmarkOptions @local {
    bool enabled;
    bool gpu_timings;
    bool validation;
    bool capture;
    bool window;
    bool panel;
    bool print_features;
    LightSelection selection;
    uint lights;
    uint frames;
    uint warmup;
    uint capacity;
    float range;
    uint width;
    uint height;
}

struct BenchmarkRun @private {
    Renderer* renderer;
    Scene* scene;
    Node* camera_node;
    ViewId view;
    platform::Window* window;
    BenchmarkRecorder* recorder @if($feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU));
    GuiRenderer* gui_renderer @if($feat(C3D_PROFILE_GUI));
    gui::ProfilerPanel* panel @if($feat(C3D_PROFILE_GUI));
}

fn HallView? populate_hall(AssetStore* assets, Scene* scene) @local {
    GeometryId box;
    @pool() {
        Geometry geometry = geometry::box(allocator: tmem, width: 1, height: 1, depth: 1);
        box = assets.add_geometry(&geometry, "hall/box")!;
    };
    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.base_color = { 0.65f, 0.65f, 0.65f, 1 };
    surface.roughness = 0.6f;
    MaterialId material = assets.add_material(material::standard(surface), "hall/surface")!;

    Node* floor = scene.add_mesh(geometry: box, material: material, name: "floor")!;
    floor.local.position = { 0, -0.25f, 0 };
    floor.local.scale = { HALL_WIDTH, 0.5f, HALL_LENGTH };
    for (uint side = 0; side < 2; side++) {
        Node* wall = scene.add_mesh(geometry: box, material: material, name: "wall")!;
        wall.local.position = { side ? HALL_WIDTH * 0.5f : -HALL_WIDTH * 0.5f, 3, 0 };
        wall.local.scale = { 0.5f, 6, HALL_LENGTH };
    }
    Node* back = scene.add_mesh(geometry: box, material: material, name: "back_wall")!;
    back.local.position = { 0, 3, -HALL_LENGTH * 0.5f };
    back.local.scale = { HALL_WIDTH, 6, 0.5f };
    for (uint row = 0; row < PILLAR_ROWS; row++) {
        for (uint column = 0; column < PILLAR_COLUMNS; column++) {
            Node* pillar = scene.add_mesh(geometry: box, material: material, name: "pillar")!;
            pillar.local.position = {
                ((float)column + 0.5f) / PILLAR_COLUMNS * HALL_WIDTH - HALL_WIDTH * 0.5f,
                1.5f,
                ((float)row + 0.5f) / PILLAR_ROWS * HALL_LENGTH - HALL_LENGTH * 0.5f,
            };
            pillar.local.scale = { 1.5f, 3, 1.5f };
        }
    }

    HallView hall;
    for (uint index = 0; index < MAX_POINT_LIGHTS; index++) {
        hall.lights[index] = scene.add_light(light::point(
            color: LIGHT_COLORS[index % LIGHT_COLORS.len],
            intensity: LIGHT_INTENSITY,
            range: 6,
        ))!;
        hall.lights[index].visible = false;
    }
    hall.camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    scene.ambient_intensity = 0.015f;
    return hall;
}

fn void apply_workload(Scene* scene, HallView* hall, Workload workload) @local {
    uint columns = (uint)math::sqrt((float)workload.light_count);
    foreach (index, node : hall.lights) {
        node.visible = index < workload.light_count;
        if (!node.visible) continue;
        node.local.position = {
            ((float)(index % columns) + 0.5f) / columns * HALL_WIDTH - HALL_WIDTH * 0.5f,
            LIGHT_HEIGHT,
            ((float)(index / columns) + 0.5f) / columns * HALL_LENGTH - HALL_LENGTH * 0.5f,
        };
        scene.get(node, Light).range = workload.light_range;
    }
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.LEFT)) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
                -ORBIT_PITCH_LIMIT, ORBIT_PITCH_LIMIT);
        }
        if (input.wheel != 0) {
            orbit.distance = math::clamp(orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel),
                ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
        }
    }
    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn Orbit reset_camera(Scene* scene, Node* camera_node) @local {
    *scene.get(camera_node, Camera) = camera::perspective_deg(60, 0.1f);
    camera_node.local.scale = { 1, 1, 1 };
    Orbit orbit = { .target = { 0, 0, 0 }, .distance = 65, .yaw = 0.2f, .pitch = 0.65f };
    Input input;
    apply_orbit(&orbit, &input, camera_node);
    return orbit;
}

fn void? draw_gui_frame(
    Renderer* renderer,
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

fn void? run_example(bool gpu_timings) @local {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d many lights", 1440, 900))!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: {
            .validation = true,
            .gpu_timings = gpu_timings,
            .present_mode = gpu::PresentMode.IMMEDIATE,
            .application_name = "c3d_many_lights",
            .max_lights = MAX_POINT_LIGHTS,
        },
    )!;
    defer render::destroy_renderer(&renderer);
    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    HallView hall = populate_hall(&assets, &scene)!;
    Workload workload = { .light_count = 256, .light_range = 6 };
    apply_workload(&scene, &hall, workload);
    Orbit orbit = reset_camera(&scene, hall.camera_node);
    scene.update_world();

    ViewDesc desc = render::default_view_desc();
    desc.lights = LightSelection.CLUSTERED;
    render::configure_view(&renderer, renderer.default_view, desc)!;
    renderer.prepare_scene(&scene)!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    bool cleanup_gui = true;
    defer catch {
        if (cleanup_gui) {
            if (catch excuse = gui::destroy_gui_renderer(&gui_renderer)) {
                io::eprintfn("GUI cleanup failed: %s", excuse);
            }
        }
    }
    TargetsPanelState targets = gui::default_targets_panel_state();
    bool escape_captured;
    io::printn("Drag to orbit, wheel to zoom; compare lighting in Targets; Escape release quits.");

    while (window.poll()) {
        platform::sync_window(&window, &renderer);
        bool keyboard_was_captured = window.input.keyboard_captured_by_gui;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        Input* input = &window.input;
        if (input.key_pressed(platform::Scancode.ESCAPE) || input.key_released(platform::Scancode.ESCAPE)) {
            escape_captured |= keyboard_was_captured || input.keyboard_captured_by_gui;
        }
        if (input.key_released(platform::Scancode.ESCAPE)) {
            bool quit = !escape_captured;
            escape_captured = false;
            if (quit) break;
        }

        bool workload_changed;
        bool reset;
        bool capacity_changed;
        uint[<2>] extent = renderer.view_extent(renderer.default_view)!;
        imgui::set_next_window_pos({ 16, 16 }, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size({ 360, 355 }, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Many lights", null, {})) {
            foreach (index, count : LIGHT_COUNTS) {
                if (imgui::radio_button(LIGHT_COUNT_LABELS[index], workload.light_count == count)) {
                    workload.light_count = count;
                    workload_changed = true;
                }
                if (index % 2 == 0) imgui::same_line();
            }
            workload_changed |= imgui::slider_float_ex(
                label: "Light range",
                v: &workload.light_range,
                v_min: RANGE_MIN,
                v_max: RANGE_MAX,
                format: "%.1f",
                flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
            );
            desc = renderer.views.get(renderer.default_view).desc;
            foreach (index, capacity : CELL_CAPACITIES) {
                if (imgui::radio_button(CAPACITY_LABELS[index], desc.clusters.lights_per_cluster == capacity)) {
                    desc.clusters.lights_per_cluster = capacity;
                    capacity_changed = true;
                }
                if (index % 2 == 0) imgui::same_line();
            }
            reset = imgui::button("Reset camera");
            imgui::text("Requested: %u   selected: %u", workload.light_count, renderer.stats.lights);
            imgui::text("Dropped: %u", renderer.stats.lights_dropped);
            imgui::text("Wall interval: %.3f ms", (double)window.clock.delta * 1000);
            imgui::text("Working extent: %u x %u", extent.x, extent.y);
            imgui::text("Framebuffer: %u x %u", window.width, window.height);
            imgui::text("Presentation: %s", gui::@enum_name(gpu::PresentMode, renderer.swapchain_info.present_mode));
            imgui::text_unformatted("Keep workload and camera fixed when comparing modes.");
        }
        imgui::end();
        if (capacity_changed) render::configure_view(&renderer, renderer.default_view, desc)!;

        imgui::set_next_window_pos({ 16, 390 }, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size({ 360, 490 }, imgui::COND_FIRST_USE_EVER);
        gui::targets_panel(&renderer, renderer.default_view, &targets)!;
        imgui::set_next_window_pos({ 1040, 16 }, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size({ 384, 850 }, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(&renderer)!;
        gui_renderer.finish_frame();

        if (workload_changed) apply_workload(&scene, &hall, workload);
        if (reset) {
            orbit = reset_camera(&scene, hall.camera_node);
        } else {
            apply_orbit(&orbit, input, hall.camera_node);
        }
        scene.update_world();
        draw_gui_frame(
            renderer: &renderer,
            scene: &scene,
            camera_node: hall.camera_node,
            gui_renderer: &gui_renderer,
            info: { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
    cleanup_gui = false;
    return gui::destroy_gui_renderer(&gui_renderer);
}

fn BenchmarkOptions? parse_options(String[] args) @local {
    BenchmarkOptions options = {
        .selection = LightSelection.CLUSTERED,
        .lights = 256, .frames = 300, .warmup = 60, .capacity = 64,
        .range = 6, .width = 1440, .height = 900,
    };
    for (usz index = 1; index < args.len; index++) {
        String argument = args[index];
        switch (argument) {
            case "--benchmark": options.enabled = true;
            case "--gpu-timings":
                $if $feat(C3D_PROFILE_GPU):
                    options.gpu_timings = true;
                $else
                    io::eprintfn("--gpu-timings needs GPU profiling: c3c build many_lights --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                    return c3d::UNSUPPORTED~;
                $endif
            case "--validation": options.validation = true;
            case "--window": options.window = true;
            case "--print-features": options.print_features = true;
            case "--capture":
                $if $feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU):
                    options.capture = true;
                $else
                    io::eprintfn("--capture needs CPU or GPU profiling: c3c build many_lights --path examples --lib c3d_profile -D C3D_PROFILE_CPU -D C3D_PROFILE_INTERNAL");
                    return c3d::UNSUPPORTED~;
                $endif
            case "--panel":
                $if $feat(C3D_PROFILE_GUI):
                    options.panel = true;
                $else
                    io::eprintfn("--panel needs the profiler GUI: c3c build many_lights --path examples --lib c3d_profile_gui --lib c3d_profile -D C3D_PROFILE_GUI -D C3D_PROFILE_CPU -D C3D_PROFILE_INTERNAL");
                    return c3d::UNSUPPORTED~;
                $endif
            default:
                if (++index == args.len) return c3d::INVALID_ARGUMENT~;
                String value = args[index];
                switch (argument) {
                    case "--mode":
                        if (value == "flat") {
                            options.selection = LightSelection.FLAT;
                        } else if (value == "clustered") {
                            options.selection = LightSelection.CLUSTERED;
                        } else {
                            return c3d::INVALID_ARGUMENT~;
                        }
                    case "--lights": options.lights = value.to_uint()!;
                    case "--frames": options.frames = value.to_uint()!;
                    case "--warmup": options.warmup = value.to_uint()!;
                    case "--capacity": options.capacity = value.to_uint()!;
                    case "--range": options.range = value.to_float()!;
                    case "--width": options.width = value.to_uint()!;
                    case "--height": options.height = value.to_uint()!;
                    default: return c3d::INVALID_ARGUMENT~;
                }
        }
    }
    if (!options.lights || options.lights > MAX_POINT_LIGHTS
        || !options.frames || options.frames > 100000 || options.warmup > 100000
        || !options.capacity || options.capacity > 256
        || !math::is_finite(options.range) || options.range < RANGE_MIN || options.range > RANGE_MAX
        || !options.width || options.width > 8192 || !options.height || options.height > 8192
        || (options.panel && (!options.window || !options.capture))) {
        return c3d::INVALID_ARGUMENT~;
    }
    return options;
}

fn void? run_benchmark(BenchmarkOptions options) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    HallView hall = populate_hall(&assets, &scene)!;
    apply_workload(&scene, &hall, { .light_count = options.lights, .light_range = options.range });
    reset_camera(&scene, hall.camera_node);
    scene.update_world();
    FrameSample[] samples = alloc::new_array(mem, FrameSample, options.frames);
    defer alloc::free(mem, samples.ptr);
    BenchmarkRun run = { .scene = &scene, .camera_node = hall.camera_node };
    RendererDesc renderer_desc = {
        .validation = options.validation,
        .gpu_timings = options.gpu_timings,
        .present_mode = gpu::PresentMode.IMMEDIATE,
        .application_name = "c3d_many_lights_benchmark",
        .max_lights = MAX_POINT_LIGHTS,
    };
    $if $feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU):
        BenchmarkRecorder recorder;
        if (options.capture) {
            recorder = create_benchmark_recorder()!;
            run.recorder = &recorder;
            $if $feat(C3D_PROFILE_GPU):
                renderer_desc.profiler = &recorder;
            $endif
        }
        defer if (options.capture) destroy_benchmark_recorder(&recorder);
    $endif
    usz collected;
    if (options.window) {
        platform::Window window = platform::create_window(
            platform::default_window_desc("c3d many lights benchmark", options.width, options.height))!;
        defer platform::destroy_window(&window);
        Renderer renderer = platform::create_window_renderer(mem, &window, &assets, renderer_desc)!;
        defer render::destroy_renderer(&renderer);
        render::configure_view(&renderer, renderer.default_view, benchmark_view_desc(render::default_view_desc(), options))!;
        run.renderer = &renderer;
        run.window = &window;
        run.view = renderer.default_view;
        $if $feat(C3D_PROFILE_GUI):
            GuiRenderer gui_renderer;
            gui::ProfilerPanel panel;
            if (options.panel) {
                gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
                run.gui_renderer = &gui_renderer;
            }
            defer if (options.panel) (void)gui::destroy_gui_renderer(&gui_renderer);
            if (options.panel) {
                panel = gui::create_profiler_panel(mem, run.recorder)!;
                run.panel = &panel;
            }
            defer if (options.panel) gui::destroy_profiler_panel(&panel);
        $endif
        collected = run_frames(&run, options, samples)!;
        bench_loop::write_samples(samples[:collected], renderer.timestamps_enabled);
    } else {
        Renderer renderer = render::create_renderer(mem, &assets, renderer_desc)!;
        defer render::destroy_renderer(&renderer);
        RenderTargetId target = render::create_render_target(&renderer,
            render::render_target_desc(options.width, options.height, PixelFormat.RGBA8_UNORM))!;
        ViewDesc view_desc = benchmark_view_desc(render::texture_view_desc(target, OutputMode.DISPLAY_LDR), options);
        run.renderer = &renderer;
        run.view = render::create_view(&renderer, view_desc)!;
        collected = run_frames(&run, options, samples)!;
        bench_loop::write_samples(samples[:collected], renderer.timestamps_enabled);
    }
}

fn ViewDesc benchmark_view_desc(ViewDesc base, BenchmarkOptions options) @local {
    base.lights = options.selection;
    base.clusters.lights_per_cluster = options.capacity;
    return base;
}

fn usz? run_frames(BenchmarkRun* run, BenchmarkOptions options, FrameSample[] samples) @local {
    Renderer* renderer = run.renderer;
    renderer.prepare_scene(run.scene)!;
    io::eprintfn("mode=%s lights=%d range=%.1f capacity=%d extent=%dx%d warmup=%d frames=%d validation=%s timestamps_requested=%s timestamps_active=%s capture=%s presentation=%s panel=%s",
        options.selection == LightSelection.FLAT ? "flat" : "clustered", options.lights, options.range,
        options.capacity, options.width, options.height, options.warmup, options.frames,
        options.validation, options.gpu_timings, renderer.timestamps_enabled, options.capture,
        options.window ? "window" : "none", options.panel);

    usz collected;
    for (uint frame = 0; frame < options.warmup + options.frames + render::FRAMES_IN_FLIGHT; frame++) {
        if (run.window && !run.window.poll()) break;
        FrameSample sample;
        $if $feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU):
            if (run.recorder) {
                record_captured_frame(run, frame, &sample)!;
            } else {
                record_frame(run, frame, &sample)!;
            }
        $else
            record_frame(run, frame, &sample)!;
        $endif
        if (frame >= options.warmup + render::FRAMES_IN_FLIGHT) {
            uint completed = frame - options.warmup - render::FRAMES_IN_FLIGHT;
            samples[completed].gpu_ms = renderer.stats.gpu_pass_ms;
            samples[completed].overflows = renderer.stats.cluster_overflows;
        }
        if (frame >= options.warmup && frame < options.warmup + options.frames) {
            samples[frame - options.warmup] = sample;
            collected = (usz)(frame - options.warmup + 1);
        }
    }
    foreach (&slot : renderer.frames) {
        if (slot.done.is_valid()) gpu::wait_completion(slot.done)!;
    }
    return collected;
}

fn void? record_frame(BenchmarkRun* run, uint frame, FrameSample* sample) @private {
    Renderer* renderer = run.renderer;
    time::Clock started = clock::now();
    time::Clock phase = started;
    run.scene.update_world();
    sample.update_ms = bench_loop::milliseconds(phase);
    phase = clock::now();
    renderer.begin_frame({ .time = (double)frame / 60, .delta = 1.0f / 60 })!;
    defer catch render::abort_frame(renderer);
    sample.begin_ms = bench_loop::milliseconds(phase);
    phase = clock::now();
    renderer.render_view(run.scene, run.camera_node, run.view)!;
    sample.render_ms = bench_loop::milliseconds(phase);
    phase = clock::now();
    renderer.finish_view(run.view)!;
    sample.finish_ms = bench_loop::milliseconds(phase);
    $if $feat(C3D_PROFILE_GUI):
        if (run.panel && renderer.has_output) {
            phase = clock::now();
            run.gui_renderer.new_frame();
            gui::profiler_panel(run.panel);
            run.gui_renderer.finish_frame();
            OverlayContext overlay = renderer.begin_overlay()!;
            run.gui_renderer.record(&overlay)!;
            renderer.end_overlay(&overlay)!;
            sample.gui_ms = bench_loop::milliseconds(phase);
        }
    $endif
    phase = clock::now();
    renderer.end_frame()!;
    sample.end_ms = bench_loop::milliseconds(phase);
    sample.wall_ms = bench_loop::milliseconds(started);
    sample.cpu_record_ms = renderer.stats.cpu_record_ms;
    sample.draws = renderer.stats.draws;
    sample.lights = renderer.stats.lights;
    sample.dropped = renderer.stats.lights_dropped;
}

<* Run the many-light comparison or a fixed headless benchmark. *>
fn int main(String[] args) {
    BenchmarkOptions? parsed = parse_options(args);
    if (catch excuse = parsed) {
        if (excuse != c3d::UNSUPPORTED) {
            io::eprintfn("Invalid options: %s", excuse);
            io::eprintn("Use --benchmark --mode flat|clustered --lights N --frames N --warmup N --capacity N --range N --width N --height N [--gpu-timings] [--validation] [--capture] [--window] [--panel] [--print-features].");
        }
        return 1;
    }
    BenchmarkOptions options = parsed;
    if (options.print_features) {
        io::printfn("cpu=%d gpu=%d internal=%d gui=%d",
            $feat(C3D_PROFILE_CPU) ? 1 : 0, $feat(C3D_PROFILE_GPU) ? 1 : 0,
            $feat(C3D_PROFILE_INTERNAL) ? 1 : 0, $feat(C3D_PROFILE_GUI) ? 1 : 0);
        return 0;
    }
    fault excuse = options.enabled ? @catch(run_benchmark(options)) : @catch(run_example(options.gpu_timings));
    if (excuse) {
        io::eprintfn("Many-light example failed: %s", excuse);
        return 1;
    }
    return 0;
}

module many_lights_example @feat(C3D_PROFILE_CPU | C3D_PROFILE_GPU);

import c3d;
import c3d::profile;
import c3d::render;
import bench_loop;

alias BenchmarkRecorder @private = profile::Recorder;

const uint CAPTURE_FRAME_CAPACITY @local = render::FRAMES_IN_FLIGHT + 2; // history slots beyond the frames in flight so no capture is dropped
const uint CAPTURE_CPU_SCOPES @local = 64; // one application scope plus the renderer's library scopes for one view
const uint CAPTURE_MAX_DEPTH @local = 8;
const uint CAPTURE_GPU_SCOPES @local = 256; // frame, view, passes, clusters and shadow layers of one view
const uint CAPTURE_LABEL_BYTES @local = 8192; // 8 KiB of copied labels per retained frame

fn BenchmarkRecorder? create_benchmark_recorder() @private {
    profile::RecorderDesc desc = {
        .frame_capacity = CAPTURE_FRAME_CAPACITY,
        .label_bytes_per_frame = CAPTURE_LABEL_BYTES,
    };
    $if $feat(C3D_PROFILE_CPU):
        desc.cpu_scopes_per_frame = CAPTURE_CPU_SCOPES;
        desc.max_depth = CAPTURE_MAX_DEPTH;
    $endif
    $if $feat(C3D_PROFILE_GPU):
        desc.gpu_scopes_per_frame = CAPTURE_GPU_SCOPES;
    $endif
    return profile::create_recorder(mem, desc);
}

fn void destroy_benchmark_recorder(BenchmarkRecorder* recorder) @private {
    profile::destroy_recorder(recorder);
}

fn void? record_captured_frame(BenchmarkRun* run, uint frame, FrameSample* sample) @private {
    profile::@capture(run.recorder, frame) {
        profile::@scope("application.frame") {
            record_frame(run, frame, sample)!;
        };
    };
}
