module terrain_example;

import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;
import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::landscape::terrain;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::spatial;
import imgui;
import landscape_ground;

const uint AUTO_TRACE_LEVEL @local = uint::max; // the finest trace level a terrain of the chosen size can pose
const uint CRATE_CAPACITY @local = 256; // one node and one body each; the scene capacity lever
const uint SCENE_NODE_CAPACITY @local = CRATE_CAPACITY + 16; // the collision windows' nodes come on top
const uint COLLISION_WINDOW_CELLS @local = 256; // 65 k samples per window: one stroke re-cooks a few of them, not the map
const uint SNAPSHOT_HEADROOM @local = 16; // slots beside two generations of every window's cooked field
const float CRATE_SIZE @local = 1;
const float CRATE_DROP_HEIGHT @local = 8; // metres above the ground a crate starts from
const float CRATE_DROP_DISTANCE @local = 6; // metres in front of the camera
const float DECAL_DISTANCE @local = 12; // metres in front of the start pose
const Vec3 DECAL_SIZE @local = { 10, 10, 24 }; // metres; local z is the projection axis, deep enough to span the slope
const Vec4 DECAL_COLOR @local = { 0.9f, 0.15f, 0.1f, 1 };
const uint CRATE_STACK_SIDE @local = 3; // the benchmark drops a 3 x 3 grid of casters in the still view
const float CRATE_STACK_SPACING @local = 3;
const float CRATE_MASS @local = CRATE_SIZE * CRATE_SIZE * CRATE_SIZE * physics::DEFAULT_DENSITY; // default density
const float PUSH_SPEED @local = 6; // m/s a click adds to a crate: a visible toss of a few metres
const float PICK_DISTANCE @local = 500;
const float PHYSICS_RAY_START @local = 400; // above HEIGHT_SCALE, so the ray starts over every ridge
const float PHYSICS_RAY_LENGTH @local = 800;
const float CAMERA_FOV_DEGREES @local = 60;
const float CAMERA_NEAR @local = 0.5f;
const float CAMERA_FAR @local = 8000; // covers the 4 km diagonal of the largest map from its middle
const uint WINDOW_WIDTH @local = 1600;
const uint WINDOW_HEIGHT @local = 900;
const uint BENCHMARK_WIDTH @local = 2560;
const uint BENCHMARK_HEIGHT @local = 1440;
const uint DEFAULT_SEGMENT_FRAMES @local = 300;
const uint WARMUP_FRAMES @local = 60; // history, caches and the first uploads settle before the timed frames
const uint FRAMES_PER_SECOND @local = 60;
const float TIME_STEP @local = 1.0f / FRAMES_PER_SECOND;
const uint BOUNDS_BUILD_RUNS @local = 5;
const uint STAMP_PERIOD @local = 30; // frames between brush stamps in the edit segment
const float STILL_ALTITUDE @local = 40;
const float SWEEP_ALTITUDE @local = 20;
const float EDIT_ALTITUDE @local = 60;
const float STILL_YAW @local = (float)math::PI * 0.25f; // towards the middle of the map
const float SWEEP_PITCH @local = -0.12f;
const float EDIT_PITCH @local = -0.8f; // looks down at the brush stamps
const float HOVER_BOB @local = 0.05f; // of the hover distance; a size ratio of 1.105 fits the 1.25 band
const Vec2 STILL_POSITION @local = { 0.3f, 0.3f };
const Vec2 SWEEP_START @local = { 0.1f, 0.15f };
const Vec2 SWEEP_END @local = { 0.9f, 0.85f };
const Vec2 EDIT_START @local = { 0.55f, 0.45f };
const Vec2 EDIT_END @local = { 0.6f, 0.5f };
const Vec2 PANEL_POSITION @local = { 16, 16 };
const Vec2 PANEL_SIZE @local = { 420, 360 };
const Vec2 STATS_PANEL_POSITION @local = { 16, 392 };
const Vec2 STATS_PANEL_SIZE @local = { 420, 300 };
const float LOD_THRESHOLD_MAX @local = 2048;
const float MORPH_MIN_THRESHOLD @local = 1; // pixels: the panel's smallest threshold while morphing
const float MORPH_BAND @local = 0.25f; // --morph: within the default hysteresis's limit of 0.375
const double NANOSECONDS_PER_MICROSECOND @local = 1_000;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const double MICROSECONDS_PER_MILLISECOND @local = 1_000;
const Vec2 CAPTURE_TARGET @local = { 0.5f, 0.4595f }; // on the x seam, where the default map's edge texels bend most
const float CAPTURE_HEIGHT @local = 24; // metres above the target; the camera looks straight down at it
const uint CAPTURE_SETTLE_FRAMES @local = 8; // uploads and the shadow cascades settle on a still camera
const uint RGBA8_BYTES @local = 4;
const String[Segment::len] SEGMENT_NAMES @local = { "still", "sweep", "hover", "edit" };

const Pass[8] REPORTED_PASSES @local = {
    Pass.DEPTH_PREPASS,
    Pass.GBUFFER,
    Pass.SHADOW_ATLAS,
    Pass.FORWARD_OPAQUE,
    Pass.LIGHTING,
    Pass.VELOCITY,
    Pass.INSTANCE_CULL,
    Pass.UPLOADS,
};

const Pass[5] SKY_PASSES @local = {
    Pass.SKY_VIEW,
    Pass.AERIAL_PERSPECTIVE,
    Pass.FOG_SCATTERING,
    Pass.FOG_INTEGRATION,
    Pass.FOG,
};

