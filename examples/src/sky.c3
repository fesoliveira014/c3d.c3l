module sky_example;

import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;
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
import c3d::shader::compile;
import imgui;

const uint WINDOW_WIDTH @local = 1600;
const uint WINDOW_HEIGHT @local = 900;
const uint BENCHMARK_WIDTH @local = 2560;
const uint BENCHMARK_HEIGHT @local = 1440;
const uint DEFAULT_SEGMENT_FRAMES @local = 300;
const uint WARMUP_FRAMES @local = 60; // history, pipelines and the first sky generation settle first
const uint TIME_LAPSE_SEGMENTS @local = 4; // the time-lapse runs four segments' frames: 5.4 degrees at the default
const uint FRAMES_PER_SECOND @local = 60;
const float TIME_STEP @local = 1.0f / FRAMES_PER_SECOND;
const double SECONDS_PER_MINUTE @local = 60;
const uint SAMPLE_BATCHES @local = 10;
const uint SAMPLES_PER_BATCH @local = 10_000; // 100,000 sun_radiance calls before the segments
const double NANOSECONDS_PER_MICROSECOND @local = 1_000;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const float DEGREE @local = (float)math::PI / 180;

// 0.5 degrees is 111.1 frames at 1/60 s, clear of an integer: the regeneration count is exact.
const float TIME_LAPSE_DEGREES_PER_SECOND @local = 0.27f;
const float TIME_LAPSE_START_DEGREES @local = 10;
const float NOON_ELEVATION_DEGREES @local = 60;
const float VALLEY_ELEVATION_DEGREES @local = 20;
const float SUN_AZIMUTH_DEGREES @local = 30; // from the view axis toward +x: the sun ahead, its glow in view
const float MIN_ELEVATION_DEGREES @local = -8;
const float MAX_ELEVATION_DEGREES @local = 90;
const Vec3 SUN_COLOR @local = { 1, 1, 1 }; // the atmosphere colours the sun; a white source keeps it neutral
const float SUN_INTENSITY @local = 3;
const float SHADOW_DISTANCE @local = 400; // metres; four cascades over the near objects
const uint SHADOW_CASCADES @local = 4;
// Metres; the cascades' texels are about 2.6, 5.3, 12 and 48 cm at 2048 texels, and the 2 cm default rings the ground.
const float SHADOW_NORMAL_BIAS @local = 0.15f;

// Exposure from the zenith sky luminance at intensity 3: exposure = 0.045 / luminance, log-linear between entries.
// The table stops at -4 degrees, the last elevation whose zenith stays above RGBA16F subnormals.
const float[8] EXPOSURE_ELEVATIONS @local = { 60, 30, 10, 5, 2, 0, -2, -4 };
const float[8] EXPOSURE_VALUES @local = { 1, 1.6f, 2.8f, 4, 6.5f, 12, 35, 155 };

const float CAMERA_FOV_DEGREES @local = 60;
const float CAMERA_NEAR @local = 0.1f;
const float CAMERA_FAR @local = 20_000; // the far objects at 800 m and the ground's 2 km edge, with headroom
const float EYE_HEIGHT @local = 1.8f;
const float VALLEY_HEIGHT @local = 300;
const float VALLEY_PITCH_DEGREES @local = -30;
const float FLY_SPEED @local = 20;
const float FAST_MULTIPLIER @local = 10;
const float LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates

const float GROUND_SIZE @local = 4_000;
const Vec4 GROUND_COLOR @local = { 0.4f, 0.4f, 0.4f, 1 };
const float GROUND_ROUGHNESS @local = 0.9f;
const float[7] OBJECT_DISTANCES @local = { 10, 25, 50, 100, 200, 400, 800 };
const float[3] OBJECT_BEARINGS_DEGREES @local = { -30, 0, 30 };
const float OBJECT_SIZE_PER_METRE @local = 0.04f; // every object spans about two degrees of view
const float OBJECT_MIN_SIZE @local = 1;
const Vec4[3] OBJECT_COLORS @local = { { 0.8f, 0.3f, 0.2f, 1 }, { 0.3f, 0.7f, 0.3f, 1 }, { 0.3f, 0.4f, 0.8f, 1 } };
const float OBJECT_ROUGHNESS @local = 0.6f;

const Vec3 BLENDED_QUAD_POSITION @local = { -2, 1.5f, -12 };
const Vec4 BLENDED_QUAD_COLOR @local = { 0.9f, 0.6f, 0.1f, 0.5f };
const float BLENDED_QUAD_ROUGHNESS @local = 0.5f;
const Vec3 GLASS_PANE_POSITION @local = { 2.5f, 1.5f, -15 };
const Vec3 BLEND_PANE_POSITION @local = { -5, 1.5f, -18 };
const Vec3 SPHERE_POSITION @local = { 5, 1, -20 };
const float SPHERE_RADIUS @local = 1;
const float PANE_SIZE @local = 2;
const float GLASS_ROUGHNESS @local = 0.05f;
const float GLASS_IOR @local = 1.5f;
const float SPHERE_THICKNESS @local = 0.5f;
const float POND_SIZE @local = 10;
const float POND_LEVEL @local = 0.4f; // metres over the ground; the water shows the ground through its depth
const Vec3 POND_POSITION @local = { -6, POND_LEVEL, -30 };
const Vec3 MIRROR_POSITION @local = { 6, POND_LEVEL, -30 };
const Plane MIRROR_PLANE @local = { .normal = { 0, 1, 0 }, .d = -POND_LEVEL };
const uint MIRROR_LAYER @local = 1 << 3; // the mirror camera never draws the surfaces on its plane
const Vec4 MIRROR_BASE_COLOR @local = { 0.2f, 0.2f, 0.22f, 1 };
const float MIRROR_REFLECTANCE @local = 0.8f;
const float MIRROR_ROUGHNESS @local = 0.3f;
const char[*] POND_FRAGMENT_SOURCE @local = $embed("../shaders/custom/water.frag.glsl");
const char[*] MIRROR_FRAGMENT_SOURCE @local = $embed("../shaders/custom/mirror.frag.glsl");
const Vec4 CLEAR_SKY_COLOR @local = { 0.45f, 0.6f, 0.85f, 1 }; // the background without an atmosphere
const float AMBIENT_INTENSITY @local = 0.3f;

