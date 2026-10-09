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
const Vec2   PANEL_SIZE @local = { 500, 420 };
const ulong PUBLICATION_ITEMS_PER_CALL @local = 1024; // atomic models above this allowance defer
const double MILLISECONDS_PER_SECOND @local = 1000;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;

enum Stage @local {
    WAITING,
    PREPARING,
    REPORT,
    SHOWN,
    FAILED,
    CANCELLED,
}

struct Timings @local {
    double decode_ms;
    double publish_ms;
    double publish_frame_ms;
    uint   prepare_frames;
    double advance_max_ms;
    double prepare_frame_max_ms;
    double first_frame_ms;
}

struct Showcase @local {
    AsyncLoader*    loader;
    LoadId          request;
    time::Clock     requested;
    LoadStatus      status;
    PublishLimits   limits;
    PublishReport   publication;
    LoaderCounters  counters;
    bool            request_alive;
    PrepareId       prepare;
    PrepareProgress progress;
    bool            decoded;
    bool            published_last_frame;
    Stage           stage;
    Timings         timings;
    Node*           placeholder;
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

fn void? panel(Showcase* showcase) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    bool visible = imgui::begin("Streaming", null, {});
    defer imgui::end();
    if (!visible) return;

    imgui::text("Phase: %s", gui::@enum_name(LoadPhase, showcase.status.phase));
    if (showcase.status.failure) imgui::text("Failure: %s", string::tformat_zstr("%s", showcase.status.failure));
    Timings* timings = &showcase.timings;
    PrepareProgress* progress = &showcase.progress;
    LoaderCounters* counters = &showcase.counters;
    imgui::text("Observed decode: %.1f ms", timings.decode_ms);
    imgui::text("Worker decode: %.3f ms", (double)counters.decode_ns / NANOSECONDS_PER_MILLISECOND);
    imgui::text("Publish: %.3f ms, frame %.1f ms", timings.publish_ms, timings.publish_frame_ms);
    imgui::text("Publication allowance: %llu items", showcase.limits.items);
    imgui::text("Publication items: %llu, total %llu", showcase.publication.items_used, counters.publication_items);
    imgui::text("Queued: %u, decoding: %u", counters.queued, counters.decoding);
    imgui::text("Decoded: %u, cancelling: %u", counters.decoded, counters.cancelling);
    imgui::text("Published total: %llu, cancelled total: %llu", counters.publications, counters.cancellations);
    imgui::text("Decode failures: %llu, commit failures: %llu", counters.decode_failures, counters.commit_failures);
    imgui::text("Prepare: %s", gui::@enum_name(PrepareState, progress.state));
    imgui::text("Prepared bytes: %llu / %llu", (ulong)progress.bytes_done, (ulong)progress.bytes_total);
    imgui::text("Prepared units: %u / %u", progress.units_done, progress.units_total);
    imgui::text("Largest advance: %.2f ms", timings.advance_max_ms);
    imgui::text("Largest frame while preparing: %.1f ms", timings.prepare_frame_max_ms);

    if (showcase.publication.deferred) {
        if (showcase.publication.required_exact) {
            imgui::text("Deferred model requires %llu items", showcase.publication.required_items);
        } else {
            imgui::text("Deferred model requires at least %llu items", showcase.publication.required_items);
        }
        if (imgui::button("Use reported item allowance")) {
            showcase.limits.items = showcase.publication.required_items;
        }
    }
    if (showcase.request_alive && showcase.stage == Stage.WAITING
      && showcase.status.phase != LoadPhase.CANCELLING && showcase.status.phase != LoadPhase.CANCELLED) {
        if (imgui::button("Cancel loading")) {
            showcase.loader.cancel(showcase.request)!;
            showcase.status = showcase.loader.status(showcase.request);
        }
    }
}

fn void? release_request(Showcase* showcase) @local {
    showcase.loader.release(showcase.request)!;
    showcase.request_alive = false;
}