enum Segment @local {
    STILL,
    SWEEP,
    HOVER,
    EDIT,
}

enum Metric @local {
    UPDATE_US,
    FRAME_MS,
    DRAWN,
    UPLOAD_BYTES,
}

struct Options @local {
    bool        benchmark;
    uint        segment_frames;
    bool        gpu_timings;
    bool        validation;
    ShadingPath shading;
    bool        traced_shadows;
    uint        trace_level;
    bool        sky;
    bool        volumetric_fog;
    uint        size;
    uint        layers;
    float       lod_threshold;
    float       morph_band;
    bool        triplanar;
    uint        width;
    uint        height;
    bool        hide_terrain;
    bool        tiles;
    uint        collision_window;
    String      capture;
}

struct Demo @local {
    Options       options;
    AssetStore*   assets;
    Scene*        scene;
    PhysicsWorld* physics;
    Ground        ground;
    Node*         camera_node;
    GeometryId    crate_geometry;
    MaterialId    crate_material;
    uint          crate_count;
    Node*         decal_node;
    TexelRect[landscape_ground::TILE_COUNT] edited_texels; // per Ground.terrain_nodes entry: what a stroke changed
}

struct HoverPose @local {
    Vec3  center;
    float distance;
}

struct FrameRecord @local {
    double                    update_us;
    double                    frame_ms;
    uint                      drawn;
    uint                      upload_bytes;
    bool                      batch_changed;
    bool                      stamped;
    float[render::PASS_COUNT] gpu_ms;
}

struct BenchmarkResult @local {
    FrameRecord[] records;
    double[]      scratch;
    double        bounds_build_ms;
    double        physics_recook_ms;
    double        physics_whole_recook_ms;
    uint          physics_recook_windows;
    bool          timestamps;
}

// The node's transform places the collider and the drawn surface alike.
fn void? add_terrain_collider(Demo* demo, Node* node) @local {
    TerrainCollisionInput input = terrain::collision_input(demo.scene, node.id)!;
    ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
    collider.height_field = { .source = TEXTURE, .texture = input.height_map };
    collider.local.scale = input.scale;
    if (!demo.options.collision_window) {
        return demo.physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1]);
    }

    return physics::add_height_field_windows(
        scene:        demo.scene,
        assets:       demo.assets,
        node:         node.id,
        collider:     &collider,
        window_cells: demo.options.collision_window,
    );
}

fn void? add_terrain_colliders(Demo* demo) @local {
    foreach (node : demo.ground.terrain_nodes()) {
        add_terrain_collider(demo, node)!;
    }
}

fn void remove_terrain_colliders(Demo* demo) @local {
    foreach (node : demo.ground.terrain_nodes()) {
        if (demo.options.collision_window) {
            physics::remove_height_field_windows(demo.scene, node.id);
        } else {
            demo.physics.remove_body(node);
        }
    }
}

fn bool has_terrain_colliders(Demo* demo) @local {
    Node* node = demo.ground.terrain_nodes()[0];
    if (demo.options.collision_window) return demo.scene.has(node, HeightFieldWindows);

    return demo.scene.has(node, PhysicsBody);
}

// One node per window of every terrain.
fn uint collision_window_count(Options options) @local {
    if (!options.collision_window) return 0;

    uint texels = options.tiles ? (options.size - 1) / landscape_ground::TILES_PER_SIDE + 1 : options.size;
    uint terrains = options.tiles ? landscape_ground::TILE_COUNT : 1;
    uint per_side = (texels - 1 + options.collision_window - 1) / options.collision_window;
    return terrains * per_side * per_side;
}

fn Scene create_demo_scene(Options options) @local {
    return scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY + collision_window_count(options) });
}

fn PhysicsDesc physics_desc(Options options) @local {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.snapshot_capacity = max(desc.snapshot_capacity, 2 * collision_window_count(options) + SNAPSHOT_HEADROOM);
    return desc;
}

fn HeightView? ground_view(Demo* demo, Vec3 position) @local {
    return terrain::height_view(demo.scene, demo.assets, demo.ground.terrain_at(position).id);
}

fn Demo? build_demo(
    Options options,
    AssetStore* assets,
    Scene* scene,
    PhysicsWorld* physics,
) @local {
    uint texels = options.tiles ? (options.size - 1) / landscape_ground::TILES_PER_SIDE + 1 : options.size;
    uint trace_level = options.trace_level;
    if (trace_level == AUTO_TRACE_LEVEL) trace_level = landscape_ground::finest_trace_level(texels);

    Ground ground;
    if (options.tiles) {
        ground = landscape_ground::add_ground_tiles(
            scene:            scene,
            assets:           assets,
            size:             options.size,
            layers:           options.layers,
            lod_threshold:    options.lod_threshold,
            morph_band:       options.morph_band,
            slope_projection: options.triplanar ? SlopeProjection.TRIPLANAR : SlopeProjection.TOP,
            trace:            options.traced_shadows,
            trace_level:      trace_level,
        )!;
    } else {
        ground = landscape_ground::add_ground(
            scene:            scene,
            assets:           assets,
            size:             options.size,
            layers:           options.layers,
            lod_threshold:    options.lod_threshold,
            morph_band:       options.morph_band,
            slope_projection: options.triplanar ? SlopeProjection.TRIPLANAR : SlopeProjection.TOP,
            trace:            options.traced_shadows,
            trace_level:      trace_level,
        )!;
    }
    ground.node.visible = !options.hide_terrain;
    Demo demo = {
        .options = options,
        .assets  = assets,
        .scene   = scene,
        .physics = physics,
        .ground  = ground,
    };
    add_terrain_colliders(&demo)!;

    @pool() {
        Geometry crate = geometry::box(tmem, CRATE_SIZE, CRATE_SIZE, CRATE_SIZE);
        demo.crate_geometry = assets.add_geometry(&crate, "terrain/crate")!;
    };
    StandardParams crate_params = material::STANDARD_PARAMS_DEFAULT;
    crate_params.base_color = { 0.7f, 0.45f, 0.2f, 1 };
    crate_params.metallic = 0;
    crate_params.roughness = 0.7f;
    demo.crate_material = assets.add_material(material::standard(crate_params), "terrain/crate_material")!;

    landscape_ground::add_sun_and_sky(scene, options.traced_shadows, options.sky)!;

    demo.camera_node = scene.add_camera(
        camera::perspective_deg(CAMERA_FOV_DEGREES, CAMERA_NEAR, CAMERA_FAR),
        name: "camera",
    )!;
    scene.update_world();
    return demo;
}

