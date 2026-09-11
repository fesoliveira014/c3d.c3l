module shadows_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import imgui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import sdl;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f; // balances precise orbit control against pointer travel
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the look-rotation up-axis degeneracy
const float ORBIT_ZOOM_STEP @local = 0.9f; // keeps each wheel step visually useful
const float ORBIT_DISTANCE_MIN @local = 4; // leaves room for the near shadow fixtures
const float ORBIT_DISTANCE_MAX @local = 48; // keeps the ground readable at the widest view
const usz MOUSE_BUTTON_LEFT @local = 1;
const uint CHECKER_SIZE @local = 8; // 256 bytes keep the generated fixture small
const uint CHECKER_CELL @local = 2; // four cells preserve visible cutouts at distance
const uint RGBA8_BYTES @local = 4;
const int SHADOW_PRIORITY_MIN @local = -100; // bounds GUI dragging without constraining renderer policy
const int SHADOW_PRIORITY_MAX @local = 100; // keeps competing request order easy to demonstrate
const float SHADOW_DISTANCE_MIN @local = 1; // keeps enabled settings within their positive-distance contract
const float SHADOW_DISTANCE_MAX @local = 200; // covers the fixture without an unwieldy slider range
const float SHADOW_BIAS_MAX @local = 4; // retains a useful slope-factor range before separation dominates
const float SHADOW_NORMAL_BIAS_MAX @local = 0.25f; // exposes offset tradeoffs at this scene scale
const float EXAMPLE_NORMAL_BIAS @local = 0.16f; // clears the ground bands at the cost of contact separation
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 }; // leaves the center of the default view unobscured
const Vec2 CONTROLS_PANEL_SIZE @local = { 400, 590 }; // contains both suns and mesh controls at 900px high
const Vec2 STATS_PANEL_POSITION @local = { 1010, 16 }; // aligns the panel against the default window edge
const Vec2 STATS_PANEL_SIZE @local = { 414, 420 }; // holds four delayed layer timings without clipping

