module custom_compute_example;

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

const String COMPUTE_FILE @local = "../shaders/custom/particles.comp.glsl";
const String VERTEX_FILE @local = "../shaders/custom/particles.vert.glsl";
const String FRAGMENT_FILE @local = "../shaders/custom/particles.frag.glsl";
const double POLL_INTERVAL_SECONDS @local = 0.5; // one stat per file per half second; keeps the loop free of file traffic
const uint PARTICLE_COUNT @local = 4096;
const uint WORKGROUP_SIZE @local = 64; // mirrored as local_size_x in particles.comp.glsl
const uint CORNERS_PER_PARTICLE @local = 4;
const uint INDICES_PER_PARTICLE @local = 6;
const float PARTICLE_SIZE @local = 0.08f;
const float PARTICLE_LIFETIME @local = 4;
const float EMITTER_RADIUS @local = 0.5f;
const float EMITTER_ORBIT_RADIUS @local = 1.5f;
const float EMITTER_ORBIT_RATE @local = 0.6f;
const float FOUNTAIN_HEIGHT @local = 6;
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 2;
const float ORBIT_DISTANCE_MAX @local = 40;
const float CHECKER_REPEATS @local = 12;
const Vec2 STATS_PANEL_POSITION @local = { 16, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 420 };

struct ParticleRoot @local {
    ulong particles;
    ulong emitter;
    uint  count;
    float delta;
    float time;
    uint  reset;
}

struct EmitterBlock @local {
    Vec4 origin_radius;
    Vec4 gravity_lifetime;
}

struct ParticleParams @local {
    ulong particles;
    uint  count;
    float size;
    float lifetime;
    uint  _pad0;
    uint  _pad1;
    uint  _pad2;
    Vec4  color_young;
    Vec4  color_old;
}

struct Particle @local {
    Vec4 position_life;
    Vec4 velocity_seed;
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

fn ShaderDesc? compile_material_files(Allocator allocator, ShaderFile* vertex, ShaderFile* fragment) @local {
    return {
        .fragment = compile_file(allocator, fragment.path, ShaderStage.FRAGMENT)!,
        .vertex = {
            .shaded = compile_file(allocator, vertex.path, ShaderStage.VERTEX)!,
            .depth = compile_file(
                allocator: allocator,
                path:      vertex.path,
                stage:     ShaderStage.VERTEX,
                defines:   { "DEPTH_ONLY" },
            )!,
        },
        .param_block_size = ParticleParams::size,
    };
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

fn void reload_material_shader(
    AssetStore* assets,
    Renderer* renderer,
    ShaderFile* vertex,
    ShaderFile* fragment,
    ShaderId shader,
) @local {
    remember_time(vertex);
    remember_time(fragment);
    @pool() {
        ShaderDesc? desc = compile_material_files(tmem, vertex, fragment);
        if (catch excuse = desc) {
            io::printfn("particles material: compile failed (%s); keeping the previous shader", excuse);
            return;
        }
        assets.replace_shader(shader, &desc)!!;
    };
    if (catch excuse = renderer.upload(shader)) {
        io::printfn("particles material: replacement rejected (%s); keeping the previous pipelines", excuse);
        return;
    }
    io::printfn("particles material: reloaded, revision %d", assets.shader(shader).header.revision);
}

fn void reload_compute_shader(
    AssetStore* assets,
    Renderer* renderer,
    ShaderFile* compute,
    ComputeShaderId shader,
) @local {
    remember_time(compute);
    @pool() {
        char[]? spirv = compile_file(tmem, compute.path, ShaderStage.COMPUTE);
        if (catch excuse = spirv) {
            io::printfn("particles compute: compile failed (%s); keeping the previous shader", excuse);
            return;
        }
        ComputeShaderDesc desc = { .compute = spirv };
        assets.replace_compute_shader(shader, &desc)!!;
    };
    if (catch excuse = renderer.upload(shader)) {
        io::printfn("particles compute: replacement rejected (%s); keeping the previous pipeline", excuse);
        return;
    }
    io::printfn("particles compute: reloaded, revision %d", assets.compute_shader(shader).header.revision);
}

fn Geometry particle_quads(Allocator allocator) @local {
    const Vec2[CORNERS_PER_PARTICLE] CORNERS = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } };
    const uint[INDICES_PER_PARTICLE] QUAD_INDICES = { 0, 1, 2, 0, 2, 3 };
    Geometry quads = {
        .positions = alloc::new_array(allocator, Vec3, PARTICLE_COUNT * CORNERS_PER_PARTICLE),
        .uv0       = alloc::new_array(allocator, Vec2, PARTICLE_COUNT * CORNERS_PER_PARTICLE),
        .indices   = alloc::new_array(allocator, uint, PARTICLE_COUNT * INDICES_PER_PARTICLE),
        .bounds    = {
            .min = { -EMITTER_ORBIT_RADIUS - EMITTER_RADIUS - 2, -1, -EMITTER_ORBIT_RADIUS - EMITTER_RADIUS - 2 },
            .max = { EMITTER_ORBIT_RADIUS + EMITTER_RADIUS + 2, FOUNTAIN_HEIGHT, EMITTER_ORBIT_RADIUS + EMITTER_RADIUS + 2 },
        },
    };
    for (uint particle = 0; particle < PARTICLE_COUNT; particle++) {
        foreach (uint corner, uv : CORNERS) quads.uv0[particle * CORNERS_PER_PARTICLE + corner] = uv;
        foreach (uint slot, index : QUAD_INDICES) {
            quads.indices[particle * INDICES_PER_PARTICLE + slot] = particle * CORNERS_PER_PARTICLE + index;
        }
    }
    return quads;
}