fn void drop_crate(Demo* demo, Vec3 position) @local {
    if (demo.crate_count == CRATE_CAPACITY) return;
    Node*? added = demo.scene.add_mesh(demo.crate_geometry, demo.crate_material, name: "crate");
    if (catch added) return;
    Node* node = added;
    node.local.position = position;
    demo.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = { CRATE_SIZE * 0.5f, CRATE_SIZE * 0.5f, CRATE_SIZE * 0.5f };
    if (catch excuse = demo.physics.add_body(node, physics::default_body_desc(DYNAMIC), (&collider)[:1])) {
        io::eprintfn("terrain: a crate has no body (%s)", excuse);
        demo.scene.remove(node);
        return;
    }
    demo.crate_count++;
}

fn void? add_ground_decal(Demo* demo, Vec3 position) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = DECAL_COLOR;
    params.roughness = 0.9f;
    DecalDesc desc = scene::default_decal_desc(demo.assets.add_material(material::standard(params), "terrain/decal")!);
    desc.size = DECAL_SIZE;
    desc.decal.weights = { .base_color = 1, .normal = 0, .roughness = 0, .metallic = 0 };
    demo.decal_node = demo.scene.add_decal(desc, name: "decal")!;
    demo.decal_node.local.position = position;
    demo.decal_node.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 }); // local z points up
    demo.scene.update_world();
}

fn Vec3 extent_point(Demo* demo, Vec2 fraction) @local {
    return { fraction.x * demo.ground.extent, 0, fraction.y * demo.ground.extent };
}

// Collision follows a stroke once it ends: the next update re-cooks the windows it touched, or the whole field.
fn void? end_stroke(Demo* demo) @local {
    foreach (index, node : demo.ground.terrain_nodes()) {
        TexelRect edited = demo.edited_texels[index];
        if (!edited.columns) continue;

        demo.edited_texels[index] = {};
        if (demo.options.collision_window) {
            if (!demo.scene.has(node, HeightFieldWindows)) continue;

            SampleRect samples = { .x = edited.x, .z = edited.z, .columns = edited.columns, .rows = edited.rows };
            (void)physics::mark_height_field_windows_changed(demo.scene, node.id, samples)!;
        } else if (demo.scene.has(node, PhysicsBody)) {
            demo.scene.get(node, PhysicsBody).mark_changed();
        }
    }
}

fn ViewDesc configure_desc(ViewDesc desc, Options options) @local {
    desc.shading = options.shading;
    desc.post.anti_aliasing = AntiAliasing.TAA;
    desc.ray_tracing.shadows = options.traced_shadows;
    desc.volumetric_fog = options.volumetric_fog;
    return desc;
}

fn double percentile(double[] samples, float share) @local {
    if (!samples.len) return 0;
    sort::quicksort(samples);
    return samples[(usz)math::round(share * (float)(samples.len - 1))];
}

