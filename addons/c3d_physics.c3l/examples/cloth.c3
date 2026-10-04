module cloth_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;
import std::io;
import std::io::file;
import std::math;
import std::math::quaternion;
import std::sort;
import std::time;
import std::time::clock;

const uint WIDTH @local = 1280;
const uint HEIGHT @local = 720;
const uint FLAG_COLUMNS @local = 24;
const uint FLAG_ROWS @local = 16;
const uint BENCHMARK_CELLS @local = 32; // a 33x33-vertex flag at the default 4x8 solver settings
const float FLAG_WIDTH @local = 1.8f;
const float FLAG_HEIGHT @local = 1.2f;
const float POLE_HEIGHT @local = 4;
const float POLE_RADIUS @local = 0.05f;
const float AIR_RESPONSE @local = 2.5f; // per second: particle acceleration per m/s of normal wind, at any flag resolution
const float DEFAULT_WIND_SPEED @local = 6;
const float DEFAULT_WIND_HEADING @local = 35; // degrees off the flag plane; drag acts on the normal component only
const float GUST_SHARE @local = 0.35f; // fraction of the speed a gust adds or removes
const float GUST_RATE @local = 0.7f; // radians per second
const uint WARMUP_FRAMES @local = 120; // two simulated seconds settle the flag before measuring
const uint MEASURED_FRAMES @local = 600;
const float STEP_SECONDS @local = 1.0f / 60;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const double PERCENTILE_95 @local = 0.95;
const uint CAPTURE_CHANNELS @local = 4;

struct Options @local {
    bool   benchmark;
    uint   frames;
    String capture_path;
}

struct Demo @local {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    Node*        flag;
    Node*        camera;
    MaterialId   cloth_material;
    float        wind_speed;
    float        wind_heading;
    bool         gusts;
}

struct Controls @local {
    bool taa;
    bool motion_blur;
    bool reset;
}

fn Geometry flag_grid(Allocator allocator, uint columns, uint rows) @local {
    uint width = columns + 1;
    Geometry grid = {
        .positions = alloc::new_array(allocator, Vec3, (sz)(width * (rows + 1))),
        .uv0       = alloc::new_array(allocator, Vec2, (sz)(width * (rows + 1))),
        .indices   = alloc::new_array(allocator, uint, (sz)(6 * columns * rows)),
    };
    for (uint row = 0; row <= rows; row++) {
        for (uint column = 0; column <= columns; column++) {
            float u = (float)column / columns;
            float v = (float)row / rows;
            grid.positions[row * width + column] = { u * FLAG_WIDTH, -v * FLAG_HEIGHT, 0 };
            grid.uv0[row * width + column] = { u, v };
        }
    }
    usz next;
    for (uint row = 0; row < rows; row++) {
        for (uint column = 0; column < columns; column++) {
            uint top_left = row * width + column;
            uint bottom_left = top_left + width;
            uint[6] corners = { top_left, bottom_left, top_left + 1, top_left + 1, bottom_left, bottom_left + 1 };
            grid.indices[next:6] = corners[..];
            next += 6;
        }
    }
    grid.finalize();
    return grid;
}

