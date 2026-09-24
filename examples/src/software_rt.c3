module software_rt_example;

import std::io;
import std::io::file;
import std::io::path;
import std::math;
import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import imgui;

const String MODEL_FILE @local = "../assets/benchmark/sponza/glTF/Sponza.gltf";
const String TRACE_FILE @local = "../shaders/custom/trace_primary.comp.glsl";
const uint GROUP_SIZE @local = 8; // mirrored as local_size_x and local_size_y in trace_primary.comp.glsl
const float LIGHT_INTENSITY @local = 4;
const float AMBIENT_INTENSITY @local = 0.3f;
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN_SCALE @local = 0.05f;
const float ORBIT_DISTANCE_MAX_SCALE @local = 2;
const float ORBIT_START_SCALE @local = 0.4f;
const float NEAR_PLANE_SCALE @local = 0.002f;
const Vec2 STATS_PANEL_POSITION @local = { 16, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 380, 560 };
const double MILLISECONDS_PER_SECOND @local = 1000;
const double RAYS_PER_MEGARAY @local = 1e6;
const uint WINDOW_WIDTH @local = 1280;
const uint WINDOW_HEIGHT @local = 720;
const uint BENCHMARK_WIDTH @local = 1920;
const uint BENCHMARK_HEIGHT @local = 1080;
const uint BENCHMARK_WARMUP_FRAMES @local = 30; // lets clocks and caches settle before the timed frames

enum TraceMode @local { // mirrored as MODE_* in trace_primary.comp.glsl
    DISTANCE,
    NORMAL,
    INSTANCE,
}

struct TracePrimaryRoot @local {
    Mat4  inverse_view_projection;
    Vec4  camera_position;
    ulong scene;
    uint  mode;
    uint  width;
    uint  height;
    uint  split_x;
}

