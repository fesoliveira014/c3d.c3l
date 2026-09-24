module rt_shadows_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
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

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the look-rotation up-axis degeneracy
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 3;
const float ORBIT_DISTANCE_MAX @local = 30;
const uint CHECKER_SIZE @local = 8; // 256 bytes keep the generated fixture small
const uint CHECKER_CELL @local = 2; // four cells keep the holes visible in the shadow
const uint RGBA8_BYTES @local = 4;
const Vec2 STATS_PANEL_POSITION @local = { 16, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 560 };
const Vec2 POST_PANEL_POSITION @local = { 1060, 16 };
const Vec2 POST_PANEL_SIZE @local = { 360, 420 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
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

fn TextureId add_checker(AssetStore* assets) @local {
    TextureId texture;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, CHECKER_SIZE * CHECKER_SIZE * RGBA8_BYTES);
        for (uint y = 0; y < CHECKER_SIZE; y++) {
            for (uint x = 0; x < CHECKER_SIZE; x++) {
                bool opaque = ((x / CHECKER_CELL + y / CHECKER_CELL) & 1) == 0;
                usz offset = (usz)(y * CHECKER_SIZE + x) * RGBA8_BYTES;
                pixels[offset] = 230;
                pixels[offset + 1] = 120;
                pixels[offset + 2] = 60;
                pixels[offset + 3] = opaque ? 255 : 0;
            }
        }
        texture = assets.add_texture(
            desc:   material::texture_2d_desc(
                width:      CHECKER_SIZE,
                height:     CHECKER_SIZE,
                format:     RGBA8_SRGB,
                debug_name: "rt_shadow_checker",
            ),
            pixels: pixels,
            key:    "texture/rt_shadows/checker",
        )!!;
    };
    return texture;
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

fn int main(String[] args) {
    bool gpu_timings;
    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            $if $feat(C3D_PROFILE_GPU):
                gpu_timings = true;
            $else
                io::eprintfn("--gpu-timings needs GPU profiling: c3c build <target> --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                return 1;
            $endif
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(platform::default_window_desc("c3d rt shadows", 1440, 900))!!;
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
            .application_name = "c3d_rt_shadows",
            .ray_queries      = true,
        },
    );
    if (catch excuse = created) {
        io::printfn("rt_shadows: ray queries unavailable (%s)", excuse);
        return 1;
    }
    Renderer renderer = created;
    defer render::destroy_renderer(&renderer);

    TextureId checker = add_checker(&assets);
    GeometryId plane_geometry;
    GeometryId sphere_geometry;
    GeometryId box_geometry;
    @pool() {
        Geometry plane = geometry::plane(tmem, 30, 30);
        plane_geometry = assets.add_geometry(&plane, "geometry/rt_shadows/plane")!!;
        Geometry sphere = geometry::sphere(tmem, 0.5f);
        sphere_geometry = assets.add_geometry(&sphere, "geometry/rt_shadows/sphere")!!;
        Geometry box = geometry::box(tmem, 0.6f, 4, 0.6f);
        box_geometry = assets.add_geometry(&box, "geometry/rt_shadows/box")!!;
    };
    MaterialId ground_material = assets.add_material(material::standard({
        .base_color = { 0.72f, 0.72f, 0.7f, 1 },
        .roughness  = 0.8f,
    }), "material/rt_shadows/ground")!!;
    MaterialId sphere_material = assets.add_material(material::standard({
        .base_color = { 0.2f, 0.45f, 0.9f, 1 },
        .roughness  = 0.4f,
    }), "material/rt_shadows/sphere")!!;
    MaterialId box_material = assets.add_material(material::standard({
        .base_color = { 0.9f, 0.47f, 0.24f, 1 },
        .roughness  = 0.6f,
    }), "material/rt_shadows/box")!!;
    MaterialCommon masked = material::MATERIAL_COMMON_DEFAULT;
    masked.alpha_mode = MASK;
    masked.double_sided = true;
    MaterialId masked_box_material = assets.add_material(material::standard(
        params: {
            .base_color     = { 1, 1, 1, 1 },
            .roughness      = 0.6f,
            .base_color_map = material::texture_slot(checker, asset::SAMPLER_NEAREST),
        },
        common: masked,
    ), "material/rt_shadows/masked_box")!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = 0.05f;
    scene.add_mesh(plane_geometry, ground_material, name: "ground")!!;
    Node* sphere = scene.add_mesh(sphere_geometry, sphere_material, name: "sphere")!!;
    sphere.local.position = { 1.5f, 0.5f, 0 };
    Node* box = scene.add_mesh(box_geometry, box_material, name: "off_camera_box")!!;
    box.local.position = { 0, 2, 11 };
    Mesh* box_mesh = scene.get(box, Mesh);

    Light sun = light::directional({ 1, 0.95f, 0.85f }, 3);
    sun.shadow.enabled = true;
    sun.shadow.ray_traced = true;
    Node* sun_node = scene.add_light(sun, name: "sun")!!;
    sun_node.local.rotation = maths::look_rotation((Vec3){ 0.1f, -0.4f, -1 }.normalize(), { 0, 1, 0 });

    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f, 100), name: "camera")!!;
    Orbit orbit = { .target = { 0, 0.5f, 0 }, .distance = 8, .yaw = 0, .pitch = 0.45f };
    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    ViewDesc view_desc = renderer.views.get(renderer.default_view).desc;
    view_desc.ray_tracing.shadows = true;
    render::configure_view(&renderer, renderer.default_view, view_desc)!!;

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    io::printn("T toggles ray-traced shadows and the atlas; M swaps the box between opaque and masked");
    io::printn("Drag to orbit, wheel to zoom; Escape release quits");
    bool box_masked;
    while (window.poll()) {
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        bool view_changed;
        if (input.key_pressed(platform::Scancode.T) && !input.keyboard_captured_by_gui) {
            view_desc.ray_tracing.shadows = !view_desc.ray_tracing.shadows;
            view_changed = true;
        }
        if (input.key_pressed(platform::Scancode.M) && !input.keyboard_captured_by_gui) {
            box_masked = !box_masked;
            box_mesh.material = box_masked ? masked_box_material : box_material;
        }
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(&renderer)!!;
        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        view_changed |= gui::post_panel(&view_desc, {}, renderer.caps.ray_queries.enabled);
        gui_renderer.finish_frame();

        platform::sync_window(&window, &renderer);
        if (view_changed) render::configure_view(&renderer, renderer.default_view, view_desc)!!;
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
