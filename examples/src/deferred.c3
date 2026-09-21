module deferred_example;

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
import c3d::render::post;
import c3d::scene;
import imgui;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 2.0f;
const float ORBIT_DISTANCE_MAX @local = 40.0f;
const float LAMP_RADIANS_PER_SECOND @local = 0.7f;
const float LAMP_RADIUS @local = 3.5f;
const float LAMP_HEIGHT @local = 1.8f;
const float LAMP_INTENSITY @local = 18;
const float LAMP_RANGE @local = 9;
const float SUN_INTENSITY @local = 4;
const float AMBIENT_INTENSITY @local = 0.05f;
const float ENVIRONMENT_INTENSITY @local = 0.6f;
const float BACKGROUND_INTENSITY @local = 0.3f;
const float SPHERE_RADIUS @local = 0.6f;
const float CUBE_SIZE @local = 1.1f;
const float COLUMN_SPACING @local = 1.7f;
const float ROW_SPACING @local = 1.9f;
const float GROUND_SIZE @local = 16;
const float GROUND_LEVEL @local = -0.7f;
const uint COLUMNS @local = 5;
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 340, 180 };
const Vec2 POST_PANEL_POSITION @local = { 16, 212 };
const Vec2 POST_PANEL_SIZE @local = { 340, 300 };
const Vec2 TARGETS_PANEL_POSITION @local = { 920, 16 };
const Vec2 TARGETS_PANEL_SIZE @local = { 344, 690 };
const Vec2 STATS_PANEL_POSITION @local = { 372, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 300, 700 };

struct Orbit @local {
    Vec3  target;
    float distance;
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
    bool effects;
    bool clustered;
}

struct Materials @local {
    MaterialId ground;
    MaterialId dielectric;
    MaterialId mapped;
    MaterialId physical_plain;
    MaterialId physical_coat;
    MaterialId physical_ior;
    MaterialId toon;
    MaterialId basic;
    MaterialId glass;
    MaterialId transmissive;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.LEFT)) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
                -ORBIT_PITCH_LIMIT, ORBIT_PITCH_LIMIT);
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

fn bool shading_radios(ZString label, ViewDesc* desc) @local {
    bool changed;
    imgui::push_id(label);
    defer imgui::pop_id();
    imgui::text_unformatted(label);
    imgui::same_line();
    if (imgui::radio_button("Forward", desc.shading == FORWARD) && desc.shading != FORWARD) {
        desc.shading = FORWARD;
        changed = true;
    }
    imgui::same_line();
    if (imgui::radio_button("Deferred", desc.shading == DEFERRED) && desc.shading != DEFERRED) {
        desc.shading = DEFERRED;
        changed = true;
    }
    return changed;
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
    Node* lamp_node,
    EnvironmentId environment,
    Options options,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    Views views = {
        .left       = renderer.default_view,
        .left_desc  = render::default_view_desc(),
        .right_desc = render::default_view_desc(),
    };
    if (options.effects) {
        views.right_desc.post.bloom = true;
        views.right_desc.post.motion_blur = true;
        views.right_desc.post.depth_of_field = true;
        views.right_desc.post.dof_params.focus_distance = 11;
        views.left_desc.post = views.right_desc.post;
    }
    if (options.clustered) {
        views.left_desc.lights = LightSelection.CLUSTERED;
        views.right_desc.lights = LightSelection.CLUSTERED;
    }
    views.right_desc.shading = ShadingPath.DEFERRED;
    views.right = render::create_view(renderer, views.right_desc)!;
    defer (void)render::destroy_view(renderer, views.right);
    configure_views(renderer, &views)!;
    renderer.prepare_scene(scene)!;

    Orbit orbit = { .target = { 0, 0.2f, 0 }, .distance = 11, .pitch = 0.35f };
    TargetsPanelState targets = gui::default_targets_panel_state();
    float lamp_angle;
    bool orbit_lamp = true;
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
        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Deferred", null, {})) {
            imgui::text_unformatted("Left and right views render the same scene and camera.");
            views_changed |= shading_radios("Left", &views.left_desc);
            views_changed |= shading_radios("Right", &views.right_desc);
            imgui::checkbox("Orbit lamp", &orbit_lamp);
            if (imgui::radio_button("Flat lights", views.right_desc.lights == FLAT)) {
                views.right_desc.lights = FLAT;
                views_changed = true;
            }
            imgui::same_line();
            if (imgui::radio_button("Clustered lights", views.right_desc.lights == CLUSTERED)) {
                views.right_desc.lights = CLUSTERED;
                views_changed = true;
            }
        }
        imgui::end();

        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (gui::post_panel(&views.right_desc, {})) {
            views.left_desc.post = views.right_desc.post;
            views_changed = true;
        }

        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::targets_panel(renderer, views.right, &targets, environment)!;
        views.right_desc = renderer.views.get(views.right).desc;

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        if (orbit_lamp) lamp_angle += window.clock.delta * LAMP_RADIANS_PER_SECOND;
        lamp_node.local.position = { math::cos(lamp_angle) * LAMP_RADIUS, LAMP_HEIGHT, math::sin(lamp_angle) * LAMP_RADIUS };
        apply_orbit(&orbit, input, camera_node);
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