fn void? advance(
    Showcase* showcase,
    AssetStore* assets,
    Scene* scene,
    render::Renderer* renderer,
    double frame_ms,
) @local {
    if (showcase.request_alive) showcase.status = showcase.loader.status(showcase.request);
    LoadPhase phase = showcase.status.phase;
    if (!showcase.decoded && phase != LoadPhase.QUEUED && phase != LoadPhase.DECODING
      && phase != LoadPhase.CANCELLING) {
        showcase.decoded = true;
        showcase.timings.decode_ms = elapsed_ms(&showcase.requested);
    }
    switch (showcase.stage) {
        case WAITING:
            time::Clock clock = time::clock::now();
            showcase.publication = showcase.loader.publish_within(showcase.limits);
            double publish_ms = elapsed_ms(&clock);
            showcase.status = showcase.loader.status(showcase.request);
            if (showcase.status.phase == LoadPhase.FAILED) {
                showcase.stage = Stage.FAILED;
                release_request(showcase)!;
                io::printfn("streaming: failed: %s", showcase.status.failure);
            } else if (showcase.status.phase == LoadPhase.CANCELLED) {
                showcase.stage = Stage.CANCELLED;
                release_request(showcase)!;
                io::printn("streaming: loading cancelled");
            } else if (showcase.status.phase == LoadPhase.PUBLISHED) {
                showcase.timings.publish_ms = publish_ms;
                showcase.prepare = renderer.begin_prepare_model(showcase.status.model)!;
                release_request(showcase)!;
                showcase.published_last_frame = true;
                showcase.stage = Stage.PREPARING;
            }
        case PREPARING:
            Timings* timings = &showcase.timings;
            if (showcase.published_last_frame) {
                timings.publish_frame_ms = frame_ms;
                showcase.published_last_frame = false;
            } else {
                timings.prepare_frame_max_ms = math::max(timings.prepare_frame_max_ms, frame_ms);
            }
            showcase.progress = renderer.prepare_progress(showcase.prepare);
            if (showcase.progress.state == PrepareState.FAILED) {
                io::printfn("streaming: preparation failed: %s", showcase.progress.failure);
                renderer.end_prepare(showcase.prepare)!;
                showcase.stage = Stage.FAILED;
            } else if (showcase.progress.state == PrepareState.READY) {
                Node* instance = model::instantiate(assets, scene, showcase.status.model, name: "model")!;
                instance.local.position = MODEL_POSITION;
                showcase.placeholder.visible = false;
                renderer.end_prepare(showcase.prepare)!;
                showcase.stage = Stage.REPORT;
            }
        case REPORT:
            Timings* timings = &showcase.timings;
            timings.first_frame_ms = frame_ms;
            io::printfn(
                "streaming: decode %.1f ms, publish %.3f ms (frame %.1f ms), %d frames to ready, "
                "largest advance %.2f ms, largest frame %.1f ms, first frame drawn %.1f ms",
                timings.decode_ms, timings.publish_ms, timings.publish_frame_ms, timings.prepare_frames,
                timings.advance_max_ms, timings.prepare_frame_max_ms, timings.first_frame_ms,
            );
            showcase.stage = Stage.SHOWN;
        case SHOWN:
        case FAILED:
        case CANCELLED:
            break;
    }
    showcase.counters = showcase.loader.counters();
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    Showcase* showcase,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    if (showcase.stage == Stage.PREPARING) {
        time::Clock clock = time::clock::now();
        renderer.advance_prepares()!;
        showcase.timings.advance_max_ms = math::max(showcase.timings.advance_max_ms, elapsed_ms(&clock));
        showcase.timings.prepare_frames++;
    }
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
        panel(showcase)!;
        gui_renderer.finish_frame();
        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            showcase:     showcase,
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
        .limits      = { .items = PUBLICATION_ITEMS_PER_CALL },
        .placeholder = build_scene(&assets, &scene)!!,
    };
    showcase.requested = time::clock::now();
    showcase.request = loader.request({
        .path    = model_path,
        .format  = ModelFormat.GLTF,
        .options = asset::LOAD_OPTIONS_DEFAULT,
    })!!;
    showcase.request_alive = true;

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