const float FOG_DENSITY_MAX @local = 0.02f;
const float FOG_FALLOFF_MAX @local = 0.1f;
const Vec2 PANEL_POSITION @local = { 16, 16 };
const Vec2 PANEL_SIZE @local = { 440, 520 };
const Vec2 STATS_PANEL_POSITION @local = { 472, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 420, 260 };

const String[Segment::len] SEGMENT_NAMES @local = { "noon", "twilight", "valley", "time-lapse" };
const Pass[15] REPORTED_PASSES @local = {
    Pass.SKY_VIEW,
    Pass.AERIAL_PERSPECTIVE,
    Pass.DEPTH_PREPASS,
    Pass.GBUFFER,
    Pass.LIGHTING,
    Pass.FORWARD_OPAQUE,
    Pass.SKY,
    Pass.SCENE_SNAPSHOT,
    Pass.SCENE_READ,
    Pass.SSGI_COLOR_COPY,
    Pass.FOG,
    Pass.FORWARD_TRANSPARENT,
    Pass.PATH_TRACE,
    Pass.SHADOW_ATLAS,
    Pass.ENVIRONMENT,
};
const EnvironmentStage[3] REFRESH_STAGES @local = {
    EnvironmentStage.SKY,
    EnvironmentStage.PREFILTER,
    EnvironmentStage.IRRADIANCE,
};

enum Segment @local {
    NOON,
    TWILIGHT,
    VALLEY,
    TIME_LAPSE,
}

enum Preset @local {
    NOON,
    TWILIGHT,
    VALLEY,
    TIME_LAPSE,
}

struct MirrorBlock @local {
    Vec4     base_color;
    float    reflectance;
    float    roughness;
    float[2] padding;
}
$assert MirrorBlock::size == 32;

struct Options @local {
    bool        benchmark;
    uint        segment_frames;
    bool        gpu_timings;
    bool        validation;
    ShadingPath shading;
    bool        traced_shadows;
    bool        ssgi;
    bool        path_traced;
    bool        fog;
    bool        atmosphere;
    Preset      preset;
    uint        width;
    uint        height;
}

struct Mirror @local {
    RenderTargetId target;
    ViewId         view;
    Node*          camera_node;
}

struct Demo @local {
    Options     options;
    AssetStore* assets;
    Scene*      scene;
    Node*       camera_node;
    Node*       sun;
    Node*       fog;
    MaterialId  mirror_material;
    Mirror      mirror;
}

struct SkyPose @local {
    Vec3  camera_position;
    float yaw;
    float pitch;
    float elevation_degrees;
}

struct Controls @local {
    float elevation_degrees;
    float azimuth_degrees;
    bool  playing;
    bool  exposure_table;
    uint  regenerations;
}

struct FlyCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
}

struct FrameRecord @local {
    double                                    frame_ms;
    uint                                      regenerations;
    float[render::PASS_COUNT]                 frame_gpu_ms;
    float[render::PASS_COUNT]                 main_gpu_ms;
    float[render::PASS_COUNT]                 mirror_gpu_ms;
    float[render::ENVIRONMENT_STAGE_COUNT]    stage_ms;
}

struct BenchmarkResult @local {
    FrameRecord[] records;
    double[]      scratch;
    double        sun_extract_us;
    bool          timestamps;
}

fn double elapsed_ms(time::Clock started) @local => (double)(long)started.to_now() / NANOSECONDS_PER_MILLISECOND;

fn double frame_time(uint frame) @local => (double)frame * TIME_STEP;

// ----------------------------------------------------------------------------- scene

fn Vec3 look_direction(float yaw, float pitch) @local {
    return { -math::cos(pitch) * math::sin(yaw), math::sin(pitch), -math::cos(pitch) * math::cos(yaw) };
}

fn Vec3 sun_to(float elevation_degrees, float azimuth_degrees) @local {
    float elevation = elevation_degrees * DEGREE;
    float azimuth = azimuth_degrees * DEGREE;
    float horizontal = math::cos(elevation);
    return { horizontal * math::sin(azimuth), math::sin(elevation), -horizontal * math::cos(azimuth) };
}

fn void aim_sun(Node* sun, Vec3 to_sun) @local {
    Vec3 up = math::abs(to_sun.y) > 0.99f ? (Vec3){ 0, 0, -1 } : (Vec3){ 0, 1, 0 };
    sun.local.rotation = maths::look_rotation(-to_sun, up);
}

fn float exposure_for(float elevation_degrees) @local {
    if (elevation_degrees >= EXPOSURE_ELEVATIONS[0]) return EXPOSURE_VALUES[0];
    for (usz index = 1; index < EXPOSURE_ELEVATIONS.len; index++) {
        float lower = EXPOSURE_ELEVATIONS[index];
        if (elevation_degrees < lower) continue;
        float upper = EXPOSURE_ELEVATIONS[index - 1];
        float share = (elevation_degrees - upper) / (lower - upper);
        float upper_stops = math::log2(EXPOSURE_VALUES[index - 1]);
        float lower_stops = math::log2(EXPOSURE_VALUES[index]);
        return math::exp2(upper_stops + (lower_stops - upper_stops) * share);
    }
    return EXPOSURE_VALUES[EXPOSURE_VALUES.len - 1];
}

fn void place_camera(
    Node* camera_node,
    Vec3 position,
    float yaw,
    float pitch,
) @local {
    camera_node.local.position = position;
    camera_node.local.rotation = maths::look_rotation(look_direction(yaw, pitch), { 0, 1, 0 });
}

fn ShaderId? add_fragment_shader(
    AssetStore* assets,
    String source,
    ZString debug_name,
    usz param_block_size,
    SceneReads scene_reads,
) @local {
    ShaderId shader;
    @pool() {
        ShaderDesc desc = {
            .fragment = compile::compile_glsl(
                allocator:  tmem,
                source:     source,
                stage:      ShaderStage.FRAGMENT,
                debug_name: debug_name.str_view(),
            )!,
            .param_block_size = param_block_size,
            .scene_reads      = scene_reads,
        };
        shader = assets.add_shader(&desc, debug_name.str_view())!;
    };
    return shader;
}

