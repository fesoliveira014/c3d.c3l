module probe_volume_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::asset::image;
import c3d::camera;
import c3d::debug;
import c3d::gui;
import c3d::light;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;

const String MODEL_FILE @local = "../assets/benchmark/sponza/glTF/Sponza.gltf";
const String ENVIRONMENT_FILE @local = "../assets/ibl/studio_small_09_1k.hdr";
const float SUN_INTENSITY @local = 3;
const float ENVIRONMENT_INTENSITY @local = 0.8f;
const float BACKGROUND_INTENSITY @local = 0.3f;
const uint[<3>] PROBE_COUNTS @local = { 16, 8, 8 }; // 1024 probes, 1.5 MiB of atlases
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN_SCALE @local = 0.05f;
const float ORBIT_DISTANCE_MAX_SCALE @local = 2;
const float ORBIT_START_SCALE @local = 0.25f;
const float NEAR_PLANE_SCALE @local = 0.002f;
const uint WINDOW_WIDTH @local = 1280;
const uint WINDOW_HEIGHT @local = 720;
const uint PROBE_COLOR @local = 0xFF40C0FF;
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 320, 130 };
const Vec2 SCENE_PANEL_POSITION @local = { 16, 160 };
const Vec2 SCENE_PANEL_SIZE @local = { 320, 540 };
const Vec2 TARGETS_PANEL_POSITION @local = { 920, 16 };
const Vec2 TARGETS_PANEL_SIZE @local = { 344, 690 };
const Vec2 STATS_PANEL_POSITION @local = { 352, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 300, 520 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float minimum;
    float maximum;
    float yaw;
    float pitch;
}

struct Options @local {
    bool gpu_timings;
    bool deferred;
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
        orbit.distance = math::clamp(zoomed, orbit.minimum, orbit.maximum);
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn Aabb template_bounds(AssetStore* assets, ModelTemplate* template) @local {
    Mat4[] node_matrices = alloc::new_array(tmem, Mat4, template.nodes.len);
    foreach (index, &node : template.nodes) {
        Mat4 local = node.local.to_mat4();
        node_matrices[index] = node.parent < 0 ? local : node_matrices[node.parent].mul(local);
    }
    Aabb bounds = { .min = { 0, 0, 0 }, .max = { 0, 0, 0 } };
    foreach (index, &mesh : template.meshes) {
        Aabb mesh_bounds = maths::aabb_transform(assets.geometry(mesh.geometry).data.bounds, node_matrices[mesh.node]);
        bounds = index == 0 ? mesh_bounds : maths::aabb_merge(bounds, mesh_bounds);
    }
    return bounds;
}

fn void? draw_frame(
    render::Renderer* renderer,
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
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Node* volume_node,
    Orbit* orbit,
    EnvironmentId environment,
    Options options,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);

    ViewDesc view_desc = render::default_view_desc();
    if (options.deferred) view_desc.shading = ShadingPath.DEFERRED;
    render::configure_view(renderer, renderer.default_view, view_desc)!;
    renderer.prepare_scene(scene)!;

    TargetsPanelState targets = gui::default_targets_panel_state();
    GuiPanelState panel = { .selected = volume_node.id };
    bool draw_probes = true;

    while (window.poll()) {
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;

        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Probe volume", null, {})) {
            imgui::text_unformatted("Hiding the volume node shows the SH term.");
            imgui::checkbox("Volume visible", &volume_node.visible);
            imgui::checkbox("Draw probes", &draw_probes);
        }
        imgui::end();

        imgui::set_next_window_pos(SCENE_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(SCENE_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::scene_panel(scene, &panel);

        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::targets_panel(renderer, renderer.default_view, &targets, environment)!;

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        apply_orbit(orbit, input, camera_node);
        scene.update_world();
        debug.clear();
        if (draw_probes) debug.probe_volumes(scene, PROBE_COLOR);
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            debug:        &debug,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main(String[] args) {
    Options options;
    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            $if $feat(C3D_PROFILE_GPU):
                options.gpu_timings = true;
            $else
                io::eprintfn("--gpu-timings needs GPU profiling: c3c build probe_volume --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                return 1;
            $endif
        } else if (argument == "--deferred") {
            options.deferred = true;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    String model_path = example_path(MODEL_FILE);
    ModelId model;
    if (catch excuse = gltf::load_model(&assets, model_path)) {
        io::printfn("Loading %s failed (%s): run python3 scripts/fetch_benchmark_assets.py", model_path, excuse);
        return 1;
    } else {
        model = assets.find_model(model_path)!!;
    }
    TextureId environment_source = image::load_hdr(
        &assets,
        example_path(ENVIRONMENT_FILE),
        "probe_volume/source/studio",
    )!!;
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(environment_source, light::ENVIRONMENT_SETTINGS_DEFAULT),
        "probe_volume/environment/studio",
    )!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    model::instantiate(&assets, &scene, model, name: "sponza")!!;
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = BACKGROUND_INTENSITY;
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, SUN_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.3f, -1, -0.2f }.normalize(), { 0, 1, 0 });

    Aabb bounds;
    @pool() {
        bounds = template_bounds(&assets, &assets.model(model).data);
    };
    Node* volume_node = scene.add_node(name: "probe_volume")!!;
    volume_node.local.position = (bounds.min + bounds.max) * 0.5f;
    scene.add(volume_node, light::probe_volume((bounds.max - bounds.min) * 0.5f, PROBE_COUNTS));

    float radius = math::max((bounds.max - bounds.min).length() * 0.5f, 0.001f);
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, radius * NEAR_PLANE_SCALE), name: "camera")!!;
    Orbit orbit = {
        .target   = (bounds.min + bounds.max) * 0.5f,
        .distance = radius * ORBIT_START_SCALE,
        .minimum  = radius * ORBIT_DISTANCE_MIN_SCALE,
        .maximum  = radius * ORBIT_DISTANCE_MAX_SCALE,
        .yaw      = (float)math::HALF_PI,
        .pitch    = 0.15f,
    };

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d probe volume", WINDOW_WIDTH, WINDOW_HEIGHT))!!;
    defer platform::destroy_window(&window);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      {
            .gpu_timings      = options.gpu_timings,
            .validation       = true,
            .application_name = "c3d_probe_volume",
        },
    )!!;
    defer render::destroy_renderer(&renderer);

    if (catch excuse = run_gui(
        window:      &window,
        renderer:    &renderer,
        scene:       &scene,
        camera_node: camera_node,
        volume_node: volume_node,
        orbit:       &orbit,
        environment: environment,
        options:     options,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }
    return 0;
}
