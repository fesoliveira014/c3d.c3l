module vegetation_example;

import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::gui;
import c3d::landscape::foliage;
import c3d::landscape::terrain;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::spatial;
import imgui;
import landscape_foliage;
import landscape_ground;

const uint FIXED_NODES @local = 16; // root, terrain, sun, camera and two layer nodes, with room to spare
const uint TRACE_INSTANCE_CAPACITY @local = 16384; // traced trees at every map size; 3.4 MiB of trace table
const float CAMERA_FOV_DEGREES @local = 60;
const float CAMERA_NEAR @local = 0.1f; // blades brush the eye at walking height
const float CAMERA_FAR @local = 8000; // covers the 4 km diagonal of the largest map from its middle
const uint WINDOW_WIDTH @local = 1600;
const uint WINDOW_HEIGHT @local = 900;
const uint BENCHMARK_WIDTH @local = 2560;
const uint BENCHMARK_HEIGHT @local = 1440;
const uint DEFAULT_SEGMENT_FRAMES @local = 300;
const uint WARMUP_FRAMES @local = 60; // history, caches and the first uploads settle before the timed frames
const uint FRAMES_PER_SECOND @local = 60;
const float TIME_STEP @local = 1.0f / FRAMES_PER_SECOND;
const uint STAMP_PERIOD @local = 30; // frames between brush stamps in the edit segment
const double NANOSECONDS_PER_MICROSECOND @local = 1_000;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const double MICROSECONDS_PER_MILLISECOND @local = 1_000;
const uint RGBA8_BYTES @local = 4;

const float STEADY_WIND_SPEED @local = 6;
const float WIND_HEADING_DEGREES @local = 30;
const float MAX_WIND_SPEED @local = 25;
const float GUST_PERIOD_SECONDS @local = 3;
const float GUST_BASE @local = 0.65f;
const float GUST_SWING @local = 0.35f;

const float EYE_HEIGHT @local = 1.7f;
const float LOOK_PITCH @local = -0.05f;
const float WALK_SPEED @local = 8; // metres per second; also the camera travel of the batch formula
const float FAR_ALTITUDE @local = 60;
const float FAR_PITCH @local = -0.1f;
const Vec2 FAR_POSITION @local = { 0.05f, 0.05f }; // a corner, looking across the terrain
const float EDIT_ALTITUDE @local = 20;
const float EDIT_PITCH @local = -0.8f; // looks down at the brush stamps
const float EDIT_SPEED @local = 8;
const float MEADOW_SEARCH_LOW @local = 0.2f; // share of the extent; keeps the meadow away from the edges
const float MEADOW_SEARCH_HIGH @local = 0.8f;
const uint MEADOW_SEARCH_STEPS @local = 13;
const uint MEADOW_RADIUS_TEXELS @local = 8; // control texels around a search point; 16 m at 2049
const Vec2 PANEL_POSITION @local = { 16, 16 };
const Vec2 PANEL_SIZE @local = { 440, 330 };
const Vec2 STATS_PANEL_POSITION @local = { 16, 362 };
const Vec2 STATS_PANEL_SIZE @local = { 440, 300 };
const String[Segment::len] SEGMENT_NAMES @local = { "still", "spin", "gust", "walk", "far", "edit" };

const Pass[7] REPORTED_PASSES @local = {
    Pass.DEPTH_PREPASS,
    Pass.GBUFFER,
    Pass.SHADOW_ATLAS,
    Pass.FORWARD_OPAQUE,
    Pass.LIGHTING,
    Pass.VELOCITY,
    Pass.INSTANCE_CULL,
};

enum Segment @local {
    STILL,
    SPIN,
    GUST,
    WALK,
    FAR,
    EDIT,
}

enum FoliageChoice @local {
    BOTH,
    GRASS,
    NONE,
}

enum Metric @local {
    CPU_RECORD_MS,
    BATCHES_FADED,
    UPDATE_US,
    UPLOAD_BYTES,
    INSTANCES_TESTED,
    INSTANCES_VISIBLE,
    FRAME_MS,
}

struct Options @local {
    bool          benchmark;
    uint          segment_frames;
    bool          gpu_timings;
    bool          validation;
    ShadingPath   shading;
    bool          traced_shadows;
    uint          size;
    FoliageChoice foliage;
    float         tree_fade_end;
    uint          width;
    uint          height;
}

struct Layer @local {
    ZString     name;
    Node*       node;
    FoliageDesc desc;
    float       reach;      // metres an instance reaches past its cell: horizontal radius at max scale plus sway
    double      scatter_ms;
}

struct Demo @local {
    Options     options;
    AssetStore* assets;
    Scene*      scene;
    Ground      ground;
    Node*       camera_node;
    Layer[2]    layers;
    uint        layer_count;
    Vec2        meadow;     // share of the extent along x and z
}

struct WindControls @local {
    float heading_degrees;
    float speed;
    bool  gust;
}

