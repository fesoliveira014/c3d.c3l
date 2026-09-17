module compute_textures_example;

import std::io;
import std::io::file;
import std::math;
import std::time;
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
import imgui;

const String NOISE_FILE @local = "../shaders/custom/noise.comp.glsl";
const String FOG_FILE @local = "../shaders/custom/fog.comp.glsl";
const double POLL_INTERVAL_SECONDS @local = 0.5; // one stat per file per half second; keeps the loop free of file traffic
const uint NOISE_SIZE @local = 256;
const float NOISE_CELLS @local = 6;
const uint GROUP_SIZE @local = 8; // mirrored as local_size_x and local_size_y in both compute files
const float FOG_DENSITY @local = 0.05f;
const Vec4 FOG_COLOR @local = { 0.55f, 0.62f, 0.75f, 1 };
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 2;
const float ORBIT_DISTANCE_MAX @local = 60;
const float CHECKER_REPEATS @local = 12;
const Vec2 STATS_PANEL_POSITION @local = { 16, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 440 };
const uint BOX_COUNT @local = 5;
const float BOX_SPACING @local = 3;

struct NoiseRoot @local {
    float time;
    uint  size;
    float cells;
    float _pad0;
}

struct FogRoot @local {
    Vec4  color;
    float proj_22;
    float proj_23;
    uint  orthographic;
    float density;
    uint  width;
    uint  height;
    uint  _pad0;
    uint  _pad1;
}

struct ShaderFile @local {
    String path;
    Time   seen;
}