fn void? create_demo(Demo* demo, uint columns, uint rows) @local {
    demo.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&demo.assets);
    demo.scene = scene::create_scene(mem, scene::default_scene_desc());
    defer catch scene::destroy_scene(&demo.scene);
    physics::register_physics(&demo.scene)!;
    demo.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &demo.assets,
        scene:     &demo.scene,
        desc:      physics::default_physics_desc(),
    )!;
    defer catch physics::destroy_physics_world(&demo.physics);

    MaterialCommon two_sided = material::MATERIAL_COMMON_DEFAULT;
    two_sided.double_sided = true;
    demo.cloth_material = demo.assets.add_material(material::standard({
        .base_color = { 0.75f, 0.12f, 0.1f, 1 }, .roughness = 0.8f,
    }, two_sided))!;
    MaterialId pole_material = demo.assets.add_material(material::standard({
        .base_color = { 0.55f, 0.55f, 0.58f, 1 }, .roughness = 0.4f, .metallic = 1,
    }))!;
    MaterialId ground_material = demo.assets.add_material(material::standard({
        .base_color = { 0.22f, 0.27f, 0.2f, 1 }, .roughness = 0.95f,
    }))!;
    GeometryId flag_geometry;
    GeometryId pole_geometry;
    GeometryId ground_geometry;
    @pool() {
        Geometry flag = flag_grid(tmem, columns, rows);
        flag_geometry = demo.assets.add_geometry(&flag, "cloth/flag")!;
        Geometry pole = geometry::cylinder(tmem, POLE_RADIUS, POLE_RADIUS, POLE_HEIGHT);
        pole_geometry = demo.assets.add_geometry(&pole, "cloth/pole")!;
        Geometry ground = geometry::plane(tmem, 40, 40);
        ground_geometry = demo.assets.add_geometry(&ground, "cloth/ground")!;
    };
    demo.scene.add_mesh(ground_geometry, ground_material, name: "ground")!;
    Node* pole = demo.scene.add_mesh(pole_geometry, pole_material, name: "pole")!;
    pole.local.position = { 0, POLE_HEIGHT * 0.5f, 0 };
    demo.flag = demo.scene.add_mesh(flag_geometry, demo.cloth_material, name: "flag")!;
    demo.flag.local.position = { POLE_RADIUS, POLE_HEIGHT - 0.1f, 0 };
    demo.scene.get(demo.flag, scene::Mesh).trace = false;
    // Particles have unit mass, so drag scales with vertex density to keep the response resolution-independent.
    float vertex_density = (float)((columns + 1) * (rows + 1)) / (FLAG_WIDTH * FLAG_HEIGHT);
    demo.scene.add(demo.flag, (Wind){ .drag = AIR_RESPONSE * vertex_density });
    Node* sun = demo.scene.add_light(light::directional({ 1, 0.96f, 0.9f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.6f }).normalize(), { 0, 1, 0 });
    demo.scene.ambient_color = { 0.55f, 0.65f, 0.8f };
    demo.scene.ambient_intensity = 0.35f;
    demo.scene.background = { .kind = COLOR, .color = { 0.45f, 0.6f, 0.8f, 1 } };
    demo.camera = demo.scene.add_camera(camera::perspective_deg(45, 0.05f), name: "camera")!;
    demo.camera.local.position = { 1.4f, POLE_HEIGHT - 0.6f, 4.2f };
    demo.camera.local.rotation = maths::look_rotation(((Vec3){ -0.25f, 0, -1 }).normalize(), { 0, 1, 0 });
    demo.scene.update_world();

    ClothDesc desc = cloth::default_cloth_desc();
    @pool() {
        uint[] pins = alloc::new_array(tmem, uint, (sz)(rows + 1));
        foreach (row, &pin : pins) *pin = (uint)row * (columns + 1);
        desc.pins = pins;
        demo.scene.add_cloth(&demo.assets, demo.flag, desc)!;
    };
    demo.wind_speed = DEFAULT_WIND_SPEED;
    demo.wind_heading = DEFAULT_WIND_HEADING;
    demo.gusts = true;
}

fn void destroy_demo(Demo* demo) @local {
    physics::destroy_physics_world(&demo.physics);
    scene::destroy_scene(&demo.scene);
    asset::destroy_asset_store(&demo.assets);
}

fn void apply_wind(Demo* demo, double time) @local {
    float speed = demo.wind_speed;
    if (demo.gusts) speed *= 1 + GUST_SHARE * math::sin((float)time * GUST_RATE) * math::sin((float)time * GUST_RATE * 2.3f);
    float heading = math::deg_to_rad(demo.wind_heading);
    demo.scene.get(demo.flag, Wind).velocity = { math::cos(heading) * speed, 0, math::sin(heading) * speed };
}

fn void step_demo(Demo* demo, float delta, double time) @local {
    apply_wind(demo, time);
    demo.scene.update_world();
    demo.physics.update(delta);
    demo.scene.update_world();
    demo.physics.update_cloths();
}

fn void? configure_temporal(Renderer* renderer, ViewId view, Controls controls) @local {
    ViewDesc desc = renderer.views.get(view).desc;
    desc.post.anti_aliasing = controls.taa ? AntiAliasing.TAA : AntiAliasing.NONE;
    desc.post.motion_blur = controls.motion_blur;
    return render::configure_view(renderer, view, desc);
}

