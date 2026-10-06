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
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;
import bench_loop;
import gpu;
import imgui;

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
const float FREE_LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float FREE_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float FREE_SPEED_SCALE @local = 0.5f; // model radii per second; crosses a model in about two seconds
const float FREE_FAST_MULTIPLIER @local = 4;
const float FREE_SPEED_WHEEL_STEP @local = 1.25f;
const Vec2 CAMERA_PANEL_POSITION @local = { 16, 16 };
const Vec2 CAMERA_PANEL_SIZE @local = { 300, 150 };
const Vec2 TARGETS_PANEL_POSITION @local = { 16, 180 };
const Vec2 TARGETS_PANEL_SIZE @local = { 420, 300 };
const Vec2 POST_PANEL_POSITION @local = { 1060, 16 };
const Vec2 POST_PANEL_SIZE @local = { 360, 420 };
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
const uint PROBE_SPLIT_VOLUMES @local = 8; // one volume per octant of the model bounds
const uint REFLECTION_PROBES_TILED @local = 16; // a 4 x 2 x 2 grid over the model bounds
const uint[<3>] REFLECTION_PROBE_TILES @local = { 4, 2, 2 };
const float REFLECTION_PROBE_OVERLAP_SCALE @local = 1.01f; // the second probe of a pair covers the first
const float REFLECTION_PROBE_SINK @local = 2;      // outside placement: bounds heights below the model
const uint REFLECTION_BENCHMARK_ENVIRONMENTS @local = 32; // one environment per probe beside the global one
const float REFLECTION_COLOR_STEP @local = 0.618f; // golden-ratio hop keeps neighbouring probes' colours apart

struct BenchmarkOptions @local {
    BenchmarkFlags flags;
    LightSelection selection;
    ShadingPath shading;
    uint lights;
    uint capacity;
    float range;
    bool shadows;
    bool traced_shadows;
    String model_path;
    uint probe_volumes;
    uint[<3>] probe_counts;
    ProbeFill probe_fill;
    uint probe_window;
    uint probe_rays;
    bool point_shadows;
    bool environment_refresh;
    uint reflection_probes;
    bool reflection_probes_outside;
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

struct FreeCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
    float speed;
}

fn Vec3 free_forward(FreeCamera* camera) @local {
    return {
        math::cos(camera.pitch) * math::sin(camera.yaw),
        math::sin(camera.pitch),
        math::cos(camera.pitch) * math::cos(camera.yaw),
    };
}

fn FreeCamera free_camera_from(Node* camera_node, float speed) @local {
    Vec3 forward = camera_node.local.rotation.rotate_vec3({ 0, 0, -1 });
    return {
        .position = camera_node.local.position,
        .yaw = math::atan2(forward.x, forward.z),
        .pitch = math::asin(math::clamp(forward.y, -1.0f, 1.0f)),
        .speed = speed,
    };
}

fn void apply_free_camera(
    FreeCamera* camera,
    Input* input,
    Node* camera_node,
    float delta_seconds,
) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.RIGHT)) {
            camera.yaw -= input.mouse_delta.x * FREE_LOOK_RADIANS_PER_PIXEL;
            camera.pitch = math::clamp(
                camera.pitch - input.mouse_delta.y * FREE_LOOK_RADIANS_PER_PIXEL,
                -FREE_PITCH_LIMIT,
                FREE_PITCH_LIMIT,
            );
        }
        if (input.wheel != 0) camera.speed *= math::pow(FREE_SPEED_WHEEL_STEP, input.wheel);
    }
    Vec3 forward = free_forward(camera);
    Vec3 up = { 0, 1, 0 };
    Vec3 right = forward.cross(up).normalize();
    if (!input.keyboard_captured_by_gui) {
        Vec3 direction;
        if (input.key_down(platform::Scancode.W)) direction += forward;
        if (input.key_down(platform::Scancode.S)) direction -= forward;
        if (input.key_down(platform::Scancode.D)) direction += right;
        if (input.key_down(platform::Scancode.A)) direction -= right;
        if (input.key_down(platform::Scancode.E)) direction += up;
        if (input.key_down(platform::Scancode.Q)) direction -= up;
        float speed = camera.speed * (input.key_down(platform::Scancode.LSHIFT) ? FREE_FAST_MULTIPLIER : 1);
        camera.position += direction * (speed * delta_seconds);
    }
    camera_node.local.position = camera.position;
    camera_node.local.rotation = maths::look_rotation(forward, up);
}

