module path_tracer_example;

import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::time;
import std::time::clock;
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
import c3d::scene;
import imgui;

const String ENVIRONMENT_FILE @local = "../assets/ibl/studio_small_09_1k.hdr";
const float ENVIRONMENT_INTENSITY @local = 0.5f;
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the look-rotation up-axis degeneracy
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 2;
const float ORBIT_DISTANCE_MAX @local = 20;
const float ROOM_SIZE @local = 4;
const float WALL_THICKNESS @local = 0.1f;
const float SPHERE_RADIUS @local = 0.8f;
const float LAMP_INTENSITY @local = 8;
const float LAMP_RANGE @local = 12;
const Vec3 PANEL_RADIANCE @local = { 1, 0.95f, 0.85f };
const float PANEL_STRENGTH @local = 6;
const PathTraceDesc STILL_SETTINGS @local = {
    .max_bounces       = 6,
    .samples_per_frame = 4,
};
const uint INTERACTIVE_MAX_SAMPLES @local = 4096; // converged for the eye; the GPU idles after it
const uint STILL_WIDTH_DEFAULT @local = 1280;
const uint STILL_HEIGHT_DEFAULT @local = 720;
const uint STILL_SAMPLES_DEFAULT @local = 256;
const String STILL_PATH_DEFAULT @local = "still.png";
const double NANOSECONDS_PER_SECOND @local = 1_000_000_000.0;
const Vec2 STATS_PANEL_POSITION @local = { 16, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 520 };
const Vec2 POST_PANEL_POSITION @local = { 1060, 16 };
const Vec2 POST_PANEL_SIZE @local = { 360, 420 };
const Vec2 TARGETS_PANEL_POSITION @local = { 16, 560 };
const Vec2 TARGETS_PANEL_SIZE @local = { 420, 300 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct Options @local {
    bool   headless;
    uint   samples;
    uint   width;
    uint   height;
    String output;
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

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.LEFT)) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(
                x:     orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
                lower: -ORBIT_PITCH_LIMIT,
                upper: ORBIT_PITCH_LIMIT,
            );
        }
        if (input.wheel != 0) {
            float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
            orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
        }
    }
    place_camera(orbit, camera_node);
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn MaterialId? add_standard(
    AssetStore* assets,
    Vec3 color,
    float metallic,
    float roughness,
) @local {
    return assets.add_material(material::standard({
        .base_color = { color.x, color.y, color.z, 1 },
        .metallic   = metallic,
        .roughness  = roughness,
    }));
}