fn MaterialId? add_standard(AssetStore* assets, Vec4 color, float roughness) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = color;
    params.metallic = 0;
    params.roughness = roughness;
    return assets.add_material(material::standard(params));
}

fn MaterialId? add_glass(AssetStore* assets, float thickness, AlphaMode alpha) @local {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    common.alpha_mode = alpha;
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.metallic = 0;
    params.standard.roughness = GLASS_ROUGHNESS;
    params.ior = GLASS_IOR;
    params.transmission = 1;
    params.thickness = thickness;
    return assets.add_material(material::physical(params, common));
}

fn Node*? add_upright(
    Scene* scene,
    GeometryId plane,
    MaterialId material,
    Vec3 position,
) @local {
    Node* node = scene.add_mesh(plane, material)!;
    node.local.position = position;
    node.local.rotation = maths::look_rotation({ 0, 1, 0 }, { 0, 0, 1 });
    return node;
}

fn void? add_objects(
    Scene* scene,
    AssetStore* assets,
    GeometryId box,
    GeometryId ball,
) @local {
    MaterialId[3] materials;
    foreach (index, color : OBJECT_COLORS) materials[index] = add_standard(assets, color, OBJECT_ROUGHNESS)!;
    foreach (distance_index, distance : OBJECT_DISTANCES) {
        float size = math::max(OBJECT_MIN_SIZE, distance * OBJECT_SIZE_PER_METRE);
        foreach (bearing_index, bearing : OBJECT_BEARINGS_DEGREES) {
            bool sphere = (distance_index + bearing_index) % 2 == 1;
            Node* node = scene.add_mesh(sphere ? ball : box, materials[bearing_index])!;
            Vec3 direction = { math::sin(bearing * DEGREE), 0, -math::cos(bearing * DEGREE) };
            node.local.position = direction * distance + (Vec3){ 0, size * 0.5f, 0 };
            node.local.scale = { size, size, size };
        }
    }
}

fn void? add_readers(
    Demo* demo,
    GeometryId pane,
    GeometryId ball,
    GeometryId pad,
) @local {
    Scene* scene = demo.scene;
    AssetStore* assets = demo.assets;
    MaterialCommon blended = material::MATERIAL_COMMON_DEFAULT;
    blended.double_sided = true;
    blended.alpha_mode = AlphaMode.BLEND;
    StandardParams quad_params = material::STANDARD_PARAMS_DEFAULT;
    quad_params.base_color = BLENDED_QUAD_COLOR;
    quad_params.metallic = 0;
    quad_params.roughness = BLENDED_QUAD_ROUGHNESS;
    MaterialId quad = assets.add_material(material::standard(quad_params, blended))!;
    MaterialId glass = add_glass(assets, 0, AlphaMode.OPAQUE)!;
    MaterialId blended_glass = add_glass(assets, 0, AlphaMode.BLEND)!;
    add_upright(
        scene:    scene,
        plane:    pane,
        material: quad,
        position: BLENDED_QUAD_POSITION,
    )!;
    add_upright(
        scene:    scene,
        plane:    pane,
        material: glass,
        position: GLASS_PANE_POSITION,
    )!;
    add_upright(
        scene:    scene,
        plane:    pane,
        material: blended_glass,
        position: BLEND_PANE_POSITION,
    )!;
    Node* sphere = scene.add_mesh(ball, add_glass(assets, SPHERE_THICKNESS, AlphaMode.OPAQUE)!)!;
    sphere.local.position = SPHERE_POSITION;
    sphere.local.scale = { SPHERE_RADIUS, SPHERE_RADIUS, SPHERE_RADIUS };

    ShaderId pond_shader = add_fragment_shader(
        assets:           assets,
        source:           (String)POND_FRAGMENT_SOURCE[..],
        debug_name:       "sky/pond",
        param_block_size: 0,
        scene_reads:      { .color, .depth },
    )!;
    Node* pond = scene.add_mesh(pad, assets.add_material(material::custom(pond_shader))!)!;
    pond.local.position = POND_POSITION;
    pond.layers = MIRROR_LAYER;
    scene.get(pond, Mesh).cast_shadow = false;

    ShaderId mirror_shader = add_fragment_shader(
        assets:           assets,
        source:           (String)MIRROR_FRAGMENT_SOURCE[..],
        debug_name:       "sky/mirror",
        param_block_size: MirrorBlock::size,
        scene_reads:      {},
    )!;
    MirrorBlock block = {
        .base_color  = MIRROR_BASE_COLOR,
        .reflectance = MIRROR_REFLECTANCE,
        .roughness   = MIRROR_ROUGHNESS,
    };
    // The target is bound once the renderer has created it.
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
    slots[0].sampler = asset::SAMPLER_LINEAR_CLAMP;
    slots[0].texture.kind = RENDER_TARGET;
    demo.mirror_material = assets.add_material(material::custom(mirror_shader, material::@as_bytes(block), slots))!;
    Node* mirror = scene.add_mesh(pad, demo.mirror_material)!;
    mirror.local.position = MIRROR_POSITION;
    mirror.layers = MIRROR_LAYER;
    scene.get(mirror, Mesh).cast_shadow = false;
}