struct Orbit @local {
    Vec3 target;
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

fn bool edit_float(
    ZString label,
    float* value,
    float minimum,
    float maximum,
) @local {
    float edited = *value;
    if (!imgui::drag_float_ex(
        label: label,
        v: &edited,
        v_speed: 0.01f,
        v_min: minimum,
        v_max: maximum,
        format: "%.4f",
        flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    )) return false;
    if (edited == *value) return false;
    *value = edited;
    return true;
}

fn void shadow_controls(ZString title, Light* sunlight, bool orthographic) @local {
    imgui::separator_text(title);
    imgui::push_id(title);
    defer imgui::pop_id();

    imgui::checkbox("Enabled", &sunlight.shadow.enabled);
    int priority = sunlight.shadow.priority;
    if (imgui::drag_int_ex(
        label: "Priority",
        v: &priority,
        v_speed: 1,
        v_min: SHADOW_PRIORITY_MIN,
        v_max: SHADOW_PRIORITY_MAX,
        format: "%d",
        flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    )) sunlight.shadow.priority = priority;

    int cascades = (int)sunlight.shadow.cascades;
    if (imgui::drag_int_ex(
        label: "Cascades",
        v: &cascades,
        v_speed: 0.1f,
        v_min: 1,
        v_max: (int)light::MAX_SHADOW_CASCADES,
        format: "%d",
        flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    )) sunlight.shadow.cascades = (uint)cascades;

    if (orthographic) {
        imgui::text_unformatted("Cascade lambda applies to perspective cameras.");
    } else {
        edit_float(
            label: "Cascade lambda",
            value: &sunlight.shadow.cascade_lambda,
            minimum: 0,
            maximum: 1,
        );
    }
    edit_float(
        label: "Max distance",
        value: &sunlight.shadow.max_distance,
        minimum: SHADOW_DISTANCE_MIN,
        maximum: SHADOW_DISTANCE_MAX,
    );
    edit_float(
        label: "Depth bias",
        value: &sunlight.shadow.bias,
        minimum: 0,
        maximum: SHADOW_BIAS_MAX,
    );
    edit_float(
        label: "Normal bias",
        value: &sunlight.shadow.normal_bias,
        minimum: 0,
        maximum: SHADOW_NORMAL_BIAS_MAX,
    );
}

fn void shadow_stats(render::Renderer* renderer) @local {
    imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    bool visible = imgui::begin("Shadow statistics", null, {});
    defer imgui::end();
    if (!visible) return;

    Stats* stats = &renderer.stats;
    imgui::text("Recorded layers: %u", stats.shadow_layers);
    imgui::text("Dropped requests: %u", stats.shadow_requests_dropped);
    imgui::text("Fixed atlas: %u layers at %u texels", renderer.max_shadow_layers, renderer.shadow_resolution);
    if (!renderer.timestamps_enabled) {
        imgui::text_unformatted("Run with --gpu-timings for delayed layer times.");
        return;
    }

    imgui::text(
        "Shadow pass: %.3f ms",
        (double)stats.gpu_pass_ms[Pass.SHADOW_ATLAS.ordinal],
    );
    if (!stats.shadow_timings.len) {
        imgui::text_unformatted("No completed layer timings yet.");
        return;
    }
    foreach (timing : stats.shadow_timings) {
        imgui::text(
            "Light %u:%u, cascade %u: %.3f ms",
            timing.light.index,
            timing.light.generation,
            timing.layer_index + 1,
            (double)timing.gpu_ms,
        );
    }
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

fn void? run_gui(
    platform::Window* window,
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Node* primary_sun,
    Node* secondary_sun,
    Node* solid_box,
    Node* masked_plane,
    Node* off_camera_box,
    Node* ground,
    Orbit* orbit,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    bool orthographic;
    bool escape_captured;
    camera::Camera* camera = scene.get(camera_node, camera::Camera);
    Light* primary_light = scene.get(primary_sun, Light);
    Light* secondary_light = scene.get(secondary_sun, Light);
    Mesh* solid_mesh = scene.get(solid_box, Mesh);
    Mesh* masked_mesh = scene.get(masked_plane, Mesh);
    Mesh* ground_mesh = scene.get(ground, Mesh);
    Mesh* off_camera_mesh = scene.get(off_camera_box, Mesh);

    while (window.poll(&forward_gui_event, &gui_renderer)) {
        bool keyboard_was_captured = window.input.keyboard_captured_by_gui;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
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
        bool controls_visible = imgui::begin("Directional shadows", null, {});
        if (controls_visible) {
            imgui::text_unformatted("Drag outside this panel to orbit; wheel to zoom.");
            imgui::text_unformatted("Release Escape outside text controls to close.");
            if (imgui::checkbox("Orthographic camera", &orthographic)) {
                uint layers = camera.layers;
                *camera = orthographic ? camera::orthographic(20, 0.1f, 100) : camera::perspective_deg(55, 0.1f, 100);
                camera.layers = layers;
            }
            if (orthographic) edit_float(
                label: "View height",
                value: &camera.ortho_height,
                minimum: 4,
                maximum: 40,
            );

            shadow_controls("Primary sun", primary_light, orthographic);
            shadow_controls("Second sun", secondary_light, orthographic);

            imgui::separator_text("Mesh switches");
            imgui::checkbox("Solid box casts", &solid_mesh.cast_shadow);
            imgui::checkbox("Masked plane casts", &masked_mesh.cast_shadow);
            imgui::checkbox("Ground receives", &ground_mesh.receive_shadow);
            imgui::checkbox("Off-camera blocker casts", &off_camera_mesh.cast_shadow);
            imgui::checkbox("Off-camera blocker visible", &off_camera_box.visible);
            imgui::text_unformatted("The off-camera blocker is on layer 2; both suns and the camera use layer 1.");
        }
        imgui::end();

        apply_orbit(orbit, input, camera_node);
        scene.update_world();
        shadow_stats(renderer);
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

fn TextureId add_mask_checker(AssetStore* assets) @local {
    TextureId texture;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, CHECKER_SIZE * CHECKER_SIZE * RGBA8_BYTES);
        for (uint y = 0; y < CHECKER_SIZE; y++) {
            for (uint x = 0; x < CHECKER_SIZE; x++) {
                bool opaque = ((x / CHECKER_CELL + y / CHECKER_CELL) & 1) == 0;
                usz offset = (usz)(y * CHECKER_SIZE + x) * RGBA8_BYTES;
                pixels[offset] = opaque ? 255 : 70;
                pixels[offset + 1] = opaque ? 230 : 70;
                pixels[offset + 2] = opaque ? 80 : 70;
                pixels[offset + 3] = opaque ? 255 : 0;
            }
        }
        texture = assets.add_texture(
            desc: material::texture_2d_desc(
                width: CHECKER_SIZE,
                height: CHECKER_SIZE,
                format: RGBA8_SRGB,
                debug_name: "shadow_mask_checker",
            ),
            pixels: pixels,
            key: "texture/shadows/mask_checker",
        )!!;
    };
    return texture;
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
        platform::default_window_desc("c3d directional shadows", 1440, 900))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_directional_shadows" },
    )!!;
    defer render::destroy_renderer(&renderer);

