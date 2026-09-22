module shading_paths_example;

import std::io;
import std::io::file;
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
import c3d::shader;
import c3d::shader::compile;
import imgui;

const String TINT_FRAGMENT_FILE @local = "../shaders/custom/tint.frag.glsl";
const String PULSE_VERTEX_FILE @local = "../shaders/custom/pulse.vert.glsl";
const String PULSE_FRAGMENT_FILE @local = "../shaders/custom/pulse.frag.glsl";
const String PULSE_GBUFFER_FILE @local = "../shaders/custom/pulse_gbuffer.frag.glsl";
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 2.0f;
const float ORBIT_DISTANCE_MAX @local = 40.0f;
const float LAMP_RADIANS_PER_SECOND @local = 0.25f;
const float LAMP_INTENSITY @local = 6;
const float LAMP_RANGE @local = 4;
const uint LAMP_COUNT @local = 48;
const uint LAMP_RINGS @local = 2;
const float[LAMP_RINGS] LAMP_RING_RADIUS @local = { 4, 7 };
const float[LAMP_RINGS] LAMP_RING_HEIGHT @local = { 1.5f, 2.5f };
const float SUN_INTENSITY @local = 3;
const float AMBIENT_INTENSITY @local = 0.05f;
const float ENVIRONMENT_INTENSITY @local = 0.5f;
const float BACKGROUND_INTENSITY @local = 0.3f;
const float SPHERE_RADIUS @local = 0.6f;
const float CUBE_SIZE @local = 1.1f;
const float COLUMN_SPACING @local = 1.7f;
const float ROW_SPACING @local = 1.9f;
const float GROUND_SIZE @local = 16;
const float GROUND_LEVEL @local = -0.7f;
const float PULSE_AMPLITUDE @local = 0.25f;
const float PULSE_ANGULAR_FREQUENCY @local = 3;
const uint COLUMNS @local = 5;
const uint VIEW_COUNT @local = 4;
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 360, 260 };
const Vec2 VIEWS_PANEL_POSITION @local = { 16, 292 };
const Vec2 VIEWS_PANEL_SIZE @local = { 620, 420 };
const Vec2 TARGETS_PANEL_POSITION @local = { 920, 16 };
const Vec2 TARGETS_PANEL_SIZE @local = { 344, 690 };
const Vec2 STATS_PANEL_POSITION @local = { 652, 292 };
const Vec2 STATS_PANEL_SIZE @local = { 260, 420 };
const ZString[VIEW_COUNT] VIEW_LABELS @local = { "Forward/Flat", "Forward/Clustered", "Deferred/Flat", "Deferred/Clustered" };
const Vec3[8] LAMP_PALETTE @local = {
    { 1, 0.3f, 0.2f }, { 1, 0.7f, 0.2f }, { 0.9f, 1, 0.3f }, { 0.3f, 1, 0.4f },
    { 0.2f, 0.9f, 1 }, { 0.3f, 0.4f, 1 }, { 0.8f, 0.3f, 1 }, { 1, 0.4f, 0.8f },
};

struct TintParams @local {
    Vec4 color;
}

struct PulseParams @local {
    Vec4 color;
    Vec4 motion;
}

struct ShaderFiles @local {
    String fragment;
    String gbuffer;
    String vertex;
    usz    param_block_size;
    String name;
}

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct Views @local {
    ViewId[VIEW_COUNT]   ids;
    ViewDesc[VIEW_COUNT] descs;
    uint                 width;
    uint                 height;
    uint                 selected;
}

struct Options @local {
    bool gpu_timings;
}

