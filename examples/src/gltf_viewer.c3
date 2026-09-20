module gltf_viewer_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;
import bench_loop;
import gpu;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_SCALE @local = 2.5f; // starting distance in model radii; frames both instances
const float ORBIT_DISTANCE_MIN_SCALE @local = 0.5f;
const float ORBIT_DISTANCE_MAX_SCALE @local = 20;
const float INSTANCE_GAP_SCALE @local = 0.25f; // gap between instances in model widths
const float SPIN_RADIANS_PER_SECOND @local = 0.4f;
const float LIGHT_INTENSITY @local = 2.5f;
const float ENVIRONMENT_INTENSITY @local = 0.6f;
const float BACKGROUND_INTENSITY @local = 0.3f;
const float STATS_PERIOD_SECONDS @local = 2;
const uint MODEL_CAPACITY @local = 4;
const String DEFAULT_MODEL @local = "../assets/gltf/BoxTextured.glb";
const String ENVIRONMENT_FILE @local = "../assets/ibl/studio_small_09_1k.hdr";
const String BENCHMARK_MODEL @local = "../assets/benchmark/sponza/glTF/Sponza.gltf";
const uint BENCHMARK_LIGHTS_MAX @local = 4096; // 320 KiB of packed lights per view; caps this workload
const uint BENCHMARK_CAPACITY_MAX @local = 256;
const float BENCHMARK_LIGHT_HEIGHT @local = 0.35f; // fraction of the vertical extent; lights float in the atrium, not the floor
const float BENCHMARK_LIGHT_INTENSITY @local = 4;
const float BENCHMARK_RANGE_MAX @local = 2; // fraction of the largest extent; above this every light covers the whole model
const float BENCHMARK_CAMERA_BACK @local = 0.35f; // fraction of the largest extent behind the center
const float BENCHMARK_CAMERA_HEIGHT @local = 0.3f; // fraction of the vertical extent above the floor
const float BENCHMARK_TARGET_HEIGHT @local = 0.1f;
const float BENCHMARK_FOV_DEGREES @local = 60;
const float BENCHMARK_NEAR_SCALE @local = 0.005f; // near plane as a fraction of the largest extent

