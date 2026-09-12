module ibl_example;

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
import sdl;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 1.0f;
const float ORBIT_DISTANCE_MAX @local = 50.0f;
const uint GRID_SIDE @local = 7; // 49 draws expose both complete material axes without instancing
const float GRID_SPACING @local = 1.1f; // separates the radius-0.4 spheres
const usz MOUSE_BUTTON_LEFT @local = 1; // SDL button index
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 390, 820 };
const Vec2 STATS_PANEL_POSITION @local = { 1104, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 320, 290 };
const float EDITOR_WIDTH @local = 170;
const float INITIAL_LIGHTING_INTENSITY @local = 1;
const float INITIAL_BACKGROUND_INTENSITY @local = 0.25f;
const float INITIAL_AMBIENT_INTENSITY @local = 0.08f;
const int ENVIRONMENT_SIZE_MAX @local = 2048;
const int ENVIRONMENT_SPECULAR_SIZE_MIN @local = 32;

enum EnvironmentChoice @local {
    NONE,
    STUDIO,
    SKY,
}

struct EnvironmentIds @local {
    EnvironmentId studio;
    EnvironmentId sky;
}

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct Controls @local {
    EnvironmentChoice lighting;
    EnvironmentChoice background;
    EnvironmentChoice quality;
    bool linked;
    float lighting_intensity;
    float background_intensity;
    float lighting_rotation_degrees;
    float background_rotation_degrees;
    Vec4 background_color;
    float ao_strength;
    int conversion_size;
    int specular_size;
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

fn bool edit_scalar(
    ZString label,
    float* value,
    float minimum,
    float maximum,
) @local {
    float edited = *value;
    imgui::set_next_item_width(EDITOR_WIDTH);
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

fn bool edit_size(ZString label, int* value, int minimum) @local {
    imgui::set_next_item_width(EDITOR_WIDTH);
    return imgui::drag_int_ex(
        label: label,
        v: value,
        v_speed: 1,
        v_min: minimum,
        v_max: ENVIRONMENT_SIZE_MAX,
        format: "%d",
        flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    );
}

fn EnvironmentId environment_id(EnvironmentChoice choice, EnvironmentIds environments) @local {
    switch (choice) {
        case NONE: return {};
        case STUDIO: return environments.studio;
        case SKY: return environments.sky;
    }
}

fn StandardParams grid_params(uint index, TextureId ao_texture) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.65f, 0.18f, 0.07f, 1 };
    params.metallic = (float)(index % GRID_SIDE) / (float)(GRID_SIDE - 1);
    params.roughness = (float)(index / GRID_SIDE) / (float)(GRID_SIDE - 1);
    params.occlusion_strength = 0;
    params.occlusion_map = material::texture_slot(ao_texture);
    return params;
}

fn void set_ao_strength(AssetStore* assets, MaterialId[] materials, float strength) @local {
    foreach (material_id : materials) {
        assets.material(material_id).data.standard.occlusion_strength = strength;
        assets.mark_material_dirty(material_id);
    }
}

fn void load_quality_controls(
    AssetStore* assets,
    EnvironmentId environment,
    Controls* controls,
) @local {
    EnvironmentSettings settings = assets.environment(environment).desc.settings;
    controls.conversion_size = (int)settings.conversion_size;
    controls.specular_size = (int)settings.specular_size;
}

fn void update_scene(
    Scene* scene,
    Controls* controls,
    EnvironmentIds environments,
) @local {
    scene.environment = environment_id(controls.lighting, environments);
    scene.environment_intensity = controls.lighting_intensity;
    scene.environment_rotation = quaternion::from_axis_angle{float}(
        { 0, 1, 0 }, math::deg_to_rad(controls.lighting_rotation_degrees));
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = controls.background == NONE ? BackgroundKind.COLOR : BackgroundKind.ENVIRONMENT;
    scene.background.color = controls.background_color;
    scene.background.environment = environment_id(controls.background, environments);
    scene.background.intensity = controls.background_intensity;
    scene.background.rotation = quaternion::from_axis_angle{float}(
        { 0, 1, 0 }, math::deg_to_rad(controls.background_rotation_degrees));
}

