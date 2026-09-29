module skinned_crowd_example;

import std::io;
import std::io::path;
import std::math;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::gui;
import c3d::light;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;

const uint  CROWD_COLUMNS @local = 32;
const uint  CROWD_ROWS @local = 16;
const uint  CROWD_SIZE @local = CROWD_COLUMNS * CROWD_ROWS;
const float CROWD_SPACING @local = 1.5f;
const float POSE_MARGIN @local = 1; // metres around the rest bounds; limbs of the chosen clips stay inside
const float SPEED_MIN @local = 0.8f;
const float SPEED_MAX @local = 1.2f;
const uint  RANDOM_SEED @local = 20260927;
const uint  SCENE_NODES @local = 40000; // the Animator baseline instantiates every template node per instance
const float REPORT_SECONDS @local = 2;
const Vec3  CAMERA_POSITION @local = { 0, 14, 30 };
const Vec3  CAMERA_TARGET @local = { 0, 0, 0 };
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 360, 420 };
const String CHARACTER @local = "../assets/quaternius/AnimationLibrary_Godot.glb";
const String[] CLIP_NAMES @local = {
    "Walk_Loop", "Jog_Fwd_Loop", "Idle_Loop", "Sprint_Loop", "Walk_Formal_Loop", "Dance_Loop",
};

struct Random @local {
    uint state;
}

fn float Random.next(&self) @local {
    self.state = self.state * 1664525 + 1013904223;
    return (float)(self.state >> 8) / (float)(1 << 24);
}

struct Showcase @local {
    Node*    crowd;
    Node*[CROWD_SIZE] animated;
    bool     baseline;
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn ClipId? clip_named(AssetStore* assets, ModelTemplate* template, String name) @local {
    foreach (clip : template.clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    return NOT_FOUND~;
}

fn Aabb rest_bounds(AssetStore* assets, ModelTemplate* template) @local {
    Aabb bounds = assets.geometry(template.meshes[0].geometry).data.bounds;
    foreach (&mesh : template.meshes) bounds = maths::aabb_merge(bounds, assets.geometry(mesh.geometry).data.bounds);
    Vec3 margin = { POSE_MARGIN, POSE_MARGIN, POSE_MARGIN };
    return { .min = bounds.min - margin, .max = bounds.max + margin };
}

fn Transform slot_placement(uint index, Random* random) @local {
    float x = ((float)(index % CROWD_COLUMNS) - (float)CROWD_COLUMNS * 0.5f) * CROWD_SPACING;
    float z = ((float)(index / CROWD_COLUMNS) - (float)CROWD_ROWS * 0.5f) * CROWD_SPACING;
    return {
        .position = { x, 0, z },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, random.next() * (float)math::PI * 2),
        .scale    = { 1, 1, 1 },
    };
}

fn void set_baseline(Scene* scene, Showcase* showcase, bool baseline) @local {
    showcase.baseline = baseline;
    showcase.crowd.visible = !baseline;
    foreach (node : showcase.animated) node.visible = baseline;
}

fn void panel(render::Renderer* renderer, Showcase* showcase) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("AnimatedCrowd", null, {})) {
        imgui::text("Mode: %s (B toggles)", showcase.baseline ? "512 Animator instances" : "crowd");
        imgui::text("CPU record: %.3f ms", (double)renderer.stats.cpu_record_ms);
        imgui::text("Frame: %.3f ms", (double)renderer.stats.frame_ms);
        imgui::text("Draws: %u", renderer.stats.draws);
        imgui::text("Instances: %u", renderer.stats.instances);
    }
    imgui::end();
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
    anim::crowd_update(assets, scene, 0);
    anim::update(assets, scene, 0);
    scene.update_world();
    renderer.prepare_scene(scene)!;

    double last_report;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        if (input.key_pressed(Scancode.B) && !input.keyboard_captured_by_gui) {
            set_baseline(scene, showcase, !showcase.baseline);
        }
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        if (showcase.baseline) {
            anim::update(assets, scene, window.clock.delta);
        } else {
            anim::crowd_update(assets, scene, window.clock.delta);
        }
        scene.update_world();
        panel(renderer, showcase);
        gui_renderer.finish_frame();
        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
        if (window.clock.total - last_report >= REPORT_SECONDS) {
            last_report = window.clock.total;
            io::printfn("%s: cpu_record %.3f ms, frame %.3f ms, draws %d, instances %d",
                showcase.baseline ? "baseline" : "crowd", renderer.stats.cpu_record_ms, renderer.stats.frame_ms,
                renderer.stats.draws, renderer.stats.instances);
        }
    }
}

fn int main(String[] args) {
    bool baseline;
    foreach (argument : args[1..]) {
        if (argument == "--baseline") {
            baseline = true;
        } else {
            io::eprintfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(platform::default_window_desc("c3d crowd", 1280, 720))!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_crowd" },
    )!!;
    defer render::destroy_renderer(&renderer);

    ModelId model = gltf::load_model(&assets, example_path(CHARACTER))!!;
    ModelTemplate* template = &assets.model(model).data;
    ClipId[CLIP_NAMES.len] clips;
    foreach (index, name : CLIP_NAMES) clips[index] = clip_named(&assets, template, name)!!;

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODES });
    defer scene::destroy_scene(&scene);
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });

    Random random = { .state = RANDOM_SEED };
    CrowdInstance[CROWD_SIZE] instances;
    Showcase showcase;
    foreach (uint index, &instance : instances) {
        ClipId clip = clips[index % clips.len];
        float duration = assets.clip(clip).data.duration;
        *instance = {
            .placement = slot_placement(index, &random),
            .pose      = {
                .clip  = clip,
                .time  = random.next() * duration,
                .speed = SPEED_MIN + (SPEED_MAX - SPEED_MIN) * random.next(),
                .loop  = true,
            },
            .color     = { 1, 1, 1, 1 },
        };
        Node* animated = model::instantiate(&assets, &scene, model, name: "baseline")!!;
        animated.local = instance.placement;
        Animator* animator = anim::add_animator(&scene, animated);
        Action* action = animator.play(&assets, clip)!!;
        action.time = instance.pose.time;
        action.speed = instance.pose.speed;
        showcase.animated[index] = animated;
    }
    showcase.crowd = model::add_crowd(
        assets:      &assets,
        scene:       &scene,
        model:       model,
        capacity:    CROWD_SIZE,
        pose_bounds: rest_bounds(&assets, template),
        instances:   instances[..],
        name:        "crowd",
    )!!;
    set_baseline(&scene, &showcase, baseline);

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
        showcase: &showcase,
    )) {
        io::eprintfn("crowd example failed: %s", excuse);
        return 1;
    }
    return 0;
}
