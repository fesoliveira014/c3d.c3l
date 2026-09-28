module streaming_example;

import std::io;
import std::io::path;
import std::math;
import std::math::quaternion;
import std::time;
import c3d;
import c3d::asset;
import c3d::asset::loader;
import c3d::camera;
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

const String DEFAULT_MODEL @local = "../assets/gltf/BoxTextured.glb";
const float  PLACEHOLDER_RADIANS_PER_SECOND @local = 1.2f;
const float  GROUND_SIZE @local = 20;
const Vec3   CAMERA_POSITION @local = { 0, 3, 8 };
const Vec3   CAMERA_TARGET @local = { 0, 1, 0 };
const Vec3   MODEL_POSITION @local = { 0, 1, 0 };
const Vec2   PANEL_POSITION @local = { 16, 16 };
const Vec2   PANEL_SIZE @local = { 440, 200 };
const double MILLISECONDS_PER_SECOND @local = 1000;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;

enum Stage @local {
    WAITING,
    PREPARE,
    REPORT,
    SHOWN,
    FAILED,
}

struct Timings @local {
    double decode_ms;
    double publish_ms;
    double publish_frame_ms;
    double prepare_ms;
    double prepare_frame_ms;
}

struct Showcase @local {
    AsyncLoader* loader;
    LoadId       request;
    time::Clock  requested;
    LoadStatus   status;
    bool         decoded;
    Stage        stage;
    Timings      timings;
    Node*        placeholder;
}

fn double elapsed_ms(time::Clock* clock) @local => (double)clock.mark() / NANOSECONDS_PER_MILLISECOND;

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn Node*? build_scene(AssetStore* assets, Scene* scene) @local {
    GeometryId ground;
    GeometryId box;
    @pool() {
        Geometry plane = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground = assets.add_geometry(&plane, "streaming/ground")!;
        Geometry cube = geometry::box(tmem, 1, 1, 1);
        box = assets.add_geometry(&cube, "streaming/placeholder")!;
    };
    MaterialId gray = assets.add_material(material::basic({ .color = { 0.6f, 0.6f, 0.6f, 1 } }), "streaming/gray")!;
    MaterialId orange = assets.add_material(material::basic({ .color = { 1, 0.5f, 0.1f, 1 } }), "streaming/orange")!;
    scene.add_mesh(ground, gray, name: "ground")!;
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });
    Node* placeholder = scene.add_mesh(box, orange, name: "placeholder")!;
    placeholder.local.position = MODEL_POSITION;
    return placeholder;
}

fn void panel(Showcase* showcase) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Streaming", null, {})) {
        imgui::text("Phase: %s", gui::@enum_name(LoadPhase, showcase.status.phase));
        if (showcase.status.failure) imgui::text("Failure: %s", string::tformat_zstr("%s", showcase.status.failure));
        Timings* timings = &showcase.timings;
        imgui::text("Decode: %.1f ms", timings.decode_ms);
        imgui::text("Publish: %.3f ms, frame %.1f ms", timings.publish_ms, timings.publish_frame_ms);
        imgui::text("Prepare: %.1f ms, frame %.1f ms", timings.prepare_ms, timings.prepare_frame_ms);
    }
    imgui::end();
}

fn void? advance(
    Showcase* showcase,
    AssetStore* assets,
    Scene* scene,
    render::Renderer* renderer,
    double frame_ms,
) @local {
    showcase.status = showcase.loader.status(showcase.request);
    LoadPhase phase = showcase.status.phase;
    if (!showcase.decoded && phase != LoadPhase.QUEUED && phase != LoadPhase.DECODING) {
        showcase.decoded = true;
        showcase.timings.decode_ms = elapsed_ms(&showcase.requested);
    }
    switch (showcase.stage) {
        case WAITING:
            time::Clock clock = time::clock::now();
            uint published = showcase.loader.publish();
            double publish_ms = elapsed_ms(&clock);
            showcase.status = showcase.loader.status(showcase.request);
            if (showcase.status.phase == LoadPhase.FAILED) {
                showcase.stage = Stage.FAILED;
                io::printfn("streaming: failed: %s", showcase.status.failure);
            } else if (published) {
                showcase.timings.publish_ms = publish_ms;
                showcase.stage = Stage.PREPARE;
            }
        case PREPARE:
            showcase.timings.publish_frame_ms = frame_ms;
            time::Clock clock = time::clock::now();
            renderer.prepare_model(showcase.status.model)!;
            showcase.timings.prepare_ms = elapsed_ms(&clock);
            Node* instance = model::instantiate(assets, scene, showcase.status.model, name: "model")!;
            instance.local.position = MODEL_POSITION;
            showcase.placeholder.visible = false;
            showcase.stage = Stage.REPORT;
        case REPORT:
            showcase.timings.prepare_frame_ms = frame_ms;
            Timings* timings = &showcase.timings;
            io::printfn(
                "streaming: decode %.1f ms, publish %.3f ms (frame %.1f ms), prepare %.1f ms (frame %.1f ms)",
                timings.decode_ms, timings.publish_ms, timings.publish_frame_ms, timings.prepare_ms,
                timings.prepare_frame_ms,
            );
            showcase.stage = Stage.SHOWN;
        case SHOWN:
        case FAILED:
            break;
    }
}

fn void? draw_frame(
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
        renderer.finish_view(renderer.default_view)!;
        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    return renderer.end_frame();
}

fn void? run(
    platform::Window* window,
    render::Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    Showcase* showcase,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!;
    camera_node.local.position = CAMERA_POSITION;
    camera_node.local.rotation = maths::look_rotation(CAMERA_TARGET - CAMERA_POSITION, { 0, 1, 0 });
    scene.update_world();
    renderer.prepare_scene(scene)!;

    while (window.poll()) {
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;

        advance(
            showcase: showcase,
            assets:   assets,
            scene:    scene,
            renderer: renderer,
            frame_ms: window.clock.delta * MILLISECONDS_PER_SECOND,
        )!;
        showcase.placeholder.local.rotation = quaternion::from_axis_angle{float}(
            { 0, 1, 0 },
            (float)window.clock.total * PLACEHOLDER_RADIANS_PER_SECOND,
        );
        scene.update_world();
        panel(showcase);
        gui_renderer.finish_frame();
        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main(String[] args) {
    if (args.len > 2) {
        io::eprintfn("usage: streaming [model.gltf | model.glb]");
        return 1;
    }
    String model_path = args.len == 2 ? args[1] : example_path(DEFAULT_MODEL);

    platform::Window window = platform::create_window(platform::default_window_desc("c3d streaming", 1280, 720))!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_streaming" },
    )!!;
    defer render::destroy_renderer(&renderer);
    AsyncLoader loader = loader::create_async_loader(mem, &assets)!!;
    defer loader::destroy_async_loader(&loader);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Showcase showcase = {
        .loader      = &loader,
        .placeholder = build_scene(&assets, &scene)!!,
    };
    showcase.requested = time::clock::now();
    showcase.request = loader.request({
        .path    = model_path,
        .format  = ModelFormat.GLTF,
        .options = asset::LOAD_OPTIONS_DEFAULT,
    })!!;

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
        showcase: &showcase,
    )) {
        io::eprintfn("streaming example failed: %s", excuse);
        return 1;
    }
    return 0;
}
