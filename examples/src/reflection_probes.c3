module reflection_probes_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;

const String ENVIRONMENT_FILE @local = "../assets/ibl/studio_small_09_1k.hdr";
const float ENVIRONMENT_INTENSITY @local = 0.6f;
const float ROOM_HALF_WIDTH @local = 3;
const float ROOM_HALF_DEPTH @local = 3;
const float ROOM_HEIGHT @local = 3;
const float WALL_THICKNESS @local = 0.1f;
const float DOORWAY_HALF_WIDTH @local = 0.6f;
const float DOORWAY_HEIGHT @local = 2.2f;
const float WINDOW_HALF_WIDTH @local = 1;
const float WINDOW_SILL @local = 1;
const float SPHERE_RADIUS @local = 0.45f;
const float SPHERE_SPACING @local = 1;
const float SPHERE_ROW_DEPTH @local = 2;
const uint SPHERE_ROW_COUNT @local = 5;
const float[2] ENDS @local = { -1, 1 };
const float FLOOR_ROUGHNESS @local = 0.1f;
const float LAMP_INTENSITY @local = 14;
const float LAMP_RANGE @local = 9;
const float LAMP_HEIGHT @local = 2.6f;
const float PROBE_BLEND_DISTANCE @local = 0.5f;
const float PROBE_BLEND_MAX @local = 3;
const Vec3 PROBE_CAPTURE_OFFSET @local = { 0, -0.3f, 0 }; // below the lamp and above the floor spheres
const uint PROBE_COLOR @local = 0xFF40C0FF;
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 0.5f;
const float ORBIT_DISTANCE_MAX @local = 14;
const float ORBIT_START_DISTANCE @local = 4;
const Vec3 ORBIT_TARGET @local = { 0, 1.2f, 0 };
const uint WINDOW_WIDTH @local = 1280;
const uint WINDOW_HEIGHT @local = 720;
const uint BENCHMARK_WIDTH @local = 2560;
const uint BENCHMARK_HEIGHT @local = 1440;
const uint BENCHMARK_FRAMES @local = 100;
const uint BENCHMARK_WARMUP @local = 30;
const uint STAGE_WAIT_FRAMES @local = 8; // frames until the first frame's GPU stage times are published
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 320, 230 };
const Vec2 SCENE_PANEL_POSITION @local = { 16, 260 };
const Vec2 SCENE_PANEL_SIZE @local = { 320, 450 };
const Vec2 TARGETS_PANEL_POSITION @local = { 920, 16 };
const Vec2 TARGETS_PANEL_SIZE @local = { 344, 690 };
const Vec2 STATS_PANEL_POSITION @local = { 352, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 300, 520 };

struct Orbit @local {
    float distance;
    float yaw;
    float pitch;
}

struct Options @local {
    bool deferred;
    bool reflections;
    bool gpu_timings;
    bool benchmark;
    bool validation;
    uint capture_size;
    uint frames;
}