fn void? environment_controls(
    render::Renderer* renderer,
    Scene* scene,
    EnvironmentIds environments,
    MaterialId[] materials,
    Controls* controls,
) @local {
    imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    bool visible = imgui::begin("Environment controls", null, {});
    defer imgui::end();
    if (!visible) return;

    imgui::text_unformatted("Columns: metallic 0 to 1");
    imgui::text_unformatted("Rows, bottom up: roughness 0 to 1");
    imgui::text_unformatted("Drag to orbit; wheel to zoom.");
    imgui::text_unformatted("Release Escape to close.");

    imgui::separator_text("Lighting");
    if (imgui::radio_button("None##lighting", controls.lighting == NONE)) {
        controls.lighting = NONE;
        if (controls.linked) controls.background = NONE;
    }
    imgui::same_line();
    if (imgui::radio_button("Studio##lighting", controls.lighting == STUDIO)) {
        controls.lighting = STUDIO;
        if (controls.linked) controls.background = STUDIO;
    }
    imgui::same_line();
    if (imgui::radio_button("Sky##lighting", controls.lighting == SKY)) {
        controls.lighting = SKY;
        if (controls.linked) controls.background = SKY;
    }
    bool lighting_intensity_changed = edit_scalar(
        label: "Lighting intensity",
        value: &controls.lighting_intensity,
        minimum: 0,
        maximum: 4,
    );
    if (lighting_intensity_changed && controls.linked) {
        controls.background_intensity = controls.lighting_intensity;
    }
    bool lighting_rotation_changed = edit_scalar(
        label: "Lighting rotation (deg)",
        value: &controls.lighting_rotation_degrees,
        minimum: -180,
        maximum: 180,
    );
    if (lighting_rotation_changed && controls.linked) {
        controls.background_rotation_degrees = controls.lighting_rotation_degrees;
    }

    imgui::separator_text("Background");
    if (imgui::radio_button("Color##background", controls.background == NONE)) {
        controls.background = NONE;
        if (controls.linked) controls.lighting = NONE;
    }
    imgui::same_line();
    if (imgui::radio_button("Studio##background", controls.background == STUDIO)) {
        controls.background = STUDIO;
        if (controls.linked) controls.lighting = STUDIO;
    }
    imgui::same_line();
    if (imgui::radio_button("Sky##background", controls.background == SKY)) {
        controls.background = SKY;
        if (controls.linked) controls.lighting = SKY;
    }
    bool background_intensity_changed = edit_scalar(
        label: "Background intensity",
        value: &controls.background_intensity,
        minimum: 0,
        maximum: 4,
    );
    if (background_intensity_changed && controls.linked) {
        controls.lighting_intensity = controls.background_intensity;
    }
    bool background_rotation_changed = edit_scalar(
        label: "Background rotation (deg)",
        value: &controls.background_rotation_degrees,
        minimum: -180,
        maximum: 180,
    );
    if (background_rotation_changed && controls.linked) {
        controls.lighting_rotation_degrees = controls.background_rotation_degrees;
    }
    imgui::color_edit4(
        "Background color",
        (float*)&controls.background_color,
        { .float_ = true },
    );
    if (imgui::checkbox("Link lighting and background", &controls.linked) && controls.linked) {
        controls.background = controls.lighting;
        controls.background_intensity = controls.lighting_intensity;
        controls.background_rotation_degrees = controls.lighting_rotation_degrees;
    }

    imgui::separator_text("Ambient and occlusion");
    imgui::checkbox("Add constant ambient", &scene.ambient_add);
    edit_scalar(
        label: "Ambient intensity",
        value: &scene.ambient_intensity,
        minimum: 0,
        maximum: 1,
    );
    float ao_strength = controls.ao_strength;
    if (edit_scalar(
        label: "AO strength",
        value: &ao_strength,
        minimum: 0,
        maximum: 1,
    )) {
        controls.ao_strength = ao_strength;
        set_ao_strength(renderer.assets, materials, ao_strength);
    }

    imgui::separator_text("Processing quality");
    if (imgui::radio_button("Studio##quality", controls.quality == STUDIO)) {
        controls.quality = STUDIO;
        load_quality_controls(renderer.assets, environments.studio, controls);
    }
    imgui::same_line();
    if (imgui::radio_button("Sky##quality", controls.quality == SKY)) {
        controls.quality = SKY;
        load_quality_controls(renderer.assets, environments.sky, controls);
    }
    edit_size("Conversion face size", &controls.conversion_size, 1);
    edit_size(
        "Specular face size",
        &controls.specular_size,
        ENVIRONMENT_SPECULAR_SIZE_MIN,
    );
    if (imgui::button("Apply processing sizes")) {
        EnvironmentId environment = environment_id(controls.quality, environments);
        EnvironmentAsset* record = renderer.assets.environment(environment);
        record.desc.settings = {
            .conversion_size = (uint)controls.conversion_size,
            .specular_size = (uint)controls.specular_size,
        };
        renderer.assets.mark_environment_dirty(environment);
        renderer.upload_environment(environment)!;
    }
    EnvironmentId selected = environment_id(controls.quality, environments);
    EnvironmentSettings applied = renderer.assets.environment(selected).desc.settings;
    imgui::text("Applied: conversion %u, specular %u", applied.conversion_size, applied.specular_size);
    imgui::text("Environment prepares: %u", renderer.stats.environment_prepares);

    update_scene(scene, controls, environments);
}

