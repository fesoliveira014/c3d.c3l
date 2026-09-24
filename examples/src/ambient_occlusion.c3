module ambient_occlusion_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::asset::image;
import c3d::camera;
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
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN_SCALE @local = 0.05f;
const float ORBIT_DISTANCE_MAX_SCALE @local = 2;
const float ORBIT_START_SCALE @local = 0.25f;
const float NEAR_PLANE_SCALE @local = 0.002f;
const uint WINDOW_WIDTH @local = 1280;
const uint WINDOW_HEIGHT @local = 720;
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 340, 150 };
const Vec2 POST_PANEL_POSITION @local = { 16, 182 };
const Vec2 POST_PANEL_SIZE @local = { 340, 330 };
const Vec2 TARGETS_PANEL_POSITION @local = { 920, 16 };
const Vec2 TARGETS_PANEL_SIZE @local = { 344, 690 };
const Vec2 STATS_PANEL_POSITION @local = { 372, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 300, 700 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float minimum;
    float maximum;
    float yaw;
    float pitch;
}

struct Views @local {
    ViewId   left;
    ViewId   right;
    ViewDesc left_desc;
    ViewDesc right_desc;
    uint     width;
    uint     height;
}

struct Options @local {
    bool gpu_timings;
    bool full_resolution;
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

fn PixelRect half_viewport(uint width, uint height, bool right) @local {
    uint half = width / 2;
    return { .x = right ? half : 0, .y = 0, .width = right ? width - half : half, .height = height };
}

fn void? configure_views(render::Renderer* renderer, Views* views) @local {
    views.width = renderer.swapchain_info.width;
    views.height = renderer.swapchain_info.height;
    views.left_desc.viewport = half_viewport(views.width, views.height, false);
    views.right_desc.viewport = half_viewport(views.width, views.height, true);
    render::configure_view(renderer, views.left, views.left_desc)!;
    render::configure_view(renderer, views.right, views.right_desc)!;
}

fn void set_ambient_occlusion(Views* views, bool enabled) @local {
    AoKind kind = enabled ? AoKind.SSAO : AoKind.NONE;
    views.left_desc.ambient_occlusion.kind = kind;
    views.right_desc.ambient_occlusion.kind = kind;
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Views* views,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, views.left)!;
        renderer.finish_view(views.left)!;
        renderer.render_view(scene, camera_node, views.right)!;
        renderer.finish_view(views.right)!;

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
    Orbit* orbit,
    EnvironmentId environment,
    Options options,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    AmbientOcclusionDesc ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
    ambient_occlusion.full_resolution = options.full_resolution;
    Views views = {
        .left       = renderer.default_view,
        .left_desc  = render::default_view_desc(),
        .right_desc = render::default_view_desc(),
    };
    views.left_desc.ambient_occlusion = ambient_occlusion;
    views.right_desc.ambient_occlusion = ambient_occlusion;
    views.right_desc.shading = ShadingPath.DEFERRED;
    views.right = render::create_view(renderer, views.right_desc)!;
    defer (void)render::destroy_view(renderer, views.right);
    configure_views(renderer, &views)!;
    renderer.prepare_scene(scene)!;

    TargetsPanelState targets = gui::default_targets_panel_state();
    bool edit_right = true;
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

        bool views_changed;
        if (input.key_pressed(platform::Scancode.O) && !input.keyboard_captured_by_gui) {
            set_ambient_occlusion(&views, views.right_desc.ambient_occlusion.kind == AoKind.NONE);
            views_changed = true;
        }

        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Ambient occlusion", null, {})) {
            imgui::text_unformatted("Left: forward. Right: deferred.");
            imgui::text_unformatted("O toggles AO; the targets panel shows ao.");
            bool enabled = views.right_desc.ambient_occlusion.kind != AoKind.NONE;
            if (imgui::checkbox("Enabled", &enabled)) {
                set_ambient_occlusion(&views, enabled);
                views_changed = true;
            }
            if (imgui::radio_button("Edit left", !edit_right)) edit_right = false;
            imgui::same_line();
            if (imgui::radio_button("Edit right", edit_right)) edit_right = true;
        }
        imgui::end();

        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        views_changed |= gui::post_panel(edit_right ? &views.right_desc : &views.left_desc, {});

        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        ViewId inspected = edit_right ? views.right : views.left;
        gui::targets_panel(renderer, inspected, &targets, environment)!;

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        apply_orbit(orbit, input, camera_node);
        scene.update_world();
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        bool resized = renderer.swapchain_info.width != views.width || renderer.swapchain_info.height != views.height;
        if (views_changed || resized) configure_views(renderer, &views)!;
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            views:        &views,
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
                io::eprintfn("--gpu-timings needs GPU profiling: c3c build ambient_occlusion --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                return 1;
            $endif
        } else if (argument == "--full") {
            options.full_resolution = true;
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
        "ambient_occlusion/source/studio",
    )!!;
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(environment_source, light::ENVIRONMENT_SETTINGS_DEFAULT),
        "ambient_occlusion/environment/studio",
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
        platform::default_window_desc("c3d ambient occlusion", WINDOW_WIDTH, WINDOW_HEIGHT))!!;
    defer platform::destroy_window(&window);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      {
            .gpu_timings      = options.gpu_timings,
            .validation       = true,
            .application_name = "c3d_ambient_occlusion",
        },
    )!!;
    defer render::destroy_renderer(&renderer);

    if (catch excuse = run_gui(
        window:      &window,
        renderer:    &renderer,
        scene:       &scene,
        camera_node: camera_node,
        orbit:       &orbit,
        environment: environment,
        options:     options,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }
    return 0;
}