fn void? draw_frame(
    Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    FrameInfo info,
    ComputeShaderId compute_shader,
    BufferId particles,
    BufferId emitter,
    bool reset,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    float orbit_angle = (float)info.time * EMITTER_ORBIT_RATE;
    EmitterBlock emitter_block = {
        .origin_radius    = {
            math::cos(orbit_angle) * EMITTER_ORBIT_RADIUS,
            0,
            math::sin(orbit_angle) * EMITTER_ORBIT_RADIUS,
            EMITTER_RADIUS,
        },
        .gravity_lifetime = { 0, -1.5f, 0, PARTICLE_LIFETIME },
    };
    renderer.write_buffer(emitter, material::@as_bytes(emitter_block))!;

    ParticleRoot root = {
        .particles = (ulong)renderer.buffer_address(particles),
        .emitter   = (ulong)renderer.buffer_address(emitter),
        .count     = PARTICLE_COUNT,
        .delta     = info.delta,
        .time      = (float)info.time,
        .reset     = reset ? 1 : 0,
    };
    BufferId[1] writes = { particles };
    renderer.dispatch({
        .shader = compute_shader,
        .root   = material::@as_bytes(root),
        .groups = { (PARTICLE_COUNT + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE, 1, 1 },
        .writes = writes[..],
    })!;

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
            gpu_timings = true;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    ShaderFile compute_file = { .path = COMPUTE_FILE };
    ShaderFile vertex_file = { .path = VERTEX_FILE };
    ShaderFile fragment_file = { .path = FRAGMENT_FILE };
    ComputeShaderId compute_shader;
    ShaderId material_shader;
    @pool() {
        char[]? compute_spirv = compile_file(tmem, COMPUTE_FILE, ShaderStage.COMPUTE);
        ShaderDesc? material_desc = compile_material_files(tmem, &vertex_file, &fragment_file);
        if (catch excuse = compute_spirv) {
            io::printfn("particles compute: compile failed (%s); run from examples/build so ../shaders resolves", excuse);
            return 1;
        }
        if (catch excuse = material_desc) {
            io::printfn("particles material: compile failed (%s); run from examples/build so ../shaders resolves", excuse);
            return 1;
        }
        ComputeShaderDesc compute_desc = { .compute = compute_spirv };
        compute_shader = assets.add_compute_shader(&compute_desc, "particles")!!;
        material_shader = assets.add_shader(&material_desc, "particles_material")!!;
    };
    remember_time(&compute_file);
    remember_time(&vertex_file);
    remember_time(&fragment_file);

    GeometryId floor;
    GeometryId quads;
    @pool() {
        Geometry floor_geometry = geometry::plane(tmem, 16, 16);
        foreach (&uv : floor_geometry.uv0) *uv *= CHECKER_REPEATS;
        floor = assets.add_geometry(&floor_geometry)!!;
        Geometry quad_geometry = particle_quads(tmem);
        quads = assets.add_geometry(&quad_geometry)!!;
    };

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d custom compute", 1280, 720))!!;
    defer platform::destroy_window(&window);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_custom_compute" },
    )!!;
    defer render::destroy_renderer(&renderer);

    BufferId particles = renderer.create_buffer({
        .size       = PARTICLE_COUNT * Particle::size,
        .usage      = BufferUsage.GPU_PRIVATE,
        .debug_name = "particles",
    })!!;
    defer (void)renderer.destroy_buffer(particles);
    BufferId emitter = renderer.create_buffer({
        .size       = EmitterBlock::size,
        .usage      = BufferUsage.UPLOAD,
        .debug_name = "particle_emitter",
    })!!;
    defer (void)renderer.destroy_buffer(emitter);

    ParticleParams params = {
        .particles   = (ulong)renderer.buffer_address(particles),
        .count       = PARTICLE_COUNT,
        .size        = PARTICLE_SIZE,
        .lifetime    = PARTICLE_LIFETIME,
        .color_young = { 1, 0.85f, 0.3f, 1 },
        .color_old   = { 0.6f, 0.1f, 0.4f, 1 },
    };
    MaterialId floor_material = assets.add_material(material::basic({
        .color = { 0.9f, 0.9f, 0.9f, 1 },
        .map = material::texture_slot(asset::TEXTURE_CHECKER),
    }))!!;
    MaterialId particle_material = assets.add_material(material::custom(material_shader, material::@as_bytes(params)))!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* floor_node = scene.add_mesh(floor, floor_material, name: "floor")!!;
    floor_node.local.position = { 0, -1, 0 };
    Node* particle_node = scene.add_mesh(quads, particle_material, name: "particles")!!;
    scene.get(particle_node, Mesh).cast_shadow = false;
    Node* sun = scene.add_light(light::directional({ 1, 0.97f, 0.9f }, 3), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });
    scene.ambient_intensity = 0.25f;
    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!!;
    Orbit orbit = { .target = { 0, 1.5f, 0 }, .distance = 10, .pitch = 0.3f };
    Input initial_input;
    apply_orbit(&orbit, &initial_input, camera_node);
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    io::printn("Edit examples/shaders/custom/particles.*.glsl and save: the stages reload; R forces a reload");
    io::printn("Space reseeds the particles; drag to orbit, wheel to zoom; Escape release quits");

    double next_poll = POLL_INTERVAL_SECONDS;
    bool reset = true;
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
            if (forced || file_changed(&compute_file)) {
                reload_compute_shader(&assets, &renderer, &compute_file, compute_shader);
            }
            if (forced || file_changed(&vertex_file) || file_changed(&fragment_file)) {
                reload_material_shader(
                    assets:   &assets,
                    renderer: &renderer,
                    vertex:   &vertex_file,
                    fragment: &fragment_file,
                    shader:   material_shader,
                );
            }
        }
        if (input.key_pressed(platform::Scancode.SPACE) && !input.keyboard_captured_by_gui) reset = true;

        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(&renderer)!!;
        gui_renderer.finish_frame();

        platform::sync_window(&window, &renderer);
        draw_frame(
            renderer:       &renderer,
            scene:          &scene,
            camera_node:    camera_node,
            gui_renderer:   &gui_renderer,
            info:           { .time = window.clock.total, .delta = window.clock.delta },
            compute_shader: compute_shader,
            particles:      particles,
            emitter:        emitter,
            reset:          reset,
        )!!;
        reset = false;
    }

    return 0;
}
