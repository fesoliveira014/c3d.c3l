module post_example;

import std::io;
import std::math;
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
const float SPIN_RADIANS_PER_SECOND @local = 0.6f;
const float CUBE_ROLL_DEGREES @local = 30; // diagonal silhouette edges expose the FXAA tradeoff
const float CUBE_SIZE @local = 1.6f;
const float SPHERE_RADIUS @local = 0.7f;
const float SPHERE_OFFSET @local = 1.9f;
const float SUN_INTENSITY @local = 6; // lit texels exceed one, so tone mapping has work to do
const float EMISSIVE_STRENGTH @local = 4;
const float AMBIENT_INTENSITY @local = 0.1f;
const float EXPOSURE_MIN @local = 0.05f;
const float EXPOSURE_MAX @local = 8;
const uint LUT_SIZE @local = 32;
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 360, 110 };
const Vec2 POST_PANEL_POSITION @local = { 16, 142 };
const Vec2 POST_PANEL_SIZE @local = { 360, 330 };
const Vec2 STATS_PANEL_POSITION @local = { 900, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 660 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
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
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    Orbit orbit = { .distance = 6 };
    ViewDesc view_desc = render::default_view_desc();
    render::configure_view(renderer, renderer.default_view, view_desc)!;
    Quat roll = quaternion::from_axis_angle{float}({ 0, 0, 1 }, math::deg_to_rad(CUBE_ROLL_DEGREES));
    float spin_angle;
    bool spin = true;
    bool orthographic;
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
        }
        imgui::end();

        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        bool changed = gui::post_panel(&view_desc, lut);

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        if (spin) spin_angle += window.clock.delta * SPIN_RADIANS_PER_SECOND;
        Quat yaw = quaternion::from_axis_angle{float}({ 0, 1, 0 }, spin_angle);
        cube.local.rotation = yaw.mul(roll).normalize();
        apply_orbit(&orbit, input, camera_node);

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
        platform::default_window_desc("c3d post", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_post" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Image decoded = image::decode_image(mem, $embed("../assets/texture.png"))!!;
    defer image::destroy_image(&decoded);
    TextureId image_texture = assets.add_texture(
        material::texture_2d_desc(decoded.width, decoded.height, RGBA8_SRGB),
        decoded.pixels,
        "post/texture",
    )!!;

    TextureId lut;
    @pool() {
        char[] lut_pixels = post::identity_lut(tmem, LUT_SIZE);
        lut = assets.add_texture(post::identity_lut_desc(LUT_SIZE), lut_pixels, "post/identity_lut")!!;
    };

    GeometryId box;
    GeometryId ball;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, CUBE_SIZE, CUBE_SIZE, CUBE_SIZE);
        box = assets.add_geometry(&box_geometry, "post/box")!!;

        Geometry ball_geometry = geometry::sphere(tmem, SPHERE_RADIUS);
        ball = assets.add_geometry(&ball_geometry, "post/sphere")!!;
    };

    MaterialId textured = assets.add_material(
        material::basic({ .color = { 1, 1, 1, 1 }, .map = material::texture_slot(image_texture) }),
        "post/textured",
    )!!;
    MaterialId chrome = assets.add_material(
        material::standard({ .base_color = { 0.9f, 0.9f, 0.9f, 1 }, .metallic = 1, .roughness = 0.25f }),
        "post/chrome",
    )!!;
    MaterialId lamp = assets.add_material(
        material::standard({
            .base_color        = { 0.2f, 0.2f, 0.2f, 1 },
            .roughness         = 0.6f,
            .emissive          = { 1, 0.6f, 0.2f },
            .emissive_strength = EMISSIVE_STRENGTH,
        }),
        "post/lamp",
    )!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = AMBIENT_INTENSITY;

    Node* cube = scene.add_mesh(box, textured, name: "cube")!!;
    Node* chrome_sphere = scene.add_mesh(ball, chrome, name: "chrome")!!;
    chrome_sphere.local.position = { SPHERE_OFFSET, 0, 0 };
    Node* lamp_sphere = scene.add_mesh(ball, lamp, name: "lamp")!!;
    lamp_sphere.local.position = { -SPHERE_OFFSET, 0, 0 };
    Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, SUN_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0.4f, -0.7f, -0.6f }.normalize(), { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;

    renderer.prepare_scene(&scene)!!;

    if (catch excuse = run_gui(
        window: &window,
        renderer: &renderer,
        scene: &scene,
        cube: cube,
        camera_node: camera_node,
        lut: lut,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }

    return 0;
}