fn void? draw_viewer_frame(
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
        .probe_counts = { 16, 8, 8 },
        .probe_fill = ProbeFill.ENVIRONMENT,
        .probe_rays = light::PROBE_UPDATE_DEFAULT.rays_per_probe,
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
            case "--shading": options.shading = bench_loop::parse_shading(value)!;
            case "--shadows":
                if (value == "on" || value == "traced") {
                    options.shadows = true;
                    options.traced_shadows = value == "traced";
                } else if (value == "off") {
                    options.shadows = false;
                    options.traced_shadows = false;
                } else {
                    return c3d::INVALID_ARGUMENT~;
                }
            case "--lights": options.lights = value.to_uint()!;
            case "--capacity": options.capacity = value.to_uint()!;
            case "--range": options.range = value.to_float()!;
            case "--probe-volumes": options.probe_volumes = value.to_uint()!;
            case "--probe-window": options.probe_window = value.to_uint()!;
            case "--probe-rays": options.probe_rays = value.to_uint()!;
            case "--probe-fill":
                switch (value) {
                    case "environment": options.probe_fill = ProbeFill.ENVIRONMENT;
                    case "scene": options.probe_fill = ProbeFill.SCENE;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--point-shadows":
                switch (value) {
                    case "on": options.point_shadows = true;
                    case "off": options.point_shadows = false;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--environment-refresh":
                switch (value) {
                    case "on": options.environment_refresh = true;
                    case "off": options.environment_refresh = false;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--reflection-probes": options.reflection_probes = value.to_uint()!;
            case "--reflection-probe-placement":
                switch (value) {
                    case "inside": options.reflection_probes_outside = false;
                    case "outside": options.reflection_probes_outside = true;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--probe-counts":
                String[] counts = value.tsplit(",");
                if (counts.len != 3) return c3d::INVALID_ARGUMENT~;
                foreach (axis, count : counts) options.probe_counts[axis] = count.to_uint()!;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    bench_loop::validate_flags(options.flags, options.shading)!;
    if (options.lights > BENCHMARK_LIGHTS_MAX || !options.capacity || options.capacity > BENCHMARK_CAPACITY_MAX
        || !math::is_finite(options.range) || options.range <= 0 || options.range > BENCHMARK_RANGE_MAX) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (options.probe_volumes != 0 && options.probe_volumes != 1 && options.probe_volumes != PROBE_SPLIT_VOLUMES) {
        return c3d::INVALID_ARGUMENT~;
    }
    uint[4] reflection_counts = { 0, 1, 2, REFLECTION_PROBES_TILED };
    bool reflection_valid;
    foreach (count : reflection_counts) reflection_valid = reflection_valid || options.reflection_probes == count;
    if (!reflection_valid) return c3d::INVALID_ARGUMENT~;
    foreach (count : options.probe_counts) {
        if (count < light::PROBE_COUNT_MIN || count > light::PROBE_COUNT_MAX) return c3d::INVALID_ARGUMENT~;
    }
    if (options.probe_rays < light::PROBE_RAYS_MIN || options.probe_rays > light::PROBE_RAYS_MAX) {
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

fn void? place_point_lights(
    Scene* scene,
    Aabb bounds,
    uint count,
    float range,
    bool shadows,
) @local {
    Vec3 extent = bounds.max - bounds.min;
    uint columns = math::max(1u, (uint)math::ceil(math::sqrt((float)count)));
    uint rows = (count + columns - 1) / columns;
    float height = bounds.min.y + extent.y * BENCHMARK_LIGHT_HEIGHT;
    for (uint index = 0; index < count; index++) {
        float across = ((float)(index % columns) + 0.5f) / (float)columns;
        float along = ((float)(index / columns) + 0.5f) / (float)rows;
        Light point = light::point(light_color(index), BENCHMARK_LIGHT_INTENSITY, range);
        point.shadow.enabled = shadows;
        Node* node = scene.add_light(point)!;
        node.local.position = { bounds.min.x + extent.x * across, height, bounds.min.z + extent.z * along };
    }
}

fn void? place_probe_volumes(Scene* scene, Aabb bounds, BenchmarkOptions options) @local {
    uint volumes = options.probe_volumes;
    if (!volumes) return;
    uint split = volumes == 1 ? 1 : 2;
    Vec3 half_extents = (bounds.max - bounds.min) / (float)(2 * split);
    for (uint z = 0; z < split; z++) {
        for (uint y = 0; y < split; y++) {
            for (uint x = 0; x < split; x++) {
                Node* node = scene.add_node(name: "probe_volume")!;
                uint[<3>] octant = { x, y, z };
                node.local.position = bounds.min + half_extents * (Vec3)(octant * 2 + 1);
                ProbeVolume volume = light::probe_volume(half_extents, options.probe_counts, options.probe_fill);
                volume.update.probes_per_frame = options.probe_window;
                volume.update.rays_per_probe = options.probe_rays;
                scene.add(node, volume);
            }
        }
    }
}

fn Vec3 reflection_probe_color(uint index) @local {
    float hue = (float)index * REFLECTION_COLOR_STEP;
    return {
        0.2f + 0.8f * (hue - math::floor(hue)),
        0.2f + 0.8f * (hue * 2 - math::floor(hue * 2)),
        0.2f + 0.8f * (hue * 3 - math::floor(hue * 3)),
    };
}

fn void? add_reflection_probe(
    AssetStore* assets,
    Scene* scene,
    Vec3 center,
    Vec3 half_extents,
    float blend_distance,
    uint index,
) @local {
    EnvironmentSettings settings = light::ENVIRONMENT_SETTINGS_DEFAULT;
    settings.specular_size = render::DEFAULT_REFLECTION_CAPTURE_SIZE;
    EnvironmentId environment = assets.add_environment(
        light::solid_environment(reflection_probe_color(index), settings))!;
    Node* node = scene.add_node(name: "reflection_probe")!;
    node.local.position = center;
    ReflectionProbe probe = light::reflection_probe(half_extents, environment);
    probe.blend_distance = blend_distance;
    scene.add(node, probe);
}

fn void? place_reflection_probes(
    AssetStore* assets,
    Scene* scene,
    Aabb bounds,
    BenchmarkOptions options,
) @local {
    uint count = options.reflection_probes;
    if (!count) return;
    Vec3 extent = bounds.max - bounds.min;
    Vec3 center = (bounds.min + bounds.max) * 0.5f;
    Vec3 shift = options.reflection_probes_outside ? (Vec3){ 0, -REFLECTION_PROBE_SINK * extent.y, 0 } : (Vec3){};
    if (count == REFLECTION_PROBES_TILED) {
        Vec3 half_extents = extent / (Vec3)(REFLECTION_PROBE_TILES * 2);
        for (uint index = 0; index < count; index++) {
            uint[<3>] tile = {
                index % REFLECTION_PROBE_TILES.x,
                (index / REFLECTION_PROBE_TILES.x) % REFLECTION_PROBE_TILES.y,
                index / (REFLECTION_PROBE_TILES.x * REFLECTION_PROBE_TILES.y),
            };
            add_reflection_probe(
                assets:         assets,
                scene:          scene,
                center:         bounds.min + half_extents * (Vec3)(tile * 2 + 1) + shift,
                half_extents:   half_extents,
                blend_distance: 0,
                index:          index,
            )!;
        }
        return;
    }
    Vec3 half_extents = extent * 0.5f;
    float blend = count == 1 ? 0 : math::min(half_extents.x, half_extents.y, half_extents.z);
    for (uint index = 0; index < count; index++) {
        add_reflection_probe(
            assets:         assets,
            scene:          scene,
            center:         center + shift,
            half_extents:   index == 0 ? half_extents : half_extents * REFLECTION_PROBE_OVERLAP_SCALE,
            blend_distance: blend,
            index:          index,
        )!;
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
    sun.shadow.ray_traced = options.traced_shadows;
    Node* sun_node = scene.add_light(sun, name: "sun")!;
    sun_node.local.rotation = maths::look_rotation((Vec3){ -0.5f, -1, -0.6f }.normalize(), { 0, 1, 0 });
    place_point_lights(
        scene:   scene,
        bounds:  bounds,
        count:   options.lights,
        range:   options.range * math::max(extent.x, extent.z),
        shadows: options.point_shadows,
    )!;
    place_probe_volumes(scene, bounds, options)!;
    place_reflection_probes(assets, scene, bounds, options)!;
    io::eprintfn("model=%s nodes=%d meshes=%d", options.model_path, template.nodes.len, template.meshes.len);
    return place_camera(scene, bounds);
}

// Traced sun shadows are a traced effect, so an AUTO run creates the renderer with ray queries for them too.
fn bool requests_ray_queries(BenchmarkOptions options) @local {
    bool automatic = options.flags.trace == TraceKind.AUTO;
    return bench_loop::requests_ray_queries(options.flags) || (automatic && options.traced_shadows);
}

fn ViewDesc benchmark_view_desc(ViewDesc base, BenchmarkOptions options) @local {
    base.post.anti_aliasing = options.flags.anti_aliasing;
    base.ambient_occlusion = options.flags.ambient_occlusion;
    base.depth_prepass = options.flags.depth_prepass;
    base.post.auto_exposure = options.flags.auto_exposure;
    base.ray_tracing.reflections = options.flags.reflections;
    base.ray_tracing.shadows = options.traced_shadows;
    if (options.flags.screen_space_gi) base.screen_space_gi = render::SCREEN_SPACE_GI_DEFAULT;
    base.shading = options.shading;
    // A path-traced view loops every light itself and rejects the cluster grid.
    base.lights = options.shading == ShadingPath.PATH_TRACED ? LightSelection.FLAT : options.selection;
    base.clusters.lights_per_cluster = options.capacity;
    return base;
}

fn void print_banner(BenchmarkOptions options, bool timestamps_active) @local {
    BenchmarkFlags flags = options.flags;
    bool scene_probes = options.probe_volumes != 0 && options.probe_fill == ProbeFill.SCENE;
    bool path_traced = options.shading == ShadingPath.PATH_TRACED;
    io::eprintfn("mode=%s shading=%s lights=%d shadows=%s range=%.3f capacity=%d extent=%dx%d warmup=%d frames=%d validation=%s timestamps_requested=%s timestamps_active=%s capture=%s presentation=%s panel=%s depth_prepass=%s ambient_occlusion=%s reflections=%s screen_space_gi=%s auto_exposure=%s probe_volumes=%d probe_counts=%dx%dx%d probe_fill=%s probe_window=%d probe_rays=%d point_shadows=%s environment_refresh=%s trace=%s reflection_probes=%d reflection_probe_placement=%s",
        options.selection == LightSelection.FLAT || options.shading == ShadingPath.PATH_TRACED ? "flat" : "clustered",
        bench_loop::shading_name(options.shading), options.lights,
        options.traced_shadows ? "traced" : options.shadows ? "on" : "off",
        options.range, options.capacity, flags.width, flags.height, flags.warmup, flags.frames,
        flags.validation, flags.gpu_timings, timestamps_active, flags.capture,
        flags.window ? "window" : "none", flags.panel, flags.depth_prepass,
        bench_loop::ambient_occlusion_name(flags.ambient_occlusion), flags.reflections ? "on" : "off",
        flags.screen_space_gi ? "on" : "off",
        flags.auto_exposure ? "on" : "off",
        options.probe_volumes, options.probe_counts.x, options.probe_counts.y, options.probe_counts.z,
        options.probe_fill == ProbeFill.SCENE ? "scene" : "environment", options.probe_window, options.probe_rays,
        options.point_shadows, options.environment_refresh, bench_loop::trace_name(
            traces:      scene_probes || bench_loop::needs_ray_queries(flags) || options.traced_shadows || path_traced,
            ray_queries: requests_ray_queries(options) || path_traced,
        ), options.reflection_probes, options.reflection_probes_outside ? "outside" : "inside");
}

fn void? run_benchmark(BenchmarkOptions options) @local {
    BenchmarkFlags flags = options.flags;
    AssetStoreDesc store_desc = asset::default_asset_store_desc();
    if (options.reflection_probes) store_desc.max_environments = REFLECTION_BENCHMARK_ENVIRONMENTS;
    AssetStore assets = asset::create_asset_store(mem, store_desc);
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
        .ray_queries = requests_ray_queries(options),
        .ray_tracing_pipelines = options.shading == ShadingPath.PATH_TRACED,
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
        if (options.environment_refresh) run.refreshed_texture = assets.environment(scene.environment).desc.source;
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
        if (options.environment_refresh) run.refreshed_texture = assets.environment(scene.environment).desc.source;
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
            io::eprintn("Use [model.gltf] [--gpu-timings] or --benchmark [model.gltf] --mode flat|clustered [--shading forward|deferred|path-traced] --lights N --shadows on|off|traced --range R --capacity N --frames N --warmup N --width N --height N [--anti-aliasing none|fxaa|taa] [--ambient-occlusion none|half|full] [--depth-prepass on|off] [--environment-refresh on|off] [--reflection-probes 0|1|2|16] [--reflection-probe-placement inside|outside] [--gpu-timings] [--validation] [--capture] [--window] [--panel] [--print-features].");
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

    RendererDesc renderer_desc = {
        .gpu_timings           = gpu_timings,
        .validation            = true,
        .application_name      = "c3d_gltf_viewer",
        .ray_tracing_pipelines = true,
    };
    render::Renderer? traced = platform::create_window_renderer(mem, &window, &assets, renderer_desc);
    if (catch traced) {
        // Adapters without ray-tracing pipelines still view the model; the Path traced choice stays disabled.
        renderer_desc.ray_tracing_pipelines = false;
        traced = platform::create_window_renderer(mem, &window, &assets, renderer_desc);
    }
    render::Renderer renderer = traced!!;
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

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    FreeCamera free_camera = free_camera_from(camera_node, radius * FREE_SPEED_SCALE);
    bool free_mode;
    TargetsPanelState targets = gui::default_targets_panel_state();

    io::printn("drag to orbit, wheel to zoom; F or the Camera panel toggles the free camera: right drag looks, WASDQE move, Shift is fast, wheel scales speed; Escape release quits");
    double last_print;
    while (window.poll()) {
        Input* input = &window.input;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;

        bool was_free = free_mode;
        if (input.key_pressed(platform::Scancode.F) && !input.keyboard_captured_by_gui) free_mode = !free_mode;
        imgui::set_next_window_pos(CAMERA_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CAMERA_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Camera", null, {})) {
            imgui::checkbox("Free camera (F)", &free_mode);
            if (free_mode) {
                imgui::text("Right drag looks, WASDQE move, Shift fast");
                imgui::text("Speed: %.2f units/s (wheel)", free_camera.speed);
            } else {
                imgui::text("Left drag orbits, wheel zooms");
            }
        }
        imgui::end();
        if (free_mode && !was_free) free_camera = free_camera_from(camera_node, free_camera.speed);
        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::targets_panel(&renderer, renderer.default_view, &targets, environment)!!;
        // The targets panel reconfigures the view it inspects; the post panel edits from that state.
        ViewDesc view_desc = renderer.views.get(renderer.default_view).desc;
        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        bool view_changed = gui::post_panel(&view_desc, {});
        gui_renderer.finish_frame();
        if (view_changed) {
            if (catch excuse = render::configure_view(&renderer, renderer.default_view, view_desc)) {
                io::printfn("gltf_viewer: settings rejected (%s)", excuse);
            }
        }

        // A moving instance restarts path-traced accumulation every frame, so it holds still there.
        if (view_desc.shading != ShadingPath.PATH_TRACED) {
            right.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 },
                (float)window.clock.total * SPIN_RADIANS_PER_SECOND);
        }
        if (free_mode) {
            apply_free_camera(&free_camera, input, camera_node, (float)window.clock.delta);
        } else if (!input.mouse_captured_by_gui) {
            apply_orbit(&orbit, input, camera_node);
        }
        scene.update_world();

        platform::sync_window(&window, &renderer);
        draw_viewer_frame(
            renderer: &renderer,
            scene: &scene,
            camera_node: camera_node,
            gui_renderer: &gui_renderer,
            info: { .time = window.clock.total, .delta = window.clock.delta },
        )!!;

        if (window.clock.total - last_print >= STATS_PERIOD_SECONDS) {
            last_print = window.clock.total;
            io::printfn("draws %d, triangles %d, culled %d, frame %.2f ms",
                renderer.stats.draws, renderer.stats.triangles, renderer.stats.culled, renderer.stats.frame_ms);
        }
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
