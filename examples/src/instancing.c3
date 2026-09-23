module instancing_example;

import std::io;
import std::io::file;
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
import c3d::shader;
import c3d::shader::compile;
import c3d::spatial;
import imgui;

const String PULSE_VERTEX_FILE @local = "../shaders/custom/pulse.vert.glsl";
const String PULSE_FRAGMENT_FILE @local = "../shaders/custom/pulse.frag.glsl";
const uint GRID_SIDE @local = 64; // 4096 props in one batch; the instance-count lever of the example
const float GRID_SPACING @local = 0.5f;
const float PROP_SIZE @local = 0.3f;
const uint PULSE_COUNT @local = 8;
const float PULSE_RING_RADIUS @local = 5;
const float PULSE_AMPLITUDE @local = 0.4f;
const float PULSE_ANGULAR_FREQUENCY @local = 3;
const float TRIO_HEIGHT @local = 1.5f;
const float TRIO_SPACING @local = 1.8f;
const float TRIO_SPIN_RADIANS_PER_SECOND @local = 0.8f;
const float BOB_HEIGHT @local = 0.8f;
const float BOB_RADIANS_PER_SECOND @local = 2;
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 3;
const float ORBIT_DISTANCE_MAX @local = 60;
const Vec2 CONTROLS_PANEL_POSITION @local = { 10, 10 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 340, 170 };
const Vec2 STATS_PANEL_POSITION @local = { 10, 190 };
const Vec2 STATS_PANEL_SIZE @local = { 340, 440 };

struct PulseParams @local {
    Vec4 color;
    Vec4 motion;
}

struct Orbit @local {
    Vec3 target;
    float distance;
    float yaw;
    float pitch;
}

struct Batches @local {
    Node* trio;
    Node* props;
    Node* pulses;
}