struct Demo @local {
    AssetStore* assets;
    Scene*      scene;
    Node*       camera_node;
    Node*[2]    probes;
    GeometryId  box;
    GeometryId  sphere;
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (input.button_down(platform::MouseButton.LEFT) && !input.mouse_captured_by_gui) {
        orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
        orbit.pitch = math::clamp(
            orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
            -ORBIT_PITCH_LIMIT,
            ORBIT_PITCH_LIMIT,
        );
    }
    if (input.wheel != 0 && !input.mouse_captured_by_gui) {
        float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
        orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
    }
    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = ORBIT_TARGET + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn void? add_slab(
    Demo* demo,
    Vec3 center,
    Vec3 size,
    MaterialId material,
) @local {
    Node* node = demo.scene.add_mesh(demo.box, material, name: "wall")!;
    node.local.position = center;
    node.local.scale = size;
}

// The warm room (side -1) also builds the wall both rooms share.
fn void? build_room(
    Demo* demo,
    float side,
    MaterialId wall,
    bool window,
) @local {
    float width = ROOM_HALF_WIDTH * 2;
    float depth = ROOM_HALF_DEPTH * 2;
    float middle = side * ROOM_HALF_WIDTH;
    float outer = side * width;
    add_slab(demo, { middle, ROOM_HEIGHT + WALL_THICKNESS * 0.5f, 0 }, { width, WALL_THICKNESS, depth }, wall)!;
    foreach (end : ENDS) {
        add_slab(demo, { middle, ROOM_HEIGHT * 0.5f, end * (ROOM_HALF_DEPTH + WALL_THICKNESS * 0.5f) },
            { width, ROOM_HEIGHT, WALL_THICKNESS }, wall)!;
    }
    float above = ROOM_HEIGHT - DOORWAY_HEIGHT;
    float flank = ROOM_HALF_DEPTH - DOORWAY_HALF_WIDTH;
    if (side < 0) {
        foreach (end : ENDS) {
            add_slab(demo, { 0, ROOM_HEIGHT * 0.5f, end * (DOORWAY_HALF_WIDTH + flank * 0.5f) },
                { WALL_THICKNESS, ROOM_HEIGHT, flank }, wall)!;
        }
        add_slab(demo, { 0, DOORWAY_HEIGHT + above * 0.5f, 0 },
            { WALL_THICKNESS, above, DOORWAY_HALF_WIDTH * 2 }, wall)!;
    }
    if (!window) {
        add_slab(demo, { outer, ROOM_HEIGHT * 0.5f, 0 }, { WALL_THICKNESS, ROOM_HEIGHT, depth }, wall)!;
        return;
    }
    float beside = ROOM_HALF_DEPTH - WINDOW_HALF_WIDTH;
    foreach (end : ENDS) {
        add_slab(demo, { outer, ROOM_HEIGHT * 0.5f, end * (WINDOW_HALF_WIDTH + beside * 0.5f) },
            { WALL_THICKNESS, ROOM_HEIGHT, beside }, wall)!;
    }
    add_slab(demo, { outer, WINDOW_SILL * 0.5f, 0 }, { WALL_THICKNESS, WINDOW_SILL, WINDOW_HALF_WIDTH * 2 }, wall)!;
    add_slab(demo, { outer, DOORWAY_HEIGHT + above * 0.5f, 0 }, { WALL_THICKNESS, above, WINDOW_HALF_WIDTH * 2 }, wall)!;
}

fn void? add_sphere_row(Demo* demo, float side, MaterialId[] materials) @local {
    float first = side * ROOM_HALF_WIDTH - SPHERE_SPACING * 2;
    foreach (index, material : materials) {
        Node* node = demo.scene.add_mesh(demo.sphere, material, name: "sphere")!;
        node.local.position = { first + (float)index * SPHERE_SPACING, SPHERE_RADIUS, -SPHERE_ROW_DEPTH };
    }
}

fn MaterialId? metal(AssetStore* assets, float roughness) @local {
    return assets.add_material(material::standard({
        .base_color = { 1, 1, 1, 1 },
        .metallic   = 1,
        .roughness  = roughness,
    }));
}

fn MaterialId? paint(AssetStore* assets, Vec3 color) @local {
    return assets.add_material(material::standard({
        .base_color = { color.x, color.y, color.z, 1 },
        .metallic   = 0,
        .roughness  = 0.8f,
    }));
}

fn void? build_scene(Demo* demo) @local {
    AssetStore* assets = demo.assets;
    Scene* scene = demo.scene;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        demo.box = assets.add_geometry(&box)!;
        Geometry sphere = geometry::sphere(tmem, SPHERE_RADIUS);
        demo.sphere = assets.add_geometry(&sphere)!;
    };

    MaterialId warm = paint(assets, { 0.9f, 0.45f, 0.25f })!;
    MaterialId cool = paint(assets, { 0.25f, 0.5f, 0.9f })!;
    build_room(demo, -1, warm, false)!;
    build_room(demo, 1, cool, true)!;
    MaterialId floor = assets.add_material(material::standard({
        .base_color = { 0.6f, 0.6f, 0.6f, 1 },
        .metallic   = 0,
        .roughness  = FLOOR_ROUGHNESS,
    }))!;
    add_slab(demo, { 0, -WALL_THICKNESS * 0.5f, 0 }, { ROOM_HALF_WIDTH * 4, WALL_THICKNESS, ROOM_HALF_DEPTH * 2 }, floor)!;