// A Cornell-style room open towards the camera: the front side lets the environment in.
fn Node*? populate_scene(AssetStore* assets, Scene* scene) @local {
    GeometryId slab;
    GeometryId wall;
    GeometryId sphere_geometry;
    GeometryId panel_geometry;
    float span = ROOM_SIZE + WALL_THICKNESS * 2;
    @pool() {
        Geometry slab_box = geometry::box(tmem, span, WALL_THICKNESS, span);
        slab = assets.add_geometry(&slab_box, "geometry/path_tracer/slab")!;
        Geometry wall_box = geometry::box(tmem, WALL_THICKNESS, span, span);
        wall = assets.add_geometry(&wall_box, "geometry/path_tracer/wall")!;
        Geometry sphere = geometry::sphere(tmem, SPHERE_RADIUS, 48, 24);
        sphere_geometry = assets.add_geometry(&sphere, "geometry/path_tracer/sphere")!;
        Geometry panel = geometry::box(tmem, ROOM_SIZE * 0.3f, WALL_THICKNESS * 0.5f, ROOM_SIZE * 0.3f);
        panel_geometry = assets.add_geometry(&panel, "geometry/path_tracer/panel")!;
    };

    float half = ROOM_SIZE * 0.5f;
    float offset = half + WALL_THICKNESS * 0.5f;
    MaterialId white = add_standard(assets, { 0.73f, 0.73f, 0.73f }, 0, 0.9f)!;
    MaterialId red = add_standard(assets, { 0.63f, 0.07f, 0.05f }, 0, 0.9f)!;
    MaterialId green = add_standard(assets, { 0.14f, 0.45f, 0.09f }, 0, 0.9f)!;
    scene.add_mesh(slab, white, name: "floor")!.local.position = { 0, -WALL_THICKNESS * 0.5f, -half };
    scene.add_mesh(slab, white, name: "ceiling")!.local.position = { 0, ROOM_SIZE + WALL_THICKNESS * 0.5f, -half };
    Node* back = scene.add_mesh(wall, white, name: "back")!;
    back.local.position = { 0, half, -ROOM_SIZE - WALL_THICKNESS * 0.5f };
    back.local.rotation = maths::look_rotation({ 1, 0, 0 }, { 0, 1, 0 });
    scene.add_mesh(wall, red, name: "left")!.local.position = { -offset, half, -half };
    scene.add_mesh(wall, green, name: "right")!.local.position = { offset, half, -half };

    MaterialId metal = add_standard(assets, { 0.95f, 0.85f, 0.6f }, 1, 0.15f)!;
    MaterialId plastic = add_standard(assets, { 0.85f, 0.85f, 0.9f }, 0, 0.6f)!;
    Node* metal_sphere = scene.add_mesh(sphere_geometry, metal, name: "metal_sphere")!;
    metal_sphere.local.position = { -0.9f, SPHERE_RADIUS, -half - 0.6f };
    Node* rough_sphere = scene.add_mesh(sphere_geometry, plastic, name: "rough_sphere")!;
    rough_sphere.local.position = { 0.9f, SPHERE_RADIUS, -half + 0.5f };

    MaterialId glow = assets.add_material(material::standard({
        .base_color        = { 0, 0, 0, 1 },
        .roughness         = 1,
        .emissive          = PANEL_RADIANCE,
        .emissive_strength = PANEL_STRENGTH,
    }), "material/path_tracer/panel")!;
    Node* panel = scene.add_mesh(panel_geometry, glow, name: "ceiling_panel")!;
    panel.local.position = { 0, ROOM_SIZE - WALL_THICKNESS * 0.5f, -half };

    Light lamp = light::point({ 1, 0.9f, 0.8f }, LAMP_INTENSITY, LAMP_RANGE);
    lamp.shadow.enabled = true;
    Node* lamp_node = scene.add_light(lamp, name: "lamp")!;
    lamp_node.local.position = { -1, ROOM_SIZE * 0.7f, -half + 1 };
    return lamp_node;
}

fn void? add_environment(AssetStore* assets, Renderer* renderer, Scene* scene) @local {
    String file = example_path(ENVIRONMENT_FILE);
    if (!file::is_file(file)) return;
    TextureId studio = image::load_hdr(assets, file, "path_tracer/environment_source")!;
    EnvironmentId environment = assets.add_environment(light::texture_environment(studio), "path_tracer/environment")!;
    renderer.upload_environment(environment)!;
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = ENVIRONMENT_INTENSITY;
}

fn Orbit starting_orbit() @local {
    return { .target = { 0, ROOM_SIZE * 0.5f, -ROOM_SIZE * 0.5f }, .distance = 8, .yaw = 0, .pitch = 0.08f };
}

fn ViewDesc path_traced(ViewDesc desc, uint max_samples) @local {
    desc.shading = ShadingPath.PATH_TRACED;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.path_trace = STILL_SETTINGS;
    desc.path_trace.max_samples = max_samples;
    return desc;
}

