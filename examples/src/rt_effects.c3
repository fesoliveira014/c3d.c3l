module rt_effects_example;

import std::io;
import std::io::path;
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
import c3d::scene;
import imgui;

const String ENVIRONMENT_FILE @local = "../assets/ibl/studio_small_09_1k.hdr";
const float ENVIRONMENT_INTENSITY @local = 0.6f;
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the look-rotation up-axis degeneracy
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 3;
const float ORBIT_DISTANCE_MAX @local = 30;
const uint SPHERE_COUNT @local = 6;
const float SPHERE_SPACING @local = 1.5f;
const Vec3 PANEL_POSITION @local = { 0, 7, -6 }; // above the starting view's top edge; its image lands in the floor
const Vec3 PANEL_COLOR @local = { 1, 0.35f, 0.1f };
const float PANEL_STRENGTH @local = 4;
const float ROUGHNESS_STEP @local = 0.05f;
const float ROUGHNESS_MIN @local = 0.05f;
const Vec2 STATS_PANEL_POSITION @local = { 16, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 560 };
const Vec2 POST_PANEL_POSITION @local = { 1060, 16 };
const Vec2 POST_PANEL_SIZE @local = { 360, 420 };
const Vec2 TARGETS_PANEL_POSITION @local = { 16, 600 };
const Vec2 TARGETS_PANEL_SIZE @local = { 420, 280 };
const uint BENCHMARK_WARMUP_FRAMES @local = 30; // lets clocks and caches settle before the timed frames

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct PassTimings @local {
    double ambient_occlusion_ms;
    double reflections_ms;
    uint   frames;
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

fn void? populate_scene(AssetStore* assets, Scene* scene) @local {
    GeometryId floor_geometry;
    GeometryId sphere_geometry;
    GeometryId block_geometry;
    GeometryId panel_geometry;
    @pool() {
        Geometry plane = geometry::plane(tmem, 30, 30);
        floor_geometry = assets.add_geometry(&plane, "geometry/rt_effects/floor")!;
        Geometry sphere = geometry::sphere(tmem, 0.5f);
        sphere_geometry = assets.add_geometry(&sphere, "geometry/rt_effects/sphere")!;
        Geometry block = geometry::box(tmem, 1, 1, 1);
        block_geometry = assets.add_geometry(&block, "geometry/rt_effects/block")!;
        Geometry panel = geometry::box(tmem, 4, 1.5f, 0.1f);
        panel_geometry = assets.add_geometry(&panel, "geometry/rt_effects/panel")!;
    };

    MaterialId mirror = assets.add_material(material::standard({
        .base_color = { 0.95f, 0.95f, 0.95f, 1 },
        .metallic   = 1,
        .roughness  = 0.02f,
    }), "material/rt_effects/mirror")!;
    scene.add_mesh(floor_geometry, mirror, name: "mirror_floor")!;

    for (uint index = 0; index < SPHERE_COUNT; index++) {
        float roughness = (float)index / (float)(SPHERE_COUNT - 1);
        MaterialId metal = assets.add_material(material::standard({
            .base_color = { 0.95f, 0.75f, 0.45f, 1 },
            .metallic   = 1,
            .roughness  = roughness,
        }))!;
        Node* sphere = scene.add_mesh(sphere_geometry, metal, name: "sphere")!;
        sphere.local.position = { ((float)index - (float)(SPHERE_COUNT - 1) * 0.5f) * SPHERE_SPACING, 0.5f, 0 };
    }

    MaterialId stone = assets.add_material(material::standard({
        .base_color = { 0.7f, 0.7f, 0.68f, 1 },
        .roughness  = 0.8f,
    }), "material/rt_effects/stone")!;
    Vec3[3] block_positions = { { -3, 0.5f, -3 }, { -2, 0.5f, -3 }, { -3, 1.5f, -3 } };
    foreach (position : block_positions) {
        Node* block = scene.add_mesh(block_geometry, stone, name: "block")!;
        block.local.position = position;
    }

    MaterialId glow = assets.add_material(material::standard({
        .base_color        = { 0, 0, 0, 1 },
        .roughness         = 1,
        .emissive          = PANEL_COLOR,
        .emissive_strength = PANEL_STRENGTH,
    }), "material/rt_effects/panel")!;
    Node* panel = scene.add_mesh(panel_geometry, glow, name: "emissive_panel")!;
    panel.local.position = PANEL_POSITION;

    Light sun = light::directional({ 1, 0.95f, 0.85f }, 2);
    sun.shadow.enabled = true;
    sun.shadow.ray_traced = true;
    Node* sun_node = scene.add_light(sun, name: "sun")!;
    sun_node.local.rotation = maths::look_rotation((Vec3){ 0.4f, -0.8f, -0.5f }.normalize(), { 0, 1, 0 });
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

fn AoKind next_ambient_occlusion(AoKind kind) @local {
    switch (kind) {
        case NONE: return AoKind.SSAO;
        case SSAO: return AoKind.RAY_TRACED;
        case RAY_TRACED: return AoKind.NONE;
    }
}

fn bool edit_from_keys(Input* input, ViewDesc* desc) @local {
    if (input.keyboard_captured_by_gui) return false;
    bool changed;
    if (input.key_pressed(platform::Scancode.A)) {
        AoKind kind = next_ambient_occlusion(desc.ambient_occlusion.kind);
        desc.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
        desc.ambient_occlusion.kind = kind;
        changed = true;
    }
    RayTracingDesc* ray_tracing = &desc.ray_tracing;
    if (input.key_pressed(platform::Scancode.R)) {
        ray_tracing.reflections = !ray_tracing.reflections;
        changed = true;
    }
    float roughness = ray_tracing.max_reflection_roughness;
    if (input.key_pressed(platform::Scancode.LEFTBRACKET)) roughness -= ROUGHNESS_STEP;
    if (input.key_pressed(platform::Scancode.RIGHTBRACKET)) roughness += ROUGHNESS_STEP;
    roughness = math::clamp(roughness, ROUGHNESS_MIN, 1.0f);
    if (roughness != ray_tracing.max_reflection_roughness) {
        ray_tracing.max_reflection_roughness = roughness;
        io::printfn("max reflection roughness %.2f", roughness);
        changed = true;
    }
    return changed;
}

fn void accumulate_timings(PassTimings* timings, Renderer* renderer) @local {
    timings.ambient_occlusion_ms += renderer.stats.gpu_pass_ms[Pass.AMBIENT_OCCLUSION.ordinal];
    timings.reflections_ms += renderer.stats.gpu_pass_ms[Pass.RT_REFLECTIONS.ordinal];
    timings.frames++;
}

fn int main(String[] args) {
    bool gpu_timings;
    uint benchmark_frames;
    for (usz index = 1; index < args.len; index++) {
        if (args[index] == "--gpu-timings") {
            $if $feat(C3D_PROFILE_GPU):
                gpu_timings = true;
            $else
                io::eprintfn("--gpu-timings needs GPU profiling: c3c build <target> --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                return 1;
            $endif
        } else if (args[index] == "--benchmark" && index + 1 < args.len) {
            index++;
            benchmark_frames = args[index].to_uint() ?? 0;
        } else {
            io::printfn("Unknown argument: %s", args[index]);
            return 1;
        }
    }
    if (benchmark_frames && !gpu_timings) {
        io::eprintn("--benchmark FRAMES needs --gpu-timings");
        return 1;
    }

    platform::Window window = platform::create_window(platform::default_window_desc("c3d rt effects", 1440, 900))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer? created = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      {
            .gpu_timings      = gpu_timings,
            .validation       = true,
            .application_name = "c3d_rt_effects",
            .ray_queries      = true,
        },
    );
    if (catch excuse = created) {
        io::printfn("rt_effects: ray queries unavailable (%s)", excuse);
        return 1;
    }
    Renderer renderer = created;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    populate_scene(&assets, &scene)!!;
    TextureId studio = image::load_hdr(&assets, example_path(ENVIRONMENT_FILE), "rt_effects/environment_source")!!;
    EnvironmentId environment = assets.add_environment(light::texture_environment(studio), "rt_effects/environment")!!;
    renderer.upload_environment(environment)!!;
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = ENVIRONMENT_INTENSITY;

    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f, 100), name: "camera")!!;
    Orbit orbit = { .target = { 0, 0.5f, 0 }, .distance = 8, .yaw = 0, .pitch = 0.45f };
    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    ViewDesc view_desc = renderer.views.get(renderer.default_view).desc;
    view_desc.shading = ShadingPath.DEFERRED;
    view_desc.post.anti_aliasing = AntiAliasing.TAA;
    view_desc.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
    view_desc.ambient_occlusion.kind = AoKind.RAY_TRACED;
    view_desc.ray_tracing = {
        .shadows                  = true,
        .reflections              = true,
        .max_reflection_roughness = render::RT_REFLECTION_ROUGHNESS_DEFAULT,
    };
    render::configure_view(&renderer, renderer.default_view, view_desc)!!;

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    TargetsPanelState targets = gui::default_targets_panel_state();

    io::printn("A cycles AO: none, SSAO, ray traced; R toggles reflections; [ and ] move the roughness threshold");
    io::printn("Drag to orbit, wheel to zoom; Escape release quits");
    uint frame;
    PassTimings timings;
    while (window.poll()) {
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;

        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::targets_panel(&renderer, renderer.default_view, &targets, environment)!!;
        // The targets panel reconfigures the view it inspects; edits below start from that state.
        view_desc = renderer.views.get(renderer.default_view).desc;

        bool view_changed = edit_from_keys(input, &view_desc);
        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(&renderer)!!;
        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        view_changed |= gui::post_panel(&view_desc, {}, renderer.caps.ray_queries.enabled);
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();
        gui_renderer.finish_frame();

        platform::sync_window(&window, &renderer);
        if (view_changed) {
            if (catch excuse = render::configure_view(&renderer, renderer.default_view, view_desc)) {
                io::printfn("rt_effects: settings rejected (%s)", excuse);
            }
        }
        draw_frame(
            renderer:     &renderer,
            scene:        &scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!!;

        frame++;
        if (!benchmark_frames || frame <= BENCHMARK_WARMUP_FRAMES) continue;
        accumulate_timings(&timings, &renderer);
        if (timings.frames == benchmark_frames) {
            io::printfn(
                "Ray-traced AO: %.4f ms, reflections: %.4f ms, mean over %d frames at %dx%d",
                timings.ambient_occlusion_ms / timings.frames,
                timings.reflections_ms / timings.frames,
                timings.frames,
                renderer.swapchain_info.width,
                renderer.swapchain_info.height,
            );
            break;
        }
    }
    return 0;
}
