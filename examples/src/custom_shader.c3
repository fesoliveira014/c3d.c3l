module custom_shader_example;

import std::io;
import std::io::file;
import std::math;
import std::time;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;

const String TINT_FRAGMENT_FILE @local = "../shaders/custom/tint.frag.glsl";
const String PULSE_VERTEX_FILE @local = "../shaders/custom/pulse.vert.glsl";
const String PULSE_FRAGMENT_FILE @local = "../shaders/custom/pulse.frag.glsl";
const double POLL_INTERVAL_SECONDS @local = 0.5; // one stat per file per half second; keeps the loop free of file traffic
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 2;
const float ORBIT_DISTANCE_MAX @local = 40;
const float CHECKER_REPEATS @local = 12;
const float PULSE_AMPLITUDE @local = 0.4f;
const float PULSE_ANGULAR_FREQUENCY @local = 3;

struct TintParams @local {
    Vec4 color;
}

struct PulseParams @local {
    Vec4 color;
    Vec4 motion;
}

struct ShaderFiles @local {
    String fragment;
    String vertex;
    usz param_block_size;
    String name;
    Time fragment_seen;
    Time vertex_seen;
}

struct Orbit @local {
    Vec3 target;
    float distance;
    float yaw;
    float pitch;
}

macro @as_bytes(#value) @local {
    return ((char*)&#value)[:$Typeof(#value)::size];
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (input.button_down(platform::MouseButton.LEFT)) {
        orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
        orbit.pitch = math::clamp(
            orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
            -ORBIT_PITCH_LIMIT,
            ORBIT_PITCH_LIMIT,
        );
    }
    if (input.wheel != 0) {
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

fn ShaderDesc? compile_shader_files(Allocator allocator, ShaderFiles* files) @local {
    ShaderDesc desc = {
        .fragment = compile_file(allocator, files.fragment, ShaderStage.FRAGMENT)!,
        .param_block_size = files.param_block_size,
    };
    if (files.vertex.len) {
        desc.vertex.shaded = compile_file(allocator, files.vertex, ShaderStage.VERTEX)!;
        desc.vertex.depth = compile_file(allocator, files.vertex, ShaderStage.VERTEX, { "DEPTH_ONLY" })!;
    }
    return desc;
}

fn Time modified_or_zero(String path) @local {
    return file::last_modified(path) ?? (Time)0;
}

fn void remember_times(ShaderFiles* files) @local {
    files.fragment_seen = modified_or_zero(files.fragment);
    files.vertex_seen = files.vertex.len ? modified_or_zero(files.vertex) : (Time)0;
}

fn bool files_changed(ShaderFiles* files) @local {
    if (modified_or_zero(files.fragment) != files.fragment_seen) return true;
    return files.vertex.len && modified_or_zero(files.vertex) != files.vertex_seen;
}

fn void reload_shader(AssetStore* assets, Renderer* renderer, ShaderFiles* files, ShaderId shader) @local {
    remember_times(files);
    @pool() {
        ShaderDesc? desc = compile_shader_files(tmem, files);
        if (catch excuse = desc) {
            io::printfn("%s: compile failed (%s); keeping the previous shader", files.name, excuse);
            return;
        }
        assets.replace_shader(shader, &desc)!!;
    };
    if (catch excuse = renderer.upload(shader)) {
        io::printfn("%s: replacement rejected (%s); keeping the previous pipelines", files.name, excuse);
        return;
    }
    io::printfn("%s: reloaded, revision %d", files.name, assets.shader(shader).header.revision);
}

fn int main() {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    ShaderFiles tint_files = {
        .fragment = TINT_FRAGMENT_FILE,
        .param_block_size = TintParams::size,
        .name = "tint",
    };
    ShaderFiles pulse_files = {
        .fragment = PULSE_FRAGMENT_FILE,
        .vertex = PULSE_VERTEX_FILE,
        .param_block_size = PulseParams::size,
        .name = "pulse",
    };
    ShaderId tint_shader;
    ShaderId pulse_shader;
    @pool() {
        ShaderDesc? tint_desc = compile_shader_files(tmem, &tint_files);
        ShaderDesc? pulse_desc = compile_shader_files(tmem, &pulse_files);
        if (catch excuse = tint_desc) {
            io::printfn("tint: compile failed (%s); run from examples/build so ../shaders resolves", excuse);
            return 1;
        }
        if (catch excuse = pulse_desc) {
            io::printfn("pulse: compile failed (%s); run from examples/build so ../shaders resolves", excuse);
            return 1;
        }
        tint_shader = assets.add_shader(&tint_desc, "tint")!!;
        pulse_shader = assets.add_shader(&pulse_desc, "pulse")!!;
    };
    remember_times(&tint_files);
    remember_times(&pulse_files);

    GeometryId floor;
    GeometryId sphere;
    GeometryId box;
    @pool() {
        Geometry floor_geometry = geometry::plane(tmem, 16, 16);
        foreach (&uv : floor_geometry.uv0) *uv *= CHECKER_REPEATS;
        floor = assets.add_geometry(&floor_geometry)!!;
        Geometry sphere_geometry = geometry::sphere(tmem, 1);
        sphere = assets.add_geometry(&sphere_geometry)!!;
        Geometry box_geometry = geometry::box(
            allocator: tmem,
            width: 1.6f,
            height: 1.6f,
            depth: 1.6f,
        );
        box = assets.add_geometry(&box_geometry)!!;
    };

    TintParams tint = { .color = { 1, 0.55f, 0.2f, 1 } };
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] tint_slots = material::CUSTOM_SLOTS_DEFAULT;
    tint_slots[0] = material::texture_slot(asset::TEXTURE_CHECKER);
    PulseParams pulse = {
        .color = { 0.3f, 0.6f, 1, 1 },
        .motion = { PULSE_AMPLITUDE, PULSE_ANGULAR_FREQUENCY, 0, 0 },
    };
    MaterialId floor_material = assets.add_material(material::basic({
        .color = { 0.9f, 0.9f, 0.9f, 1 },
        .map = material::texture_slot(asset::TEXTURE_CHECKER),
    }))!!;
    MaterialId tint_material = assets.add_material(material::custom(tint_shader, @as_bytes(tint), tint_slots))!!;
    MaterialId pulse_material = assets.add_material(material::custom(pulse_shader, @as_bytes(pulse)))!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* floor_node = scene.add_mesh(floor, floor_material, name: "floor")!!;
    floor_node.local.position = { 0, -1, 0 };
    Node* sphere_node = scene.add_mesh(sphere, tint_material, name: "tint_sphere")!!;
    sphere_node.local.position = { -1.6f, 0, 0 };
    Node* box_node = scene.add_mesh(box, pulse_material, name: "pulse_box")!!;
    box_node.local.position = { 1.6f, 0.2f, 0 };
    box_node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::PI / 5);
    Node* sun = scene.add_light(light::directional({ 1, 0.97f, 0.9f }, 3), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });
    scene.ambient_intensity = 0.25f;
    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!!;
    Orbit orbit = { .distance = 8, .pitch = 0.35f };
    Input initial_input;
    apply_orbit(&orbit, &initial_input, camera_node);
    scene.update_world();

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d custom shader", 1280, 720))!!;
    defer platform::destroy_window(&window);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .validation = true, .application_name = "c3d_custom_shader" },
    )!!;
    defer render::destroy_renderer(&renderer);
    renderer.prepare_scene(&scene)!!;

    io::printn("Edit examples/shaders/custom/*.glsl and save: the scene reloads; R forces a reload");
    io::printn("P pauses the pulse; drag to orbit, wheel to zoom; Escape release quits");

    double next_poll = POLL_INTERVAL_SECONDS;
    bool paused;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE)) break;

        bool forced = input.key_pressed(platform::Scancode.R);
        if (window.clock.total >= next_poll || forced) {
            next_poll = window.clock.total + POLL_INTERVAL_SECONDS;
            if (forced || files_changed(&tint_files)) reload_shader(&assets, &renderer, &tint_files, tint_shader);
            if (forced || files_changed(&pulse_files)) reload_shader(&assets, &renderer, &pulse_files, pulse_shader);
        }
        if (input.key_pressed(platform::Scancode.P)) {
            paused = !paused;
            PulseParams* live = assets.@custom_params(pulse_material, PulseParams);
            live.motion.x = paused ? 0 : PULSE_AMPLITUDE;
            assets.mark_material_dirty(pulse_material);
        }

        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;
    }

    return 0;
}