struct FrameRecord @local {
    double                    cpu_record_ms;
    double                    update_us;
    double                    frame_ms;
    uint                      batches_faded;
    uint                      upload_bytes;
    uint                      instances_tested;
    uint                      instances_visible;
    uint                      placed_cells;
    bool                      cells_revised;
    bool                      stamped;
    float[render::PASS_COUNT] gpu_ms;
}

struct BenchmarkResult @local {
    FrameRecord[] records;
    double[]      scratch;
    double        rescatter_ms;
    double        first_pack_ms;
    uint          batch_slots_max;
    bool          faded_cells_exact;
    bool          timestamps;
}

fn float gust_share(double time) @local {
    float phase = 2 * (float)math::PI * (float)(time / GUST_PERIOD_SECONDS);
    return GUST_BASE + GUST_SWING * math::sin(phase);
}

fn Vec3 wind_velocity(float speed, float heading_degrees) @local {
    float heading = math::deg_to_rad(heading_degrees);
    return { math::sin(heading) * speed, 0, math::cos(heading) * speed };
}

fn Vec3 controls_wind(WindControls* controls, double time) @local {
    float speed = controls.speed;
    if (controls.gust) speed *= gust_share(time);
    return wind_velocity(speed, controls.heading_degrees);
}

fn Layer[] active_layers(Demo* demo) @local => demo.layers[:demo.layer_count];

fn uint cells_per_side(float extent, float cell_size) @local => (uint)math::ceil(extent / cell_size);

fn uint grid_cells(float extent, float cell_size) @local {
    uint side = cells_per_side(extent, cell_size);
    return side * side;
}

// Cells a faded layer can hold records for per view camera; docs/vegetation.md derives it.
fn uint batch_formula(
    float fade_end,
    float reach,
    float travel,
    float cell_size,
) @local {
    float radius = fade_end + reach + travel;
    uint side = (uint)math::ceil(2 * radius / cell_size) + 1;
    return side * side;
}

// ----------------------------------------------------------------------------- scene

fn float horizontal_reach(AssetStore* assets, FoliageDesc* desc) @local {
    Aabb bounds = assets.geometry(desc.geometry).data.bounds;
    float x = math::max(math::abs(bounds.min.x), math::abs(bounds.max.x));
    float z = math::max(math::abs(bounds.min.z), math::abs(bounds.max.z));
    return math::sqrt(x * x + z * z) * desc.rules.max_scale + desc.sway.amplitude;
}

// The control-map point of the search grid with the most grass around it.
fn Vec2 find_meadow(AssetStore* assets, TextureId control_map) @local {
    TextureAsset* control = assets.texture(control_map);
    uint side = control.desc.width;
    Vec2 best;
    float best_weight = -1;
    for (uint row = 0; row < MEADOW_SEARCH_STEPS; row++) {
        for (uint column = 0; column < MEADOW_SEARCH_STEPS; column++) {
            float step = (MEADOW_SEARCH_HIGH - MEADOW_SEARCH_LOW) / (float)(MEADOW_SEARCH_STEPS - 1);
            Vec2 share = { MEADOW_SEARCH_LOW + step * (float)column, MEADOW_SEARCH_LOW + step * (float)row };
            uint center_x = (uint)(share.x * (float)(side - 1));
            uint center_z = (uint)(share.y * (float)(side - 1));
            float weight;
            for (uint z = center_z - MEADOW_RADIUS_TEXELS; z <= center_z + MEADOW_RADIUS_TEXELS; z++) {
                for (uint x = center_x - MEADOW_RADIUS_TEXELS; x <= center_x + MEADOW_RADIUS_TEXELS; x++) {
                    weight += (float)control.pixels[((usz)z * side + x) * RGBA8_BYTES];
                }
            }
            if (weight > best_weight) {
                best_weight = weight;
                best = share;
            }
        }
    }
    return best;
}

fn Layer? add_layer(
    Scene* scene,
    AssetStore* assets,
    Ground* ground,
    ZString name,
    FoliageDesc desc,
) @local {
    Node* node = scene.add_node(name: name.str_view())!;
    node.local = ground.node.local;
    node.layers = landscape_foliage::FOLIAGE_LAYER;
    scene.update_world();
    time::Clock started = clock::now();
    foliage::add_foliage(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   desc,
    )!;
    return {
        .name       = name,
        .node       = node,
        .desc       = desc,
        .reach      = horizontal_reach(assets, &desc),
        .scatter_ms = elapsed_ms(started),
    };
}