struct Orbit @local {
    Vec3 target;
    float distance;
    float yaw;
    float pitch;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (input.button_down(platform::MouseButton.LEFT) && !input.mouse_captured_by_gui) {
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

fn char[]? compile_compute_file(Allocator allocator, String path) @local {
    String source = (String)file::load(tmem, path)!;
    String log;
    char[]? spirv = compile::compile_glsl(
        allocator:  allocator,
        source:     source,
        stage:      ShaderStage.COMPUTE,
        debug_name: path,
        log:        &log,
    );
    if (log.len) io::printfn("%s", log);
    return spirv;
}

fn Time modified_or_zero(String path) @local {
    return file::last_modified(path) ?? (Time)0;
}

fn void remember_time(ShaderFile* shader_file) @local {
    shader_file.seen = modified_or_zero(shader_file.path);
}

fn bool file_changed(ShaderFile* shader_file) @local {
    return modified_or_zero(shader_file.path) != shader_file.seen;
}

fn void reload_compute_shader(
    AssetStore* assets,
    Renderer* renderer,
    ShaderFile* shader_file,
    ComputeShaderId shader,
) @local {
    remember_time(shader_file);
    @pool() {
        char[]? spirv = compile_compute_file(tmem, shader_file.path);
        if (catch excuse = spirv) {
            io::printfn("%s: compile failed (%s); keeping the previous shader", shader_file.path, excuse);
            return;
        }
        ComputeShaderDesc desc = { .compute = spirv };
        assets.replace_compute_shader(shader, &desc)!!;
    };
    if (catch excuse = renderer.upload(shader)) {
        io::printfn("%s: replacement rejected (%s); keeping the previous pipeline", shader_file.path, excuse);
        return;
    }
    io::printfn("%s: reloaded, revision %d", shader_file.path, assets.compute_shader(shader).header.revision);
}

fn uint groups_for(uint pixels) @local {
    return (pixels + GROUP_SIZE - 1) / GROUP_SIZE;
}

fn void? draw_frame(
    Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    FrameInfo info,
    ComputeShaderId noise_shader,
    ComputeShaderId fog_shader,
    TextureId noise_texture,
    float noise_time,
    bool fog,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    NoiseRoot noise = { .time = noise_time, .size = NOISE_SIZE, .cells = NOISE_CELLS };
    DispatchTexture[1] noise_textures = { render::write_texture(noise_texture) };
    renderer.dispatch({
        .shader   = noise_shader,
        .root     = material::@as_bytes(noise),
        .groups   = { groups_for(NOISE_SIZE), groups_for(NOISE_SIZE), 1 },
        .textures = noise_textures[..],
    })!;

    if (renderer.has_output) {
        ViewId view = renderer.default_view;
        renderer.render_view(scene, camera_node, view)!;

        if (fog) {
            uint[<2>] extent = renderer.view_extent(view)!;
            Camera* camera = scene.get(camera_node, Camera);
            CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, { (float)extent.x, (float)extent.y });
            FogRoot fog_root = {
                .color        = FOG_COLOR,
                .proj_22      = matrices.proj.m22,
                .proj_23      = matrices.proj.m23,
                .orthographic = camera.projection == Projection.ORTHOGRAPHIC ? 1 : 0,
                .density      = FOG_DENSITY,
                .width        = extent.x,
                .height       = extent.y,
            };
            DispatchTexture[2] fog_textures = {
                render::read_view_depth(view),
                render::write_view_color(view, DispatchAccess.READ_WRITE),
            };
            renderer.dispatch({
                .shader   = fog_shader,
                .root     = material::@as_bytes(fog_root),
                .groups   = { groups_for(extent.x), groups_for(extent.y), 1 },
                .textures = fog_textures[..],
            })!;
        }
        renderer.finish_view(view)!;

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
            gpu_timings = true;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    ShaderFile noise_file = { .path = NOISE_FILE };
    ShaderFile fog_file = { .path = FOG_FILE };
    ComputeShaderId noise_shader;
    ComputeShaderId fog_shader;
    @pool() {
        char[]? noise_spirv = compile_compute_file(tmem, NOISE_FILE);
        char[]? fog_spirv = compile_compute_file(tmem, FOG_FILE);
        if (catch excuse = noise_spirv) {
            io::printfn("noise: compile failed (%s); run from examples/build so ../shaders resolves", excuse);
            return 1;
        }
        if (catch excuse = fog_spirv) {
            io::printfn("fog: compile failed (%s); run from examples/build so ../shaders resolves", excuse);
            return 1;
        }
        ComputeShaderDesc noise_desc = { .compute = noise_spirv };
        ComputeShaderDesc fog_desc = { .compute = fog_spirv };
        noise_shader = assets.add_compute_shader(&noise_desc, "noise")!!;
        fog_shader = assets.add_compute_shader(&fog_desc, "fog")!!;
    };
    remember_time(&noise_file);
    remember_time(&fog_file);

    TextureId noise_texture = assets.add_texture_empty({
        .width      = NOISE_SIZE,
        .height     = NOISE_SIZE,
        .format     = PixelFormat.RGBA8_UNORM,
        .debug_name = "noise",
    }, "noise_texture")!!;

    GeometryId floor;
    GeometryId box;
    @pool() {
        Geometry floor_geometry = geometry::plane(tmem, 40, 40);
        foreach (&uv : floor_geometry.uv0) *uv *= CHECKER_REPEATS;
        floor = assets.add_geometry(&floor_geometry)!!;
        Geometry box_geometry = geometry::box(
            allocator: tmem,
            width: 1.6f,
            height: 1.6f,
            depth: 1.6f,
        );
        box = assets.add_geometry(&box_geometry)!!;
    };
    MaterialId floor_material = assets.add_material(material::basic({
        .color = { 0.9f, 0.9f, 0.9f, 1 },
        .map = material::texture_slot(asset::TEXTURE_CHECKER),
    }))!!;
    MaterialId noise_material = assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map = material::texture_slot(noise_texture),
    }))!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* floor_node = scene.add_mesh(floor, floor_material, name: "floor")!!;
    floor_node.local.position = { 0, -1, 0 };
    for (uint index = 0; index < BOX_COUNT; index++) {
        Node* box_node = scene.add_mesh(box, noise_material, name: "box")!!;
        float offset = ((float)index - (float)(BOX_COUNT - 1) * 0.5f) * BOX_SPACING;
        box_node.local.position = { offset, 0, -offset * 2 };
        box_node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)index * 0.4f);
    }
    Node* sun = scene.add_light(light::directional({ 1, 0.97f, 0.9f }, 3), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });
    scene.ambient_intensity = 0.25f;
    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!!;
    Orbit orbit = { .target = { 0, 0.5f, 0 }, .distance = 16, .pitch = 0.35f, .yaw = 0.6f };
    Input initial_input;
    apply_orbit(&orbit, &initial_input, camera_node);
    scene.update_world();

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d compute textures", 1280, 720))!!;
    defer platform::destroy_window(&window);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_compute_textures" },
    )!!;
    defer render::destroy_renderer(&renderer);
    renderer.prepare_scene(&scene)!!;

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    io::printn("Edit examples/shaders/custom/noise.comp.glsl or fog.comp.glsl and save: the stage reloads; R forces a reload");
    io::printn("F toggles the depth fog, N freezes the noise; drag to orbit, wheel to zoom; Escape release quits");

    double next_poll = POLL_INTERVAL_SECONDS;
    bool fog = true;
    bool frozen;
    float noise_time;
    while (window.poll()) {
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;

        bool forced = input.key_pressed(platform::Scancode.R) && !input.keyboard_captured_by_gui;
        if (window.clock.total >= next_poll || forced) {
            next_poll = window.clock.total + POLL_INTERVAL_SECONDS;
            if (forced || file_changed(&noise_file)) reload_compute_shader(&assets, &renderer, &noise_file, noise_shader);
            if (forced || file_changed(&fog_file)) reload_compute_shader(&assets, &renderer, &fog_file, fog_shader);
        }
        if (input.key_pressed(platform::Scancode.F) && !input.keyboard_captured_by_gui) fog = !fog;
        if (input.key_pressed(platform::Scancode.N) && !input.keyboard_captured_by_gui) frozen = !frozen;
        if (!frozen) noise_time += window.clock.delta;

        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(&renderer)!!;
        gui_renderer.finish_frame();

        platform::sync_window(&window, &renderer);
        draw_frame(
            renderer:      &renderer,
            scene:         &scene,
            camera_node:   camera_node,
            gui_renderer:  &gui_renderer,
            info:          { .time = window.clock.total, .delta = window.clock.delta },
            noise_shader:  noise_shader,
            fog_shader:    fog_shader,
            noise_texture: noise_texture,
            noise_time:    noise_time,
            fog:           fog,
        )!!;
    }

    return 0;
}