fn Materials? create_materials(AssetStore* assets, TextureId base_color, TextureId material_data, TextureId normal) @local {
    PhysicalParams plain = material::PHYSICAL_PARAMS_DEFAULT;
    plain.standard.base_color = { 0.2f, 0.35f, 0.9f, 1 };
    plain.standard.roughness = 0.3f;
    plain.standard.metallic = 0;
    PhysicalParams coat = plain;
    coat.standard.base_color = { 0.8f, 0.1f, 0.1f, 1 };
    coat.clearcoat = 1;
    coat.clearcoat_roughness = 0.1f;
    PhysicalParams low_ior = plain;
    low_ior.standard.base_color = { 0.9f, 0.9f, 0.9f, 1 };
    low_ior.ior = 1.0f;
    PhysicalParams transmissive = material::PHYSICAL_PARAMS_DEFAULT;
    transmissive.standard.base_color = { 0.95f, 0.95f, 1, 1 };
    transmissive.standard.roughness = 0.05f;
    transmissive.standard.metallic = 0;
    transmissive.transmission = 1;
    transmissive.thickness = 0.6f;
    MaterialCommon blended = material::MATERIAL_COMMON_DEFAULT;
    blended.alpha_mode = AlphaMode.BLEND;
    ToonParams toon = material::TOON_PARAMS_DEFAULT;
    toon.color = { 0.3f, 0.8f, 0.35f, 1 };
    toon.steps = 3;

    return {
        .ground = assets.add_material(
            material::standard({ .base_color = { 0.45f, 0.45f, 0.47f, 1 }, .metallic = 0, .roughness = 0.85f }),
            "deferred/floor",
        )!,
        .dielectric = assets.add_material(
            material::standard({ .base_color = { 0.85f, 0.3f, 0.2f, 1 }, .metallic = 0, .roughness = 0.4f }),
            "deferred/dielectric",
        )!,
        .mapped = assets.add_material(
            material::standard({
                .base_color             = { 1, 1, 1, 1 },
                .metallic               = 1,
                .roughness              = 1,
                .base_color_map         = material::texture_slot(base_color),
                .metallic_roughness_map = material::texture_slot(material_data),
                .normal_map             = material::texture_slot(normal),
            }),
            "deferred/mapped",
        )!,
        .physical_plain = assets.add_material(material::physical(plain), "deferred/physical_plain")!,
        .physical_coat = assets.add_material(material::physical(coat), "deferred/physical_coat")!,
        .physical_ior = assets.add_material(material::physical(low_ior), "deferred/physical_ior")!,
        .toon = assets.add_material(material::toon(toon), "deferred/toon")!,
        .basic = assets.add_material(material::basic({ .color = { 1, 0.85f, 0.2f, 1 } }), "deferred/basic")!,
        .glass = assets.add_material(
            material::standard({ .base_color = { 0.2f, 0.8f, 1, 0.4f }, .metallic = 0, .roughness = 0.2f }, blended),
            "deferred/glass",
        )!,
        .transmissive = assets.add_material(material::physical(transmissive), "deferred/transmissive")!,
    };
}