fn double metric_value(FrameRecord* record, Metric metric) @local {
    switch (metric) {
        case UPDATE_US: return record.update_us;
        case FRAME_MS: return record.frame_ms;
        case DRAWN: return (double)record.drawn;
        case UPLOAD_BYTES: return (double)record.upload_bytes;
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

fn String? option_value(String[] args, usz* index) @local {
    if (*index + 1 >= args.len) return c3d::INVALID_ARGUMENT~;
    (*index)++;
    return args[*index];
}

fn Options? parse_options(String[] args) @local {
    Options options = {
        .segment_frames   = DEFAULT_SEGMENT_FRAMES,
        .shading          = ShadingPath.FORWARD,
        .size             = landscape_ground::DEFAULT_MAP_SIZE,
        .layers           = landscape_ground::LAYER_COUNT,
        .lod_threshold    = terrain::DEFAULT_LOD_THRESHOLD,
        .trace_level      = AUTO_TRACE_LEVEL,
        .collision_window = COLLISION_WINDOW_CELLS,
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
                    io::eprintn("--gpu-timings needs GPU profiling: python3 scripts/build.py --target terrain --opt O3 "
                      "--define C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib c3d_profile");
                    return c3d::UNSUPPORTED~;
                $endif
            case "--validation": options.validation = true;
            case "--hide-terrain": options.hide_terrain = true;
            case "--capture": options.capture = option_value(args, &index)!;
            case "--tiles":
                switch (option_value(args, &index)!) {
                    case "2x2": options.tiles = true;
                    default: return c3d::INVALID_ARGUMENT~;
                }
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
            case "--layers":
                options.layers = option_value(args, &index)!.to_uint()!;
                if (options.layers != 1 && options.layers != landscape_ground::LAYER_COUNT) {
                    return c3d::INVALID_ARGUMENT~;
                }
            case "--trace-level":
                options.trace_level = option_value(args, &index)!.to_uint()!;
            case "--lod-threshold":
                options.lod_threshold = option_value(args, &index)!.to_float()!;
                if (!(options.lod_threshold >= 0)) return c3d::INVALID_ARGUMENT~;
            case "--morph": options.morph_band = MORPH_BAND;
            case "--triplanar": options.triplanar = true;
            case "--collision-window": options.collision_window = option_value(args, &index)!.to_uint()!;
            case "--sky": options.sky = true;
            case "--volumetric-fog": options.volumetric_fog = true;
            case "--width": options.width = option_value(args, &index)!.to_uint()!;
            case "--height": options.height = option_value(args, &index)!.to_uint()!;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    if (options.morph_band > 0 && !(options.lod_threshold > 0)) return c3d::INVALID_ARGUMENT~;
    if (options.volumetric_fog && !options.sky) return c3d::INVALID_ARGUMENT~;
    if (options.tiles && options.benchmark) return c3d::INVALID_ARGUMENT~;
    if (options.capture.len && options.benchmark) return c3d::INVALID_ARGUMENT~;
    if (!options.width) options.width = options.benchmark ? BENCHMARK_WIDTH : WINDOW_WIDTH;
    if (!options.height) options.height = options.benchmark ? BENCHMARK_HEIGHT : WINDOW_HEIGHT;
    return options;
}

// ----------------------------------------------------------------------------- interactive

fn void push_picked_crate(Demo* demo, Renderer* renderer, Vec2 pixel) @local {
    Vec2 viewport = { renderer.output_width, renderer.output_height };
    Camera* lens = demo.scene.get(demo.camera_node, Camera);
    CameraMatrices matrices = camera::derive_matrices(*lens, demo.camera_node.world, viewport);
    Ray ray = camera::screen_to_ray(&matrices, pixel, viewport);
    PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
    options.precision = PickPrecision.TRIANGLES;
    options.layers = camera::ALL_LAYERS & ~landscape_ground::TERRAIN_LAYER;
    @pool() {
        PickHit[] hits = spatial::pick(
            allocator: tmem,
            assets:    demo.assets,
            scene:     demo.scene,
            ray:       ray,
            options:   options,
        );
        if (!hits.len || hits[0].distance > PICK_DISTANCE) return;
        // A crate dropped this frame has no simulated body until the next physics update.
        if (!demo.scene.has(hits[0].node, RigidBody)) return;
        Vec3 direction = (ray.direction + (Vec3){ 0, 1, 0 }).normalize();
        demo.physics.apply_impulse(hits[0].node, direction * (CRATE_MASS * PUSH_SPEED), hits[0].position);
    };
}

fn void? terrain_panel(
    Demo* demo,
    Renderer* renderer,
    FlyCamera* fly_camera,
    float delta,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Terrain", null, {})) {
        imgui::text("Right drag looks, WASD move, Shift fast; F flies, Q and E sink and rise");
        imgui::text("G drops a crate, B paints, P toggles the collider, click pushes a crate");
        imgui::text("T toggles the ground decal");
        uint nodes;
        foreach (node : demo.ground.terrain_nodes()) nodes += demo.scene.get(node, InstancedMesh).count;
        imgui::text(
            "Nodes: %u   Drawn instances over all passes: %u   Fallbacks: %u",
            nodes,
            renderer.stats.instances_visible,
            renderer.stats.quadtree_fallbacks,
        );
        TerrainDesc first_desc = demo.scene.get(demo.ground.terrain_nodes()[0], Terrain).desc;
        float lod_threshold = first_desc.lod_threshold;
        float morph_band = first_desc.morph_band;
        imgui::slider_float(
            label: "LOD threshold",
            v:     &lod_threshold,
            v_min: 0,
            v_max: LOD_THRESHOLD_MAX,
        );
        imgui::slider_float(
            label: "Morph band",
            v:     &morph_band,
            v_min: 0,
            v_max: (1 - first_desc.lod_hysteresis) * 0.5f,
        );

        // Morphing needs a positive threshold.
        if (morph_band > 0) lod_threshold = math::max(lod_threshold, MORPH_MIN_THRESHOLD);
        foreach (node : demo.ground.terrain_nodes()) {
            TerrainDesc* desc = &demo.scene.get(node, Terrain).desc;
            desc.lod_threshold = lod_threshold;
            desc.morph_band = morph_band;
        }

        Vec3 position = fly_camera.position;
        HeightView view = ground_view(demo, position)!;
        if (try height = terrain::sample_height(&view, position.x, position.z)) {
            imgui::text("Terrain height %.3f m", height);
        } else {
            imgui::text("Off the terrain");
        }
        if (try normal = terrain::sample_normal(&view, position.x, position.z)) {
            imgui::text("Terrain normal %.3f %.3f %.3f", normal.x, normal.y, normal.z);
        }
        Vec3 ray_origin = { position.x, PHYSICS_RAY_START, position.z };
        if (try hit = demo.physics.raycast(ray_origin, { 0, -1, 0 }, PHYSICS_RAY_LENGTH)) {
            imgui::text("Physics ray height %.3f m", hit.point.y);
        } else {
            imgui::text("Physics ray: no hit");
        }
        imgui::text(
            "%s, collider %s, crates %u",
            fly_camera.flying ? "Flying" : "Walking",
            has_terrain_colliders(demo) ? "on" : "off",
            demo.crate_count,
        );
        imgui::text("Frame: %.2f ms", delta * 1000);
    }
    imgui::end();
    return;
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
        platform::default_window_desc("c3d terrain", options.width, options.height))!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      {
            .validation       = true,
            .gpu_timings      = options.gpu_timings,
            .application_name = "c3d_terrain",
            .ray_queries      = options.traced_shadows,
        },
    )!;
    defer render::destroy_renderer(&renderer);
    Scene scene = create_demo_scene(options);
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!;
    terrain::register_terrain(&scene, &assets)!;
    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      physics_desc(options),
    )!;
    defer physics::destroy_physics_world(&physics);

    Demo demo = build_demo(
        options: options,
        assets:  &assets,
        scene:   &scene,
        physics: &physics,
    )!;
    render::configure_view(&renderer, renderer.default_view, configure_desc(render::default_view_desc(), options))!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    FlyCamera fly_camera = { .position = extent_point(&demo, STILL_POSITION), .yaw = STILL_YAW };
    if (!options.benchmark) {
        Vec3 ahead = fly_camera.position + landscape_ground::look_direction(fly_camera.yaw, 0) * DECAL_DISTANCE;
        HeightView start_view = ground_view(&demo, ahead)!;
        ahead.y = landscape_ground::ground_under(&start_view, ahead, fly_camera.ground);
        add_ground_decal(&demo, ahead)!;
    }
    renderer.prepare_scene(&scene)!;
    Brush brush;
    bool painting;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        HeightView view = ground_view(&demo, fly_camera.position)!;
        if (!input.keyboard_captured_by_gui) {
            if (input.key_pressed(platform::Scancode.F)) fly_camera.flying = !fly_camera.flying;
            if (input.key_pressed(platform::Scancode.G)) {
                Vec3 heading = landscape_ground::look_direction(fly_camera.yaw, 0);
                Vec3 ahead = fly_camera.position + heading * CRATE_DROP_DISTANCE;
                HeightView ahead_view = ground_view(&demo, ahead)!;
                ahead.y = landscape_ground::ground_under(&ahead_view, ahead, fly_camera.ground) + CRATE_DROP_HEIGHT;
                drop_crate(&demo, ahead);
            }
            if (input.key_pressed(platform::Scancode.T) && demo.decal_node) demo.decal_node.visible = !demo.decal_node.visible;
            if (input.key_pressed(platform::Scancode.P)) {
                if (has_terrain_colliders(&demo)) {
                    remove_terrain_colliders(&demo);
                } else {
                    add_terrain_colliders(&demo)!;
                }
            }
            bool brush_held = input.key_down(platform::Scancode.B);
            float rise = brush.rise(brush_held, delta);
            if (rise > 0) {
                bool stamped = landscape_ground::stamp_ground(
                    scene:    &scene,
                    assets:   &assets,
                    ground:   &demo.ground,
                    position: fly_camera.position,
                    rise:     rise,
                    edited:   demo.edited_texels[..],
                )!;
                if (stamped) painting = true;
            }
            if (!brush_held && painting) {
                end_stroke(&demo)!;
                painting = false;
            }
        }
        if (!input.mouse_captured_by_gui && input.button_pressed(platform::MouseButton.LEFT)) {
            push_picked_crate(&demo, &renderer, input.mouse_position);
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
        physics.update(delta);
        scene.update_world();
        terrain::update(&scene, &assets)!;

        terrain_panel(
            demo:       &demo,
            renderer:   &renderer,
            fly_camera: &fly_camera,
            delta:      delta,
        )!;
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

fn HoverPose hover_pose(Demo* demo, Options options) @local {
    TerrainDesc* desc = &demo.ground.desc;
    TextureAsset* record = demo.assets.texture(desc.height_map);
    ushort* texels = (ushort*)record.pixels.ptr;
    uint side = record.desc.width;
    uint span = terrain::CHUNK_CELLS * 2;
    uint first = ((side - 1) / span / 2) * span;
    ushort lowest = ushort::max;
    ushort highest = 0;
    for (uint z = first; z <= first + span; z++) {
        for (uint x = first; x <= first + span; x++) {
            lowest = min(lowest, texels[(usz)z * side + x]);
            highest = max(highest, texels[(usz)z * side + x]);
        }
    }
    float metres_per_unit = desc.height_scale / (float)ushort::max;
    float edge = (float)span * desc.cell_size;
    Vec3 low = { (float)first * desc.cell_size, (float)lowest * metres_per_unit, (float)first * desc.cell_size };
    Vec3 high = { low.x + edge, (float)highest * metres_per_unit, low.z + edge };
    float diameter = (high - low).length();
    // A zero threshold splits everything, so any distance keeps the gate; hover where the default would sit.
    float threshold = options.lod_threshold > 0 ? options.lod_threshold : terrain::DEFAULT_LOD_THRESHOLD;
    float middle = (threshold + threshold / (1 + desc.lod_hysteresis)) * 0.5f;
    float pixels_per_unit = (float)options.height / (2 * math::tan(math::deg_to_rad(CAMERA_FOV_DEGREES) * 0.5f));
    return { .center = (low + high) * 0.5f, .distance = diameter * pixels_per_unit / middle };
}

fn void? pose_segment(
    Demo* demo,
    Segment segment,
    uint step,
    uint segment_frames,
    HoverPose hover,
) @local {
    HeightView view = terrain::height_view(demo.scene, demo.assets, demo.ground.node.id)!;
    float progress = (float)step / (float)segment_frames;
    Vec2 fraction;
    Vec2 travel;
    float altitude;
    float pitch;
    switch (segment) {
        case STILL:
            Vec3 position = extent_point(demo, STILL_POSITION);
            position.y = landscape_ground::ground_under(&view, position, 0) + STILL_ALTITUDE;
            landscape_ground::place_camera(
                camera_node: demo.camera_node,
                position:    position,
                yaw:         STILL_YAW,
                pitch:       SWEEP_PITCH,
            );
            return;
        case HOVER:
            float phase = 2 * (float)math::PI * (float)(step % FRAMES_PER_SECOND) / (float)FRAMES_PER_SECOND;
            float height = hover.distance * (1 + HOVER_BOB * math::sin(phase));
            demo.camera_node.local.position = hover.center + (Vec3){ 0, height, 0 };
            demo.camera_node.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 });
            return;
        case SWEEP:
            fraction = SWEEP_START + (SWEEP_END - SWEEP_START) * progress;
            travel = SWEEP_END - SWEEP_START;
            altitude = SWEEP_ALTITUDE;
            pitch = SWEEP_PITCH;
        case EDIT:
            fraction = EDIT_START + (EDIT_END - EDIT_START) * progress;
            travel = EDIT_END - EDIT_START;
            altitude = EDIT_ALTITUDE;
            pitch = EDIT_PITCH;
    }
    Vec3 position = extent_point(demo, fraction);
    position.y = landscape_ground::ground_under(&view, position, 0) + altitude;
    landscape_ground::place_camera(
        camera_node: demo.camera_node,
        position:    position,
        yaw:         math::atan2(travel.x, travel.y),
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

fn double elapsed_ms(time::Clock started) @local => (double)(long)started.to_now() / NANOSECONDS_PER_MILLISECOND;

fn double? time_bounds_build(Demo* demo, BenchmarkResult* result) @local {
    double[] runs = result.scratch[:BOUNDS_BUILD_RUNS];
    foreach (&run : runs) {
        demo.assets.mark_texture_dirty(demo.ground.desc.height_map);
        time::Clock started = clock::now();
        terrain::update(demo.scene, demo.assets)!;
        *run = elapsed_ms(started);
    }
    return percentile(runs, 0.5f);
}

// What a stroke would repeat with one collider over the whole map: a cook of every sample.
fn double? time_whole_field_cook(Demo* demo) @local {
    Node* probe = demo.scene.add_node(name: "whole_field_probe")!;
    ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
    TerrainCollisionInput input = terrain::collision_input(demo.scene, demo.ground.node.id)!;
    collider.height_field = { .source = TEXTURE, .texture = input.height_map };
    collider.local.scale = input.scale;

    time::Clock started = clock::now();
    demo.physics.add_body(probe, physics::default_body_desc(STATIC), (&collider)[:1])!;
    double elapsed = elapsed_ms(started);

    demo.physics.remove_body(probe);
    demo.scene.remove(probe);
    return elapsed;
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
    InstancedMesh* batch = demo.scene.get(demo.ground.node, InstancedMesh);
    HoverPose hover = hover_pose(demo, options);

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
            hover:          hover,
        )!;
        bool stamped = timed && segment == Segment.EDIT && segment_step % STAMP_PERIOD == 0;
        if (stamped) {
            landscape_ground::stamp_ground(
                scene:    demo.scene,
                assets:   demo.assets,
                ground:   &demo.ground,
                position: demo.camera_node.local.position,
                rise:     landscape_ground::BRUSH_RISE,
                edited:   demo.edited_texels[..],
            )!;
        }

        demo.scene.update_world();
        demo.physics.update(TIME_STEP);
        demo.scene.update_world();
        uint revision = batch.revision;
        time::Clock update_started = clock::now();
        terrain::update(demo.scene, demo.assets)!;
        double update_us = (double)(long)update_started.to_now() / NANOSECONDS_PER_MICROSECOND;
        render_offscreen(
            renderer:    renderer,
            scene:       demo.scene,
            camera_node: demo.camera_node,
            view:        view,
            frame:       frame,
        )!;

        if (timed) {
            result.records[step] = {
                .update_us     = update_us,
                .frame_ms      = elapsed_ms(frame_started),
                .drawn         = renderer.stats.instances_visible,
                .upload_bytes  = renderer.stats.upload_bytes,
                .batch_changed = batch.revision != revision,
                .stamped       = stamped,
            };
        }
        // A frame's GPU timings arrive once its slot comes round again.
        if (frame >= WARMUP_FRAMES + render::FRAMES_IN_FLIGHT) {
            uint completed = frame - render::FRAMES_IN_FLIGHT - WARMUP_FRAMES;
            if (completed < measured) result.records[completed].gpu_ms = renderer.stats.gpu_pass_ms;
        }
    }

    end_stroke(demo)!;
    result.physics_recook_windows = demo.physics.counters().pending_bodies;
    time::Clock recook_started = clock::now();
    demo.physics.update(TIME_STEP);
    result.physics_recook_ms = elapsed_ms(recook_started);
    result.physics_whole_recook_ms = result.physics_recook_ms;
    if (options.collision_window) result.physics_whole_recook_ms = time_whole_field_cook(demo)!;
}