fn void? build_demo(Demo* demo) @local {
    Scene* scene = demo.scene;
    AssetStore* assets = demo.assets;
    GeometryId ground;
    GeometryId box;
    GeometryId ball;
    GeometryId pane;
    GeometryId pad;
    @pool() {
        Geometry ground_geometry = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground = assets.add_geometry(&ground_geometry)!;
        Geometry box_geometry = geometry::box(tmem, 1, 1, 1);
        box = assets.add_geometry(&box_geometry)!;
        Geometry ball_geometry = geometry::sphere(tmem, 0.5f);
        ball = assets.add_geometry(&ball_geometry)!;
        Geometry pane_geometry = geometry::plane(tmem, PANE_SIZE, PANE_SIZE);
        pane = assets.add_geometry(&pane_geometry)!;
        Geometry pad_geometry = geometry::plane(tmem, POND_SIZE, POND_SIZE);
        pad = assets.add_geometry(&pad_geometry)!;
    };
    scene.add_mesh(ground, add_standard(assets, GROUND_COLOR, GROUND_ROUGHNESS)!, name: "ground")!;
    add_objects(
        scene:  scene,
        assets: assets,
        box:    box,
        ball:   ball,
    )!;
    add_readers(
        demo: demo,
        pane: pane,
        ball: ball,
        pad:  pad,
    )!;

    Light sun = light::directional(SUN_COLOR, SUN_INTENSITY);
    sun.shadow.cascades = SHADOW_CASCADES;
    sun.shadow.max_distance = SHADOW_DISTANCE;
    sun.shadow.normal_bias = SHADOW_NORMAL_BIAS;
    sun.shadow.ray_traced = demo.options.traced_shadows;
    demo.sun = scene.add_light(sun, name: "sun")!;
    if (demo.options.atmosphere) scene.add(demo.sun, light::ATMOSPHERE_EARTH);
    if (demo.options.fog) {
        demo.fog = scene.add_node(name: "fog")!;
        scene.add(demo.fog, light::HEIGHT_FOG_DEFAULT);
    }
    scene.background.kind = BackgroundKind.COLOR;
    scene.background.color = CLEAR_SKY_COLOR;
    scene.ambient_color = CLEAR_SKY_COLOR.xyz;
    scene.ambient_intensity = AMBIENT_INTENSITY;

    demo.camera_node = scene.add_camera(
        camera::perspective_deg(CAMERA_FOV_DEGREES, CAMERA_NEAR, CAMERA_FAR),
        name: "camera",
    )!;
    demo.mirror.camera_node = scene.add_camera(
        camera::perspective_deg(CAMERA_FOV_DEGREES, CAMERA_NEAR, CAMERA_FAR),
        name: "mirror",
    )!;
    scene.get(demo.mirror.camera_node, Camera).layers = camera::ALL_LAYERS & ~MIRROR_LAYER;
}

fn RendererDesc renderer_desc(Options options, bool validation, ZString application_name) @local {
    return {
        .validation            = validation,
        .gpu_timings           = options.gpu_timings,
        .application_name      = application_name,
        .ray_queries           = options.traced_shadows,
        .ray_tracing_pipelines = options.path_traced,
    };
}

fn ViewDesc main_view_desc(ViewDesc desc, Options options) @local {
    desc.shading = options.shading;
    desc.ray_tracing.shadows = options.traced_shadows;
    if (options.ssgi) {
        desc.post.anti_aliasing = AntiAliasing.TAA;
        desc.screen_space_gi = render::SCREEN_SPACE_GI_DEFAULT;
    }
    if (options.path_traced) {
        desc.shading = ShadingPath.PATH_TRACED;
        desc.post.anti_aliasing = AntiAliasing.NONE;
        desc.lights = LightSelection.FLAT;
        desc.ray_tracing.shadows = false;
    }
    return desc;
}

// docs/views.md's planar reflection: a half-size target clipped to the pond's plane, rendered first.
fn void? create_mirror(
    Demo* demo,
    Renderer* renderer,
    uint width,
    uint height,
) @local {
    demo.mirror.target = render::create_render_target(
        renderer,
        render::render_target_desc(math::max(width / 2, 1u), math::max(height / 2, 1u)),
    )!;
    ViewDesc desc = render::texture_view_desc(demo.mirror.target);
    desc.shading = demo.options.shading;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.clip_plane = MIRROR_PLANE;
    desc.ray_tracing.shadows = demo.options.traced_shadows;
    demo.mirror.view = render::create_view(renderer, desc)!;
    AssetStore* assets = demo.assets;
    assets.material(demo.mirror_material).data.custom.slots[0].texture = {
        .kind   = RENDER_TARGET,
        .target = demo.mirror.target,
    };
    assets.mark_material_dirty(demo.mirror_material);
}

fn void? place_mirror_camera(Demo* demo, float aspect) @local {
    Mat4 mirrored = maths::reflection_matrix(MIRROR_PLANE).mul(demo.camera_node.local.to_mat4());
    demo.mirror.camera_node.local = maths::transform_from_affine(mirrored)!;
    demo.scene.get(demo.mirror.camera_node, Camera).aspect = aspect;
}

// The frame order: pose the camera and the sun, then update the world once.
fn void? apply_pose(
    Demo* demo,
    SkyPose pose,
    float azimuth_degrees,
    float aspect,
    bool exposure_table,
) @local {
    place_camera(
        camera_node: demo.camera_node,
        position:    pose.camera_position,
        yaw:         pose.yaw,
        pitch:       pose.pitch,
    );
    place_mirror_camera(demo, aspect)!;
    aim_sun(demo.sun, sun_to(pose.elevation_degrees, azimuth_degrees));
    float exposure = exposure_table ? exposure_for(pose.elevation_degrees) : 1;
    demo.scene.get(demo.camera_node, Camera).exposure = exposure;
    demo.scene.get(demo.mirror.camera_node, Camera).exposure = exposure;
    demo.scene.update_world();
}

fn void? render_views(Demo* demo, Renderer* renderer, ViewId main_view) @local {
    renderer.render_view(demo.scene, demo.mirror.camera_node, demo.mirror.view)!;
    renderer.finish_view(demo.mirror.view)!;
    renderer.render_view(demo.scene, demo.camera_node, main_view)!;
    return renderer.finish_view(main_view);
}

fn SkyPose preset_pose(Preset preset) @local {
    SkyPose pose = { .camera_position = { 0, EYE_HEIGHT, 0 }, .elevation_degrees = NOON_ELEVATION_DEGREES };
    switch (preset) {
        case NOON: pose.elevation_degrees = NOON_ELEVATION_DEGREES;
        case TWILIGHT: pose.elevation_degrees = EXPOSURE_ELEVATIONS[EXPOSURE_ELEVATIONS.len - 1];
        case VALLEY:
            pose.camera_position.y = VALLEY_HEIGHT;
            pose.pitch = VALLEY_PITCH_DEGREES * DEGREE;
            pose.elevation_degrees = VALLEY_ELEVATION_DEGREES;
        case TIME_LAPSE: pose.elevation_degrees = TIME_LAPSE_START_DEGREES;
    }
    return pose;
}

