module pbr_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import imgui;
import c3d::material;
import c3d::light;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import sdl;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 1.0f;
const float ORBIT_DISTANCE_MAX @local = 50.0f;
const uint GRID_SIDE @local = 7; // 49 draws compare both scalar axes without instancing
const float GRID_SPACING @local = 1.1f; // separates the radius-0.4 spheres
const float CONE_GAP_DEGREES @local = 0.1f; // keeps inner and outer half-angles distinct
const usz MOUSE_BUTTON_LEFT @local = 1; // SDL button index
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 320, 275 };
const Vec2 SCENE_PANEL_POSITION @local = { 16, 307 };
const Vec2 SCENE_PANEL_SIZE @local = { 320, 285 };
const Vec2 MATERIAL_PANEL_POSITION @local = { 16, 608 };
const Vec2 MATERIAL_PANEL_SIZE @local = { 320, 250 };
const Vec2 STATS_PANEL_POSITION @local = { 1104, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 320, 800 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.mouse_buttons[MOUSE_BUTTON_LEFT]) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(
                x: orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
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

fn void forward_gui_event(sdl::Event* event, void* user) @local {
    GuiRenderer* gui_renderer = (GuiRenderer*)user;
    gui_renderer.process_event(event);
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
        renderer.render_view(scene, camera_node)!;
        renderer.composite_view()!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    return renderer.end_frame();
}

fn StandardParams grid_params(uint index) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.7f, 0.25f, 0.1f, 1 };
    params.metallic = (float)(index % GRID_SIDE) / (float)(GRID_SIDE - 1);
    params.roughness = 0.05f + (float)(index / GRID_SIDE) * 0.95f / (float)(GRID_SIDE - 1);
    return params;
}

fn void reset_grid(AssetStore* assets, MaterialId[] materials) @local {
    foreach (index, material_id : materials) {
        MaterialAsset* record = assets.material(material_id);
        StandardParams params = grid_params((uint)index);
        StandardParams previous = record.data.standard;
        if (previous.base_color == params.base_color && previous.metallic == params.metallic
            && previous.roughness == params.roughness && previous.emissive == params.emissive
            && previous.emissive_strength == params.emissive_strength) continue;
        record.data.standard = params;
        assets.mark_material_dirty(material_id);
    }
}

fn bool edit_scalar(
    ZString label,
    float* value,
    float minimum,
    float maximum,
) @local {
    float edited = *value;
    if (!imgui::drag_float_ex(
        label: label,
        v: &edited,
        v_speed: 0.05f,
        v_min: minimum,
        v_max: maximum,
        format: "%.3f",
        flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    )) return false;
    if (!(edited >= minimum && edited <= maximum) || edited == *value) return false;
    *value = edited;
    return true;
}

fn void edit_light_color(ZString label, Vec3* color) @local {
    Vec3 edited = *color;
    if (!imgui::color_edit3(label, (float*)&edited, { .hdr = true, .float_ = true })) return;
    if (edited.x >= 0 && edited.x <= float::max && edited.y >= 0 && edited.y <= float::max
        && edited.z >= 0 && edited.z <= float::max) *color = edited;
}

fn void edit_layer(ZString label, uint* layers, uint mask) @local {
    bool enabled = (*layers & mask) != 0;
    if (imgui::checkbox(label, &enabled)) {
        if (enabled) {
            *layers |= mask;
        } else {
            *layers &= ~mask;
        }
    }
}

fn void light_controls(Light* light) @local {
    bool visible = imgui::begin("Light", null, {});
    defer imgui::end();
    if (!visible) return;

    edit_light_color("Color", &light.color);
    edit_scalar(
        label: "Intensity",
        value: &light.intensity,
        minimum: 0,
        maximum: float::max,
    );
    switch (light.kind) {
        case DIRECTIONAL:
            imgui::text_unformatted("Directional");
        case POINT:
            imgui::text_unformatted("Point");
            edit_scalar(
                label: "Range",
                value: &light.range,
                minimum: 0,
                maximum: float::max,
            );
            imgui::text_unformatted("Range 0 is unbounded.");
        case SPOT:
            imgui::text_unformatted("Spot");
            edit_scalar(
                label: "Range",
                value: &light.range,
                minimum: 0,
                maximum: float::max,
            );
            imgui::text_unformatted("Range 0 is unbounded.");
            float outer_degrees = math::rad_to_deg(light.outer_cone);
            float inner_degrees = math::rad_to_deg(light.inner_cone);
            if (edit_scalar(
                label: "Outer half-angle (deg)",
                value: &outer_degrees,
                minimum: inner_degrees + CONE_GAP_DEGREES,
                maximum: 90,
            )) light.outer_cone = math::deg_to_rad(outer_degrees);
            if (edit_scalar(
                label: "Inner half-angle (deg)",
                value: &inner_degrees,
                minimum: 0,
                maximum: outer_degrees - CONE_GAP_DEGREES,
            )) light.inner_cone = math::deg_to_rad(inner_degrees);
    }

    edit_layer("Receive on layer 1", &light.layers, 1);
    edit_layer("Receive on layer 2", &light.layers, 2);
}