fn void print_edit_results(BenchmarkResult* result, FrameRecord[] edit) @local {
    usz stamps;
    foreach (record : edit) {
        if (!record.stamped) continue;
        result.scratch[stamps] = record.update_us / MICROSECONDS_PER_MILLISECOND;
        stamps++;
    }
    double[] update_ms = result.scratch[:stamps];
    io::printfn("edit_update_ms median=%.4f p99=%.4f", percentile(update_ms, 0.5f), percentile(update_ms, 0.99f));
    stamps = 0;
    foreach (record : edit) {
        if (!record.stamped) continue;
        result.scratch[stamps] = (double)record.upload_bytes;
        stamps++;
    }
    io::printfn("edit_upload_bytes median=%.0f", percentile(result.scratch[:stamps], 0.5f));
}

fn bool print_results(Options options, BenchmarkResult* result) @local {
    uint frames = options.segment_frames;
    io::printfn("bounds_build_ms %.4f", result.bounds_build_ms);
    print_edit_results(result, result.records[Segment.EDIT.ordinal * frames:frames]);
    io::printfn("physics_recook_ms %.4f", result.physics_recook_ms);
    if (options.collision_window) {
        io::printfn("physics_recook_windows %d", result.physics_recook_windows);
        io::printfn("physics_recook_window_ms %.4f", result.physics_recook_ms / result.physics_recook_windows);
    }
    io::printfn("physics_whole_recook_ms %.4f", result.physics_whole_recook_ms);

    bool still_gate = true;
    foreach (ordinal, name : SEGMENT_NAMES) {
        Segment segment = Segment::from_ordinal(ordinal);
        FrameRecord[] records = result.records[ordinal * frames:frames];
        double[] update = gather(records, UPDATE_US, result.scratch);
        io::printfn(
            "update_us segment=%s median=%.3f p99=%.3f",
            name,
            percentile(update, 0.5f),
            percentile(update, 0.99f),
        );
        double[] drawn = gather(records, DRAWN, result.scratch);
        io::printfn("drawn segment=%s median=%.0f max=%.0f", name, percentile(drawn, 0.5f), percentile(drawn, 1.0f));
        double[] uploads = gather(records, UPLOAD_BYTES, result.scratch);
        io::printfn(
            "upload_bytes segment=%s median=%.0f max=%.0f",
            name,
            percentile(uploads, 0.5f),
            percentile(uploads, 1.0f),
        );

        uint upload_frames;
        uint revisions;
        foreach (index, record : records) {
            if (record.upload_bytes) upload_frames++;
            if (index > 0 && record.batch_changed) revisions++;
            bool still_changed = record.upload_bytes || record.batch_changed;
            if (segment == Segment.STILL && index > 0 && still_changed) still_gate = false;
        }
        io::printfn("upload_frames segment=%s %d", name, upload_frames);
        if (segment == Segment.STILL) io::printfn("batch_revisions segment=still %d", revisions);
        if (result.timestamps) {
            foreach (pass : REPORTED_PASSES) {
                double median = percentile(gather_pass(records, pass, result.scratch), 0.5f);
                io::printfn("gpu_ms segment=%s pass=%s median=%.4f", name, pass, median);
            }
            if (options.sky) {
                foreach (pass : SKY_PASSES) {
                    double median = percentile(gather_pass(records, pass, result.scratch), 0.5f);
                    io::printfn("gpu_ms segment=%s pass=%s median=%.4f", name, pass, median);
                }
            }
        }
        double[] frame_ms = gather(records, FRAME_MS, result.scratch);
        io::printfn(
            "frame_ms segment=%s median=%.3f p99=%.3f",
            name,
            percentile(frame_ms, 0.5f),
            percentile(frame_ms, 0.99f),
        );
    }
    io::printfn("gate still_uploads %s", still_gate ? "pass" : "fail");
    return still_gate;
}