fn Demo? build_demo(Options options, AssetStore* assets, Scene* scene) @local {
    Ground ground = landscape_ground::add_ground(
        scene:         scene,
        assets:        assets,
        size:          options.size,
        layers:        landscape_ground::LAYER_COUNT,
        lod_threshold: terrain::DEFAULT_LOD_THRESHOLD,
    )!;
    landscape_ground::add_sun_and_sky(scene, options.traced_shadows)!;
    Node* camera_node = scene.add_camera(
        camera::perspective_deg(CAMERA_FOV_DEGREES, CAMERA_NEAR, CAMERA_FAR),
        name: "camera",
    )!;
    Demo demo = {
        .options     = options,
        .assets      = assets,
        .scene       = scene,
        .ground      = ground,
        .camera_node = camera_node,
        .meadow      = find_meadow(assets, ground.desc.control_map),
    };

    if (options.foliage != NONE) {
        demo.layers[demo.layer_count++] = add_layer(
            scene:  scene,
            assets: assets,
            ground: &ground,
            name:   "grass",
            desc:   landscape_foliage::grass_layer_desc(assets, &ground)!,
        )!;
    }
    if (options.foliage == BOTH) {
        FoliageDesc desc = landscape_foliage::tree_layer_desc(assets, &ground, options.tree_fade_end)!;
        demo.layers[demo.layer_count++] = add_layer(
            scene:  scene,
            assets: assets,
            ground: &ground,
            name:   "trees",
            desc:   desc,
        )!;
    }
    scene.update_world();
    return demo;
}

fn Vec3 extent_point(Demo* demo, Vec2 share) @local {
    return { share.x * demo.ground.extent, 0, share.y * demo.ground.extent };
}

// Towards the middle of the map, so walks and edits stay on the terrain.
fn float meadow_yaw(Demo* demo) @local {
    Vec2 towards = (Vec2){ 0.5f, 0.5f } - demo.meadow;
    return math::atan2(towards.x, towards.y);
}

fn ViewDesc configure_desc(ViewDesc desc, Options options) @local {
    desc.shading = options.shading;
    desc.post.anti_aliasing = AntiAliasing.TAA;
    desc.ray_tracing.shadows = options.traced_shadows;
    return desc;
}

fn uint scene_node_budget(Options options, float extent) @local {
    uint nodes = FIXED_NODES;
    if (options.foliage != NONE) nodes += grid_cells(extent, foliage::DEFAULT_CELL_SIZE);
    if (options.foliage == BOTH) nodes += grid_cells(extent, landscape_foliage::TREE_CELL_SIZE);
    return nodes;
}

fn RendererDesc renderer_desc(Options options, bool validation, ZString application_name) @local {
    float extent = (float)(options.size - 1) * landscape_ground::CELL_SIZE;
    return {
        .validation           = validation,
        .gpu_timings          = options.gpu_timings,
        .application_name     = application_name,
        .ray_queries          = options.traced_shadows,
        .max_trace_instances  = options.traced_shadows ? TRACE_INSTANCE_CAPACITY : 0,
        .max_instance_batches = scene_node_budget(options, extent) - FIXED_NODES + 1,
    };
}

fn Scene create_demo_scene(Options options) @local {
    float extent = (float)(options.size - 1) * landscape_ground::CELL_SIZE;
    return scene::create_scene(mem, { .max_nodes = scene_node_budget(options, extent) });
}

fn double percentile(double[] samples, float share) @local {
    if (!samples.len) return 0;
    sort::quicksort(samples);
    return samples[(usz)math::round(share * (float)(samples.len - 1))];
}

fn double metric_value(FrameRecord* record, Metric metric) @local {
    switch (metric) {
        case CPU_RECORD_MS: return record.cpu_record_ms;
        case BATCHES_FADED: return (double)record.batches_faded;
        case UPDATE_US: return record.update_us;
        case UPLOAD_BYTES: return (double)record.upload_bytes;
        case INSTANCES_TESTED: return (double)record.instances_tested;
        case INSTANCES_VISIBLE: return (double)record.instances_visible;
        case FRAME_MS: return record.frame_ms;
    }
}

fn double[] gather(FrameRecord[] records, Metric metric, double[] scratch) @local {
    foreach (index, &record : records) scratch[index] = metric_value(record, metric);
    return scratch[:records.len];
}

fn double[] gather_pass(FrameRecord[] records, Pass pass, double[] scratch) @local {
    foreach (index, record : records) scratch[index] = (double)record.gpu_ms[pass.ordinal];
    return scratch[:records.len];
}

fn double elapsed_ms(time::Clock started) @local => (double)(long)started.to_now() / NANOSECONDS_PER_MILLISECOND;

fn String? option_value(String[] args, usz* index) @local {
    if (*index + 1 >= args.len) return c3d::INVALID_ARGUMENT~;
    (*index)++;
    return args[*index];
}