fn void? place_row(Scene* scene, GeometryId geometry, MaterialId[] materials, float z, String prefix) @local {
    float start = -(float)(materials.len - 1) * 0.5f * COLUMN_SPACING;
    foreach (index, material : materials) {
        Node* node = scene.add_mesh(geometry, material, name: prefix)!;
        node.local.position = { start + (float)index * COLUMN_SPACING, 0, z };
    }
}

fn int main(String[] args) {
    Options options;
    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            $if $feat(C3D_PROFILE_GPU):
                options.gpu_timings = true;
            $else
                io::eprintfn("--gpu-timings needs GPU profiling: c3c build deferred --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                return 1;
            $endif
        } else if (argument == "--effects") {
            options.effects = true;
        } else if (argument == "--clustered") {
            options.clustered = true;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d deferred", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = options.gpu_timings, .validation = true, .application_name = "c3d_deferred" },
    )!!;
    defer render::destroy_renderer(&renderer);

    TextureId studio_source;
    TextureId base_color;
    TextureId material_data;
    TextureId normal;
    @pool() {
        Path source = path::tnew($$FILEPATH)!!;
        Path assets_directory = source.parent()!!.tappend("../assets")!!;
        Path pbr_directory = assets_directory.tappend("pbr")!!;
        studio_source = image::load_hdr(
            &assets,
            (String)assets_directory.tappend("ibl/studio_small_09_1k.hdr")!!,
            "deferred/source/studio",
        )!!;
        base_color = image::load_texture(&assets, (String)pbr_directory.tappend("base_color.png")!!, true)!!;
        material_data = image::load_texture(
            assets: &assets,
            path:   (String)pbr_directory.tappend("material_data.png")!!,
            srgb:   false,
        )!!;
        normal = image::load_texture(&assets, (String)pbr_directory.tappend("normal.png")!!, false)!!;
    };
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(studio_source, light::ENVIRONMENT_SETTINGS_DEFAULT),
        "deferred/environment/studio",
    )!!;

    GeometryId sphere;
    GeometryId box;
    GeometryId ground;
    @pool() {
        Geometry sphere_geometry = geometry::sphere(tmem, SPHERE_RADIUS);
        sphere = assets.add_geometry(&sphere_geometry, "deferred/sphere")!!;
        Geometry box_geometry = geometry::box(tmem, CUBE_SIZE, CUBE_SIZE, CUBE_SIZE);
        box = assets.add_geometry(&box_geometry, "deferred/box")!!;
        Geometry ground_geometry = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground = assets.add_geometry(&ground_geometry, "deferred/ground")!!;
    };
    Materials materials = create_materials(&assets, base_color, material_data, normal)!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = AMBIENT_INTENSITY;
    scene.ambient_add = true;
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = BACKGROUND_INTENSITY;

    Node* floor = scene.add_mesh(ground, materials.ground, name: "ground")!!;
    floor.local.position = { 0, GROUND_LEVEL, 0 };
    MaterialId[COLUMNS] back_row = {
        materials.dielectric, materials.mapped, materials.physical_plain, materials.physical_coat, materials.physical_ior,
    };
    MaterialId[COLUMNS] front_row = {
        materials.toon, materials.basic, materials.glass, materials.transmissive, materials.mapped,
    };
    place_row(&scene, sphere, back_row[..], -ROW_SPACING * 0.5f, "back")!!;
    place_row(&scene, box, front_row[..], ROW_SPACING * 0.5f, "front")!!;

    Node* sun = scene.add_light(light::directional({ 1, 0.98f, 0.92f }, SUN_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0.35f, -0.8f, -0.45f }.normalize(), { 0, 1, 0 });
    Node* lamp = scene.add_light(light::point({ 1, 0.7f, 0.4f }, LAMP_INTENSITY, LAMP_RANGE), name: "lamp")!!;
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!!;

    if (catch excuse = run_gui(
        window:      &window,
        renderer:    &renderer,
        scene:       &scene,
        camera_node: camera_node,
        lamp_node:   lamp,
        environment: environment,
        options:     options,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }
    return 0;
}