fn Options? parse_options(String[] args) @local {
    Options options = {
        .samples = STILL_SAMPLES_DEFAULT,
        .width   = STILL_WIDTH_DEFAULT,
        .height  = STILL_HEIGHT_DEFAULT,
        .output  = STILL_PATH_DEFAULT,
    };
    for (usz index = 1; index < args.len; index++) {
        String argument = args[index];
        if (argument == "--headless") {
            options.headless = true;
            continue;
        }
        if (index + 1 >= args.len) return c3d::INVALID_ARGUMENT~;
        String value = args[++index];
        switch (argument) {
            case "--samples": options.samples = value.to_uint()!;
            case "--width": options.width = value.to_uint()!;
            case "--height": options.height = value.to_uint()!;
            case "--out": options.output = value;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    if (options.samples == 0 || options.width == 0 || options.height == 0) return c3d::INVALID_ARGUMENT~;
    return options;
}

fn void? render_still(Options options) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = render::create_renderer(mem, &assets, {
        .validation            = true,
        .application_name      = "c3d_path_tracer",
        .ray_tracing_pipelines = true,
    })!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    populate_scene(&assets, &scene)!;
    add_environment(&assets, &renderer, &scene)!;
    Node* camera_node = scene.add_camera(camera::perspective_deg(45, 0.1f, 100), name: "camera")!;
    Orbit orbit = starting_orbit();
    place_camera(&orbit, camera_node);
    scene.update_world();

    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc: render::render_target_desc(options.width, options.height, PixelFormat.RGBA8_SRGB),
    )!;
    ViewDesc desc = path_traced(render::texture_view_desc(target, OutputMode.DISPLAY_LDR), options.samples);
    ViewId view = render::create_view(&renderer, desc)!;
    renderer.prepare_scene(&scene)!;

    time::Clock started = clock::now();
    while (renderer.view_stats(view)!.accumulated_samples < options.samples) {
        renderer.begin_frame()!;
        defer catch render::abort_frame(&renderer);
        renderer.render_view(&scene, camera_node, view)!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
    }
    char[] pixels = mem::new_array(char, (usz)options.width * options.height * 4);
    defer free(pixels);
    renderer.read_render_target(target, pixels)!;
    double seconds = (double)(clock::now() - started) / NANOSECONDS_PER_SECOND;
    image::write_png(options.output, options.width, options.height, pixels)!;

    double samples_per_second = (double)options.samples * options.width * options.height / seconds;
    io::printfn(
        "path_tracer: %d samples at %dx%d in %.2f s (%.1f M samples/s), wrote %s",
        options.samples,
        options.width,
        options.height,
        seconds,
        samples_per_second / 1e6,
        options.output,
    );
}

fn void? draw_frame(
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

fn int run_window() @local {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d path tracer", 1440, 900))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer? created = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      {
            .validation            = true,
            .application_name      = "c3d_path_tracer",
            .ray_tracing_pipelines = true,
        },
    );
    if (catch excuse = created) {
        io::printfn("path_tracer: ray-tracing pipelines unavailable (%s)", excuse);
        return 1;
    }
    Renderer renderer = created;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* lamp_node = populate_scene(&assets, &scene)!!;
    add_environment(&assets, &renderer, &scene)!!;
    Node* camera_node = scene.add_camera(camera::perspective_deg(45, 0.1f, 100), name: "camera")!!;
    Orbit orbit = starting_orbit();
    place_camera(&orbit, camera_node);
    scene.update_world();

    ViewDesc view_desc = path_traced(renderer.views.get(renderer.default_view).desc, INTERACTIVE_MAX_SAMPLES);
    render::configure_view(&renderer, renderer.default_view, view_desc)!!;
    renderer.prepare_scene(&scene)!!;

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    TargetsPanelState targets = gui::default_targets_panel_state();

    io::printn("Drag to orbit, wheel to zoom; Space toggles the lamp; Escape release quits");
    while (window.poll()) {
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        if (input.key_pressed(platform::Scancode.SPACE) && !input.keyboard_captured_by_gui) {
            Light* lamp = scene.get(lamp_node, Light);
            lamp.intensity = lamp.intensity > 0 ? 0 : LAMP_INTENSITY;
            // Light edits do not reset accumulation on their own.
            render::reset_view_history(&renderer, renderer.default_view)!!;
        }

        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::targets_panel(&renderer, renderer.default_view, &targets)!!;
        // The targets panel reconfigures the view it inspects; edits below start from that state.
        view_desc = renderer.views.get(renderer.default_view).desc;
        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(&renderer)!!;
        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        bool view_changed = gui::post_panel(&view_desc, {}, renderer.caps.ray_queries.enabled);
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();
        gui_renderer.finish_frame();

        platform::sync_window(&window, &renderer);
        if (view_changed) {
            if (catch excuse = render::configure_view(&renderer, renderer.default_view, view_desc)) {
                io::printfn("path_tracer: settings rejected (%s)", excuse);
            }
        }
        draw_frame(
            renderer:     &renderer,
            scene:        &scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!!;
    }
    return 0;
}

fn int main(String[] args) {
    Options? parsed = parse_options(args);
    if (catch excuse = parsed) {
        io::eprintfn("Invalid options (%s).", excuse);
        io::eprintn("Use [--headless] [--samples N] [--width W] [--height H] [--out file.png]");
        return 1;
    }
    Options options = parsed;
    if (!options.headless) return run_window();
    if (catch excuse = render_still(options)) {
        io::eprintfn("path_tracer: still failed (%s)", excuse);
        return 1;
    }
    return 0;
}