fn void? drop_benchmark_crates(Demo* demo) @local {
    HeightView view = terrain::height_view(demo.scene, demo.assets, demo.ground.node.id)!;
    Vec3 center = demo.camera_node.local.position + landscape_ground::look_direction(STILL_YAW, 0) * STILL_ALTITUDE;
    for (uint index = 0; index < CRATE_STACK_SIDE * CRATE_STACK_SIDE; index++) {
        Vec3 offset = { (float)(index % CRATE_STACK_SIDE), 0, (float)(index / CRATE_STACK_SIDE) };
        Vec3 position = center + (offset - (Vec3){ 1, 0, 1 }) * CRATE_STACK_SPACING;
        position.y = landscape_ground::ground_under(&view, position, 0) + CRATE_DROP_HEIGHT;
        drop_crate(demo, position);
    }
}

fn bool? run_benchmark(Options options) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      {
            .validation       = options.validation,
            .gpu_timings      = options.gpu_timings,
            .application_name = "c3d_terrain_benchmark",
            .ray_queries      = options.traced_shadows,
        },
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
    physics::register_physics(&scene)!;
    terrain::register_terrain(&scene, &assets)!;
    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      physics_desc(options),
    )!;
    defer physics::destroy_physics_world(&physics);

    Demo demo = build_demo(
        options: options,
        assets:  &assets,
        scene:   &scene,
        physics: &physics,
    )!;
    pose_segment(
        demo:           &demo,
        segment:        Segment.STILL,
        step:           0,
        segment_frames: options.segment_frames,
        hover:          {},
    )!;
    drop_benchmark_crates(&demo)!;
    scene.update_world();

    uint measured = Segment::len * options.segment_frames;
    BenchmarkResult result = {
        .records    = alloc::new_array(mem, FrameRecord, (sz)measured),
        .scratch    = alloc::new_array(mem, double, (sz)max(measured, BOUNDS_BUILD_RUNS)),
        .timestamps = renderer.timestamps_enabled,
    };
    defer alloc::free(mem, result.records.ptr);
    defer alloc::free(mem, result.scratch.ptr);
    renderer.prepare_scene(&scene)!;
    result.bounds_build_ms = time_bounds_build(&demo, &result)!;

    io::printfn(
        "# terrain size=%d layers=%d shading=%s shadows=%s lod_threshold=%g hysteresis=%g extent=%dx%d frames=%d "
          "terrain=%s sky=%s volumetric_fog=%s collision_window=%d",
        options.size,
        options.layers,
        options.shading == ShadingPath.DEFERRED ? "deferred" : "forward",
        options.traced_shadows ? "traced" : "atlas",
        options.lod_threshold,
        demo.ground.desc.lod_hysteresis,
        options.width,
        options.height,
        options.segment_frames,
        options.hide_terrain ? "hidden" : "visible",
        options.sky ? "on" : "off",
        options.volumetric_fog ? "on" : "off",
        options.collision_window,
    );
    run_segments(
        demo:     &demo,
        renderer: &renderer,
        view:     view,
        result:   &result,
    )!;
    render::wait_frames(&renderer)!;
    return print_results(options, &result);
}