struct Orbit @local {
    Vec3  target;
    float distance;
    float minimum;
    float maximum;
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
        orbit.distance = math::clamp(zoomed, orbit.minimum, orbit.maximum);
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn Aabb template_bounds(AssetStore* assets, ModelTemplate* template) @local {
    Mat4[] node_matrices = alloc::new_array(tmem, Mat4, template.nodes.len);
    foreach (index, &node : template.nodes) {
        Mat4 local = node.local.to_mat4();
        node_matrices[index] = node.parent < 0 ? local : node_matrices[node.parent].mul(local);
    }
    Aabb bounds = { .min = { 0, 0, 0 }, .max = { 0, 0, 0 } };
    foreach (index, &mesh : template.meshes) {
        Aabb mesh_bounds = maths::aabb_transform(assets.geometry(mesh.geometry).data.bounds, node_matrices[mesh.node]);
        bounds = index == 0 ? mesh_bounds : maths::aabb_merge(bounds, mesh_bounds);
    }
    return bounds;
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

fn uint groups_for(uint pixels) @local {
    return (pixels + GROUP_SIZE - 1) / GROUP_SIZE;
}

fn void? draw_frame(
    Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    FrameInfo info,
    ComputeShaderId trace_shader,
    TraceMode mode,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        ViewId view = renderer.default_view;
        renderer.render_view(scene, camera_node, view)!;

        uint[<2>] extent = renderer.view_extent(view)!;
        Camera* camera = scene.get(camera_node, Camera);
        CameraMatrices matrices = camera::derive_matrices(
            camera:       *camera,
            camera_world: camera_node.world,
            viewport:     { (float)extent.x, (float)extent.y },
        );
        Vec3 eye = maths::transform_point(camera_node.world, { 0, 0, 0 });
        TracePrimaryRoot root = {
            .inverse_view_projection = matrices.inv_view_proj,
            .camera_position         = { eye.x, eye.y, eye.z, 1 },
            .scene                   = (ulong)renderer.prepare_scene_trace(scene)!,
            .mode                    = (uint)mode.ordinal,
            .width                   = extent.x,
            .height                  = extent.y,
            .split_x                 = extent.x / 2,
        };
        DispatchTexture[1] textures = { render::write_view_color(view, DispatchAccess.READ_WRITE) };
        renderer.dispatch({
            .shader   = trace_shader,
            .root     = material::@as_bytes(root),
            .groups   = { groups_for(extent.x), groups_for(extent.y), 1 },
            .textures = textures[..],
        })!;
        renderer.finish_view(view)!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    return renderer.end_frame();
}

fn ZString mode_name(TraceMode mode) @local {
    switch (mode) {
        case DISTANCE: return "distance";
        case NORMAL: return "normal";
        case INSTANCE: return "instance id";
    }
}

fn double traced_rays(Renderer* renderer) @local {
    uint[<2>] extent = renderer.view_extent(renderer.default_view) ?? (uint[<2>]){};
    return (double)(extent.x - extent.x / 2) * (double)extent.y;
}

fn float trace_pass_ms(Renderer* renderer) @local {
    return renderer.stats.gpu_pass_ms[Pass.CUSTOM_COMPUTE_POST.ordinal];
}

fn void trace_panel(Renderer* renderer, TraceMode mode) @local {
    if (imgui::begin("Software trace", null, {})) {
        imgui::text("Right half: %s (M cycles)", mode_name(mode));
        float trace_ms = trace_pass_ms(renderer);
        if (trace_ms > 0) {
            double rays_per_second = traced_rays(renderer) / ((double)trace_ms / MILLISECONDS_PER_SECOND);
            imgui::text("Rays per second: %.1f M", rays_per_second / RAYS_PER_MEGARAY);
        } else {
            imgui::text("Rays per second: run with --gpu-timings");
        }
    }
    imgui::end();
}

fn int main(String[] args) {
    bool gpu_timings;
    uint benchmark_frames;
    for (usz index = 1; index < args.len; index++) {
        if (args[index] == "--gpu-timings") {
            $if $feat(C3D_PROFILE_GPU):
                gpu_timings = true;
            $else
                io::eprintfn("--gpu-timings needs GPU profiling: c3c build <target> --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                return 1;
            $endif
        } else if (args[index] == "--benchmark" && index + 1 < args.len) {
            index++;
            benchmark_frames = args[index].to_uint() ?? 0;
        } else {
            io::printfn("Unknown argument: %s", args[index]);
            return 1;
        }
    }
    if (benchmark_frames && !gpu_timings) {
        io::eprintn("--benchmark FRAMES needs --gpu-timings");
        return 1;
    }

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    String model_path = example_path(MODEL_FILE);
    ModelId model;
    if (catch excuse = gltf::load_model(&assets, model_path)) {
        io::printfn("Loading %s failed (%s): run python3 scripts/fetch_benchmark_assets.py", model_path, excuse);
        return 1;
    } else {
        model = assets.find_model(model_path)!!;
    }

    ComputeShaderId trace_shader;
    @pool() {
        char[]? spirv = compile_compute_file(tmem, TRACE_FILE);
        if (catch excuse = spirv) {
            io::printfn("trace: compile failed (%s); run from examples/build so ../shaders resolves", excuse);
            return 1;
        }
        ComputeShaderDesc desc = { .compute = spirv };
        trace_shader = assets.add_compute_shader(&desc, "trace_primary")!!;
    };

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    model::instantiate(&assets, &scene, model, name: "sponza")!!;
    Aabb bounds;
    @pool() {
        bounds = template_bounds(&assets, &assets.model(model).data);
    };
    float radius = math::max((bounds.max - bounds.min).length() * 0.5f, 0.001f);
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, LIGHT_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.3f, -1, -0.2f }.normalize(), { 0, 1, 0 });
    scene.ambient_intensity = AMBIENT_INTENSITY;
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, radius * NEAR_PLANE_SCALE), name: "camera")!!;
    Orbit orbit = {
        .target   = (bounds.min + bounds.max) * 0.5f,
        .distance = radius * ORBIT_START_SCALE,
        .minimum  = radius * ORBIT_DISTANCE_MIN_SCALE,
        .maximum  = radius * ORBIT_DISTANCE_MAX_SCALE,
        .yaw      = 1.5708f,
        .pitch    = 0.15f,
    };

    platform::Window window = platform::create_window(platform::default_window_desc(
        "c3d software rt",
        benchmark_frames ? BENCHMARK_WIDTH : WINDOW_WIDTH,
        benchmark_frames ? BENCHMARK_HEIGHT : WINDOW_HEIGHT,
    ))!!;
    defer platform::destroy_window(&window);
    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_software_rt" },
    )!!;
    defer render::destroy_renderer(&renderer);
    renderer.prepare_scene(&scene)!!;
    renderer.prepare_scene_trace(&scene)!!;
    io::printfn(
        "Bottom and top levels built in %.1f ms: %d instances, %d top-level nodes, %d skipped",
        renderer.stats.trace_build_ms,
        renderer.stats.trace_instances,
        renderer.stats.trace_nodes,
        renderer.stats.trace_skipped,
    );

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    io::printn("The right half is traced through the software BVH; M cycles distance, normal and instance id");
    io::printn("Drag to orbit, wheel to zoom; Escape release quits");
    TraceMode mode = TraceMode.DISTANCE;
    uint frame;
    uint timed_frames;
    double timed_ms;
    while (window.poll()) {
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        if (input.key_pressed(platform::Scancode.M) && !input.keyboard_captured_by_gui) {
            mode = TraceMode::from_ordinal(((usz)mode.ordinal + 1) % TraceMode::len);
        }
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(&renderer)!!;
        trace_panel(&renderer, mode);
        gui_renderer.finish_frame();

        platform::sync_window(&window, &renderer);
        draw_frame(
            renderer:     &renderer,
            scene:        &scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
            trace_shader: trace_shader,
            mode:         mode,
        )!!;

        frame++;
        if (!benchmark_frames || frame <= BENCHMARK_WARMUP_FRAMES || trace_pass_ms(&renderer) <= 0) continue;
        timed_ms += trace_pass_ms(&renderer);
        timed_frames++;
        if (timed_frames == benchmark_frames) {
            double mean_ms = timed_ms / timed_frames;
            double rays_per_second = traced_rays(&renderer) / (mean_ms / MILLISECONDS_PER_SECOND);
            uint[<2>] extent = renderer.view_extent(renderer.default_view)!!;
            io::printfn(
                "Trace pass: %.4f ms mean over %d frames at %dx%d, %.1f M rays per second",
                mean_ms,
                timed_frames,
                extent.x,
                extent.y,
                rays_per_second / RAYS_PER_MEGARAY,
            );
            break;
        }
    }

    return 0;
}