// ----------------------------------------------------------------------------- options

fn String? option_value(String[] args, usz* index) @local {
    if (*index + 1 >= args.len) return c3d::INVALID_ARGUMENT~;
    (*index)++;
    return args[*index];
}

fn bool? on_off(String value) @local {
    switch (value) {
        case "on": return true;
        case "off": return false;
        default: return c3d::INVALID_ARGUMENT~;
    }
}

fn Options? parse_options(String[] args) @local {
    Options options = {
        .segment_frames = DEFAULT_SEGMENT_FRAMES,
        .shading        = ShadingPath.FORWARD,
        .fog            = true,
        .atmosphere     = true,
        .preset         = Preset.NOON,
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
                    io::eprintn("--gpu-timings needs GPU profiling: python3 scripts/build.py --target sky --opt O3 "
                      "--define C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib c3d_profile");
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
            case "--ssgi": options.ssgi = true;
            case "--path-traced": options.path_traced = true;
            case "--fog": options.fog = on_off(option_value(args, &index)!)!;
            case "--atmosphere": options.atmosphere = on_off(option_value(args, &index)!)!;
            case "--preset":
                switch (option_value(args, &index)!) {
                    case "noon": options.preset = Preset.NOON;
                    case "twilight": options.preset = Preset.TWILIGHT;
                    case "valley": options.preset = Preset.VALLEY;
                    case "time-lapse": options.preset = Preset.TIME_LAPSE;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--width": options.width = option_value(args, &index)!.to_uint()!;
            case "--height": options.height = option_value(args, &index)!.to_uint()!;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    if (options.segment_frames < 2) return c3d::INVALID_ARGUMENT~;
    if (!options.width) options.width = options.benchmark ? BENCHMARK_WIDTH : WINDOW_WIDTH;
    if (!options.height) options.height = options.benchmark ? BENCHMARK_HEIGHT : WINDOW_HEIGHT;
    return options;
}

// ----------------------------------------------------------------------------- interactive

fn void apply_preset(Controls* controls, FlyCamera* fly_camera, Preset preset) @local {
    SkyPose pose = preset_pose(preset);
    fly_camera.position = pose.camera_position;
    fly_camera.yaw = pose.yaw;
    fly_camera.pitch = pose.pitch;
    controls.elevation_degrees = pose.elevation_degrees;
    controls.playing = preset == Preset.TIME_LAPSE;
}

fn void apply_fly_camera(FlyCamera* fly_camera, Input* input, float delta) @local {
    if (!input.mouse_captured_by_gui && input.button_down(platform::MouseButton.RIGHT)) {
        fly_camera.yaw -= input.mouse_delta.x * LOOK_RADIANS_PER_PIXEL;
        fly_camera.pitch = math::clamp(
            fly_camera.pitch - input.mouse_delta.y * LOOK_RADIANS_PER_PIXEL,
            -PITCH_LIMIT,
            PITCH_LIMIT,
        );
    }
    if (input.keyboard_captured_by_gui) return;
    Vec3 forward = look_direction(fly_camera.yaw, fly_camera.pitch);
    Vec3 up = { 0, 1, 0 };
    Vec3 right = forward.cross(up).normalize();
    Vec3 direction;
    if (input.key_down(platform::Scancode.W)) direction += forward;
    if (input.key_down(platform::Scancode.S)) direction -= forward;
    if (input.key_down(platform::Scancode.D)) direction += right;
    if (input.key_down(platform::Scancode.A)) direction -= right;
    if (input.key_down(platform::Scancode.E)) direction += up;
    if (input.key_down(platform::Scancode.Q)) direction -= up;
    float speed = input.key_down(platform::Scancode.LSHIFT) ? FLY_SPEED * FAST_MULTIPLIER : FLY_SPEED;
    fly_camera.position += direction * (speed * delta);
    fly_camera.position.y = math::max(fly_camera.position.y, CAMERA_NEAR);
}

fn void sky_panel(
    Demo* demo,
    Renderer* renderer,
    Controls* controls,
    FlyCamera* fly_camera,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Sky", null, {})) {
        imgui::text("Right drag looks, WASD move, Q and E sink and rise, Shift fast");
        imgui::separator_text("Time of day");
        imgui::slider_float(
            label: "Sun elevation",
            v:     &controls.elevation_degrees,
            v_min: MIN_ELEVATION_DEGREES,
            v_max: MAX_ELEVATION_DEGREES,
        );
        imgui::slider_float(
            label: "Sun azimuth",
            v:     &controls.azimuth_degrees,
            v_min: 0,
            v_max: 360,
        );
        imgui::checkbox("Play the time-lapse", &controls.playing);
        imgui::checkbox("Exposure table", &controls.exposure_table);
        if (imgui::button("Noon")) apply_preset(controls, fly_camera, Preset.NOON);
        imgui::same_line();
        if (imgui::button("Twilight")) apply_preset(controls, fly_camera, Preset.TWILIGHT);
        imgui::same_line();
        if (imgui::button("Valley")) apply_preset(controls, fly_camera, Preset.VALLEY);
        imgui::same_line();
        if (imgui::button("Time-lapse")) apply_preset(controls, fly_camera, Preset.TIME_LAPSE);
        if (demo.fog) {
            imgui::separator_text("Height fog");
            HeightFog* fog = demo.scene.get(demo.fog, HeightFog);
            imgui::slider_float(
                label: "Density",
                v:     &fog.density,
                v_min: 0,
                v_max: FOG_DENSITY_MAX,
            );
            imgui::slider_float(
                label: "Falloff",
                v:     &fog.falloff,
                v_min: 0,
                v_max: FOG_FALLOFF_MAX,
            );
        }
        imgui::separator_text("Frame");
        float exposure = demo.scene.get(demo.camera_node, Camera).exposure;
        imgui::text("Sun elevation %.2f, exposure %.2f", controls.elevation_degrees, exposure);
        imgui::text("Sky regenerations %u", controls.regenerations);
        imgui::text(
            "Ignored: atmospheres %u, fogs %u; dropped atmospheres %u",
            renderer.stats.atmospheres_ignored,
            renderer.stats.fogs_ignored,
            renderer.stats.atmospheres_dropped,
        );
        if (renderer.timestamps_enabled) {
            float[render::PASS_COUNT]* passes = &renderer.stats.gpu_pass_ms;
            imgui::text("SKY_VIEW %.4f ms", (*passes)[Pass.SKY_VIEW.ordinal]);
            imgui::text("AERIAL_PERSPECTIVE %.4f ms", (*passes)[Pass.AERIAL_PERSPECTIVE.ordinal]);
            imgui::text("FOG %.4f ms", (*passes)[Pass.FOG.ordinal]);
            imgui::text("ENVIRONMENT %.4f ms", (*passes)[Pass.ENVIRONMENT.ordinal]);
            foreach (ordinal, stage_ms : renderer.stats.gpu_environment_stage_ms) {
                String label = EnvironmentStage::from_ordinal(ordinal).label;
                imgui::text("  %.*s %.4f ms", (int)label.len, label.ptr, stage_ms);
            }
        } else {
            imgui::text("GPU timings off: build with C3D_PROFILE_GPU and pass --gpu-timings");
        }
    }
    imgui::end();
}

fn void? draw_frame(
    Demo* demo,
    Renderer* renderer,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        render_views(demo, renderer, renderer.default_view)!;
        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    return renderer.end_frame();
}

fn void? run_interactive(Options options) @local {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d sky", options.width, options.height))!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      renderer_desc(options, true, "c3d_sky"),
    )!;
    defer render::destroy_renderer(&renderer);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Demo demo = { .options = options, .assets = &assets, .scene = &scene };
    build_demo(&demo)!;
    render::configure_view(&renderer, renderer.default_view, main_view_desc(render::default_view_desc(), options))!;
    create_mirror(
        demo:     &demo,
        renderer: &renderer,
        width:    math::max(renderer.output_width, 1u),
        height:   math::max(renderer.output_height, 1u),
    )!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    Controls controls = { .azimuth_degrees = SUN_AZIMUTH_DEGREES, .exposure_table = true };
    FlyCamera fly_camera;
    apply_preset(&controls, &fly_camera, options.preset);
    renderer.prepare_scene(&scene)!;
    SkyPose last_pose;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        sky_panel(
            demo:       &demo,
            renderer:   &renderer,
            controls:   &controls,
            fly_camera: &fly_camera,
        );
        ViewId[2] views = { renderer.default_view, demo.mirror.view };
        ZString[2] labels = { "main", "mirror" };
        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("View stats", null, {})) gui::view_stats_table(&renderer, views[..], labels[..]);
        imgui::end();
        gui_renderer.finish_frame();

        if (controls.playing) {
            controls.elevation_degrees += TIME_LAPSE_DEGREES_PER_SECOND * delta;
            if (controls.elevation_degrees > MAX_ELEVATION_DEGREES) controls.elevation_degrees = MIN_ELEVATION_DEGREES;
        }
        apply_fly_camera(&fly_camera, input, delta);
        SkyPose pose = {
            .camera_position   = fly_camera.position,
            .yaw               = fly_camera.yaw,
            .pitch             = fly_camera.pitch,
            .elevation_degrees = controls.elevation_degrees,
        };
        float aspect = (float)math::max(renderer.output_width, 1u) / (float)math::max(renderer.output_height, 1u);
        apply_pose(
            demo:            &demo,
            pose:            pose,
            azimuth_degrees: controls.azimuth_degrees,
            aspect:          aspect,
            exposure_table:  controls.exposure_table,
        )!;
        // The path tracer keeps accumulating across a sun change unless its history is reset.
        if (options.path_traced && pose.elevation_degrees != last_pose.elevation_degrees) {
            render::reset_view_history(&renderer, renderer.default_view)!;
        }
        last_pose = pose;

        platform::sync_window(&window, &renderer);
        draw_frame(
            demo:         &demo,
            renderer:     &renderer,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = delta },
        )!;
        controls.regenerations += renderer.stats.sky_regenerations;
    }
}