    TextureId checker = add_mask_checker(&assets);
    GeometryId ground_geometry;
    GeometryId box_geometry;
    GeometryId plane_geometry;
    @pool() {
        Geometry ground_data = geometry::plane(tmem, 28, 28);
        ground_geometry = assets.add_geometry(&ground_data, "geometry/shadows/ground")!!;
        Geometry box_data = geometry::box(
            allocator: tmem,
            width: 2,
            height: 2,
            depth: 2,
        );
        box_geometry = assets.add_geometry(&box_data, "geometry/shadows/box")!!;
        Geometry plane_data = geometry::plane(tmem, 3, 3);
        plane_geometry = assets.add_geometry(&plane_data, "geometry/shadows/masked_plane")!!;
    };

    MaterialId ground_material = assets.add_material(material::standard({
        .base_color = { 0.62f, 0.64f, 0.68f, 1 },
        .metallic = 0,
        .roughness = 0.82f,
    }), "material/shadows/ground")!!;
    MaterialId standard_box_material = assets.add_material(material::standard({
        .base_color = { 0.12f, 0.38f, 0.82f, 1 },
        .metallic = 0.08f,
        .roughness = 0.35f,
    }), "material/shadows/standard_box")!!;
    MaterialId basic_box_material = assets.add_material(material::basic({
        .color = { 0.95f, 0.22f, 0.12f, 1 },
    }), "material/shadows/basic_box")!!;
    MaterialCommon masked = material::MATERIAL_COMMON_DEFAULT;
    masked.alpha_mode = MASK;
    masked.double_sided = true;
    MaterialId mask_material = assets.add_material(material::basic(
        params: {
            .color = { 1, 1, 1, 1 },
            .map = material::texture_slot(checker, asset::SAMPLER_NEAREST),
        },
        common: masked,
    ), "material/shadows/masked_plane")!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = 0.04f;

    Node* ground = scene.add_mesh(ground_geometry, ground_material, name: "ground_receiver")!!;
    Node* standard_box = scene.add_mesh(box_geometry, standard_box_material, name: "standard_box")!!;
    standard_box.local.position = { -3, 1, 1 };
    Node* solid_box = scene.add_mesh(box_geometry, basic_box_material, name: "basic_box")!!;
    solid_box.local.position = { 3, 1, -1 };
    Node* masked_plane = scene.add_mesh(plane_geometry, mask_material, name: "masked_plane")!!;
    masked_plane.local.position = { -0.5f, 1.5f, -2 };
    masked_plane.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::PI / 2);
    Node* off_camera_box = scene.add_mesh(box_geometry, standard_box_material, name: "off_camera_blocker")!!;
    off_camera_box.layers = 2;
    off_camera_box.local.position = { 15, 30, 9 };

    Light primary = light::directional({ 1, 0.95f, 0.85f }, 3);
    primary.layers = 1;
    primary.shadow.priority = 10;
    primary.shadow.normal_bias = EXAMPLE_NORMAL_BIAS;
    Node* primary_sun = scene.add_light(primary, name: "primary_sun")!!;
    primary_sun.layers = 1;
    primary_sun.local.rotation = maths::look_rotation((Vec3){ -0.5f, -1, -0.3f }.normalize(), { 0, 1, 0 });
    Light secondary = light::directional({ 0.35f, 0.45f, 0.8f }, 0.25f);
    secondary.layers = 1;
    secondary.shadow.priority = 0;
    secondary.shadow.normal_bias = EXAMPLE_NORMAL_BIAS;
    Node* secondary_sun = scene.add_light(secondary, name: "secondary_sun")!!;
    secondary_sun.layers = 1;
    secondary_sun.local.rotation = maths::look_rotation((Vec3){ 0.4f, -1, 0.2f }.normalize(), { 0, 1, 0 });

    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f, 100), name: "camera")!!;
    camera_node.layers = 1;
    Orbit orbit = {
        .target = { 0, 0.8f, 0 },
        .distance = 18,
        .yaw = 0.75f,
        .pitch = 0.35f,
    };
    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    if (catch excuse = run_gui(
        window: &window,
        renderer: &renderer,
        scene: &scene,
        camera_node: camera_node,
        primary_sun: primary_sun,
        secondary_sun: secondary_sun,
        solid_box: solid_box,
        masked_plane: masked_plane,
        off_camera_box: off_camera_box,
        ground: ground,
        orbit: &orbit,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }
    return 0;
}