struct Controls @local {
    bool motion_blur;
    bool deferred;
    bool animate;
    bool picked;
    String pick_name;
    uint pick_instance;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (input.button_down(platform::MouseButton.RIGHT) && !input.mouse_captured_by_gui) {
        orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
        orbit.pitch = math::clamp(
            orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
            -ORBIT_PITCH_LIMIT,
            ORBIT_PITCH_LIMIT,
        );
    }
    if (input.wheel != 0 && !input.mouse_captured_by_gui) {
        float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
        orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
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

fn ShaderDesc? compile_pulse(Allocator allocator) @local {
    String[2] depth_instanced = { "DEPTH_ONLY", "INSTANCED" };
    return {
        .fragment = compile_file(allocator, PULSE_FRAGMENT_FILE, ShaderStage.FRAGMENT)!,
        .vertex   = {
            .shaded           = compile_file(allocator, PULSE_VERTEX_FILE, ShaderStage.VERTEX)!,
            .depth            = compile_file(allocator, PULSE_VERTEX_FILE, ShaderStage.VERTEX, { "DEPTH_ONLY" })!,
            .instanced_shaded = compile_file(allocator, PULSE_VERTEX_FILE, ShaderStage.VERTEX, { "INSTANCED" })!,
            .instanced_depth  = compile_file(allocator, PULSE_VERTEX_FILE, ShaderStage.VERTEX, depth_instanced[..])!,
        },
        .param_block_size = PulseParams::size,
    };
}

fn Node*? add_trio(Scene* scene, GeometryId cube, MaterialId white) @local {
    Transform[3] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    transforms[0].position = { -TRIO_SPACING, 0, 0 };
    transforms[2].position = { TRIO_SPACING, 0, 0 };
    transforms[2].scale = { -1, 1, 1 };
    Vec4[3] colors = { { 1, 0.2f, 0.2f, 1 }, { 0.2f, 1, 0.2f, 1 }, { 0.2f, 0.4f, 1, 1 } };
    Node* node = scene.add_instanced_mesh(
        geometry:   cube,
        material:   white,
        capacity:   3,
        transforms: transforms[..],
        colors:     colors[..],
        name:       "trio",
    )!;
    node.local.position = { 0, TRIO_HEIGHT, 0 };
    return node;
}

fn Node*? add_props(Scene* scene, GeometryId prop, MaterialId white) @local {
    uint count = GRID_SIDE * GRID_SIDE;
    Node* node = scene.add_instanced_mesh(prop, white, count, name: "props")!;
    scene.resize_instances(node, count)!;
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    float half_extent = (GRID_SIDE - 1) * GRID_SPACING * 0.5f;
    for (uint row = 0; row < GRID_SIDE; row++) {
        for (uint column = 0; column < GRID_SIDE; column++) {
            uint index = row * GRID_SIDE + column;
            float u = (float)column / (GRID_SIDE - 1);
            float v = (float)row / (GRID_SIDE - 1);
            batch.transforms[index].position = { column * GRID_SPACING - half_extent, 0, row * GRID_SPACING - half_extent };
            batch.transforms[index].rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (u + v) * (float)math::PI);
            batch.colors[index] = { u, 0.4f, v, 1 };
        }
    }
    node.local.position = { 0, PROP_SIZE * 0.5f, 12 };
    return node;
}

fn Node*? add_pulses(Scene* scene, GeometryId sphere, MaterialId pulse_material) @local {
    Transform[PULSE_COUNT] transforms;
    Vec4[PULSE_COUNT] colors;
    for (uint index = 0; index < PULSE_COUNT; index++) {
        float angle = (float)index / PULSE_COUNT * 2 * (float)math::PI;
        transforms[index] = maths::TRANSFORM_IDENTITY;
        transforms[index].position = { math::cos(angle) * PULSE_RING_RADIUS, 0.8f, math::sin(angle) * PULSE_RING_RADIUS };
        colors[index] = { 0.5f + 0.5f * math::cos(angle), 1, 0.5f + 0.5f * math::sin(angle), 1 };
    }
    return scene.add_instanced_mesh(
        geometry:   sphere,
        material:   pulse_material,
        capacity:   PULSE_COUNT,
        transforms: transforms[..],
        colors:     colors[..],
        name:       "pulses",
    );
}

fn Batches? build_scene(AssetStore* assets, Scene* scene, ShaderId pulse_shader) @local {
    GeometryId ground;
    GeometryId cube;
    GeometryId prop;
    GeometryId sphere;
    @pool() {
        Geometry ground_geometry = geometry::plane(tmem, 60, 60);
        ground = assets.add_geometry(&ground_geometry, "instancing/ground")!;
        Geometry cube_geometry = geometry::box(tmem, 1, 1, 1);
        cube = assets.add_geometry(&cube_geometry, "instancing/cube")!;
        Geometry prop_geometry = geometry::box(tmem, PROP_SIZE, PROP_SIZE, PROP_SIZE);
        prop = assets.add_geometry(&prop_geometry, "instancing/prop")!;
        Geometry sphere_geometry = geometry::sphere(tmem, 0.5f);
        sphere = assets.add_geometry(&sphere_geometry, "instancing/sphere")!;
    };

    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.metallic = 0;
    surface.base_color = { 0.7f, 0.7f, 0.7f, 1 };
    MaterialId ground_material = assets.add_material(material::standard(surface), "instancing/ground_material")!;
    surface.base_color = { 1, 1, 1, 1 };
    surface.roughness = 0.4f;
    MaterialId white = assets.add_material(material::standard(surface), "instancing/white")!;
    PulseParams pulse = {
        .color  = { 1, 1, 1, 1 },
        .motion = { PULSE_AMPLITUDE, PULSE_ANGULAR_FREQUENCY, 0, 0 },
    };
    MaterialId pulse_material = assets.add_material(
        material::custom(pulse_shader, material::@as_bytes(pulse)),
        "instancing/pulse",
    )!;

    scene.add_mesh(ground, ground_material, name: "ground")!;
    Node* sun = scene.add_light(light::directional({ 1, 0.97f, 0.9f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });
    scene.ambient_intensity = 0.25f;
    return {
        .trio   = add_trio(scene, cube, white)!,
        .props  = add_props(scene, prop, white)!,
        .pulses = add_pulses(scene, sphere, pulse_material)!,
    };
}

fn void animate(Scene* scene, Batches* batches, double time) @local {
    batches.trio.local.rotation = quaternion::from_axis_angle{float}(
        { 0, 1, 0 },
        (float)time * TRIO_SPIN_RADIANS_PER_SECOND,
    );
    InstancedMesh* trio = scene.get(batches.trio, InstancedMesh);
    trio.transforms[1].position.y = BOB_HEIGHT * (float)math::sin(time * BOB_RADIANS_PER_SECOND);
}

fn void pick_under_cursor(
    AssetStore* assets,
    Scene* scene,
    Node* camera_node,
    Vec2 pixel,
    Vec2 viewport,
    Controls* controls,
) @local {
    Camera* camera = scene.get(camera_node, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, viewport);
    Ray ray = camera::screen_to_ray(&matrices, pixel, viewport);
    PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
    options.precision = PickPrecision.TRIANGLES;
    @pool() {
        PickHit[] hits = spatial::pick(tmem, assets, scene, ray, options);
        controls.picked = hits.len > 0;
        if (!hits.len) return;
        controls.pick_name = hits[0].node.name;
        controls.pick_instance = hits[0].instance_index;
        if (hits[0].instanced) {
            io::printfn("picked %s instance %d", controls.pick_name, controls.pick_instance);
        } else {
            io::printfn("picked %s", controls.pick_name);
        }
    };
}

fn bool draw_controls(Controls* controls) @local {
    bool changed;
    imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Instancing", null, {})) {
        imgui::text("Right drag orbits, wheel zooms, left click picks");
        imgui::checkbox("Animate", &controls.animate);
        changed |= imgui::checkbox("Motion blur", &controls.motion_blur);
        changed |= imgui::checkbox("Deferred shading", &controls.deferred);
        if (controls.picked) {
            imgui::text("Picked: %.*s instance %u", (int)controls.pick_name.len, controls.pick_name.ptr, controls.pick_instance);
        } else {
            imgui::text("Picked: nothing");
        }
    }
    imgui::end();
    return changed;
}

fn ViewDesc view_desc_of(Controls* controls) @local {
    ViewDesc desc = render::default_view_desc();
    desc.post.motion_blur = controls.motion_blur;
    desc.shading = controls.deferred ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
    return desc;
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
    ShaderId pulse_shader,
) @local {
    Batches batches = build_scene(assets, scene, pulse_shader)!;
    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!;
    Orbit orbit = { .distance = 14, .pitch = 0.45f, .target = { 0, 1, 4 } };
    Input initial_input;
    apply_orbit(&orbit, &initial_input, camera_node);
    scene.update_world();

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    Controls controls = { .animate = true };
    render::configure_view(renderer, renderer.default_view, view_desc_of(&controls))!;
    renderer.prepare_scene(scene)!;

    while (window.poll()) {
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;

        bool changed = draw_controls(&controls);
        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        if (controls.animate) animate(scene, &batches, window.clock.total);
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();
        if (input.button_pressed(platform::MouseButton.LEFT) && !input.mouse_captured_by_gui) {
            pick_under_cursor(
                assets:      assets,
                scene:       scene,
                camera_node: camera_node,
                pixel:       input.mouse_position,
                viewport:    { renderer.output_width, renderer.output_height },
                controls:    &controls,
            );
        }
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        if (changed) render::configure_view(renderer, renderer.default_view, view_desc_of(&controls))!;
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main() {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    ShaderId pulse_shader;
    @pool() {
        ShaderDesc? pulse_desc = compile_pulse(tmem);
        if (catch excuse = pulse_desc) {
            io::eprintfn("pulse: compile failed (%s); run from examples/build so ../shaders resolves", excuse);
            return 1;
        }
        pulse_shader = assets.add_shader(&pulse_desc, "pulse")!!;
    };

    platform::Window window = platform::create_window(platform::default_window_desc("c3d instancing", 1280, 720))!!;
    defer platform::destroy_window(&window);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_instancing" },
    )!!;
    defer render::destroy_renderer(&renderer);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    if (catch excuse = run(
        window:       &window,
        renderer:     &renderer,
        assets:       &assets,
        scene:        &scene,
        pulse_shader: pulse_shader,
    )) {
        io::eprintfn("instancing example failed: %s", excuse);
        return 1;
    }
    return 0;
}