// ----------------------------------------------------------------------------- capture

fn void? pose_capture(Demo* demo) @local {
    Vec3 target = extent_point(demo, CAPTURE_TARGET);
    HeightView view = ground_view(demo, target)!;
    target.y = landscape_ground::ground_under(&view, target, 0);
    demo.camera_node.local.position = target + (Vec3){ 0, CAPTURE_HEIGHT, 0 };
    demo.camera_node.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 });
}

fn void? run_capture(Options options) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      {
            .validation       = true,
            .application_name = "c3d_terrain_capture",
            .ray_queries      = options.traced_shadows,
        },
    )!;
    defer render::destroy_renderer(&renderer);
    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc:     render::render_target_desc(options.width, options.height, PixelFormat.RGBA8_UNORM),
    )!;
    ViewDesc view_desc = configure_desc(render::texture_view_desc(target, OutputMode.DISPLAY_LDR), options);
    view_desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId view = render::create_view(&renderer, view_desc)!;
    Scene scene = create_demo_scene(options);
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!;
    terrain::register_terrain(&scene, &assets)!;
    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      physics_desc(options),
    )!;
    defer physics::destroy_physics_world(&physics);

    Demo demo = build_demo(
        options: options,
        assets:  &assets,
        scene:   &scene,
        physics: &physics,
    )!;
    pose_capture(&demo)!;
    scene.update_world();
    renderer.prepare_scene(&scene)!;
    for (uint frame = 0; frame < CAPTURE_SETTLE_FRAMES; frame++) {
        terrain::update(&scene, &assets)!;
        render_offscreen(
            renderer:    &renderer,
            scene:       &scene,
            camera_node: demo.camera_node,
            view:        view,
            frame:       frame,
        )!;
    }
    render::wait_frames(&renderer)!;

    char[] pixels = alloc::new_array(mem, char, (sz)options.width * options.height * RGBA8_BYTES);
    defer alloc::free(mem, pixels.ptr);
    renderer.read_render_target(target, pixels)!;
    image::write_png(
        path:   options.capture,
        width:  options.width,
        height: options.height,
        pixels: pixels,
    )!;
}