struct BenchmarkOptions @local {
    BenchmarkFlags flags;
    LightSelection selection;
    uint lights;
    uint capacity;
    float range;
    bool shadows;
    String model_path;
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

fn usz skeleton_count(ModelTemplate* template) @local {
    usz count;
    foreach (usz index, &skin : template.skins) {
        bool seen;
        for (usz earlier = 0; earlier < index && !seen; earlier++) {
            seen = template.skins[earlier].skeleton.index == skin.skeleton.index;
        }
        if (!seen) count++;
    }
    return count;
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn BenchmarkOptions? parse_options(String[] args) @local {
    BenchmarkOptions options = {
        .flags = bench_loop::default_flags(),
        .selection = LightSelection.CLUSTERED,
        .lights = 64, .capacity = 64, .range = 0.08f, .shadows = true,
    };
    for (usz index = 1; index < args.len; index++) {
        if (bench_loop::parse_flag(args, &index, &options.flags, "gltf_viewer")!) continue;
        String argument = args[index];
        if (!argument.starts_with("--")) {
            if (options.model_path.len) return c3d::INVALID_ARGUMENT~;
            options.model_path = argument;
            continue;
        }
        String value = bench_loop::option_value(args, &index)!;
        switch (argument) {
            case "--mode":
                if (value == "flat") {
                    options.selection = LightSelection.FLAT;
                } else if (value == "clustered") {
                    options.selection = LightSelection.CLUSTERED;
                } else {
                    return c3d::INVALID_ARGUMENT~;
                }
            case "--shadows":
                if (value == "on") {
                    options.shadows = true;
                } else if (value == "off") {
                    options.shadows = false;
                } else {
                    return c3d::INVALID_ARGUMENT~;
                }
            case "--lights": options.lights = value.to_uint()!;
            case "--capacity": options.capacity = value.to_uint()!;
            case "--range": options.range = value.to_float()!;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    bench_loop::validate_flags(options.flags)!;
    if (options.lights > BENCHMARK_LIGHTS_MAX || !options.capacity || options.capacity > BENCHMARK_CAPACITY_MAX
        || !math::is_finite(options.range) || options.range <= 0 || options.range > BENCHMARK_RANGE_MAX) {
        return c3d::INVALID_ARGUMENT~;
    }
    return options;
}

fn Vec3 light_color(uint index) @local {
    switch (index % 3) {
        case 0: return { 1, 0.85f, 0.7f };
        case 1: return { 0.7f, 0.85f, 1 };
        default: return { 0.8f, 1, 0.8f };
    }
}

fn void? place_point_lights(Scene* scene, Aabb bounds, uint count, float range) @local {
    Vec3 extent = bounds.max - bounds.min;
    uint columns = math::max(1u, (uint)math::ceil(math::sqrt((float)count)));
    uint rows = (count + columns - 1) / columns;
    float height = bounds.min.y + extent.y * BENCHMARK_LIGHT_HEIGHT;
    for (uint index = 0; index < count; index++) {
        float across = ((float)(index % columns) + 0.5f) / (float)columns;
        float along = ((float)(index / columns) + 0.5f) / (float)rows;
        Node* node = scene.add_light(light::point(light_color(index), BENCHMARK_LIGHT_INTENSITY, range))!;
        node.local.position = { bounds.min.x + extent.x * across, height, bounds.min.z + extent.z * along };
    }
}

fn Node*? place_camera(Scene* scene, Aabb bounds) @local {
    Vec3 extent = bounds.max - bounds.min;
    Vec3 center = (bounds.min + bounds.max) * 0.5f;
    float longest = math::max(extent.x, extent.z);
    Vec3 axis = extent.x >= extent.z ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 0, 1 };
    Vec3 eye = center - axis * (longest * BENCHMARK_CAMERA_BACK);
    eye.y = bounds.min.y + extent.y * BENCHMARK_CAMERA_HEIGHT;
    Vec3 target = center + axis * (longest * BENCHMARK_CAMERA_BACK);
    target.y = bounds.min.y + extent.y * BENCHMARK_TARGET_HEIGHT;
    Node* camera_node = scene.add_camera(
        camera::perspective_deg(BENCHMARK_FOV_DEGREES, longest * BENCHMARK_NEAR_SCALE), name: "camera")!;
    camera_node.local.position = eye;
    camera_node.local.rotation = maths::look_rotation((target - eye).normalize(), { 0, 1, 0 });
    return camera_node;
}

fn Node*? populate_benchmark_scene(
    AssetStore* assets,
    Scene* scene,
    Renderer* renderer,
    BenchmarkOptions options,
) @local {
    ModelId model = gltf::load_model(assets, options.model_path)!;
    TextureId studio = image::load_hdr(assets, example_path(ENVIRONMENT_FILE), "gltf_benchmark/environment_source")!;
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(studio), "gltf_benchmark/environment")!;
    renderer.upload_environment(environment)!;
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = BACKGROUND_INTENSITY;

    ModelTemplate* template = &assets.model(model).data;
    Aabb bounds = template_bounds(assets, template);
    Vec3 extent = bounds.max - bounds.min;
    model::instantiate(assets, scene, model, name: "model")!;
    Light sun = light::directional({ 1, 0.95f, 0.85f }, LIGHT_INTENSITY, options.shadows);
    Node* sun_node = scene.add_light(sun, name: "sun")!;
    sun_node.local.rotation = maths::look_rotation((Vec3){ -0.5f, -1, -0.6f }.normalize(), { 0, 1, 0 });
    place_point_lights(scene, bounds, options.lights, options.range * math::max(extent.x, extent.z))!;
    io::eprintfn("model=%s nodes=%d meshes=%d", options.model_path, template.nodes.len, template.meshes.len);
    return place_camera(scene, bounds);
}

fn ViewDesc benchmark_view_desc(ViewDesc base, BenchmarkOptions options) @local {
    base.lights = options.selection;
    base.clusters.lights_per_cluster = options.capacity;
    return base;
}

fn void print_banner(BenchmarkOptions options, bool timestamps_active) @local {
    BenchmarkFlags flags = options.flags;
    io::eprintfn("mode=%s lights=%d shadows=%s range=%.3f capacity=%d extent=%dx%d warmup=%d frames=%d validation=%s timestamps_requested=%s timestamps_active=%s capture=%s presentation=%s panel=%s",
        options.selection == LightSelection.FLAT ? "flat" : "clustered", options.lights, options.shadows,
        options.range, options.capacity, flags.width, flags.height, flags.warmup, flags.frames,
        flags.validation, flags.gpu_timings, timestamps_active, flags.capture,
        flags.window ? "window" : "none", flags.panel);
}

fn void? run_benchmark(BenchmarkOptions options) @local {
    BenchmarkFlags flags = options.flags;
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    FrameSample[] samples = alloc::new_array(mem, FrameSample, flags.frames);
    defer alloc::free(mem, samples.ptr);
    BenchmarkRun run = { .scene = &scene };
    RendererDesc renderer_desc = {
        .validation = flags.validation,
        .gpu_timings = flags.gpu_timings,
        .present_mode = gpu::PresentMode.IMMEDIATE,
        .application_name = "c3d_gltf_benchmark",
        .max_lights = BENCHMARK_LIGHTS_MAX,
    };
    $if $feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU):
        BenchmarkRecorder recorder;
        if (flags.capture) {
            recorder = bench_loop::create_recorder()!;
            run.recorder = &recorder;
            $if $feat(C3D_PROFILE_GPU):
                renderer_desc.profiler = &recorder;
            $endif
        }
        defer if (flags.capture) bench_loop::destroy_recorder(&recorder);
    $endif

    usz collected;
    if (flags.window) {
        platform::Window window = platform::create_window(
            platform::default_window_desc("c3d glTF benchmark", flags.width, flags.height))!;
        defer platform::destroy_window(&window);
        Renderer renderer = platform::create_window_renderer(mem, &window, &assets, renderer_desc)!;
        defer render::destroy_renderer(&renderer);
        render::configure_view(&renderer, renderer.default_view, benchmark_view_desc(render::default_view_desc(), options))!;
        run.renderer = &renderer;
        run.window = &window;
        run.view = renderer.default_view;
        run.camera_node = populate_benchmark_scene(&assets, &scene, &renderer, options)!;
        $if $feat(C3D_PROFILE_GUI):
            GuiRenderer gui_renderer;
            gui::ProfilerPanel panel;
            if (flags.panel) {
                gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
                run.gui_renderer = &gui_renderer;
            }
            defer if (flags.panel) (void)gui::destroy_gui_renderer(&gui_renderer);
            if (flags.panel) {
                panel = gui::create_profiler_panel(mem, run.recorder)!;
                run.panel = &panel;
            }
            defer if (flags.panel) gui::destroy_profiler_panel(&panel);
        $endif
        print_banner(options, renderer.timestamps_enabled);
        collected = bench_loop::run_frames(&run, flags, samples)!;
        bench_loop::write_samples(samples[:collected], renderer.timestamps_enabled);
    } else {
        Renderer renderer = render::create_renderer(mem, &assets, renderer_desc)!;
        defer render::destroy_renderer(&renderer);
        RenderTargetId target = render::create_render_target(&renderer,
            render::render_target_desc(flags.width, flags.height, PixelFormat.RGBA8_UNORM))!;
        run.renderer = &renderer;
        run.view = render::create_view(&renderer,
            benchmark_view_desc(render::texture_view_desc(target, OutputMode.DISPLAY_LDR), options))!;
        run.camera_node = populate_benchmark_scene(&assets, &scene, &renderer, options)!;
        print_banner(options, renderer.timestamps_enabled);
        collected = bench_loop::run_frames(&run, flags, samples)!;
        bench_loop::write_samples(samples[:collected], renderer.timestamps_enabled);
    }
}

<* View a glTF model interactively, or run the fixed scene benchmark. *>
fn int main(String[] args) {
    BenchmarkOptions? parsed = parse_options(args);
    if (catch excuse = parsed) {
        if (excuse != c3d::UNSUPPORTED) {
            io::eprintfn("Invalid options: %s", excuse);
            io::eprintn("Use [model.gltf] [--gpu-timings] or --benchmark [model.gltf] --mode flat|clustered --lights N --shadows on|off --range R --capacity N --frames N --warmup N --width N --height N [--gpu-timings] [--validation] [--capture] [--window] [--panel] [--print-features].");
        }
        return 1;
    }
    BenchmarkOptions options = parsed;
    if (options.flags.print_features) {
        bench_loop::print_features();
        return 0;
    }
    if (!options.flags.enabled) return run_example(options.model_path, options.flags.gpu_timings);
    if (!options.model_path.len) options.model_path = example_path(BENCHMARK_MODEL);
    if (catch excuse = run_benchmark(options)) {
        io::eprintfn("glTF benchmark failed: %s", excuse);
        return 1;
    }
    return 0;
}

fn int run_example(String model_path, bool gpu_timings) @local {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d glTF viewer", 1440, 900))!!;
    defer platform::destroy_window(&window);

    AssetStoreDesc store_desc = asset::default_asset_store_desc();
    store_desc.max_models = MODEL_CAPACITY;
    AssetStore assets = asset::create_asset_store(mem, store_desc);
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_gltf_viewer" },
    )!!;
    defer render::destroy_renderer(&renderer);