    MaterialId[SPHERE_ROW_COUNT] row;
    foreach (index, &slot : row) *slot = metal(assets, (float)index * 0.25f)!;
    add_sphere_row(demo, -1, &row)!;
    add_sphere_row(demo, 1, &row)!;
    PhysicalParams coat = material::PHYSICAL_PARAMS_DEFAULT;
    coat.standard.metallic = 0;
    coat.standard.base_color = { 0.7f, 0.05f, 0.05f, 1 };
    coat.clearcoat = 1;
    coat.clearcoat_roughness = 0.05f;
    PhysicalParams sheen = material::PHYSICAL_PARAMS_DEFAULT;
    sheen.standard.metallic = 0;
    sheen.standard.base_color = { 0.1f, 0.1f, 0.3f, 1 };
    sheen.sheen_color = { 1, 1, 1 };
    sheen.sheen_roughness = 0.4f;
    Node* coat_sphere = scene.add_mesh(demo.sphere, assets.add_material(material::physical(coat))!, name: "coat")!;
    coat_sphere.local.position = { -ROOM_HALF_WIDTH - 1, SPHERE_RADIUS, SPHERE_ROW_DEPTH };
    Node* sheen_sphere = scene.add_mesh(demo.sphere, assets.add_material(material::physical(sheen))!, name: "sheen")!;
    sheen_sphere.local.position = { -ROOM_HALF_WIDTH + 1, SPHERE_RADIUS, SPHERE_ROW_DEPTH };

    Node* warm_lamp = scene.add_light(light::point({ 1, 0.65f, 0.35f }, LAMP_INTENSITY, LAMP_RANGE), name: "warm_lamp")!;
    warm_lamp.local.position = { -ROOM_HALF_WIDTH, LAMP_HEIGHT, 0 };
    Node* cool_lamp = scene.add_light(light::point({ 0.4f, 0.65f, 1 }, LAMP_INTENSITY, LAMP_RANGE), name: "cool_lamp")!;
    cool_lamp.local.position = { ROOM_HALF_WIDTH, LAMP_HEIGHT, 0 };

    foreach (index, &probe : demo.probes) {
        float side = index == 0 ? -1.0f : 1.0f;
        *probe = scene.add_node(name: "reflection_probe")!;
        probe.local.position = { side * ROOM_HALF_WIDTH, ROOM_HEIGHT * 0.5f, 0 };
        ReflectionProbe component = light::reflection_probe({ ROOM_HALF_WIDTH, ROOM_HEIGHT * 0.5f, ROOM_HALF_DEPTH }, {});
        component.capture_offset = PROBE_CAPTURE_OFFSET;
        component.blend_distance = PROBE_BLEND_DISTANCE;
        scene.add(*probe, component);
    }
    demo.camera_node = scene.add_camera(camera::perspective_deg(60, 0.05f), name: "camera")!;
    scene.update_world();
}

fn void? install_environment(Demo* demo, Renderer* renderer) @local {
    AssetStore* assets = demo.assets;
    TextureId source = image::load_hdr(assets, example_path(ENVIRONMENT_FILE), "reflection_probes/source/studio")!;
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(source, light::ENVIRONMENT_SETTINGS_DEFAULT),
        "reflection_probes/environment/studio",
    )!;
    renderer.upload_environment(environment)!;
    Scene* scene = demo.scene;
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
}

fn void? capture_probes(
    Demo* demo,
    Renderer* renderer,
    Options options,
    double[2]* elapsed,
    bool upload,
) @local {
    ReflectionCaptureDesc desc = render::REFLECTION_CAPTURE_DESC_DEFAULT;
    desc.size = options.capture_size;
    foreach (index, probe_node : demo.probes) {
        ReflectionProbe* probe = demo.scene.get(probe_node, ReflectionProbe);
        probe.environment = renderer.capture_reflection_probe(demo.scene, probe_node, desc)!;
        if (upload) renderer.upload_environment(probe.environment)!;
        if (elapsed) (*elapsed)[index] = renderer.last_reflection_capture.elapsed_ms;
    }
}

fn ViewDesc view_desc_for(ViewDesc base, Options options) @local {
    if (options.deferred || options.reflections) base.shading = ShadingPath.DEFERRED;
    base.ray_tracing.reflections = options.reflections;
    return base;
}

fn Renderer? create_example_renderer(
    Allocator allocator,
    platform::Window* window,
    AssetStore* assets,
    Options options,
) @local {
    RendererDesc desc = {
        .gpu_timings      = options.gpu_timings,
        .validation       = options.validation || !options.benchmark,
        .ray_queries      = options.reflections,
        .application_name = "c3d_reflection_probes",
    };
    if (window) return platform::create_window_renderer(allocator, window, assets, desc);
    return render::create_renderer(allocator, assets, desc);
}

fn void? draw_frame(
    Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    DebugDraw* debug,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view, debug)!;
        renderer.finish_view(renderer.default_view)!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    return renderer.end_frame();
}

