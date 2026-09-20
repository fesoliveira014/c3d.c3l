module profile_gui_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::material;
import c3d::platform;
import c3d::profile;
import c3d::render;
import c3d::scene;
import imgui;

const float SPIN_RADIANS_PER_SECOND @local = 0.8f; // Visible motion without obscuring scope inspection.
const uint PROFILE_FRAME_CAPACITY @local = 64; // About one second at 60 Hz; multiplies per-frame storage.
const uint PROFILE_CPU_SCOPES_PER_FRAME @local = 128; // Covers the hierarchy; reserves 128 samples per frame.
const uint PROFILE_MAX_DEPTH @local = 16; // Exceeds the hierarchy; reserves 16 stack indices.
const uint PROFILE_GPU_SCOPES_PER_FRAME @local = 512; // Covers this renderer; reserves 512 samples per frame.
const uint PROFILE_LABEL_BYTES_PER_FRAME @local = 8192; // Covers repeated labels; reserves 8 KiB per frame.
const Vec2 CONTROLS_PANEL_POSITION @local = { 1120, 16 }; // Clears the first-use profiler placement.
const Vec2 CONTROLS_PANEL_SIZE @local = { 144, 70 }; // Fits the visibility control at 1280 width.

fn void update_scene(
    Node* cube,
    Node* sphere,
    Scene* scene,
    float delta,
) @local {
    profile::@scope("scene.motion") {
        Quat increment = quaternion::from_axis_angle{float}(
            { 0, 1, 0 }, delta * SPIN_RADIANS_PER_SECOND);
        cube.local.rotation = cube.local.rotation.mul(increment).normalize();
    };
    profile::@scope("scene.motion") {
        Quat increment = quaternion::from_axis_angle{float}(
            { 1, 0, 0 }, delta * SPIN_RADIANS_PER_SECOND);
        sphere.local.rotation = sphere.local.rotation.mul(increment).normalize();
    };
    scene.update_world();
}

fn void? draw_profile_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    profile::GpuScopeToken render_scope = render::@gpu_begin(renderer, "application.render")!;
    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    render::@gpu_end(renderer, render_scope)!;

    return renderer.end_frame();
}

fn void? run_gui(
    platform::Window* window,
    render::Renderer* renderer,
    profile::Recorder* recorder,
    Scene* scene,
    Node* cube,
    Node* sphere,
    Node* camera_node,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    gui::ProfilerPanel profiler_panel = gui::create_profiler_panel(mem, recorder)!;
    defer gui::destroy_profiler_panel(&profiler_panel);

    bool profiler_visible = true;

    while (window.poll()) {
        profile::@capture(recorder, window.clock.frame) {
            gui_renderer.new_frame();
            defer {
                if (gui_renderer.frame_open) gui_renderer.finish_frame();
            }

            imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
            imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
            bool controls_visible = imgui::begin("Controls", null, {});
            if (controls_visible) imgui::checkbox("Show profiler", &profiler_visible);
            imgui::end();

            if (profiler_visible) gui::profiler_panel(&profiler_panel);

            profile::@scope("application.update") {
                update_scene(
                    cube: cube,
                    sphere: sphere,
                    scene: scene,
                    delta: window.clock.delta,
                );
            };

            gui_renderer.finish_frame();
            platform::sync_window(window, renderer);

            profile::@scope("application.render") {
                draw_profile_frame(
                    renderer: renderer,
                    scene: scene,
                    camera_node: camera_node,
                    gui_renderer: &gui_renderer,
                    info: { .time = window.clock.total, .delta = window.clock.delta },
                )!;
            };
        };
    }
}

<* Run a windowed profiler over a moving scene. *>
fn int main() {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d profiler", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    profile::RecorderDesc recorder_desc = {
        .frame_capacity = PROFILE_FRAME_CAPACITY,
        .label_bytes_per_frame = PROFILE_LABEL_BYTES_PER_FRAME,
    };
    $if $feat(C3D_PROFILE_CPU):
        recorder_desc.cpu_scopes_per_frame = PROFILE_CPU_SCOPES_PER_FRAME;
        recorder_desc.max_depth = PROFILE_MAX_DEPTH;
    $endif
    $if $feat(C3D_PROFILE_GPU):
        recorder_desc.gpu_scopes_per_frame = PROFILE_GPU_SCOPES_PER_FRAME;
    $endif
    profile::Recorder recorder = profile::create_recorder(mem, recorder_desc)!!;
    defer profile::destroy_recorder(&recorder);

    render::RendererDesc renderer_desc = {
        .validation = true,
        .gpu_timings = $feat(C3D_PROFILE_GPU),
        .application_name = "c3d_profile_gui",
    };
    $if $feat(C3D_PROFILE_GPU):
        renderer_desc.profiler = &recorder;
    $endif
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: renderer_desc,
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId box;
    GeometryId ball;
    @pool() {
        Geometry box_geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        box = assets.add_geometry(&box_geometry, "profile/box")!!;

        Geometry ball_geometry = geometry::sphere(tmem, 0.6f);
        ball = assets.add_geometry(&ball_geometry, "profile/sphere")!!;
    };

    MaterialId red = assets.add_material(
        material::basic({ .color = { 0.9f, 0.2f, 0.2f, 1 } }), "profile/red")!!;
    MaterialId blue = assets.add_material(
        material::basic({ .color = { 0.2f, 0.4f, 0.9f, 1 } }), "profile/blue")!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    Node* cube = scene.add_mesh(box, red, name: "cube")!!;
    cube.local.position = { -0.8f, 0, 0 };
    Node* sphere = scene.add_mesh(ball, blue, name: "sphere")!!;
    sphere.local.position = { 0.8f, 0, 0 };
    Node* camera_node = scene.add_camera(
        camera::perspective_deg(60, 0.1f), name: "camera")!!;
    camera_node.local.position = { 0, 0, 5 };

    renderer.prepare_scene(&scene)!!;

    if (catch excuse = run_gui(
        window: &window,
        renderer: &renderer,
        recorder: &recorder,
        scene: &scene,
        cube: cube,
        sphere: sphere,
        camera_node: camera_node,
    )) {
        io::eprintfn("Profiler GUI failed: %s", excuse);
        return 1;
    }

    return 0;
}