fn Options? parse_options(String[] args) @local {
    Options options = {
        .segment_frames = DEFAULT_SEGMENT_FRAMES,
        .shading        = ShadingPath.FORWARD,
        .size           = landscape_ground::DEFAULT_MAP_SIZE,
        .foliage        = FoliageChoice.BOTH,
        .tree_fade_end  = landscape_foliage::DEFAULT_TREE_FADE_END,
    };
    for (usz index = 1; index < args.len; index++) {
        switch (args[index]) {
            case "--benchmark":
                options.benchmark = true;
                if (index + 1 < args.len) {
                    if (try frames = args[index + 1].to_uint()) {
                        options.segment_frames = frames;
                        index++;
                    }
                }
            case "--gpu-timings":
                $if $feat(C3D_PROFILE_GPU):
                    options.gpu_timings = true;
                $else
                    io::eprintn("--gpu-timings needs GPU profiling: python3 scripts/build.py --target vegetation "
                      "--opt O3 --define C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib c3d_profile");
                    return c3d::UNSUPPORTED~;
                $endif
            case "--validation": options.validation = true;
            case "--shading":
                switch (option_value(args, &index)!) {
                    case "forward": options.shading = ShadingPath.FORWARD;
                    case "deferred": options.shading = ShadingPath.DEFERRED;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--shadows":
                switch (option_value(args, &index)!) {
                    case "atlas": options.traced_shadows = false;
                    case "traced": options.traced_shadows = true;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--size":
                options.size = option_value(args, &index)!.to_uint()!;
                if (!landscape_ground::is_map_size(options.size)) return c3d::INVALID_ARGUMENT~;
            case "--foliage":
                switch (option_value(args, &index)!) {
                    case "both": options.foliage = FoliageChoice.BOTH;
                    case "grass": options.foliage = FoliageChoice.GRASS;
                    case "none": options.foliage = FoliageChoice.NONE;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--tree-fade-end":
                options.tree_fade_end = option_value(args, &index)!.to_float()!;
                if (!(options.tree_fade_end > 0)) return c3d::INVALID_ARGUMENT~;
            case "--width": options.width = option_value(args, &index)!.to_uint()!;
            case "--height": options.height = option_value(args, &index)!.to_uint()!;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    if (!options.width) options.width = options.benchmark ? BENCHMARK_WIDTH : WINDOW_WIDTH;
    if (!options.height) options.height = options.benchmark ? BENCHMARK_HEIGHT : WINDOW_HEIGHT;
    return options;
}

// ----------------------------------------------------------------------------- interactive

fn void vegetation_panel(
    Demo* demo,
    Renderer* renderer,
    WindControls* wind,
    float delta,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Vegetation", null, {})) {
        imgui::text("Right drag looks, WASD move, Shift fast; F flies, Q and E sink and rise");
        imgui::text("B raises the ground under the camera; its grass and trees follow");
        foreach (&layer : active_layers(demo)) {
            FoliageRuntime* runtime = demo.scene.get(layer.node, FoliageRuntime);
            imgui::text(
                "%s: %u of %u cells, %u instances, %u placed",
                layer.name,
                runtime.cell_nodes,
                (uint)runtime.cells.len,
                runtime.instances,
                runtime.placed_cells,
            );
        }
        Stats* stats = &renderer.stats;
        imgui::text("Batches faded %u, culled %u", stats.batches_faded, stats.culled);
        imgui::text("Instances tested %u, visible %u", stats.instances_tested, stats.instances_visible);
        imgui::text(
            "Upload %u bytes, record %.2f ms, frame %.2f ms",
            stats.upload_bytes,
            stats.cpu_record_ms,
            delta * 1000,
        );
        imgui::slider_float(
            label: "Wind heading",
            v:     &wind.heading_degrees,
            v_min: 0,
            v_max: 360,
        );
        imgui::slider_float(
            label: "Wind speed",
            v:     &wind.speed,
            v_min: 0,
            v_max: MAX_WIND_SPEED,
        );
        imgui::checkbox("Gusts", &wind.gust);
    }
    imgui::end();
}

fn void? draw_frame(
    Renderer* renderer,
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

fn void? run_interactive(Options options) @local {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d vegetation", options.width, options.height))!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      renderer_desc(options, true, "c3d_vegetation"),
    )!;
    defer render::destroy_renderer(&renderer);
    Scene scene = create_demo_scene(options);
    defer scene::destroy_scene(&scene);
    terrain::register_terrain(&scene, &assets)!;
    foliage::register_foliage(&scene)!;

    Demo demo = build_demo(options, &assets, &scene)!;
    render::configure_view(&renderer, renderer.default_view, configure_desc(render::default_view_desc(), options))!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    FlyCamera fly_camera = { .position = extent_point(&demo, demo.meadow), .yaw = meadow_yaw(&demo) };
    WindControls wind = { .heading_degrees = WIND_HEADING_DEGREES, .speed = STEADY_WIND_SPEED };
    renderer.prepare_scene(&scene)!;
    Brush brush;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        HeightView view = terrain::height_view(&scene, &assets, demo.ground.node.id)!;
        if (!input.keyboard_captured_by_gui) {
            if (input.key_pressed(platform::Scancode.F)) fly_camera.flying = !fly_camera.flying;
            float rise = brush.rise(input.key_down(platform::Scancode.B), delta);
            if (rise > 0) {
                landscape_ground::stamp_under(
                    scene:        &scene,
                    assets:       &assets,
                    terrain_node: demo.ground.node,
                    position:     fly_camera.position,
                    rise:         rise,
                )!;
            }
        }
        landscape_ground::apply_fly_camera(
            fly_camera: &fly_camera,
            input:      input,
            view:       &view,
            delta:      delta,
        );
        landscape_ground::place_camera(
            camera_node: demo.camera_node,
            position:    fly_camera.position,
            yaw:         fly_camera.yaw,
            pitch:       fly_camera.pitch,
        );
        scene.update_world();
        terrain::update(
            scene:                &scene,
            assets:               &assets,
            camera_node:          demo.camera_node,
            output_height_pixels: (float)max(renderer.output_height, 1u),
        )!;
        foliage::update(&scene, &assets, controls_wind(&wind, window.clock.total))!;

        vegetation_panel(
            demo:     &demo,
            renderer: &renderer,
            wind:     &wind,
            delta:    delta,
        );
        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(&renderer)!;
        gui_renderer.finish_frame();

        platform::sync_window(&window, &renderer);
        draw_frame(
            renderer:     &renderer,
            scene:        &scene,
            camera_node:  demo.camera_node,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = delta },
        )!;
    }
}

// ----------------------------------------------------------------------------- benchmark

fn void? pose_segment(
    Demo* demo,
    Segment segment,
    uint step,
    uint segment_frames,
) @local {
    HeightView view = terrain::height_view(demo.scene, demo.assets, demo.ground.node.id)!;
    float seconds = (float)step * TIME_STEP;
    float yaw = meadow_yaw(demo);
    Vec3 heading = landscape_ground::look_direction(yaw, 0);
    Vec3 position = extent_point(demo, demo.meadow);
    float altitude = EYE_HEIGHT;
    float pitch = LOOK_PITCH;
    switch (segment) {
        case STILL:
        case GUST:
            break;
        case SPIN:
            yaw += 2 * (float)math::PI * (float)step / (float)segment_frames;
        case WALK:
            position += heading * (WALK_SPEED * seconds);
        case FAR:
            position = extent_point(demo, FAR_POSITION);
            Vec3 centre = extent_point(demo, { 0.5f, 0.5f });
            yaw = math::atan2(centre.x - position.x, centre.z - position.z);
            altitude = FAR_ALTITUDE;
            pitch = FAR_PITCH;
        case EDIT:
            position += heading * (EDIT_SPEED * seconds);
            altitude = EDIT_ALTITUDE;
            pitch = EDIT_PITCH;
    }
    position.y = landscape_ground::ground_under(&view, position, 0) + altitude;
    landscape_ground::place_camera(
        camera_node: demo.camera_node,
        position:    position,
        yaw:         yaw,
        pitch:       pitch,
    );
}

fn void? render_offscreen(
    Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    ViewId view,
    uint frame,
) @local {
    renderer.begin_frame({ .time = (double)frame * TIME_STEP, .delta = TIME_STEP })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(scene, camera_node, view)!;
    renderer.finish_view(view)!;
    return renderer.end_frame();
}

fn ulong cell_revision_sum(Demo* demo) @local {
    ulong sum;
    foreach (&layer : active_layers(demo)) {
        foreach (cell : demo.scene.get(layer.node, FoliageRuntime).cells) {
            if (cell.generation) sum += demo.scene.world.get(cell, InstancedMesh).revision;
        }
    }
    return sum;
}

fn uint placed_cells(Demo* demo) @local {
    uint placed;
    foreach (&layer : active_layers(demo)) placed += demo.scene.get(layer.node, FoliageRuntime).placed_cells;
    return placed;
}

// The terrain's slot is left out: the formula it is checked against counts cells only.
fn uint batch_slots_held(Demo* demo, Renderer* renderer) @local {
    uint held;
    foreach (&slot : renderer.instances.slots) {
        if (slot.key.scene && !c3d::same_id(slot.key.node, demo.ground.node.id)) held++;
    }
    return held;
}

fn uint slot_formula(Demo* demo) @local {
    float travel = WALK_SPEED * (float)(render::INSTANCE_ABSENCE_FRAMES + 1) / (float)FRAMES_PER_SECOND;
    uint slots;
    foreach (&layer : active_layers(demo)) {
        FoliageDesc* desc = &layer.desc;
        if (desc.fade.end == 0) {
            slots += grid_cells(demo.ground.extent, desc.cell_size);
            continue;
        }
        slots += batch_formula(
            fade_end:  desc.fade.end,
            reach:     layer.reach,
            travel:    travel,
            cell_size: desc.cell_size,
        );
    }
    return slots;
}

fn bool has_node(MeshCandidate[] candidates, Node* node) @local {
    foreach (&candidate : candidates) {
        if (candidate.node == node) return true;
    }
    return false;
}

fn bool has_near_instance(
    Node* cell,
    InstancedMesh* batch,
    Vec3 base_centre,
    Vec3 camera_position,
) @local {
    if (batch.fade.end == 0) return batch.count > 0;
    for (uint index = 0; index < batch.count; index++) {
        Mat4 model = cell.world.mul(batch.transforms[index].to_mat4());
        if (maths::transform_point(model, base_centre).distance(camera_position) <= batch.fade.end) return true;
    }
    return false;
}

// No possibly visible instance was dropped: the fade skip keeps every cell with an instance inside the band.
fn bool check_faded_cells(Demo* demo, Renderer* renderer) @local {
    bool fading;
    foreach (&layer : active_layers(demo)) fading = fading || layer.desc.fade.end > 0;
    if (fading && !renderer.stats.batches_faded) return false;

    Scene* scene = demo.scene;
    Camera* lens = scene.get(demo.camera_node, Camera);
    Vec2 viewport = { (float)demo.options.width, (float)demo.options.height };
    CameraMatrices matrices = camera::derive_matrices(*lens, demo.camera_node.world, viewport);
    @pool() {
        ExtractCounts counts;
        MeshCandidate[] candidates = render::extract_candidates(
            allocator: tmem,
            scene:     scene,
            assets:    demo.assets,
            camera:    &matrices,
            layers:    lens.layers,
            counts:    &counts,
        );
        if (counts.batches_faded != renderer.stats.batches_faded) return false;
        ExtractCounts caster_counts;
        MeshCandidate[] casters = render::extract_shadow_candidates(
            allocator:   tmem,
            scene:       scene,
            assets:      demo.assets,
            fade_origin: matrices.position,
            counts:      &caster_counts,
        );
        foreach (&layer : active_layers(demo)) {
            Aabb bounds = demo.assets.geometry(layer.desc.geometry).data.bounds;
            Vec3 centre = (bounds.min + bounds.max) * 0.5f;
            Vec3 base_centre = { centre.x, bounds.min.y, centre.z };
            foreach (cell : scene.get(layer.node, FoliageRuntime).cells) {
                if (!cell.generation) continue;
                Node* node = scene.node(cell);
                InstancedMesh* batch = scene.get(node, InstancedMesh);
                bool near = has_near_instance(
                    cell:            node,
                    batch:           batch,
                    base_centre:     base_centre,
                    camera_position: matrices.position,
                );
                if (!near) continue;
                Aabb world = spatial::instanced_world_bounds(demo.assets, node, batch);
                bool in_view = maths::frustum_intersects_aabb(&matrices.frustum, world);
                if (in_view && !has_node(candidates, node)) return false;
                if (batch.cast_shadow && !has_node(casters, node)) return false;
            }
        }
    };
    return true;
}

fn void? run_segments(
    Demo* demo,
    Renderer* renderer,
    ViewId view,
    BenchmarkResult* result,
) @local {
    Options options = demo.options;
    uint frames = options.segment_frames;
    uint measured = Segment::len * frames;
    float output_height = (float)options.height;
    Vec3 steady_wind = wind_velocity(STEADY_WIND_SPEED, WIND_HEADING_DEGREES);

    for (uint frame = 0; frame < WARMUP_FRAMES + measured + render::FRAMES_IN_FLIGHT; frame++) {
        bool timed = frame >= WARMUP_FRAMES && frame < WARMUP_FRAMES + measured;
        uint step = timed ? frame - WARMUP_FRAMES : 0;
        Segment segment = Segment.STILL;
        if (timed) segment = Segment::from_ordinal(step / frames);
        if (frame >= WARMUP_FRAMES + measured) segment = Segment.EDIT;
        uint segment_step = timed ? step % frames : frames - 1;
        time::Clock frame_started = clock::now();
        pose_segment(
            demo:           demo,
            segment:        segment,
            step:           segment_step,
            segment_frames: frames,
        )!;
        bool stamped = timed && segment == Segment.EDIT && segment_step % STAMP_PERIOD == 0;
        if (stamped) {
            landscape_ground::stamp_under(
                scene:        demo.scene,
                assets:       demo.assets,
                terrain_node: demo.ground.node,
                position:     demo.camera_node.local.position,
                rise:         landscape_ground::BRUSH_RISE,
            )!;
        }

        demo.scene.update_world();
        terrain::update(
            scene:                demo.scene,
            assets:               demo.assets,
            camera_node:          demo.camera_node,
            output_height_pixels: output_height,
        )!;
        Vec3 wind = steady_wind;
        if (segment == Segment.GUST) {
            wind = wind_velocity(STEADY_WIND_SPEED * gust_share((double)frame * TIME_STEP), WIND_HEADING_DEGREES);
        }
        ulong revisions = cell_revision_sum(demo);
        time::Clock update_started = clock::now();
        foliage::update(demo.scene, demo.assets, wind)!;
        double update_us = (double)(long)update_started.to_now() / NANOSECONDS_PER_MICROSECOND;
        render_offscreen(
            renderer:    renderer,
            scene:       demo.scene,
            camera_node: demo.camera_node,
            view:        view,
            frame:       frame,
        )!;
        double frame_ms = elapsed_ms(frame_started);
        if (frame == 0) result.first_pack_ms = renderer.stats.cpu_record_ms;

        if (timed) {
            result.records[step] = {
                .cpu_record_ms     = renderer.stats.cpu_record_ms,
                .update_us         = update_us,
                .frame_ms          = frame_ms,
                .batches_faded     = renderer.stats.batches_faded,
                .upload_bytes      = renderer.stats.upload_bytes,
                .instances_tested  = renderer.stats.instances_tested,
                .instances_visible = renderer.stats.instances_visible,
                .placed_cells      = placed_cells(demo),
                .cells_revised     = cell_revision_sum(demo) != revisions,
                .stamped           = stamped,
            };
            result.batch_slots_max = max(result.batch_slots_max, batch_slots_held(demo, renderer));
            if (segment == Segment.FAR && !check_faded_cells(demo, renderer)) result.faded_cells_exact = false;
        }
        // A frame's GPU timings arrive once its slot comes round again.
        if (frame >= WARMUP_FRAMES + render::FRAMES_IN_FLIGHT) {
            uint completed = frame - render::FRAMES_IN_FLIGHT - WARMUP_FRAMES;
            if (completed < measured) result.records[completed].gpu_ms = renderer.stats.gpu_pass_ms;
        }
    }
}

fn void print_median_p99(String label, String segment_name, double[] samples) @local {
    io::printfn(
        "%s segment=%s median=%.4f p99=%.4f",
        label,
        segment_name,
        percentile(samples, 0.5f),
        percentile(samples, 0.99f),
    );
}

fn void print_edit_results(FrameRecord[] edit, double[] scratch) @local {
    usz stamps;
    foreach (record : edit) {
        if (!record.stamped) continue;
        scratch[stamps] = record.update_us / MICROSECONDS_PER_MILLISECOND;
        stamps++;
    }
    double replace_median = percentile(scratch[:stamps], 0.5f);
    double replace_p99 = percentile(scratch[:stamps], 0.99f);
    stamps = 0;
    foreach (record : edit) {
        if (!record.stamped) continue;
        scratch[stamps] = (double)record.placed_cells;
        stamps++;
    }
    io::printfn(
        "replace_ms median=%.4f p99=%.4f placed_cells_median=%.0f",
        replace_median,
        replace_p99,
        percentile(scratch[:stamps], 0.5f),
    );
}

fn bool print_results(Demo* demo, BenchmarkResult* result) @local {
    uint frames = demo.options.segment_frames;
    io::printfn("rescatter_ms %.4f", result.rescatter_ms);
    io::printfn("first_pack_ms %.4f", result.first_pack_ms);
    io::printfn("batch_slots max=%d formula=%d", result.batch_slots_max, slot_formula(demo));
    print_edit_results(result.records[Segment.EDIT.ordinal * frames:frames], result.scratch);

    bool steady_gate = true;
    foreach (ordinal, name : SEGMENT_NAMES) {
        Segment segment = Segment::from_ordinal(ordinal);
        FrameRecord[] records = result.records[ordinal * frames:frames];
        print_median_p99("cpu_record_ms", name, gather(records, CPU_RECORD_MS, result.scratch));
        double[] faded = gather(records, BATCHES_FADED, result.scratch);
        io::printfn(
            "batches_faded segment=%s median=%.0f max=%.0f",
            name,
            percentile(faded, 0.5f),
            percentile(faded, 1.0f),
        );
        print_median_p99("update_us", name, gather(records, UPDATE_US, result.scratch));
        double[] uploads = gather(records, UPLOAD_BYTES, result.scratch);
        io::printfn(
            "upload_bytes segment=%s median=%.0f max=%.0f",
            name,
            percentile(uploads, 0.5f),
            percentile(uploads, 1.0f),
        );

        uint upload_frames;
        uint revised_frames;
        foreach (index, record : records) {
            if (record.upload_bytes) upload_frames++;
            if (index > 0 && record.cells_revised) revised_frames++;
            if (segment == Segment.STILL && index > 0 && record.upload_bytes) steady_gate = false;
        }
        io::printfn("upload_frames segment=%s %d", name, upload_frames);
        if (segment == Segment.STILL || segment == Segment.SPIN) {
            io::printfn("cell_revisions segment=%s %d", name, revised_frames);
            if (revised_frames) steady_gate = false;
        }
        double tested = percentile(gather(records, INSTANCES_TESTED, result.scratch), 0.5f);
        double visible = percentile(gather(records, INSTANCES_VISIBLE, result.scratch), 0.5f);
        io::printfn("instances segment=%s tested_median=%.0f visible_median=%.0f", name, tested, visible);
        if (result.timestamps) {
            foreach (pass : REPORTED_PASSES) {
                double median = percentile(gather_pass(records, pass, result.scratch), 0.5f);
                io::printfn("gpu_ms segment=%s pass=%s median=%.4f", name, pass, median);
            }
        }
        print_median_p99("frame_ms", name, gather(records, FRAME_MS, result.scratch));
    }
    io::printfn("gate steady_wind_uploads %s", steady_gate ? "pass" : "fail");
    io::printfn("gate faded_cells_exact %s", result.faded_cells_exact ? "pass" : "fail");
    return steady_gate && result.faded_cells_exact;
}

fn String foliage_name(FoliageChoice choice) @local {
    switch (choice) {
        case BOTH: return "both";
        case GRASS: return "grass";
        case NONE: return "none";
    }
}

fn void print_header(Demo* demo, uint max_instance_batches) @local {
    Options options = demo.options;
    uint grass_cells = options.foliage != NONE ? grid_cells(demo.ground.extent, foliage::DEFAULT_CELL_SIZE) : 0;
    uint tree_cells = options.foliage == BOTH ? grid_cells(demo.ground.extent, landscape_foliage::TREE_CELL_SIZE) : 0;
    io::printfn(
        "# vegetation size=%d shading=%s shadows=%s foliage=%s tree_fade_end=%g extent=%dx%d frames=%d "
          "grass_cells=%d tree_cells=%d max_nodes=%d max_instance_batches=%d",
        options.size,
        options.shading == ShadingPath.DEFERRED ? "deferred" : "forward",
        options.traced_shadows ? "traced" : "atlas",
        foliage_name(options.foliage),
        options.tree_fade_end,
        options.width,
        options.height,
        options.segment_frames,
        grass_cells,
        tree_cells,
        scene_node_budget(options, demo.ground.extent),
        max_instance_batches,
    );
    foreach (&layer : active_layers(demo)) {
        FoliageRuntime* runtime = demo.scene.get(layer.node, FoliageRuntime);
        io::printfn(
            "scatter_ms load layer=%s %.3f instances=%d cell_nodes=%d spacing=%.3f",
            layer.name,
            layer.scatter_ms,
            runtime.instances,
            runtime.cell_nodes,
            layer.desc.rules.spacing,
        );
    }
}

fn bool? run_benchmark(Options options) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    RendererDesc desc = renderer_desc(options, options.validation, "c3d_vegetation_benchmark");
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      desc,
    )!;
    defer render::destroy_renderer(&renderer);
    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc:     render::render_target_desc(options.width, options.height, PixelFormat.RGBA8_UNORM),
    )!;
    ViewId view = render::create_view(
        renderer: &renderer,
        desc:     configure_desc(render::texture_view_desc(target, OutputMode.DISPLAY_LDR), options),
    )!;
    Scene scene = create_demo_scene(options);
    defer scene::destroy_scene(&scene);
    terrain::register_terrain(&scene, &assets)!;
    foliage::register_foliage(&scene)!;

    Demo demo = build_demo(options, &assets, &scene)!;
    print_header(&demo, desc.max_instance_batches);
    pose_segment(
        demo:           &demo,
        segment:        Segment.STILL,
        step:           0,
        segment_frames: options.segment_frames,
    )!;
    scene.update_world();

    uint measured = Segment::len * options.segment_frames;
    BenchmarkResult result = {
        .records           = alloc::new_array(mem, FrameRecord, (sz)measured),
        .scratch           = alloc::new_array(mem, double, (sz)measured),
        .faded_cells_exact = true,
        .timestamps        = renderer.timestamps_enabled,
    };
    defer alloc::free(mem, result.records.ptr);
    defer alloc::free(mem, result.scratch.ptr);
    renderer.prepare_scene(&scene)!;

    assets.mark_texture_dirty(demo.ground.desc.control_map);
    time::Clock rescatter_started = clock::now();
    foliage::update(&scene, &assets, wind_velocity(STEADY_WIND_SPEED, WIND_HEADING_DEGREES))!;
    result.rescatter_ms = elapsed_ms(rescatter_started);

    run_segments(
        demo:     &demo,
        renderer: &renderer,
        view:     view,
        result:   &result,
    )!;
    render::wait_frames(&renderer)!;
    return print_results(&demo, &result);
}

<* View vegetation over a generated terrain interactively, or run the scripted benchmark. *>
fn int main(String[] args) {
    Options? parsed = parse_options(args);
    if (catch excuse = parsed) {
        if (excuse != c3d::UNSUPPORTED) {
            io::eprintfn("Invalid options: %s", excuse);
            io::eprintn("Use [--benchmark [frames]] [--gpu-timings] [--validation] [--shading forward|deferred] "
              "[--shadows atlas|traced] [--size 1025|2049|4097] [--foliage both|grass|none] "
              "[--tree-fade-end METRES] [--width W] [--height H].");
        }
        return 1;
    }
    Options options = parsed;
    if (!options.benchmark) {
        if (catch excuse = run_interactive(options)) {
            io::eprintfn("vegetation example failed: %s", excuse);
            return 1;
        }
        return 0;
    }
    bool? gates = run_benchmark(options);
    if (catch excuse = gates) {
        io::eprintfn("vegetation benchmark failed: %s", excuse);
        return 1;
    }
    return gates ? 0 : 1;
}
