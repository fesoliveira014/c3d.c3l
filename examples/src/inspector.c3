module inspector_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::asset::image;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 0.5f;
const float ORBIT_DISTANCE_MAX @local = 60;
const float SPIN_RADIANS_PER_SECOND @local = 0.4f;
const float MODEL_SCALE @local = 0.02f; // the fox is authored in centimetres
const float INSTANCE_SPACING @local = 3;
const float GROUND_SIZE @local = 20;
const float SUN_INTENSITY @local = 2.5f;
const float SPOT_INTENSITY @local = 120;
const float POINT_INTENSITY @local = 30;
const float ENVIRONMENT_INTENSITY @local = 0.5f;
const float BACKGROUND_INTENSITY @local = 0.3f;
const float SELECTED_AXES_SIZE @local = 0.5f;
const uint SUN_CASCADES @local = 3;
const uint MODEL_CAPACITY @local = 4;
const String MODEL_FILE @local = "../assets/gltf/Fox.glb";
const String ENVIRONMENT_FILE @local = "../assets/ibl/studio_small_09_1k.hdr";
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 360, 190 };
const Vec2 SCENE_PANEL_POSITION @local = { 16, 222 };
const Vec2 SCENE_PANEL_SIZE @local = { 360, 420 };
const Vec2 MATERIAL_PANEL_POSITION @local = { 16, 658 };
const Vec2 MATERIAL_PANEL_SIZE @local = { 360, 220 };
const Vec2 STATS_PANEL_POSITION @local = { 1060, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 420 };
const Vec2 TARGETS_PANEL_POSITION @local = { 1060, 452 };
const Vec2 TARGETS_PANEL_SIZE @local = { 360, 430 };
const Vec2 POST_PANEL_POSITION @local = { 392, 16 };
const Vec2 POST_PANEL_SIZE @local = { 300, 260 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct DebugToggles @local {
    bool bounds;
    bool lights;
    bool shadow_frusta;
    bool joints;
    bool axes;
    bool spin;
    bool animate;
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

fn void fill_debug_lines(
    DebugDraw* debug,
    DebugToggles* toggles,
    Scene* scene,
    AssetStore* assets,
    render::Renderer* renderer,
    Node* selected,
) @local {
    debug.clear();
    if (toggles.bounds) debug.mesh_bounds(scene, assets, debug::COLOR_YELLOW);
    if (toggles.lights) debug.light_volumes(scene, debug::rgba(1, 0.6f, 0.2f));
    if (toggles.shadow_frusta) renderer.draw_shadow_frusta(debug, debug::COLOR_WHITE);
    if (toggles.joints) debug.joints(scene, debug::rgba(0.4f, 1, 0.9f));
    if (toggles.axes && selected) debug.node_axes(selected, SELECTED_AXES_SIZE);
}

fn void? draw_gui_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    DebugDraw* debug,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view, debug)!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    return renderer.end_frame();
}