    if (!model_path.len) model_path = example_path(DEFAULT_MODEL);
    ModelId model;
    if (catch excuse = gltf::load_model(&assets, model_path)) {
        io::printfn("Loading %s failed: %s", model_path, excuse);
        return 1;
    } else {
        model = assets.find_model(model_path)!!;
    }
    TextureId studio = image::load_hdr(&assets, example_path(ENVIRONMENT_FILE), "gltf_viewer/environment_source")!!;
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(studio), "gltf_viewer/environment")!!;
    renderer.upload_environment(environment)!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = BACKGROUND_INTENSITY;

    ModelTemplate* template = &assets.model(model).data;
    Aabb bounds = template_bounds(&assets, template);
    Vec3 extent = bounds.max - bounds.min;
    Vec3 center = (bounds.min + bounds.max) * 0.5f;
    float radius = math::max(extent.length() * 0.5f, 0.001f);
    float spacing = extent.x * (1 + INSTANCE_GAP_SCALE);

    Node* left = model::instantiate(&assets, &scene, model, name: "left")!!;
    Node* right = model::instantiate(&assets, &scene, model, name: "right")!!;
    left.local.position = { -spacing * 0.5f, 0, 0 };
    right.local.position = { spacing * 0.5f, 0, 0 };
    io::printfn("%s: %d nodes, %d meshes, %d cameras, %d lights, %d skeletons, %d skins, %d clips",
        model_path, template.nodes.len, template.meshes.len, template.cameras.len, template.lights.len,
        skeleton_count(template), template.skins.len, template.clips.len);

    Light sun = light::directional({ 1, 0.95f, 0.85f }, LIGHT_INTENSITY);
    Node* sun_node = scene.add_light(sun, name: "sun")!!;
    sun_node.local.rotation = maths::look_rotation((Vec3){ -0.5f, -1, -0.6f }.normalize(), { 0, 1, 0 });

    Node* camera_node = scene.add_camera(camera::perspective_deg(50, radius * 0.05f), name: "camera")!!;
    Orbit orbit = {
        .target   = center,
        .distance = radius * ORBIT_DISTANCE_SCALE + spacing,
        .minimum  = radius * ORBIT_DISTANCE_MIN_SCALE,
        .maximum  = (radius + spacing) * ORBIT_DISTANCE_MAX_SCALE,
        .yaw      = 0.6f,
        .pitch    = 0.35f,
    };
    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    io::printn("drag to orbit, wheel to zoom, Escape release quits");
    double last_print;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE)) break;

        right.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 },
            (float)window.clock.total * SPIN_RADIANS_PER_SECOND);
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;

        if (window.clock.total - last_print >= STATS_PERIOD_SECONDS) {
            last_print = window.clock.total;
            io::printfn("draws %d, triangles %d, culled %d, frame %.2f ms",
                renderer.stats.draws, renderer.stats.triangles, renderer.stats.culled, renderer.stats.frame_ms);
        }
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