fn void? run_gui(
    platform::Window* window,
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    EnvironmentIds environments,
    MaterialId[] materials,
    Orbit* orbit,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    Controls controls = {
        .lighting = STUDIO,
        .background = STUDIO,
        .quality = STUDIO,
        .linked = false,
        .lighting_intensity = INITIAL_LIGHTING_INTENSITY,
        .background_intensity = INITIAL_BACKGROUND_INTENSITY,
        .background_color = { 0.025f, 0.025f, 0.025f, 1 },
        .ao_strength = 0,
        .conversion_size = (int)light::ENVIRONMENT_SETTINGS_DEFAULT.conversion_size,
        .specular_size = (int)light::ENVIRONMENT_SETTINGS_DEFAULT.specular_size,
    };
    bool escape_captured;

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

        environment_controls(
            renderer: renderer,
            scene: scene,
            environments: environments,
            materials: materials,
            controls: &controls,
        )!;

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
        platform::default_window_desc("c3d IBL environments", 1440, 900))!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_ibl" },
    )!!;
    defer render::destroy_renderer(&renderer);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_color = { 1, 1, 1 };
    scene.ambient_intensity = INITIAL_AMBIENT_INTENSITY;

    TextureId studio_source;
    TextureId sky_source;
    TextureId ao_texture;
    @pool() {
        Path source = path::tnew($$FILEPATH)!!;
        Path assets_directory = source.parent()!!.tappend("../assets")!!;
        Path environment_directory = assets_directory.tappend("ibl")!!;
        Path pbr_directory = assets_directory.tappend("pbr")!!;
        studio_source = image::load_hdr(
            &assets,
            (String)environment_directory.tappend("studio_small_09_1k.hdr")!!,
            "ibl/source/studio",
        )!!;
        sky_source = image::load_hdr(
            &assets,
            (String)environment_directory.tappend("kloppenheim_06_puresky_1k.hdr")!!,
            "ibl/source/sky",
        )!!;
        ao_texture = image::load_texture(
            assets: &assets,
            path: (String)pbr_directory.tappend("material_data.png")!!,
            srgb: false,
            key: "ibl/occlusion",
        )!!;
    };

    EnvironmentSettings settings = light::ENVIRONMENT_SETTINGS_DEFAULT;
    EnvironmentIds environments = {
        .studio = assets.add_environment(
            light::texture_environment(studio_source, settings),
            "ibl/environment/studio",
        )!!,
        .sky = assets.add_environment(
            light::texture_environment(sky_source, settings),
            "ibl/environment/sky",
        )!!,
    };
    renderer.upload_environment(environments.studio)!!;
    renderer.upload_environment(environments.sky)!!;

    MaterialId[GRID_SIDE * GRID_SIDE] materials;
    @pool() {
        Geometry sphere = geometry::sphere(tmem, 0.4f);
        GeometryId sphere_geometry = assets.add_geometry(&sphere, "ibl/sphere")!!;
        for (uint index = 0; index < materials.len; index++) {
            uint column = index % GRID_SIDE;
            uint row = index / GRID_SIDE;
            materials[index] = assets.add_material(material::standard(grid_params(index, ao_texture)))!!;
            Node* node = scene.add_mesh(
                geometry: sphere_geometry,
                material: materials[index],
                name: string::tformat("sphere %d,%d", column, row),
            )!!;
            node.local.position = {
                ((float)column - (float)(GRID_SIDE - 1) * 0.5f) * GRID_SPACING,
                ((float)row - (float)(GRID_SIDE - 1) * 0.5f) * GRID_SPACING,
                0,
            };
        }
    };

    scene.environment = environments.studio;
    scene.environment_intensity = INITIAL_LIGHTING_INTENSITY;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environments.studio;
    scene.background.intensity = INITIAL_BACKGROUND_INTENSITY;

    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    Orbit orbit = { .distance = 12 };
    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    if (catch excuse = run_gui(
        window: &window,
        renderer: &renderer,
        scene: &scene,
        camera_node: camera_node,
        environments: environments,
        materials: materials[..],
        orbit: &orbit,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }
    return 0;
}