fn void? run_gui(
    platform::Window* window,
    render::Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    Node* spinning,
    Node* camera_node,
    Orbit* orbit,
    EnvironmentId environment,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);

    GuiPanelState panels = { .selected = spinning.id };
    TargetsPanelState targets = gui::default_targets_panel_state();
    ViewDesc view_desc = render::default_view_desc();
    view_desc.post.bloom = true;
    render::configure_view(renderer, renderer.default_view, view_desc)!;
    DebugToggles toggles = { .bounds = true, .lights = true, .axes = true, .animate = true };
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

        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        bool controls_visible = imgui::begin("Controls", null, {});
        if (controls_visible) {
            imgui::checkbox("Mesh bounds", &toggles.bounds);
            imgui::checkbox("Light volumes", &toggles.lights);
            imgui::checkbox("Shadow frusta", &toggles.shadow_frusta);
            imgui::checkbox("Joints", &toggles.joints);
            imgui::checkbox("Selected axes", &toggles.axes);
            imgui::checkbox("Spin", &toggles.spin);
            imgui::checkbox("Animate", &toggles.animate);
        }
        imgui::end();

        if (toggles.spin) {
            Quat increment = quaternion::from_axis_angle{float}({ 0, 1, 0 },
                window.clock.delta * SPIN_RADIANS_PER_SECOND);
            spinning.local.rotation = spinning.local.rotation.mul(increment).normalize();
        }
        if (toggles.animate) anim::update(assets, scene, (float)window.clock.delta);
        apply_orbit(orbit, input, camera_node);

        imgui::set_next_window_pos(SCENE_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(SCENE_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::scene_panel(scene, &panels);

        Node* selected = scene.world.is_alive(panels.selected) ? scene.node(panels.selected) : null;
        if (selected) {
            if (Mesh* mesh = scene.get(selected, Mesh)) {
                imgui::set_next_window_pos(MATERIAL_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
                imgui::set_next_window_size(MATERIAL_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
                gui::material_panel(assets, mesh.material)!;
            }
        }

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::targets_panel(renderer, renderer.default_view, &targets, environment)!;

        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (gui::post_panel(&view_desc, {})) {
            render::configure_view(renderer, renderer.default_view, view_desc)!;
        }

        scene.update_world();
        fill_debug_lines(
            debug:    &debug,
            toggles:  &toggles,
            scene:    scene,
            assets:   assets,
            renderer: renderer,
            selected: selected,
        );
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_gui_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            debug:        &debug,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main(String[] args) {
    bool gpu_timings;
    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            gpu_timings = true;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d inspector", 1440, 900))!!;
    defer platform::destroy_window(&window);

    AssetStoreDesc store_desc = asset::default_asset_store_desc();
    store_desc.max_models = MODEL_CAPACITY;
    AssetStore assets = asset::create_asset_store(mem, store_desc);
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_inspector" },
    )!!;
    defer render::destroy_renderer(&renderer);

    String model_path = example_path(MODEL_FILE);
    ModelId model;
    if (catch excuse = gltf::load_model(&assets, model_path)) {
        io::printfn("Loading %s failed: %s", model_path, excuse);
        return 1;
    } else {
        model = assets.find_model(model_path)!!;
    }
    TextureId studio = image::load_hdr(&assets, example_path(ENVIRONMENT_FILE), "inspector/environment_source")!!;
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(studio), "inspector/environment")!!;
    renderer.upload_environment(environment)!!;

    GeometryId ground_geometry;
    @pool() {
        Geometry ground_data = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground_geometry = assets.add_geometry(&ground_data, "inspector/ground")!!;
    };
    MaterialId ground_material = assets.add_material(material::standard({
        .base_color = { 0.62f, 0.64f, 0.68f, 1 },
        .metallic   = 0,
        .roughness  = 0.82f,
    }), "inspector/ground_material")!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = BACKGROUND_INTENSITY;

    Node* ground = scene.add_mesh(ground_geometry, ground_material, name: "ground")!!;
    ground.local.position = { 0, -0.001f, 0 };

    Node* left = model::instantiate(&assets, &scene, model, name: "fox_left")!!;
    Node* right = model::instantiate(&assets, &scene, model, name: "fox_right")!!;
    left.local.position = { -INSTANCE_SPACING * 0.5f, 0, 0 };
    right.local.position = { INSTANCE_SPACING * 0.5f, 0, 0 };
    left.local.scale = { MODEL_SCALE, MODEL_SCALE, MODEL_SCALE };
    right.local.scale = { MODEL_SCALE, MODEL_SCALE, MODEL_SCALE };
    ClipId[] clips = scene.get(right, ModelInstance).clips;
    anim::add_animator(&scene, right);
    if (clips.len) scene.get(right, Animator).play(&assets, clips[0])!!;

    Light sun = light::directional({ 1, 0.95f, 0.85f }, SUN_INTENSITY);
    sun.shadow.cascades = SUN_CASCADES;
    Node* sun_node = scene.add_light(sun, name: "sun")!!;
    sun_node.local.rotation = maths::look_rotation((Vec3){ -0.5f, -1, -0.6f }.normalize(), { 0, 1, 0 });

    Light spot = light::spot(
        color:     { 1, 0.82f, 0.62f },
        intensity: SPOT_INTENSITY,
        inner:     math::deg_to_rad(20.0f),
        outer:     math::deg_to_rad(32.0f),
        range:     12,
    );
    spot.shadow.enabled = true;
    Node* spot_node = scene.add_light(spot, name: "spot")!!;
    spot_node.local.position = { 0, 6, 4 };
    spot_node.local.rotation = maths::look_rotation((Vec3){ 0, -6, -4 }.normalize(), { 0, 1, 0 });

    Light point = light::point({ 0.72f, 0.84f, 1 }, POINT_INTENSITY, 5);
    Node* point_node = scene.add_light(point, name: "point")!!;
    point_node.local.position = { 0, 2, -3 };

    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.05f), name: "camera")!!;
    Orbit orbit = {
        .target   = { 0, 0.8f, 0 },
        .distance = 8,
        .yaw      = 0.6f,
        .pitch    = 0.35f,
    };
    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    io::printn("drag to orbit, wheel to zoom, Escape release quits");
    if (catch excuse = run_gui(
        window:      &window,
        renderer:    &renderer,
        assets:      &assets,
        scene:       &scene,
        spinning:    left,
        camera_node: camera_node,
        orbit:       &orbit,
        environment: environment,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