fn void panel(Demo* demo, Controls* controls, Renderer* renderer, float frame_ms) @local {
    if (imgui::begin("Cloth", null, {})) {
        ClothStats stats = demo.physics.cloth_stats;
        imgui::text("Solve %.3f ms, publish %.3f ms", stats.solve_seconds * 1000, stats.publish_seconds * 1000);
        imgui::text("Particles %u, constraints %u", stats.particles, stats.constraints);
        imgui::text("Geometry upload %u bytes, frame %.2f ms", renderer.stats.upload_bytes, frame_ms);
        imgui::slider_float(
            label: "Wind speed",
            v: &demo.wind_speed,
            v_min: 0,
            v_max: 20,
        );
        imgui::slider_float(
            label: "Wind heading",
            v: &demo.wind_heading,
            v_min: -180,
            v_max: 180,
        );
        imgui::checkbox("Gusts", &demo.gusts);
        imgui::checkbox("TAA", &controls.taa);
        imgui::checkbox("Motion blur", &controls.motion_blur);
        controls.reset = imgui::button("Reset flag");
    }
    imgui::end();
}

fn void? reset_flag(Demo* demo) @local {
    demo.scene.remove_cloth(demo.flag);
    ClothDesc desc = cloth::default_cloth_desc();
    @pool() {
        uint[] pins = alloc::new_array(tmem, uint, (sz)(FLAG_ROWS + 1));
        foreach (row, &pin : pins) *pin = (uint)row * (FLAG_COLUMNS + 1);
        desc.pins = pins;
        demo.scene.add_cloth(&demo.assets, demo.flag, desc)!;
    };
}

fn void? run_interactive(Options options) @local {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d cloth", WIDTH, HEIGHT))!;
    defer platform::destroy_window(&window);
    Demo demo;
    create_demo(&demo, FLAG_COLUMNS, FLAG_ROWS)!;
    defer destroy_demo(&demo);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &demo.assets,
        desc: { .validation = true, .gpu_timings = true },
    )!;
    defer render::destroy_renderer(&renderer);
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    Controls controls = { .taa = true, .motion_blur = true };
    Controls applied;
    double elapsed;
    float frame_ms;
    uint frame;
    while (window.poll()) {
        if (options.frames && frame++ >= options.frames) break;
        if (window.input.key_released(platform::Scancode.ESCAPE) && !window.input.keyboard_captured_by_gui) break;
        time::Clock started = clock::now();
        @pool() {
            gui_renderer.new_frame();
            defer if (gui_renderer.frame_open) gui_renderer.finish_frame();
            panel(&demo, &controls, &renderer, frame_ms);
            gui_renderer.finish_frame();
            platform::sync_window(&window, &renderer);
            if (controls.taa != applied.taa || controls.motion_blur != applied.motion_blur || !frame) {
                configure_temporal(&renderer, renderer.default_view, controls)!;
                applied = controls;
            }
            if (controls.reset) reset_flag(&demo)!;
            elapsed += window.clock.delta;
            step_demo(&demo, window.clock.delta, elapsed);
            renderer.begin_frame({ .time = elapsed, .delta = window.clock.delta, .reference_position = demo.camera.world_position() })!;
            defer catch render::abort_frame(&renderer);
            if (renderer.has_output) {
                renderer.render_view(&demo.scene, demo.camera, renderer.default_view)!;
                renderer.finish_view(renderer.default_view)!;
                OverlayContext overlay = renderer.begin_overlay()!;
                gui_renderer.record(&overlay)!;
                renderer.end_overlay(&overlay)!;
            }
            renderer.end_frame()!;
        };
        frame_ms = (float)((double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND);
    }
    return renderer.log.check_validation();
}

fn double percentile(double[] samples, double fraction) @local {
    sort::quicksort(samples);
    usz index = (usz)math::min((double)(samples.len - 1), math::floor(fraction * (double)samples.len));
    return samples[index];
}

fn double mean(double[] samples) @local {
    double total;
    foreach (sample : samples) total += sample;
    return total / (double)samples.len;
}

