module views_example;

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
import sdl;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 1.0f;
const float ORBIT_DISTANCE_MAX @local = 50.0f;
const float SPIN_RADIANS_PER_SECOND @local = 0.6f;
const float PRODUCER_RADIANS_PER_SECOND @local = 0.35f;
const float PRODUCER_DISTANCE @local = 4.5f;
const float PRODUCER_HEIGHT @local = 1.6f;
const float CUBE_ROLL_DEGREES @local = 30;
const float CUBE_SIZE @local = 1.6f;
const float SPHERE_RADIUS @local = 0.7f;
const float SPHERE_OFFSET @local = 1.9f;
const float GROUND_SIZE @local = 14;
const float GROUND_LEVEL @local = -1.2f;
const float MONITOR_WIDTH @local = 3.6f;
const float MONITOR_HEIGHT @local = 3.6f;
const float MONITOR_DEPTH @local = 0.08f;
const Vec3 MONITOR_POSITION @local = { 0, 1.4f, -4.5f };
const float SUN_INTENSITY @local = 6;
const float EMISSIVE_STRENGTH @local = 4;
const float AMBIENT_INTENSITY @local = 0.1f;
const float RENDER_SCALE_MIN @local = 0.25f;
const uint MONITOR_LAYER @local = 2; // the producer camera renders layer 1 only, so it never sees its own output
const uint[3] CAPTURE_SIZES @local = { 256, 512, 1024 };
const ZString[3] CAPTURE_SIZE_LABELS @local = { "256", "512", "1024" };
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 360, 250 };
const Vec2 POST_PANEL_POSITION @local = { 16, 282 };
const Vec2 POST_PANEL_SIZE @local = { 360, 330 };
const Vec2 STATS_PANEL_POSITION @local = { 900, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 660 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct Capture @local {
    RenderTargetId target;
    ViewId         view;
    ViewDesc       desc;
    int            size_index;
    bool           hdr;
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

fn void place_producer(Node* producer_node, double time) @local {
    float yaw = (float)time * PRODUCER_RADIANS_PER_SECOND;
    Vec3 offset = { math::sin(yaw) * PRODUCER_DISTANCE, PRODUCER_HEIGHT, math::cos(yaw) * PRODUCER_DISTANCE };
    producer_node.local.position = offset;
    producer_node.local.rotation = maths::look_rotation(-offset.normalize(), { 0, 1, 0 });
}

fn void forward_gui_event(sdl::Event* event, void* user) @local {
    GuiRenderer* gui_renderer = (GuiRenderer*)user;
    gui_renderer.process_event(event);
}

fn void? create_capture(
    render::Renderer* renderer,
    AssetStore* assets,
    MaterialId monitor,
    Capture* capture,
) @local {
    uint size = CAPTURE_SIZES[capture.size_index];
    material::PixelFormat format = capture.hdr ? material::PixelFormat.RGBA16_FLOAT : material::PixelFormat.RGBA8_SRGB;
    capture.target = render::create_render_target(renderer, render::render_target_desc(size, size, format))!;
    defer catch (void)render::destroy_render_target(renderer, capture.target);

    capture.desc.output = ViewOutput.TEXTURE;
    capture.desc.target = capture.target;
    capture.desc.color = capture.hdr ? OutputMode.LINEAR_HDR : OutputMode.DISPLAY_LDR;
    capture.view = render::create_view(renderer, capture.desc)!;

    assets.material(monitor).data.basic.map.texture = { .kind = RENDER_TARGET, .target = capture.target };
    assets.mark_material_dirty(monitor);
}

fn void? destroy_capture(render::Renderer* renderer, Capture* capture) @local {
    render::destroy_view(renderer, capture.view)!;
    return render::destroy_render_target(renderer, capture.target);
}

fn void? draw_gui_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Node* producer_node,
    ViewId capture_view,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    renderer.render_view(scene, producer_node, capture_view)!;
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
    AssetStore* assets,
    Scene* scene,
    Node* cube,
    Node* camera_node,
    Node* producer_node,
    MaterialId monitor,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    Orbit orbit = { .distance = 8, .pitch = 0.3f };
    ViewDesc window_desc = render::default_view_desc();
    Capture capture = { .desc = render::default_view_desc(), .size_index = 1 };
    create_capture(renderer, assets, monitor, &capture)!;
    defer (void)destroy_capture(renderer, &capture);
    renderer.prepare_scene(scene)!;

    Quat roll = quaternion::from_axis_angle{float}({ 0, 0, 1 }, math::deg_to_rad(CUBE_ROLL_DEGREES));
    float spin_angle;
    bool spin = true;
    bool escape_captured;

    while (window.poll(&forward_gui_event, &gui_renderer)) {
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

        bool window_changed;
        bool capture_changed;
        bool capture_recreate;
        bool capture_resize;
        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Views", null, {})) {
            imgui::checkbox("Spin", &spin);
            imgui::separator_text("Window view");
            window_changed |= imgui::slider_float_ex(
                label:  "Render scale",
                v:      &window_desc.render_scale,
                v_min:  RENDER_SCALE_MIN,
                v_max:  render::MAX_RENDER_SCALE,
                format: "%.2f",
                flags:  imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
            );
            imgui::separator_text("Capture view");
            capture_resize |= imgui::combo_char(
                label:         "Size",
                current_item:  &capture.size_index,
                items:         &CAPTURE_SIZE_LABELS[0],
                items_count:   CAPTURE_SIZES.len,
            );
            if (imgui::radio_button("Display LDR, sRGB target", !capture.hdr)) {
                capture.hdr = false;
                capture_recreate = true;
            }
            if (imgui::radio_button("Linear HDR, float target", capture.hdr)) {
                capture.hdr = true;
                capture_recreate = true;
            }
            capture_changed |= imgui::checkbox("FXAA", &capture.desc.post.fxaa);
            capture_changed |= imgui::checkbox("Bloom", &capture.desc.post.bloom);
        }
        imgui::end();

        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        window_changed |= gui::post_panel(&window_desc, {});

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        if (spin) spin_angle += window.clock.delta * SPIN_RADIANS_PER_SECOND;
        Quat yaw = quaternion::from_axis_angle{float}({ 0, 1, 0 }, spin_angle);
        cube.local.rotation = yaw.mul(roll).normalize();
        apply_orbit(&orbit, input, camera_node);
        place_producer(producer_node, window.clock.total);

        scene.update_world();
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        if (window_changed) render::configure_view(renderer, renderer.default_view, window_desc)!;
        if (capture_recreate) {
            destroy_capture(renderer, &capture)!;
            create_capture(renderer, assets, monitor, &capture)!;
        } else if (capture_resize) {
            uint size = CAPTURE_SIZES[capture.size_index];
            render::resize_render_target(renderer, capture.target, size, size)!;
        } else if (capture_changed) {
            render::configure_view(renderer, capture.view, capture.desc)!;
        }
        draw_gui_frame(
            renderer:      renderer,
            scene:         scene,
            camera_node:   camera_node,
            producer_node: producer_node,
            capture_view:  capture.view,
            gui_renderer:  &gui_renderer,
            info:          { .time = window.clock.total, .delta = window.clock.delta },
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
        platform::default_window_desc("c3d views", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_views" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Image decoded = image::decode_image(mem, $embed("../assets/texture.png"))!!;
    defer image::destroy_image(&decoded);
    TextureId image_texture = assets.add_texture(
        material::texture_2d_desc(decoded.width, decoded.height, RGBA8_SRGB),
        decoded.pixels,
        "views/texture",
    )!!;

    GeometryId box;
    GeometryId ball;
    GeometryId ground;
    GeometryId screen;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, CUBE_SIZE, CUBE_SIZE, CUBE_SIZE);
        box = assets.add_geometry(&box_geometry, "views/box")!!;

        Geometry ball_geometry = geometry::sphere(tmem, SPHERE_RADIUS);
        ball = assets.add_geometry(&ball_geometry, "views/sphere")!!;

        Geometry ground_geometry = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground = assets.add_geometry(&ground_geometry, "views/ground")!!;

        Geometry screen_geometry = geometry::box(tmem, MONITOR_WIDTH, MONITOR_HEIGHT, MONITOR_DEPTH);
        screen = assets.add_geometry(&screen_geometry, "views/screen")!!;
    };

    MaterialId textured = assets.add_material(
        material::basic({ .color = { 1, 1, 1, 1 }, .map = material::texture_slot(image_texture) }),
        "views/textured",
    )!!;
    MaterialId chrome = assets.add_material(
        material::standard({ .base_color = { 0.9f, 0.9f, 0.9f, 1 }, .metallic = 1, .roughness = 0.25f }),
        "views/chrome",
    )!!;
    MaterialId lamp = assets.add_material(
        material::standard({
            .base_color        = { 0.2f, 0.2f, 0.2f, 1 },
            .roughness         = 0.6f,
            .emissive          = { 1, 0.6f, 0.2f },
            .emissive_strength = EMISSIVE_STRENGTH,
        }),
        "views/lamp",
    )!!;
    MaterialId concrete = assets.add_material(
        material::standard({ .base_color = { 0.5f, 0.5f, 0.52f, 1 }, .metallic = 0, .roughness = 0.9f }),
        "views/concrete",
    )!!;
    // The capture target is bound once the renderer has created it; the sampler clamps the screen edges.
    MaterialId monitor = assets.add_material(
        material::basic({
            .color = { 1, 1, 1, 1 },
            .map   = material::texture_slot(sampler: asset::SAMPLER_LINEAR_CLAMP),
        }),
        "views/monitor",
    )!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = AMBIENT_INTENSITY;

    Node* cube = scene.add_mesh(box, textured, name: "cube")!!;
    Node* chrome_sphere = scene.add_mesh(ball, chrome, name: "chrome")!!;
    chrome_sphere.local.position = { SPHERE_OFFSET, 0, 0 };
    Node* lamp_sphere = scene.add_mesh(ball, lamp, name: "lamp")!!;
    lamp_sphere.local.position = { -SPHERE_OFFSET, 0, 0 };
    Node* floor = scene.add_mesh(ground, concrete, name: "ground")!!;
    floor.local.position = { 0, GROUND_LEVEL, 0 };
    Node* screen_node = scene.add_mesh(screen, monitor, name: "monitor")!!;
    screen_node.local.position = MONITOR_POSITION;
    screen_node.layers = MONITOR_LAYER;
    Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, SUN_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0.4f, -0.7f, -0.6f }.normalize(), { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    Node* producer_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "producer")!!;
    scene.get(producer_node, camera::Camera).layers = scene::DEFAULT_LAYERS;

    if (catch excuse = run_gui(
        window:        &window,
        renderer:      &renderer,
        assets:        &assets,
        scene:         &scene,
        cube:          cube,
        camera_node:   camera_node,
        producer_node: producer_node,
        monitor:       monitor,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }

    return 0;
}
