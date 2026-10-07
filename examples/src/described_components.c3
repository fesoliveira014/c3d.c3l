module described_components_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::describe;
import c3d::geometry;
import c3d::gui;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import described_component;
import imgui;
import std::io;
import std::math;

const Vec2 PANEL_POSITION @local = { 16, 16 };
const Vec2 PANEL_SIZE @local = { 440, 660 };
const float PULSE_SCALE @local = 0.002f; // bounds the speed-squared response to one fifth of the base size

fn void animate_component(Node* node, DescribedComponent* component, double time) @local {
    node.local.position = component.offset;
    node.local.scale = { 1, 1, 1 };
    if (!component.enabled) return;
    float phase = (float)time * component.speed;
    switch (component.mode) {
        case STILL:
            return;
        case ORBIT:
            node.local.position += (Vec3){ math::cos(phase), 0, math::sin(phase) };
        case PULSE:
            float scale = 1 + math::sin(phase) * component.speed_squared * PULSE_SCALE;
            node.local.scale = { scale, scale, scale };
    }
}

fn void? draw_frame(
    Renderer* renderer,
    GuiRenderer* gui_renderer,
    Scene* scene,
    Node* camera_node,
    FrameInfo frame,
) @local {
    renderer.begin_frame(frame)!;
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

fn int main() {
    described_component::register_described_component()!!;
    String missing_type;
    if (catch excuse = describe::validate_descriptions(&missing_type)) {
        io::eprintfn("Description setup failed for %s: %s", missing_type, excuse);
        return 1;
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("Described components", 1280, 720),
    )!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .validation = true, .application_name = "described_components" },
    )!!;
    defer render::destroy_renderer(&renderer);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.register(DescribedComponent)!!;

    GeometryId geometry_id;
    @pool() {
        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        geometry_id = assets.add_geometry(&geometry, "described/box")!!;
    };
    MaterialId material_id = assets.add_material(
        material::basic({ .color = { 0.25f, 0.65f, 0.95f, 1 } }),
        "described/blue",
    )!!;
    Node* subject = scene.add_mesh(geometry_id, material_id, name: "Described component")!!;
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "Camera")!!;
    camera_node.local.position = { 3, 2, 6 };
    camera_node.local.rotation = maths::look_rotation(-camera_node.local.position, { 0, 1, 0 });
    scene.add(subject, (DescribedComponent){
        .enabled = true,
        .speed = 2,
        .mode = PULSE,
        .target = camera_node.id,
        .geometry = geometry_id,
        .speed_squared = 4,
    });
    scene.update_world();
    renderer.prepare_scene(&scene)!!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    GuiPanelState panel = { .selected = subject.id };

    while (window.poll()) {
        gui_renderer.new_frame();
        if (window.input.key_released(platform::Scancode.ESCAPE)
            && !window.input.keyboard_captured_by_gui) {
            gui_renderer.finish_frame();
            break;
        }
        imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Scene", null, {})) {
            imgui::text_wrapped("Speed 10 is rejected; reduce Speed to clear the error.");
        }
        imgui::end();
        gui::scene_panel(&scene, &panel);
        animate_component(subject, scene.get(subject, DescribedComponent), window.clock.total);
        scene.update_world();
        gui_renderer.finish_frame();
        platform::sync_window(&window, &renderer);
        if (catch excuse = draw_frame(
            renderer: &renderer,
            gui_renderer: &gui_renderer,
            scene: &scene,
            camera_node: camera_node,
            frame: { .time = window.clock.total, .delta = window.clock.delta },
        )) {
            io::eprintfn("Rendering failed: %s", excuse);
            return 1;
        }
    }
    return 0;
}