struct Materials @local {
    MaterialId ground;
    MaterialId dielectric;
    MaterialId mapped;
    MaterialId physical_plain;
    MaterialId physical_coat;
    MaterialId toon;
    MaterialId glass;
    MaterialId transmissive;
    MaterialId tint;
    MaterialId pulse;
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

fn PixelRect quadrant(uint width, uint height, uint index) @local {
    uint half_width = width / 2;
    uint half_height = height / 2;
    bool right = (index & 1) != 0;
    bool bottom = index >= 2;
    return {
        .x = right ? half_width : 0,
        .y = bottom ? half_height : 0,
        .width = right ? width - half_width : half_width,
        .height = bottom ? height - half_height : half_height,
    };
}

fn void? configure_views(render::Renderer* renderer, Views* views) @local {
    views.width = renderer.swapchain_info.width;
    views.height = renderer.swapchain_info.height;
    foreach (index, &desc : views.descs) {
        desc.viewport = quadrant(views.width, views.height, (uint)index);
        render::configure_view(renderer, views.ids[index], *desc)!;
    }
}

fn bool path_radios(ZString label, ViewDesc* desc) @local {
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
    imgui::same_line();
    if (imgui::radio_button("Flat", desc.lights == FLAT) && desc.lights != FLAT) {
        desc.lights = FLAT;
        changed = true;
    }
    imgui::same_line();
    if (imgui::radio_button("Clustered", desc.lights == CLUSTERED) && desc.lights != CLUSTERED) {
        desc.lights = CLUSTERED;
        changed = true;
    }
    return changed;
}

fn char[]? compile_file(Allocator allocator, String path, ShaderStage stage, String[] defines = {}) @local {
    String source = (String)file::load(tmem, path)!;
    String log;
    char[]? spirv = compile::compile_glsl(
        allocator:  allocator,
        source:     source,
        stage:      stage,
        defines:    defines,
        debug_name: path,
        log:        &log,
    );
    if (log.len) io::printfn("%s", log);
    return spirv;
}

fn ShaderDesc? compile_shader_files(Allocator allocator, ShaderFiles* files) @local {
    ShaderDesc desc = {
        .fragment = compile_file(allocator, files.fragment, ShaderStage.FRAGMENT)!,
        .param_block_size = files.param_block_size,
    };
    if (files.gbuffer.len) desc.gbuffer = compile_file(allocator, files.gbuffer, ShaderStage.FRAGMENT)!;
    if (files.vertex.len) {
        desc.vertex.shaded = compile_file(allocator, files.vertex, ShaderStage.VERTEX)!;
        desc.vertex.depth = compile_file(allocator, files.vertex, ShaderStage.VERTEX, { "DEPTH_ONLY" })!;
    }
    return desc;
}

fn ShaderId? add_shader_files(AssetStore* assets, ShaderFiles* files) @local {
    @pool() {
        ShaderDesc? desc = compile_shader_files(tmem, files);
        if (catch excuse = desc) {
            io::printfn("%s: compile failed (%s); run from examples/build so ../shaders resolves", files.name, excuse);
            return excuse~;
        }
        return assets.add_shader(&desc, files.name);
    };
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
        foreach (view : views.ids) {
            renderer.render_view(scene, camera_node, view)!;
            renderer.finish_view(view)!;
        }

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
    Node*[] lamp_nodes,
    EnvironmentId environment,
    Options options,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    Views views;
    foreach (index, &desc : views.descs) {
        *desc = render::default_view_desc();
        desc.shading = index >= 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        desc.lights = (index & 1) != 0 ? LightSelection.CLUSTERED : LightSelection.FLAT;
    }
    views.ids[0] = renderer.default_view;
    uint created;
    defer foreach (view : views.ids[1:created]) (void)render::destroy_view(renderer, view);
    for (uint index = 1; index < VIEW_COUNT; index++) {
        views.ids[index] = render::create_view(renderer, views.descs[index])!;
        created++;
    }
    configure_views(renderer, &views)!;
    renderer.prepare_scene(scene)!;

    Orbit orbit = { .target = { 0, 0.2f, 0 }, .distance = 13, .pitch = 0.4f };
    TargetsPanelState targets = gui::default_targets_panel_state();
    float lamp_angle;
    bool orbit_lamps = true;
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
        if (imgui::begin("Shading paths", null, {})) {
            imgui::text_unformatted("Four views render the same scene and camera.");
            foreach (index, &desc : views.descs) views_changed |= path_radios(VIEW_LABELS[index], desc);
            imgui::separator_text("Targets panel view");
            foreach (index, label : VIEW_LABELS) {
                if (imgui::radio_button(label, views.selected == index)) views.selected = (uint)index;
                if (index + 1 < VIEW_COUNT) imgui::same_line();
            }
            imgui::checkbox("Orbit lamps", &orbit_lamps);
        }
        imgui::end();

        imgui::set_next_window_pos(VIEWS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(VIEWS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Views", null, {})) gui::view_stats_table(renderer, views.ids[..], VIEW_LABELS[..]);
        imgui::end();

        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        ViewId selected = views.ids[views.selected];
        gui::targets_panel(renderer, selected, &targets, environment)!;
        views.descs[views.selected] = renderer.views.get(selected).desc;

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        if (orbit_lamps) lamp_angle += window.clock.delta * LAMP_RADIANS_PER_SECOND;
        place_lamps(lamp_nodes, lamp_angle);
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

fn void place_lamps(Node*[] lamp_nodes, float angle) @local {
    uint per_ring = LAMP_COUNT / LAMP_RINGS;
    foreach (index, node : lamp_nodes) {
        uint ring = (uint)index / per_ring;
        float phase = angle + (float)((uint)index % per_ring) * (2 * math::PI / (float)per_ring);
        float radius = LAMP_RING_RADIUS[ring];
        node.local.position = { math::cos(phase) * radius, LAMP_RING_HEIGHT[ring], math::sin(phase) * radius };
    }
}

fn Materials? create_materials(
    AssetStore* assets,
    TextureId base_color,
    TextureId material_data,
    TextureId normal,
    ShaderId tint_shader,
    ShaderId pulse_shader,
) @local {
    PhysicalParams plain = material::PHYSICAL_PARAMS_DEFAULT;
    plain.standard.base_color = { 0.2f, 0.35f, 0.9f, 1 };
    plain.standard.roughness = 0.3f;
    plain.standard.metallic = 0;
    PhysicalParams coat = plain;
    coat.standard.base_color = { 0.8f, 0.1f, 0.1f, 1 };
    coat.clearcoat = 1;
    coat.clearcoat_roughness = 0.1f;
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
    TintParams tint = { .color = { 1, 0.55f, 0.2f, 1 } };
    PulseParams pulse = {
        .color = { 0.3f, 0.6f, 1, 1 },
        .motion = { PULSE_AMPLITUDE, PULSE_ANGULAR_FREQUENCY, 0, 0 },
    };

    return {
        .ground = assets.add_material(
            material::standard({ .base_color = { 0.45f, 0.45f, 0.47f, 1 }, .metallic = 0, .roughness = 0.85f }),
            "shading_paths/floor",
        )!,
        .dielectric = assets.add_material(
            material::standard({ .base_color = { 0.85f, 0.3f, 0.2f, 1 }, .metallic = 0, .roughness = 0.4f }),
            "shading_paths/dielectric",
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
            "shading_paths/mapped",
        )!,
        .physical_plain = assets.add_material(material::physical(plain), "shading_paths/physical_plain")!,
        .physical_coat = assets.add_material(material::physical(coat), "shading_paths/physical_coat")!,
        .toon = assets.add_material(material::toon(toon), "shading_paths/toon")!,
        .glass = assets.add_material(
            material::standard({ .base_color = { 0.2f, 0.8f, 1, 0.4f }, .metallic = 0, .roughness = 0.2f }, blended),
            "shading_paths/glass",
        )!,
        .transmissive = assets.add_material(material::physical(transmissive), "shading_paths/transmissive")!,
        .tint = assets.add_material(material::custom(tint_shader, material::@as_bytes(tint)), "shading_paths/tint")!,
        .pulse = assets.add_material(material::custom(pulse_shader, material::@as_bytes(pulse)), "shading_paths/pulse")!,
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
                io::eprintfn("--gpu-timings needs GPU profiling: c3c build shading_paths --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                return 1;
            $endif
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d shading paths", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = options.gpu_timings, .validation = true, .application_name = "c3d_shading_paths" },
    )!!;
    defer render::destroy_renderer(&renderer);

    ShaderFiles tint_files = {
        .fragment = TINT_FRAGMENT_FILE,
        .param_block_size = TintParams::size,
        .name = "tint",
    };
    ShaderFiles pulse_files = {
        .fragment = PULSE_FRAGMENT_FILE,
        .gbuffer = PULSE_GBUFFER_FILE,
        .vertex = PULSE_VERTEX_FILE,
        .param_block_size = PulseParams::size,
        .name = "pulse",
    };
    ShaderId? tint_shader = add_shader_files(&assets, &tint_files);
    ShaderId? pulse_shader = add_shader_files(&assets, &pulse_files);
    if (catch tint_shader) return 1;
    if (catch pulse_shader) return 1;

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
            "shading_paths/source/studio",
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
        "shading_paths/environment/studio",
    )!!;

    GeometryId sphere;
    GeometryId box;
    GeometryId ground;
    @pool() {
        Geometry sphere_geometry = geometry::sphere(tmem, SPHERE_RADIUS);
        sphere = assets.add_geometry(&sphere_geometry, "shading_paths/sphere")!!;
        Geometry box_geometry = geometry::box(tmem, CUBE_SIZE, CUBE_SIZE, CUBE_SIZE);
        box = assets.add_geometry(&box_geometry, "shading_paths/box")!!;
        Geometry ground_geometry = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground = assets.add_geometry(&ground_geometry, "shading_paths/ground")!!;
    };
    Materials materials = create_materials(
        assets:        &assets,
        base_color:    base_color,
        material_data: material_data,
        normal:        normal,
        tint_shader:   tint_shader,
        pulse_shader:  pulse_shader,
    )!!;

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
        materials.dielectric, materials.mapped, materials.physical_plain, materials.physical_coat, materials.tint,
    };
    MaterialId[COLUMNS] front_row = {
        materials.toon, materials.pulse, materials.glass, materials.transmissive, materials.mapped,
    };
    place_row(&scene, sphere, back_row[..], -ROW_SPACING * 0.5f, "back")!!;
    place_row(&scene, box, front_row[..], ROW_SPACING * 0.5f, "front")!!;

    Node* sun = scene.add_light(light::directional({ 1, 0.98f, 0.92f }, SUN_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0.35f, -0.8f, -0.45f }.normalize(), { 0, 1, 0 });
    Node*[LAMP_COUNT] lamps;
    foreach (index, &lamp : lamps) {
        Vec3 color = LAMP_PALETTE[index % LAMP_PALETTE.len];
        *lamp = scene.add_light(light::point(color, LAMP_INTENSITY, LAMP_RANGE), name: "lamp")!!;
    }
    place_lamps(lamps[..], 0);
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!!;

    if (catch excuse = run_gui(
        window:      &window,
        renderer:    &renderer,
        scene:       &scene,
        camera_node: camera_node,
        lamp_nodes:  lamps[..],
        environment: environment,
        options:     options,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }
    return 0;
}