fn void? run_benchmark(Options options) @local {
    Demo demo;
    create_demo(&demo, BENCHMARK_CELLS, BENCHMARK_CELLS)!;
    defer destroy_demo(&demo);
    demo.gusts = false;
    Renderer renderer = render::create_renderer(mem, &demo.assets, { .validation = true, .gpu_timings = true })!;
    defer render::destroy_renderer(&renderer);
    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc: render::render_target_desc(WIDTH, HEIGHT, PixelFormat.RGBA8_SRGB),
    )!;
    ViewDesc view_desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    view_desc.post.anti_aliasing = AntiAliasing.TAA;
    view_desc.post.motion_blur = true;
    ViewId view = render::create_view(&renderer, view_desc)!;
    double[MEASURED_FRAMES] solve_ms;
    double[MEASURED_FRAMES] publish_ms;
    double[MEASURED_FRAMES] gpu_ms;
    usz gpu_samples;
    ulong upload_bytes;
    ulong first_measured = renderer.frame_index + WARMUP_FRAMES;
    ulong last_gpu_frame = ulong::max;
    uint total_frames = WARMUP_FRAMES + MEASURED_FRAMES + render::FRAMES_IN_FLIGHT + 1;
    for (uint frame = 0; frame < total_frames; frame++) {
        double time = (double)frame * STEP_SECONDS;
        step_demo(&demo, STEP_SECONDS, time);
        renderer.begin_frame({ .time = time, .delta = STEP_SECONDS })!;
        defer catch render::abort_frame(&renderer);
        renderer.render_view(&demo.scene, demo.camera, view)!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
        if (frame >= WARMUP_FRAMES && frame < WARMUP_FRAMES + MEASURED_FRAMES) {
            solve_ms[frame - WARMUP_FRAMES] = demo.physics.cloth_stats.solve_seconds * 1000;
            publish_ms[frame - WARMUP_FRAMES] = demo.physics.cloth_stats.publish_seconds * 1000;
            upload_bytes += renderer.stats.upload_bytes;
        }
        Stats* stats = &renderer.stats;
        if (stats.gpu_timing_state == GpuTimingState.READY && stats.gpu_frame_index != last_gpu_frame
            && stats.gpu_frame_index >= first_measured && stats.gpu_frame_index < first_measured + MEASURED_FRAMES) {
            double total;
            foreach (pass_ms : stats.gpu_pass_ms) total += pass_ms;
            gpu_ms[gpu_samples++] = total;
            last_gpu_frame = stats.gpu_frame_index;
        }
    }
    if (options.capture_path.len) {
        char[] pixels = alloc::new_array(mem, char, WIDTH * HEIGHT * CAPTURE_CHANNELS);
        defer alloc::free(mem, pixels.ptr);
        renderer.read_render_target(target, pixels)!;
        file::save(options.capture_path, pixels)!;
    }
    ClothStats stats = demo.physics.cloth_stats;
    io::printfn("adapter,%s", renderer.adapter_name);
    io::printfn("resolution,%dx%d,flag_vertices,%d,constraints,%d", WIDTH, HEIGHT, stats.particles, stats.constraints);
    io::printfn("frames,%d,warmup,%d,substeps,%d,iterations,%d", MEASURED_FRAMES, WARMUP_FRAMES,
        cloth::DEFAULT_CLOTH_SUBSTEPS, cloth::DEFAULT_CLOTH_ITERATIONS);
    io::printfn("solve_ms,mean,%.4f,p95,%.4f", mean(solve_ms[..]), percentile(solve_ms[..], PERCENTILE_95));
    io::printfn("publish_ms,mean,%.4f,p95,%.4f", mean(publish_ms[..]), percentile(publish_ms[..], PERCENTILE_95));
    io::printfn("upload_bytes_per_frame,%.0f", (double)upload_bytes / MEASURED_FRAMES);
    if (gpu_samples) {
        io::printfn("gpu_frame_ms,samples,%d,median,%.4f,p95,%.4f", gpu_samples,
            percentile(gpu_ms[:gpu_samples], 0.5), percentile(gpu_ms[:gpu_samples], PERCENTILE_95));
    }
    return renderer.log.check_validation();
}

fn Options? parse_options(String[] args) @local {
    Options options;
    for (usz index = 1; index < args.len; index++) {
        if (args[index] == "--benchmark") {
            options.benchmark = true;
        } else if (args[index] == "--frames" && index + 1 < args.len) {
            options.frames = args[++index].to_uint()!;
        } else if (args[index] == "--capture" && index + 1 < args.len) {
            options.capture_path = args[++index];
        } else {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    return options;
}

fn int main(String[] args) {
    Options? options = parse_options(args);
    if (catch excuse = options) {
        io::eprintn("Use cloth [--benchmark [--capture path.rgba]] [--frames count].");
        return 1;
    }
    fault excuse = options.benchmark ? @catch(run_benchmark(options)) : @catch(run_interactive(options));
    if (excuse) {
        io::eprintfn("Cloth example failed: %s", excuse);
        return 1;
    }
    return 0;
}