fn void? run_gui(
    platform::Window* window,
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Node* selected,
    MaterialId[] materials,
    Orbit* orbit,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    GuiPanelState panels = { .selected = selected.id };
    bool orthographic;
    bool escape_captured;
    camera::Camera* camera = scene.get(camera_node, camera::Camera);

    while (window.poll(&forward_gui_event, &gui_renderer)) {
        bool keyboard_was_captured = window.input.keyboard_captured_by_gui;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        // Text editing can drop capture on Escape down before its release arrives.
        if (input.keys_pressed[(usz)sdl::Scancode.ESCAPE] || input.keys_released[(usz)sdl::Scancode.ESCAPE]) {
            escape_captured |= keyboard_was_captured || input.keyboard_captured_by_gui;
        }
        if (input.keys_released[(usz)sdl::Scancode.ESCAPE]) {
            bool quit = !escape_captured;
            escape_captured = false;
            if (quit) break;
        }

        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        bool controls_visible = imgui::begin("Controls", null, {});
        if (controls_visible) {
            imgui::text_unformatted("Columns: metallic 0 to 1");
            imgui::text_unformatted("Rows, bottom up: roughness .05 to 1");
            imgui::text_unformatted("Drag to orbit; wheel to zoom.");
            imgui::text_unformatted("Release Escape to close.");
            if (imgui::button("Reset grid factors")) reset_grid(renderer.assets, materials);
            if (imgui::checkbox("Orthographic", &orthographic)) {
                uint layers = camera.layers;
                *camera = orthographic ? camera::orthographic(9, 0.1f, 100) : camera::perspective_deg(60, 0.1f);
                camera.layers = layers;
            }
            if (orthographic) {
                edit_scalar(
                    label: "View height",
                    value: &camera.ortho_height,
                    minimum: 0.1f,
                    maximum: 100,
                );
            }
            edit_layer("Camera sees layer 1", &camera.layers, 1);
            edit_layer("Camera sees layer 2", &camera.layers, 2);
            edit_light_color("Ambient", &scene.ambient_color);
            edit_scalar(
                label: "Ambient intensity",
                value: &scene.ambient_intensity,
                minimum: 0,
                maximum: float::max,
            );
        }
        imgui::end();

        imgui::set_next_window_pos(SCENE_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(SCENE_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::scene_panel(scene, &panels);
        if (scene.world.is_alive(panels.selected)) {
            Node* node = scene.node(panels.selected);
            if (Mesh* mesh = scene.get(node, Mesh)) {
                imgui::set_next_window_pos(MATERIAL_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
                imgui::set_next_window_size(MATERIAL_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
                gui::material_panel(renderer.assets, mesh.material)!;
            }
            if (Light* light = scene.get(node, Light)) {
                imgui::set_next_window_pos(MATERIAL_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
                imgui::set_next_window_size(MATERIAL_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
                light_controls(light);
            }
        }

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        apply_orbit(orbit, input, camera_node);
        scene.update_world();
        gui_renderer.finish_frame();
        platform::sync_window(window, renderer);
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
        platform::default_window_desc("c3d PBR", 1440, 900))!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_pbr" },
    )!!;
    defer render::destroy_renderer(&renderer);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = 0.03f;

    Light directional = light::directional({ 1, 1, 1 }, 1);
    directional.layers = 3;
    Node* sun = scene.add_light(directional, name: "directional")!!;
    sun.layers = 3;
    sun.local.rotation = maths::look_rotation((Vec3){ 0.5f, -0.5f, -1 }.normalize(), { 0, 1, 0 });
    Light point = light::point({ 1, 1, 1 }, 10, 10);
    point.layers = 3;
    Node* bulb = scene.add_light(point, name: "point")!!;
    bulb.layers = 3;
    bulb.local.position = { -3, 2, 4 };
    Light spot = light::spot(
        color: { 1, 1, 1 },
        intensity: 20,
        inner: 0.3f,
        outer: 0.6f,
        range: 12,
    );
    spot.layers = 3;
    Node* spotlight = scene.add_light(spot, name: "spot")!!;
    spotlight.layers = 3;
    spotlight.local.position = { 3, 3, 5 };
    spotlight.local.rotation = maths::look_rotation((-spotlight.local.position).normalize(), { 0, 1, 0 });

    MaterialId[GRID_SIDE * GRID_SIDE] materials;
    @pool() {
        Geometry sphere = geometry::sphere(tmem, 0.4f);
        GeometryId geometry_id = assets.add_geometry(&sphere, "pbr/sphere")!!;
        for (uint index = 0; index < materials.len; index++) {
            uint column = index % GRID_SIDE;
            uint row = index / GRID_SIDE;
            materials[index] = assets.add_material(material::standard(grid_params(index)))!!;
            Node* node = scene.add_mesh(
                geometry: geometry_id,
                material: materials[index],
                name: string::tformat("sphere %d,%d", column, row),
            )!!;
            node.local.position = {
                ((float)column - (float)(GRID_SIDE - 1) * 0.5f) * GRID_SPACING,
                ((float)row - (float)(GRID_SIDE - 1) * 0.5f) * GRID_SPACING,
                0,
            };
            node.layers = column % 2 == 0 ? 1 : 2;
        }
    };
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    scene.get(camera_node, camera::Camera).layers = 3;
    Orbit orbit = { .distance = 12 };
    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    if (catch excuse = run_gui(
        window: &window,
        renderer: &renderer,
        scene: &scene,
        camera_node: camera_node,
        selected: sun,
        materials: materials[..],
        orbit: &orbit,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }
    return 0;
}