// ----------------------------------------------------------------------------- benchmark

fn uint segment_frames(Options options, Segment segment) @local {
    return segment == Segment.TIME_LAPSE ? options.segment_frames * TIME_LAPSE_SEGMENTS : options.segment_frames;
}

fn uint segment_start(Options options, Segment segment) @local {
    uint start;
    for (uint ordinal = 0; ordinal < (uint)segment.ordinal; ordinal++) {
        start += segment_frames(options, Segment::from_ordinal(ordinal));
    }
    return start;
}

fn uint measured_frames(Options options) @local {
    return segment_start(options, Segment.TIME_LAPSE) + segment_frames(options, Segment.TIME_LAPSE);
}

fn Segment segment_of(Options options, uint step) @local {
    Segment segment = Segment.NOON;
    for (uint ordinal = 1; ordinal < Segment::len; ordinal++) {
        Segment candidate = Segment::from_ordinal(ordinal);
        if (step >= segment_start(options, candidate)) segment = candidate;
    }
    return segment;
}

fn float time_lapse_step_degrees() @local => TIME_LAPSE_DEGREES_PER_SECOND * TIME_STEP;

fn SkyPose segment_pose(Segment segment, uint step) @local {
    switch (segment) {
        case NOON: return preset_pose(Preset.NOON);
        case TWILIGHT: return preset_pose(Preset.TWILIGHT);
        case VALLEY: return preset_pose(Preset.VALLEY);
        case TIME_LAPSE:
            SkyPose pose = preset_pose(Preset.TIME_LAPSE);
            pose.elevation_degrees += (float)step * time_lapse_step_degrees();
            return pose;
    }
}

fn void? render_offscreen(
    Demo* demo,
    Renderer* renderer,
    ViewId main_view,
    uint frame,
) @local {
    renderer.begin_frame({ .time = frame_time(frame), .delta = TIME_STEP })!;
    defer catch render::abort_frame(renderer);
    render_views(demo, renderer, main_view)!;
    return renderer.end_frame();
}