fn void? run_gui(
    platform::Window* window,
    Renderer* renderer,
    Demo* demo,
    Options options,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);
    render::configure_view(renderer, renderer.default_view, view_desc_for(render::default_view_desc(), options))!;
    renderer.prepare_scene(demo.scene)!;

    Scene* scene = demo.scene;
    TargetsPanelState targets = gui::default_targets_panel_state();
    GuiPanelState panel = { .selected = demo.probes[0].id };
    Orbit orbit = { .distance = ORBIT_START_DISTANCE, .yaw = -(float)math::HALF_PI, .pitch = 0.15f };
    bool probes_on = true;
    bool draw_boxes = true;
    float blend = PROBE_BLEND_DISTANCE;
    int projection;

    while (window.poll()) {
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;

        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Reflection probes", null, {})) {
            if (imgui::checkbox("Probes on", &probes_on)) {
                foreach (probe : demo.probes) probe.visible = probes_on;
            }
            imgui::checkbox("Box lines", &draw_boxes);
            if (imgui::slider_float("Blend distance", &blend, 0, PROBE_BLEND_MAX)) {
                foreach (probe : demo.probes) scene.get(probe, ReflectionProbe).blend_distance = blend;
            }
            ZString[ReflectionProjection::len] projections = { "Box", "Infinite" };
            if (imgui::combo_char("Projection", &projection, &projections, ReflectionProjection::len)) {
                foreach (probe : demo.probes) {
                    scene.get(probe, ReflectionProbe).projection = ReflectionProjection::from_ordinal((usz)projection);
                }
            }
            if (imgui::button("Re-capture both")) {
                ReflectionCaptureDesc desc = render::REFLECTION_CAPTURE_DESC_DEFAULT;
                desc.size = options.capture_size;
                foreach (probe : demo.probes) renderer.recapture_reflection_probe(scene, probe, desc)!;
            }
            imgui::text("Trace: %s", renderer.caps.ray_queries.enabled ? "ray queries" : "software BVH");
        }
        imgui::end();

        imgui::set_next_window_pos(SCENE_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(SCENE_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::scene_panel(scene, &panel);
        ReflectionCaptureDesc selected_desc = render::REFLECTION_CAPTURE_DESC_DEFAULT;
        selected_desc.size = options.capture_size;
        gui::reflection_capture_buttons(renderer, scene, &panel, selected_desc)!;

        EnvironmentId shown = {};
        if (scene.world.is_alive(panel.selected)) {
            ReflectionProbe* selected = scene.get(scene.node(panel.selected), ReflectionProbe);
            if (selected && renderer.assets.environments.is_live(selected.environment)) shown = selected.environment;
        }
        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::targets_panel(renderer, renderer.default_view, &targets, shown)!;

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        apply_orbit(&orbit, input, demo.camera_node);
        scene.update_world();
        debug.clear();
        if (draw_boxes) debug.reflection_probes(scene, PROBE_COLOR);
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  demo.camera_node,
            debug:        &debug,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn void? render_one_frame(Renderer* renderer, Demo* demo, ViewId view) @local {
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(demo.scene, demo.camera_node, view)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
}

fn void? run_benchmark(Demo* demo, Renderer* renderer, Options options) @local {
    RenderTargetId target = render::create_render_target(
        renderer: renderer,
        desc:     render::render_target_desc(BENCHMARK_WIDTH, BENCHMARK_HEIGHT, PixelFormat.RGBA8_UNORM),
    )!;
    ViewId view = render::create_view(
        renderer: renderer,
        desc:     view_desc_for(render::texture_view_desc(target, OutputMode.DISPLAY_LDR), options),
    )!;
    Scene* scene = demo.scene;
    demo.camera_node.local.position = ORBIT_TARGET + (Vec3){ -ORBIT_START_DISTANCE, 0.6f, 0 };
    demo.camera_node.local.rotation = maths::look_rotation({ 1, -0.15f, 0 }, { 0, 1, 0 });
    scene.update_world();

    double[2] elapsed;
    capture_probes(demo, renderer, options, &elapsed, false)!;
    io::printfn("capture_size=%d", options.capture_size);
    io::printfn("probe_a_capture_ms=%.3f probe_b_capture_ms=%.3f", elapsed[0], elapsed[1]);

    render_one_frame(renderer, demo, view)!;
    float prefilter_ms;
    float irradiance_ms;
    $if $feat(C3D_PROFILE_GPU):
        for (uint wait = 0; wait < STAGE_WAIT_FRAMES && prefilter_ms == 0; wait++) {
            render_one_frame(renderer, demo, view)!;
            prefilter_ms = renderer.stats.gpu_environment_stage_ms[EnvironmentStage.PREFILTER.ordinal];
            irradiance_ms = renderer.stats.gpu_environment_stage_ms[EnvironmentStage.IRRADIANCE.ordinal];
        }
    $endif
    io::printfn("first_frame environment.prefilter_ms=%.4f environment.irradiance_ms=%.4f", prefilter_ms, irradiance_ms);

    bool deferred_pass = options.deferred || options.reflections;
    Pass pass = deferred_pass ? Pass.LIGHTING : Pass.FORWARD_OPAQUE;
    for (uint frame = 0; frame < BENCHMARK_WARMUP; frame++) render_one_frame(renderer, demo, view)!;
    double total_ms;
    uint samples;
    for (uint frame = 0; frame < options.frames; frame++) {
        render_one_frame(renderer, demo, view)!;
        $if $feat(C3D_PROFILE_GPU):
            if (renderer.stats.gpu_pass_valid[pass.ordinal]) {
                total_ms += renderer.stats.gpu_pass_ms[pass.ordinal];
                samples++;
            }
        $endif
    }
    render::wait_frames(renderer)!;
    String label = deferred_pass ? "lighting" : "forward_opaque";
    if (samples) {
        io::printfn("gpu_%s_ms=%.4f samples=%d", label, total_ms / samples, samples);
    } else {
        io::printfn("gpu_%s_ms=unavailable", label);
    }
}

fn Options? parse_options(String[] args) @local {
    Options options = { .capture_size = render::DEFAULT_REFLECTION_CAPTURE_SIZE, .frames = BENCHMARK_FRAMES };
    for (usz index = 1; index < args.len; index++) {
        switch (args[index]) {
            case "--deferred": options.deferred = true;
            case "--reflections": options.reflections = true;
            case "--gpu-timings":
                $if $feat(C3D_PROFILE_GPU):
                    options.gpu_timings = true;
                $else
                    io::eprintn("--gpu-timings needs GPU profiling: c3c build reflection_probes --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                    return c3d::UNSUPPORTED~;
                $endif
            case "--benchmark": options.benchmark = true;
            case "--validation": options.validation = true;
            case "--frames":
                if (++index >= args.len) return c3d::INVALID_ARGUMENT~;
                options.frames = args[index].to_uint()!;
                if (!options.frames) return c3d::INVALID_ARGUMENT~;
            case "--capture-size":
                if (++index >= args.len) return c3d::INVALID_ARGUMENT~;
                options.capture_size = args[index].to_uint()!;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    return options;
}

<* Two rooms with a reflection probe each, interactively or as a headless benchmark. *>
fn int main(String[] args) {
    Options? parsed = parse_options(args);
    if (catch excuse = parsed) {
        if (excuse != c3d::UNSUPPORTED) {
            io::eprintfn("Invalid options: %s", excuse);
            io::eprintn("Use [--deferred] [--reflections] [--gpu-timings] [--validation] [--capture-size N] [--benchmark [--frames N]].");
        }
        return 1;
    }
    Options options = parsed;

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Demo demo = { .assets = &assets, .scene = &scene };
    if (catch excuse = build_scene(&demo)) {
        io::eprintfn("Building the scene failed: %s", excuse);
        return 1;
    }

    platform::Window window;
    if (!options.benchmark) {
        platform::Window? created_window = platform::create_window(
            platform::default_window_desc("c3d reflection probes", WINDOW_WIDTH, WINDOW_HEIGHT));
        if (catch excuse = created_window) {
            io::eprintfn("Window creation failed: %s", excuse);
            return 1;
        }
        window = created_window;
    }
    defer if (!options.benchmark) platform::destroy_window(&window);

    Renderer? created = create_example_renderer(mem, options.benchmark ? null : &window, &assets, options);
    if (catch excuse = created) {
        io::eprintfn("reflection_probes: renderer creation failed (%s)", excuse);
        return 1;
    }
    Renderer renderer = created;
    defer render::destroy_renderer(&renderer);

    if (catch excuse = install_environment(&demo, &renderer)) {
        io::eprintfn("Loading the environment failed (%s)", excuse);
        return 1;
    }
    if (options.benchmark) {
        if (catch excuse = run_benchmark(&demo, &renderer, options)) {
            io::eprintfn("Benchmark failed: %s", excuse);
            return 1;
        }
        return 0;
    }
    if (catch excuse = capture_probes(&demo, &renderer, options, null, true)) {
        io::eprintfn("Capturing the probes failed: %s", excuse);
        return 1;
    }
    if (catch excuse = run_gui(&window, &renderer, &demo, options)) {
        io::eprintfn("GUI failed: %s", excuse);
        return 1;
    }
    return 0;
}
