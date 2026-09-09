module cube_gui_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import imgui;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import sdl;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 1.0f;
const float ORBIT_DISTANCE_MAX @local = 50.0f;
const float SPIN_RADIANS_PER_SECOND @local = 0.8f;
const float MOVE_UNITS_PER_SECOND @local = 2.0f;
const usz MOUSE_BUTTON_LEFT @local = 1; // SDL button index
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 360, 70 };
const Vec2 SCENE_PANEL_POSITION @local = { 16, 102 };
const Vec2 SCENE_PANEL_SIZE @local = { 360, 300 };
const Vec2 MATERIAL_PANEL_POSITION @local = { 16, 418 };
const Vec2 MATERIAL_PANEL_SIZE @local = { 360, 130 };
const Vec2 STATS_PANEL_POSITION @local = { 900, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 620 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.mouse_buttons[MOUSE_BUTTON_LEFT]) {
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

fn void move_cube(Node* cube, Input* input, float delta) @local {
    if (input.keyboard_captured_by_gui) return;

    float step = MOVE_UNITS_PER_SECOND * delta;
    if (input.keys[(usz)sdl::Scancode.LEFT]) cube.local.position.x -= step;
    if (input.keys[(usz)sdl::Scancode.RIGHT]) cube.local.position.x += step;
    if (input.keys[(usz)sdl::Scancode.UP]) cube.local.position.y += step;
    if (input.keys[(usz)sdl::Scancode.DOWN]) cube.local.position.y -= step;
}

fn void forward_gui_event(sdl::Event* event, void* user) @local {
    GuiRenderer* gui_renderer = (GuiRenderer*)user;
    gui_renderer.process_event(event);
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
        renderer.render_view(scene, camera_node)!;
        renderer.composite_view()!;

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
    Orbit* orbit,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    GuiPanelState panels = { .selected = cube.id };
    bool spin;
    bool orthographic;
    bool escape_captured;

    while (window.poll(&forward_gui_event, &gui_renderer)) {
        bool keyboard_was_captured = window.input.keyboard_captured_by_gui;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        // Text editing can drop capture on Escape down before its release arrives.
        if (input.keys_pressed[(usz)sdl::Scancode.ESCAPE] || input.keys_released[(usz)sdl::Scancode.ESCAPE]) {
            escape_captured |= keyboard_was_captured || input.keyboard_captured_by_gui;
        }

        if (input.keys_released[(usz)sdl::Scancode.ESCAPE]) {
            bool quit = !escape_captured;
            escape_captured = false;
            if (quit) break;
        }

        if (input.keys_pressed[(usz)sdl::Scancode.O] && !input.keyboard_captured_by_gui) {
            orthographic = !orthographic;
            *scene.get(camera_node, camera::Camera) = orthographic
                ? camera::orthographic(6, 0.1f, 100)
                : camera::perspective_deg(60, 0.1f);
        }

        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        bool controls_visible = imgui::begin("Controls", null, {});
        if (controls_visible) imgui::checkbox("Spin", &spin);
        imgui::end();

        move_cube(cube, input, window.clock.delta);
        if (spin) {
            Quat increment = quaternion::from_axis_angle{float}({ 0, 1, 0 },
                window.clock.delta * SPIN_RADIANS_PER_SECOND);
            cube.local.rotation = cube.local.rotation.mul(increment).normalize();
        }

        apply_orbit(orbit, input, camera_node);

        imgui::set_next_window_pos(SCENE_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(SCENE_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::scene_panel(scene, &panels);

        if (scene.world.is_alive(panels.selected)) {
            Node* selected = scene.node(panels.selected);
            if (Mesh* mesh = scene.get(selected, Mesh)) {
                imgui::set_next_window_pos(MATERIAL_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
                imgui::set_next_window_size(MATERIAL_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
                gui::material_panel(renderer.assets, mesh.material)!;
            }
        }

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        scene.update_world();
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_gui_frame(
            renderer: renderer,
            scene: scene,
            camera_node: camera_node,
            gui_renderer: &gui_renderer,
            info: { .time = window.clock.total, .delta = window.clock.delta },
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
        platform::default_window_desc("c3d cube GUI", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_cube_gui" },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId box;
    GeometryId ball;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, 1, 1, 1);
        box = assets.add_geometry(&box_geometry, "cube/box")!!;

        Geometry ball_geometry = geometry::sphere(tmem, 0.6f);
        ball = assets.add_geometry(&ball_geometry, "cube/sphere")!!;
    };

    MaterialId red = assets.add_material(material::basic({ .color = { 0.9f, 0.2f, 0.2f, 1 } }), "cube/red")!!;
    MaterialId blue = assets.add_material(material::basic({ .color = { 0.2f, 0.4f, 0.9f, 1 } }), "cube/blue")!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    Node* cube = scene.add_mesh(box, red, name: "cube")!!;
    Node* sphere = scene.add_mesh(ball, blue, name: "sphere")!!;
    sphere.local.position = { 0.7f, 0.4f, 0.3f };
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    Orbit orbit = { .distance = 5 };

    renderer.prepare_scene(&scene)!!;

    if (catch excuse = run_gui(
        window: &window,
        renderer: &renderer,
        scene: &scene,
        cube: cube,
        camera_node: camera_node,
        orbit: &orbit,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }

    return 0;
}