fn double? time_sun_extraction(Demo* demo) @local {
    Atmosphere atmosphere = light::ATMOSPHERE_EARTH;
    Light* sun = demo.scene.get(demo.sun, Light);
    double[SAMPLE_BATCHES] batches;
    Vec3 sum;
    foreach (&nanoseconds : batches) {
        time::Clock started = clock::now();
        for (uint sample = 0; sample < SAMPLES_PER_BATCH; sample++) {
            float elevation = (float)sample / (float)SAMPLES_PER_BATCH * (float)math::PI / 2;
            sum += light::sun_radiance(
                atmosphere: &atmosphere,
                sun:        sun,
                to_sun:     { math::cos(elevation), math::sin(elevation), 0 },
                altitude:   EYE_HEIGHT,
            );
        }
        *nanoseconds = (double)(long)started.to_now() / (double)SAMPLES_PER_BATCH;
    }
    // The radiance feeds the check, so no call is optimised away.
    if (!math::is_finite(sum.x)) return c3d::INVALID_ARGUMENT~;
    return percentile(batches[..], 0.5f) / NANOSECONDS_PER_MICROSECOND;
}

fn void? run_segments(
    Demo* demo,
    Renderer* renderer,
    ViewId main_view,
    BenchmarkResult* result,
) @local {
    Options options = demo.options;
    uint measured = measured_frames(options);
    float aspect = (float)options.width / (float)options.height;
    SkyPose last_pose;
    for (uint frame = 0; frame < WARMUP_FRAMES + measured + render::FRAMES_IN_FLIGHT; frame++) {
        bool timed = frame >= WARMUP_FRAMES && frame < WARMUP_FRAMES + measured;
        uint step = timed ? frame - WARMUP_FRAMES : 0;
        Segment segment = timed ? segment_of(options, step) : Segment.NOON;
        uint segment_step = step - segment_start(options, segment);
        if (frame >= WARMUP_FRAMES + measured) {
            segment = Segment.TIME_LAPSE;
            segment_step = segment_frames(options, segment) - 1;
        }
        time::Clock frame_started = clock::now();
        SkyPose pose = segment_pose(segment, segment_step);
        apply_pose(
            demo:            demo,
            pose:            pose,
            azimuth_degrees: SUN_AZIMUTH_DEGREES,
            aspect:          aspect,
            exposure_table:  true,
        )!;
        if (options.path_traced && pose.elevation_degrees != last_pose.elevation_degrees) {
            render::reset_view_history(renderer, main_view)!;
        }
        last_pose = pose;
        render_offscreen(
            demo:      demo,
            renderer:  renderer,
            main_view: main_view,
            frame:     frame,
        )!;
        if (timed) {
            result.records[step].frame_ms = elapsed_ms(frame_started);
            result.records[step].regenerations = renderer.stats.sky_regenerations;
        }
        // A frame's GPU timings arrive once its slot comes round again.
        if (frame >= WARMUP_FRAMES + render::FRAMES_IN_FLIGHT) {
            uint completed = frame - render::FRAMES_IN_FLIGHT - WARMUP_FRAMES;
            if (completed < measured) {
                FrameRecord* record = &result.records[completed];
                record.frame_gpu_ms = renderer.stats.gpu_pass_ms;
                record.stage_ms = renderer.stats.gpu_environment_stage_ms;
                record.main_gpu_ms = renderer.view_stats(main_view)!.gpu_pass_ms;
                record.mirror_gpu_ms = renderer.view_stats(demo.mirror.view)!.gpu_pass_ms;
            }
        }
    }
}

fn double percentile(double[] samples, float share) @local {
    if (!samples.len) return 0;
    sort::quicksort(samples);
    return samples[(usz)math::round(share * (float)(samples.len - 1))];
}

fn double[] gather_frame_ms(FrameRecord[] records, double[] scratch) @local {
    foreach (index, record : records) scratch[index] = record.frame_ms;
    return scratch[:records.len];
}

fn double[] gather_pass(
    FrameRecord[] records,
    bool mirror,
    Pass pass,
    double[] scratch,
) @local {
    foreach (index, record : records) {
        float[render::PASS_COUNT]* passes = mirror ? &record.mirror_gpu_ms : &record.main_gpu_ms;
        scratch[index] = (double)(*passes)[pass.ordinal];
    }
    return scratch[:records.len];
}

// Frames of the time-lapse whose recorded work regenerated the sky.
fn double[] gather_refresh(
    FrameRecord[] records,
    EnvironmentStage stage,
    bool total,
    double[] scratch,
) @local {
    usz count;
    foreach (record : records) {
        if (record.regenerations != 1) continue;
        float stage_ms = total ? record.frame_gpu_ms[Pass.ENVIRONMENT.ordinal] : record.stage_ms[stage.ordinal];
        scratch[count] = (double)stage_ms;
        count++;
    }
    return scratch[:count];
}

fn void print_refresh(String stage, double[] samples) @local {
    usz count = samples.len;
    io::printfn(
        "refresh_ms segment=time-lapse stage=%s median=%.4f max=%.4f count=%d",
        stage,
        percentile(samples, 0.5f),
        percentile(samples, 1.0f),
        count,
    );
}

fn uint regenerations_after_first(FrameRecord[] records) @local {
    uint count;
    foreach (index, record : records) {
        if (index > 0) count += record.regenerations;
    }
    return count;
}