<* View a generated terrain interactively, run the scripted benchmark, or capture one frame. *>
fn int main(String[] args) {
    Options? parsed = parse_options(args);
    if (catch excuse = parsed) {
        if (excuse != c3d::UNSUPPORTED) {
            io::eprintfn("Invalid options: %s", excuse);
            io::eprintn("Use [--benchmark [frames]] [--gpu-timings] [--validation] [--shading forward|deferred] "
              "[--shadows atlas|traced] [--trace-level LEVEL] [--size 1025|2049|4097] [--layers 1|4] "
              "[--lod-threshold PIXELS] [--morph] [--triplanar] [--width W] [--height H] [--hide-terrain] "
              "[--tiles 2x2] "
              "[--capture FILE.png] [--sky] [--volumetric-fog] [--collision-window CELLS].");
        }
        return 1;
    }
    Options options = parsed;
    if (options.capture.len) {
        if (catch excuse = run_capture(options)) {
            io::eprintfn("terrain capture failed: %s", excuse);
            return 1;
        }
        return 0;
    }
    if (!options.benchmark) {
        if (catch excuse = run_interactive(options)) {
            io::eprintfn("terrain example failed: %s", excuse);
            return 1;
        }
        return 0;
    }
    bool? gates = run_benchmark(options);
    if (catch excuse = gates) {
        io::eprintfn("terrain benchmark failed: %s", excuse);
        return 1;
    }
    return gates ? 0 : 1;
}