fn bool print_time_lapse(
    Options options,
    BenchmarkResult* result,
    FrameRecord[] records,
    uint regenerations,
) @local {
    if (result.timestamps) {
        foreach (stage : REFRESH_STAGES) {
            double[] samples = gather_refresh(
                records: records,
                stage:   stage,
                total:   false,
                scratch: result.scratch,
            );
            print_refresh(stage.label, samples);
        }
        double[] totals = gather_refresh(
            records: records,
            stage:   EnvironmentStage.SKY,
            total:   true,
            scratch: result.scratch,
        );
        print_refresh("total", totals);
    }
    double seconds = (double)(records.len - 1) * TIME_STEP;
    io::printfn(
        "refreshes_per_minute segment=time-lapse value=%.2f",
        (double)regenerations / seconds * SECONDS_PER_MINUTE,
    );
    // The sky regenerates on the first frame past the threshold, one step beyond it.
    double step_degrees = time_lapse_step_degrees();
    double threshold_degrees = render::SKY_REGENERATION_SUN_ANGLE / DEGREE;
    double period = (math::floor(threshold_degrees / step_degrees) + 1) * step_degrees;
    double sweep = (double)(records.len - 1) * step_degrees;
    uint expected = options.atmosphere ? (uint)math::floor(sweep / period) : 0;
    bool gate = regenerations == expected;
    io::printfn(
        "gate time_lapse_regenerations expected=%d found=%d %s",
        expected,
        regenerations,
        gate ? "pass" : "fail",
    );
    return gate;
}

fn bool print_results(Demo* demo, BenchmarkResult* result) @local {
    Options options = demo.options;
    io::printfn("sun_extract_us median=%.4f", result.sun_extract_us);
    bool steady_gate = true;
    bool time_lapse_gate = true;
    foreach (ordinal, name : SEGMENT_NAMES) {
        Segment segment = Segment::from_ordinal(ordinal);
        FrameRecord[] records = result.records[segment_start(options, segment):segment_frames(options, segment)];
        if (result.timestamps) {
            bool[2] mirrors = { false, true };
            foreach (mirror : mirrors) {
                foreach (pass : REPORTED_PASSES) {
                    double[] samples = gather_pass(
                        records: records,
                        mirror:  mirror,
                        pass:    pass,
                        scratch: result.scratch,
                    );
                    io::printfn(
                        "gpu_ms view=%s segment=%s pass=%s median=%.4f p99=%.4f",
                        mirror ? "mirror" : "main",
                        name,
                        pass,
                        percentile(samples, 0.5f),
                        percentile(samples, 0.99f),
                    );
                }
            }
        }
        double[] frame_ms = gather_frame_ms(records, result.scratch);
        io::printfn(
            "frame_ms segment=%s median=%.3f p99=%.3f",
            name,
            percentile(frame_ms, 0.5f),
            percentile(frame_ms, 0.99f),
        );
        uint regenerations = regenerations_after_first(records);
        if (segment == Segment.NOON) steady_gate = regenerations == 0;
        if (segment == Segment.TIME_LAPSE) {
            time_lapse_gate = print_time_lapse(
                options:       options,
                result:        result,
                records:       records,
                regenerations: regenerations,
            );
        }
    }
    io::printfn("gate steady_sky %s", steady_gate ? "pass" : "fail");
    return steady_gate && time_lapse_gate;
}

fn void print_header(Options options) @local {
    io::printfn(
        "# sky shading=%s shadows=%s ssgi=%s path_traced=%s fog=%s atmosphere=%s extent=%dx%d frames=%d",
        options.shading == ShadingPath.DEFERRED ? "deferred" : "forward",
        options.traced_shadows ? "traced" : "atlas",
        options.ssgi ? "on" : "off",
        options.path_traced ? "on" : "off",
        options.fog ? "on" : "off",
        options.atmosphere ? "on" : "off",
        options.width,
        options.height,
        options.segment_frames,
    );
}

fn bool? run_benchmark(Options options) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      renderer_desc(options, options.validation, "c3d_sky_benchmark"),
    )!;
    defer render::destroy_renderer(&renderer);
    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc:     render::render_target_desc(options.width, options.height, PixelFormat.RGBA8_UNORM),
    )!;
    ViewId main_view = render::create_view(
        renderer: &renderer,
        desc:     main_view_desc(render::texture_view_desc(target, OutputMode.DISPLAY_LDR), options),
    )!;
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Demo demo = { .options = options, .assets = &assets, .scene = &scene };
    build_demo(&demo)!;
    create_mirror(
        demo:     &demo,
        renderer: &renderer,
        width:    options.width,
        height:   options.height,
    )!;
    print_header(options);

    uint measured = measured_frames(options);
    BenchmarkResult result = {
        .records    = alloc::new_array(mem, FrameRecord, (sz)measured),
        .scratch    = alloc::new_array(mem, double, (sz)measured),
        .timestamps = renderer.timestamps_enabled,
    };
    defer alloc::free(mem, result.records.ptr);
    defer alloc::free(mem, result.scratch.ptr);
    result.sun_extract_us = time_sun_extraction(&demo)!;
    apply_pose(
        demo:            &demo,
        pose:            segment_pose(Segment.NOON, 0),
        azimuth_degrees: SUN_AZIMUTH_DEGREES,
        aspect:          (float)options.width / (float)options.height,
        exposure_table:  true,
    )!;
    renderer.prepare_scene(&scene)!;

    run_segments(
        demo:      &demo,
        renderer:  &renderer,
        main_view: main_view,
        result:    &result,
    )!;
    render::wait_frames(&renderer)!;
    return print_results(&demo, &result);
}

<* A physical sky with its sun, aerial perspective and height fog, interactively or as the scripted benchmark. *>
fn int main(String[] args) {
    Options? parsed = parse_options(args);
    if (catch excuse = parsed) {
        if (excuse != c3d::UNSUPPORTED) {
            io::eprintfn("Invalid options: %s", excuse);
            io::eprintn("Use [--benchmark [frames]] [--gpu-timings] [--validation] [--shading forward|deferred] "
              "[--shadows atlas|traced] [--ssgi] [--path-traced] [--fog on|off] [--atmosphere on|off] "
              "[--preset noon|twilight|valley|time-lapse] [--width W] [--height H].");
        }
        return 1;
    }
    Options options = parsed;
    if (!options.benchmark) {
        if (catch excuse = run_interactive(options)) {
            io::eprintfn("sky example failed: %s", excuse);
            return 1;
        }
        return 0;
    }
    bool? gates = run_benchmark(options);
    if (catch excuse = gates) {
        io::eprintfn("sky benchmark failed: %s", excuse);
        return 1;
    }
    return gates ? 0 : 1;
}
