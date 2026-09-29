module terrain_example;

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
import c3d::landscape::terrain;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::spatial;
import imgui;

const uint[3] MAP_SIZES @local = { 1025, 2049, 4097 }; // four, five and six levels
const uint DEFAULT_SIZE @local = 2049; // 2 km across at 1 m cells: 256 finest chunks
const float CELL_SIZE @local = 1; // metres between texels
const float HEIGHT_SCALE @local = 300; // metres at texel 65535; ridges reach about two thirds of it
const uint HEIGHT_SEED @local = 0x7e11a1;
const uint HEIGHT_OCTAVES @local = 7; // 512 m ridges down to 8 m bumps; each octave is one noise pass per texel
const float HEIGHT_BASE_TEXELS @local = 512; // wavelength of the first octave: a few ranges per map
const float HEIGHT_GAIN @local = 0.5f; // amplitude kept per octave; higher is rougher
const float HEIGHT_VALLEY_POWER @local = 1.6f; // flattens valley floors so walking and crates have ground
const uint CONTROL_SIZE @local = 1024; // weight texels over the whole extent; 4 MiB, two metres each at 2049
const float SNOW_LINE @local = 0.62f; // share of the height scale where snow starts
const float SNOW_BAND @local = 0.08f;
const float ROCK_SLOPE @local = 0.9f; // rise over run where rock takes over
const float ROCK_BAND @local = 0.35f;
const float DIRT_SLOPE @local = 0.35f;
const float DIRT_BAND @local = 0.2f;
const uint LAYER_COUNT @local = 4;
const uint LAYER_MAP_SIZE @local = 256; // tileable texels per layer map; 256 KiB each
const uint LAYER_NOISE_CELLS @local = 16; // lattice cells across one tile; the tile repeats without seams
const uint LAYER_DETAIL_SCALE @local = 4; // the detail octave's cells per base cell
const float LAYER_DETAIL_WEIGHT @local = 0.35f;
const uint LAYER_SEED @local = 0x51a7e;
const uint LAYER_SEED_STRIDE @local = 16;
const float DISPLAY_GAMMA @local = 2.2f; // layer colours are authored linear and stored sRGB
const uint RGBA8_BYTES @local = 4;
const uint TERRAIN_LAYER @local = 1 << 1; // node layer bit that picks leave out
const uint CRATE_CAPACITY @local = 256; // one node and one body each; the scene capacity lever
const uint SCENE_NODE_CAPACITY @local = CRATE_CAPACITY + 16;
const float CRATE_SIZE @local = 1;
const float CRATE_DROP_HEIGHT @local = 8; // metres above the ground a crate starts from
const float CRATE_DROP_DISTANCE @local = 6; // metres in front of the camera
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
const float EYE_HEIGHT @local = 1.8f;
const float WALK_SPEED @local = 8;
const float FLY_SPEED @local = 60;
const float FAST_MULTIPLIER @local = 4;
const float LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const uint BRUSH_RADIUS @local = 24; // texels; a stamp touches 49 x 49 texels, the typical edit
const float BRUSH_RISE @local = 600; // texel units at the centre per benchmark stamp, 2.7 m at this height scale
const float BRUSH_RISE_PER_SECOND @local = 1200; // texel units at the centre while B is held, 5.5 m/s
const float BRUSH_STAMP_SECONDS @local = 1.0f / 30; // held painting stamps at this period whatever the frame rate
const Vec3 SUN_DIRECTION @local = { -0.45f, -0.6f, -0.35f };
const float SUN_INTENSITY @local = 3;
const float SHADOW_DISTANCE @local = 1500; // metres; the cascades spread over it, the atlas cost is fixed
const float SHADOW_NORMAL_BIAS @local = 0.5f; // metres; cascade texels here are 0.1 to 1.8 m, less bands gentle ground
const float AMBIENT_INTENSITY @local = 0.25f;
const Vec4 SKY_COLOR @local = { 0.55f, 0.7f, 0.9f, 1 };
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
const double NANOSECONDS_PER_MICROSECOND @local = 1_000;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const double MICROSECONDS_PER_MILLISECOND @local = 1_000;
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

const LayerLook[LAYER_COUNT] LAYER_LOOKS @local = {
    { // grass
        .low         = { 0.16f, 0.26f, 0.08f },
        .high        = { 0.3f, 0.42f, 0.14f },
        .roughness   = 0.9f,
        .tile_metres = 4,
        .bump        = 1.5f,
    },
    { // dirt
        .low         = { 0.28f, 0.2f, 0.12f },
        .high        = { 0.42f, 0.32f, 0.2f },
        .roughness   = 0.95f,
        .tile_metres = 6,
        .bump        = 2,
    },
    { // rock
        .low         = { 0.3f, 0.29f, 0.28f },
        .high        = { 0.52f, 0.5f, 0.47f },
        .roughness   = 0.75f,
        .tile_metres = 10,
        .bump        = 4,
    },
    { // snow
        .low         = { 0.82f, 0.85f, 0.9f },
        .high        = { 0.95f, 0.96f, 0.98f },
        .roughness   = 0.5f,
        .tile_metres = 8,
        .bump        = 0.8f,
    },
};

enum Segment @local {
    STILL,
    SWEEP,
    HOVER,
    EDIT,
}

enum Metric @local {
    SELECTION_US,
    FRAME_MS,
    CHUNKS,
    UPLOAD_BYTES,
}

struct NoiseSource @local {
    uint seed;
    int  period; // lattice cells before the noise repeats; 0 never repeats
}

struct LayerLook @local {
    Vec3  low;
    Vec3  high;
    float roughness;
    float tile_metres; // one tile of the layer maps covers this many metres
    float bump;        // normal-map slope at full noise contrast
}

struct Options @local {
    bool        benchmark;
    uint        segment_frames;
    bool        gpu_timings;
    bool        validation;
    ShadingPath shading;
    bool        traced_shadows;
    uint        size;
    uint        layers;
    float       lod_threshold;
    uint        width;
    uint        height;
    bool        hide_terrain;
}

struct Demo @local {
    Options       options;
    AssetStore*   assets;
    Scene*        scene;
    PhysicsWorld* physics;
    Node*         terrain_node;
    Node*         camera_node;
    TerrainDesc   desc;
    float         extent;
    GeometryId    crate_geometry;
    MaterialId    crate_material;
    uint          crate_count;
}

struct FlyCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
    bool  flying;
    float ground;
}

struct HoverPose @local {
    Vec3  center;
    float distance;
}

struct FrameRecord @local {
    double                    selection_us;
    double                    frame_ms;
    uint                      chunks;
    uint                      upload_bytes;
    uint                      lod_switches;
    bool                      batch_changed;
    bool                      stamped;
    float[render::PASS_COUNT] gpu_ms;
}

struct BenchmarkResult @local {
    FrameRecord[] records;
    double[]      scratch;
    double        bounds_build_ms;
    double        physics_recook_ms;
    uint          level_count;
    bool          timestamps;
    uint[terrain::MAX_TERRAIN_LEVELS][Segment::len] chunks_per_level;
}

fn float blend(float from, float to, float amount) @local => from + (to - from) * amount;

fn float lattice_value(NoiseSource source, int x, int z) @local {
    if (source.period) {
        x = ((x % source.period) + source.period) % source.period;
        z = ((z % source.period) + source.period) % source.period;
    }
    // An integer hash of the lattice point: value noise needs no gradient table.
    uint hash = ((uint)x * 0x8da6b343) ^ ((uint)z * 0xd8163841) ^ (source.seed * 0xcb1ab31f);
    hash = (hash ^ (hash >> 13)) * 0x5bd1e995;
    hash ^= hash >> 15;
    return (float)(hash & 0xffffff) / (float)0x1000000;
}

fn float value_noise(NoiseSource source, float x, float z) @local {
    float cell_x = math::floor(x);
    float cell_z = math::floor(z);
    float fraction_x = x - cell_x;
    float fraction_z = z - cell_z;
    float blend_x = fraction_x * fraction_x * (3 - 2 * fraction_x);
    float blend_z = fraction_z * fraction_z * (3 - 2 * fraction_z);
    int lattice_x = (int)cell_x;
    int lattice_z = (int)cell_z;
    float near_row = blend(
        lattice_value(source, lattice_x, lattice_z),
        lattice_value(source, lattice_x + 1, lattice_z),
        blend_x,
    );
    float far_row = blend(
        lattice_value(source, lattice_x, lattice_z + 1),
        lattice_value(source, lattice_x + 1, lattice_z + 1),
        blend_x,
    );
    return blend(near_row, far_row, blend_z);
}

fn float ridged_height(float texel_x, float texel_z) @local {
    float total;
    float weight_sum;
    float amplitude = 1;
    float frequency = 1 / HEIGHT_BASE_TEXELS;
    for (uint octave = 0; octave < HEIGHT_OCTAVES; octave++) {
        float noise = value_noise({ .seed = HEIGHT_SEED + octave }, texel_x * frequency, texel_z * frequency);
        float ridge = 1 - math::abs(2 * noise - 1);
        total += amplitude * ridge * ridge;
        weight_sum += amplitude;
        amplitude *= HEIGHT_GAIN;
        frequency *= 2;
    }
    return math::pow(total / weight_sum, HEIGHT_VALLEY_POWER);
}

fn TextureId? add_height_map(AssetStore* assets, uint texels) @local {
    usz count = (usz)texels * texels;
    char[] pixels = alloc::new_array(assets.allocator, char, (sz)(count * ushort::size));
    ushort[] heights = ((ushort*)pixels.ptr)[:count];
    for (uint z = 0; z < texels; z++) {
        for (uint x = 0; x < texels; x++) {
            float height = math::clamp(ridged_height((float)x, (float)z), 0.0f, 1.0f);
            heights[(usz)z * texels + x] = (ushort)(height * (float)ushort::max + 0.5f);
        }
    }
    TextureDesc desc = material::texture_2d_desc(
        width:      texels,
        height:     texels,
        format:     R16_UINT,
        debug_name: "terrain_height",
    );
    desc.generate_mips = false;
    TextureId? added = assets.add_texture_owned(desc, pixels, "terrain/height");
    if (catch excuse = added) {
        alloc::free(assets.allocator, pixels.ptr);
        return excuse~;
    }
    return added;
}

fn float smooth_band(float value, float start, float width) @local {
    float t = math::clamp((value - start) / width, 0.0f, 1.0f);
    return t * t * (3 - 2 * t);
}

fn char unit_to_byte(float value) @local => (char)(math::clamp(value, 0.0f, 1.0f) * (float)char::max + 0.5f);

// Layer weights of grass, dirt, rock and snow in the red, green, blue and alpha channels.
fn TextureId? add_control_map(AssetStore* assets, ushort[] heights, uint texels) @local {
    TextureId control;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)((usz)CONTROL_SIZE * CONTROL_SIZE * RGBA8_BYTES));
        float texels_per_control = (float)(texels - 1) / (float)(CONTROL_SIZE - 1);
        float metres_per_unit = HEIGHT_SCALE / (float)ushort::max;
        for (uint row = 0; row < CONTROL_SIZE; row++) {
            for (uint column = 0; column < CONTROL_SIZE; column++) {
                uint x = (uint)((float)column * texels_per_control + 0.5f);
                uint z = (uint)((float)row * texels_per_control + 0.5f);
                uint low_x = x > 0 ? x - 1 : 0;
                uint high_x = min(x + 1, texels - 1);
                uint low_z = z > 0 ? z - 1 : 0;
                uint high_z = min(z + 1, texels - 1);
                float rise_x = ((float)heights[(usz)z * texels + high_x] - (float)heights[(usz)z * texels + low_x])
                  * metres_per_unit / ((float)(high_x - low_x) * CELL_SIZE);
                float rise_z = ((float)heights[(usz)high_z * texels + x] - (float)heights[(usz)low_z * texels + x])
                  * metres_per_unit / ((float)(high_z - low_z) * CELL_SIZE);
                float slope = math::sqrt(rise_x * rise_x + rise_z * rise_z);
                float height = (float)heights[(usz)z * texels + x] / (float)ushort::max;

                float rock = smooth_band(slope, ROCK_SLOPE, ROCK_BAND);
                float snow = smooth_band(height, SNOW_LINE, SNOW_BAND) * (1 - rock);
                float dirt = smooth_band(slope, DIRT_SLOPE, DIRT_BAND) * (1 - rock) * (1 - snow);
                float grass = math::max(1 - rock - dirt - snow, 0.0f);
                usz offset = ((usz)row * CONTROL_SIZE + column) * RGBA8_BYTES;
                pixels[offset] = unit_to_byte(grass);
                pixels[offset + 1] = unit_to_byte(dirt);
                pixels[offset + 2] = unit_to_byte(rock);
                pixels[offset + 3] = unit_to_byte(snow);
            }
        }
        // Linear: the stage divides raw weights, so an sRGB curve would skew the blend.
        TextureDesc desc = material::texture_2d_desc(
            width:      CONTROL_SIZE,
            height:     CONTROL_SIZE,
            format:     RGBA8_UNORM,
            debug_name: "terrain_control",
        );
        control = assets.add_texture(desc, pixels, "terrain/control")!;
    };
    return control;
}

fn float layer_noise(uint seed, uint x, uint z) @local {
    float cells_per_texel = (float)LAYER_NOISE_CELLS / (float)LAYER_MAP_SIZE;
    float base = value_noise(
        { .seed = seed, .period = (int)LAYER_NOISE_CELLS },
        (float)x * cells_per_texel,
        (float)z * cells_per_texel,
    );
    float detail = value_noise(
        { .seed = seed + 1, .period = (int)(LAYER_NOISE_CELLS * LAYER_DETAIL_SCALE) },
        (float)x * cells_per_texel * LAYER_DETAIL_SCALE,
        (float)z * cells_per_texel * LAYER_DETAIL_SCALE,
    );
    return blend(base, detail, LAYER_DETAIL_WEIGHT);
}

fn MaterialId? add_layer(AssetStore* assets, LayerLook look, uint index) @local {
    TextureId base_color;
    TextureId normal_map;
    @pool() {
        usz bytes = (usz)LAYER_MAP_SIZE * LAYER_MAP_SIZE * RGBA8_BYTES;
        char[] colors = alloc::new_array(tmem, char, (sz)bytes);
        char[] normals = alloc::new_array(tmem, char, (sz)bytes);
        uint seed = LAYER_SEED + index * LAYER_SEED_STRIDE;
        uint last = LAYER_MAP_SIZE - 1;
        for (uint z = 0; z < LAYER_MAP_SIZE; z++) {
            for (uint x = 0; x < LAYER_MAP_SIZE; x++) {
                float value = layer_noise(seed, x, z);
                float rise_x = layer_noise(seed, (x + 1) % LAYER_MAP_SIZE, z)
                  - layer_noise(seed, (x + last) % LAYER_MAP_SIZE, z);
                float rise_z = layer_noise(seed, x, (z + 1) % LAYER_MAP_SIZE)
                  - layer_noise(seed, x, (z + last) % LAYER_MAP_SIZE);
                Vec3 color = look.low + (look.high - look.low) * value;
                Vec3 normal = (Vec3){ -rise_x * look.bump, -rise_z * look.bump, 1 }.normalize();
                usz offset = ((usz)z * LAYER_MAP_SIZE + x) * RGBA8_BYTES;
                colors[offset] = unit_to_byte(math::pow(color.x, 1 / DISPLAY_GAMMA));
                colors[offset + 1] = unit_to_byte(math::pow(color.y, 1 / DISPLAY_GAMMA));
                colors[offset + 2] = unit_to_byte(math::pow(color.z, 1 / DISPLAY_GAMMA));
                colors[offset + 3] = char::max;
                normals[offset] = unit_to_byte(normal.x * 0.5f + 0.5f);
                normals[offset + 1] = unit_to_byte(normal.y * 0.5f + 0.5f);
                normals[offset + 2] = unit_to_byte(normal.z * 0.5f + 0.5f);
                normals[offset + 3] = char::max;
            }
        }
        TextureDesc color_desc = material::texture_2d_desc(
            width:      LAYER_MAP_SIZE,
            height:     LAYER_MAP_SIZE,
            format:     RGBA8_SRGB,
            debug_name: "terrain_layer_color",
        );
        base_color = assets.add_texture(color_desc, colors)!;
        TextureDesc normal_desc = material::texture_2d_desc(
            width:      LAYER_MAP_SIZE,
            height:     LAYER_MAP_SIZE,
            format:     RGBA8_UNORM,
            debug_name: "terrain_layer_normal",
        );
        normal_map = assets.add_texture(normal_desc, normals)!;
    };

    UvTransform tiling = { .scale = { 1 / look.tile_metres, 1 / look.tile_metres } };
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.metallic = 0;
    params.roughness = look.roughness;
    params.base_color_map = material::texture_slot(texture: base_color, transform: tiling);
    params.normal_map = material::texture_slot(texture: normal_map, transform: tiling);
    return assets.add_material(material::standard(params));
}

// The collider as docs/terrain.md builds it: the node's transform places both.
fn void? add_terrain_collider(PhysicsWorld* physics, Node* node, TerrainDesc desc) @local {
    ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
    collider.height_field = { .source = TEXTURE, .texture = desc.height_map };
    collider.local.scale = { desc.cell_size, desc.height_scale, desc.cell_size };
    return physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1]);
}

fn Demo? build_demo(
    Options options,
    AssetStore* assets,
    Scene* scene,
    PhysicsWorld* physics,
) @local {
    Demo demo = {
        .options = options,
        .assets  = assets,
        .scene   = scene,
        .physics = physics,
        .extent  = (float)(options.size - 1) * CELL_SIZE,
    };
    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = add_height_map(assets, options.size)!;
    TextureAsset* heights = assets.texture(desc.height_map);
    desc.control_map = add_control_map(
        assets:  assets,
        heights: ((ushort*)heights.pixels.ptr)[:(usz)options.size * options.size],
        texels:  options.size,
    )!;
    for (uint index = 0; index < options.layers; index++) {
        desc.layers[index] = add_layer(assets, LAYER_LOOKS[index], index)!;
    }
    desc.cell_size = CELL_SIZE;
    desc.height_scale = HEIGHT_SCALE;
    desc.lod_threshold = options.lod_threshold;

    demo.terrain_node = scene.add_node(name: "terrain")!;
    demo.terrain_node.layers = TERRAIN_LAYER;
    demo.terrain_node.visible = !options.hide_terrain;
    scene.update_world();
    terrain::add_terrain(
        scene:  scene,
        assets: assets,
        node:   demo.terrain_node,
        desc:   desc,
    )!;
    demo.desc = desc;
    add_terrain_collider(physics, demo.terrain_node, desc)!;

    @pool() {
        Geometry crate = geometry::box(tmem, CRATE_SIZE, CRATE_SIZE, CRATE_SIZE);
        demo.crate_geometry = assets.add_geometry(&crate, "terrain/crate")!;
    };
    StandardParams crate_params = material::STANDARD_PARAMS_DEFAULT;
    crate_params.base_color = { 0.7f, 0.45f, 0.2f, 1 };
    crate_params.metallic = 0;
    crate_params.roughness = 0.7f;
    demo.crate_material = assets.add_material(material::standard(crate_params), "terrain/crate_material")!;

    Light sun = light::directional({ 1, 0.95f, 0.85f }, SUN_INTENSITY);
    sun.shadow.max_distance = SHADOW_DISTANCE;
    sun.shadow.normal_bias = SHADOW_NORMAL_BIAS;
    sun.shadow.ray_traced = options.traced_shadows;
    Node* sun_node = scene.add_light(sun, name: "sun")!;
    sun_node.local.rotation = maths::look_rotation(SUN_DIRECTION.normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = SKY_COLOR };
    scene.ambient_color = SKY_COLOR.xyz;
    scene.ambient_intensity = AMBIENT_INTENSITY;

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

fn Vec3 extent_point(Demo* demo, Vec2 fraction) @local {
    return { fraction.x * demo.extent, 0, fraction.y * demo.extent };
}

fn float ground_under(HeightView* view, Vec3 position, float last_ground) @local {
    return terrain::sample_height(view, position.x, position.z) ?? last_ground;
}

fn Vec3 look_direction(float yaw, float pitch) @local {
    return { math::cos(pitch) * math::sin(yaw), math::sin(pitch), math::cos(pitch) * math::cos(yaw) };
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

fn void stamp_brush(
    Scene* scene,
    AssetStore* assets,
    Node* terrain_node,
    uint center_x,
    uint center_z,
    float rise,
) @local {
    TextureId height_map = scene.get(terrain_node, Terrain).desc.height_map;
    TextureAsset* record = assets.texture(height_map);
    uint side = record.desc.width;
    ushort* texels = (ushort*)record.pixels.ptr;
    uint first_x = center_x > BRUSH_RADIUS ? center_x - BRUSH_RADIUS : 0;
    uint first_z = center_z > BRUSH_RADIUS ? center_z - BRUSH_RADIUS : 0;
    uint last_x = min(center_x + BRUSH_RADIUS, side - 1);
    uint last_z = min(center_z + BRUSH_RADIUS, side - 1);
    float radius_squared = (float)(BRUSH_RADIUS * BRUSH_RADIUS);
    for (uint z = first_z; z <= last_z; z++) {
        for (uint x = first_x; x <= last_x; x++) {
            float offset_x = (float)x - (float)center_x;
            float offset_z = (float)z - (float)center_z;
            float falloff = 1 - (offset_x * offset_x + offset_z * offset_z) / radius_squared;
            if (falloff <= 0) continue;
            usz index = (usz)z * side + x;
            uint raised = (uint)texels[index] + (uint)(rise * falloff + 0.5f);
            texels[index] = (ushort)min(raised, (uint)ushort::max);
        }
    }
    assets.mark_texture_dirty(height_map);
    terrain::mark_dirty(scene, terrain_node, {
        .x       = first_x,
        .z       = first_z,
        .columns = last_x - first_x + 1,
        .rows    = last_z - first_z + 1,
    });
}

// A re-cook rebuilds the whole field, so collision follows a stroke once it ends, not while it is painted.
fn void end_stroke(Scene* scene, Node* terrain_node) @local {
    if (scene.has(terrain_node, PhysicsBody)) scene.get(terrain_node, PhysicsBody).mark_changed();
}

fn bool? stamp_under(Demo* demo, Vec3 position, float rise) @local {
    HeightView view = terrain::height_view(demo.scene, demo.assets, demo.terrain_node.id)!;
    Vec3 local = maths::transform_point(view.local_from_world, position);
    float column = math::round(local.x / view.cell_size);
    float row = math::round(local.z / view.cell_size);
    float last = (float)(view.texels_per_side - 1);
    if (column < 0 || row < 0 || column > last || row > last) return false;
    stamp_brush(
        scene:        demo.scene,
        assets:       demo.assets,
        terrain_node: demo.terrain_node,
        center_x:     (uint)column,
        center_z:     (uint)row,
        rise:         rise,
    );
    return true;
}

fn ViewDesc configure_desc(ViewDesc desc, Options options) @local {
    desc.shading = options.shading;
    desc.post.anti_aliasing = AntiAliasing.TAA;
    desc.ray_tracing.shadows = options.traced_shadows;
    return desc;
}

fn double percentile(double[] samples, float share) @local {
    if (!samples.len) return 0;
    sort::quicksort(samples);
    return samples[(usz)math::round(share * (float)(samples.len - 1))];
}

fn double metric_value(FrameRecord* record, Metric metric) @local {
    switch (metric) {
        case SELECTION_US: return record.selection_us;
        case FRAME_MS: return record.frame_ms;
        case CHUNKS: return (double)record.chunks;
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

fn bool is_map_size(uint size) @local {
    foreach (map_size : MAP_SIZES) {
        if (size == map_size) return true;
    }
    return false;
}

fn String? option_value(String[] args, usz* index) @local {
    if (*index + 1 >= args.len) return c3d::INVALID_ARGUMENT~;
    (*index)++;
    return args[*index];
}

fn Options? parse_options(String[] args) @local {
    Options options = {
        .segment_frames = DEFAULT_SEGMENT_FRAMES,
        .shading        = ShadingPath.FORWARD,
        .size           = DEFAULT_SIZE,
        .layers         = LAYER_COUNT,
        .lod_threshold  = terrain::DEFAULT_LOD_THRESHOLD,
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
                if (!is_map_size(options.size)) return c3d::INVALID_ARGUMENT~;
            case "--layers":
                options.layers = option_value(args, &index)!.to_uint()!;
                if (options.layers != 1 && options.layers != LAYER_COUNT) return c3d::INVALID_ARGUMENT~;
            case "--lod-threshold":
                options.lod_threshold = option_value(args, &index)!.to_float()!;
                if (!(options.lod_threshold >= 0)) return c3d::INVALID_ARGUMENT~;
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

fn void apply_fly_camera(
    FlyCamera* fly_camera,
    Input* input,
    HeightView* view,
    float delta,
) @local {
    if (!input.mouse_captured_by_gui && input.button_down(platform::MouseButton.RIGHT)) {
        fly_camera.yaw -= input.mouse_delta.x * LOOK_RADIANS_PER_PIXEL;
        fly_camera.pitch = math::clamp(
            fly_camera.pitch - input.mouse_delta.y * LOOK_RADIANS_PER_PIXEL,
            -PITCH_LIMIT,
            PITCH_LIMIT,
        );
    }
    Vec3 forward = look_direction(fly_camera.yaw, fly_camera.flying ? fly_camera.pitch : 0);
    Vec3 up = { 0, 1, 0 };
    Vec3 right = forward.cross(up).normalize();
    if (!input.keyboard_captured_by_gui) {
        Vec3 direction;
        if (input.key_down(platform::Scancode.W)) direction += forward;
        if (input.key_down(platform::Scancode.S)) direction -= forward;
        if (input.key_down(platform::Scancode.D)) direction += right;
        if (input.key_down(platform::Scancode.A)) direction -= right;
        if (fly_camera.flying && input.key_down(platform::Scancode.E)) direction += up;
        if (fly_camera.flying && input.key_down(platform::Scancode.Q)) direction -= up;
        float speed = fly_camera.flying ? FLY_SPEED : WALK_SPEED;
        if (input.key_down(platform::Scancode.LSHIFT)) speed *= FAST_MULTIPLIER;
        fly_camera.position += direction * (speed * delta);
    }
    fly_camera.ground = ground_under(view, fly_camera.position, fly_camera.ground);
    if (!fly_camera.flying) fly_camera.position.y = fly_camera.ground + EYE_HEIGHT;
}

fn void push_picked_crate(Demo* demo, Renderer* renderer, Vec2 pixel) @local {
    Vec2 viewport = { renderer.output_width, renderer.output_height };
    Camera* lens = demo.scene.get(demo.camera_node, Camera);
    CameraMatrices matrices = camera::derive_matrices(*lens, demo.camera_node.world, viewport);
    Ray ray = camera::screen_to_ray(&matrices, pixel, viewport);
    PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
    options.precision = PickPrecision.TRIANGLES;
    options.layers = camera::ALL_LAYERS & ~TERRAIN_LAYER;
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

fn void? terrain_panel(Demo* demo, FlyCamera* fly_camera, float delta) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Terrain", null, {})) {
        imgui::text("Right drag looks, WASD move, Shift fast; F flies, Q and E sink and rise");
        imgui::text("G drops a crate, B paints, P toggles the collider, click pushes a crate");
        TerrainRuntime* runtime = demo.scene.get(demo.terrain_node, TerrainRuntime);
        InstancedMesh* batch = demo.scene.get(demo.terrain_node, InstancedMesh);
        imgui::text("Chunks: %u   LOD switches: %u", batch.count, runtime.lod_switches);
        for (uint level = 0; level < runtime.level_count; level++) {
            imgui::text("  level %u: %u", level, runtime.chunks_per_level[level]);
        }
        Terrain* authored = demo.scene.get(demo.terrain_node, Terrain);
        imgui::slider_float(
            label: "LOD threshold",
            v:     &authored.desc.lod_threshold,
            v_min: 0,
            v_max: LOD_THRESHOLD_MAX,
        );
        HeightView view = terrain::height_view(demo.scene, demo.assets, demo.terrain_node.id)!;
        Vec3 position = fly_camera.position;
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
            demo.scene.has(demo.terrain_node, PhysicsBody) ? "on" : "off",
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
    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!;
    terrain::register_terrain(&scene, &assets)!;
    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      physics::default_physics_desc(),
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
    renderer.prepare_scene(&scene)!;
    bool painting;
    float brush_seconds;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        HeightView view = terrain::height_view(&scene, &assets, demo.terrain_node.id)!;
        if (!input.keyboard_captured_by_gui) {
            if (input.key_pressed(platform::Scancode.F)) fly_camera.flying = !fly_camera.flying;
            if (input.key_pressed(platform::Scancode.G)) {
                Vec3 ahead = fly_camera.position + look_direction(fly_camera.yaw, 0) * CRATE_DROP_DISTANCE;
                ahead.y = ground_under(&view, ahead, fly_camera.ground) + CRATE_DROP_HEIGHT;
                drop_crate(&demo, ahead);
            }
            if (input.key_pressed(platform::Scancode.P)) {
                if (scene.has(demo.terrain_node, PhysicsBody)) {
                    physics.remove_body(demo.terrain_node);
                } else {
                    add_terrain_collider(&physics, demo.terrain_node, demo.desc)!;
                }
            }
            if (input.key_down(platform::Scancode.B)) {
                brush_seconds += delta;
                uint stamps = (uint)(brush_seconds / BRUSH_STAMP_SECONDS);
                brush_seconds -= (float)stamps * BRUSH_STAMP_SECONDS;
                float rise = BRUSH_RISE_PER_SECOND * BRUSH_STAMP_SECONDS * (float)stamps;
                if (stamps && stamp_under(&demo, fly_camera.position, rise)!) painting = true;
            } else {
                brush_seconds = 0;
                if (painting) {
                    end_stroke(&scene, demo.terrain_node);
                    painting = false;
                }
            }
        }
        if (!input.mouse_captured_by_gui && input.button_pressed(platform::MouseButton.LEFT)) {
            push_picked_crate(&demo, &renderer, input.mouse_position);
        }
        apply_fly_camera(
            fly_camera: &fly_camera,
            input:      input,
            view:       &view,
            delta:      delta,
        );
        place_camera(
            camera_node: demo.camera_node,
            position:    fly_camera.position,
            yaw:         fly_camera.yaw,
            pitch:       fly_camera.pitch,
        );
        scene.update_world();
        physics.update(delta);
        scene.update_world();
        terrain::update(
            scene:                &scene,
            assets:               &assets,
            camera_node:          demo.camera_node,
            output_height_pixels: (float)max(renderer.output_height, 1u),
        )!;

        terrain_panel(&demo, &fly_camera, delta)!;
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
    TextureAsset* record = demo.assets.texture(demo.desc.height_map);
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
    float metres_per_unit = HEIGHT_SCALE / (float)ushort::max;
    float edge = (float)span * CELL_SIZE;
    Vec3 low = { (float)first * CELL_SIZE, (float)lowest * metres_per_unit, (float)first * CELL_SIZE };
    Vec3 high = { low.x + edge, (float)highest * metres_per_unit, low.z + edge };
    float diameter = (high - low).length();
    // A zero threshold splits everything, so any distance keeps the gate; hover where the default would sit.
    float threshold = options.lod_threshold > 0 ? options.lod_threshold : terrain::DEFAULT_LOD_THRESHOLD;
    float middle = (threshold + threshold / (1 + demo.desc.lod_hysteresis)) * 0.5f;
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
    HeightView view = terrain::height_view(demo.scene, demo.assets, demo.terrain_node.id)!;
    float progress = (float)step / (float)segment_frames;
    Vec2 fraction;
    Vec2 travel;
    float altitude;
    float pitch;
    switch (segment) {
        case STILL:
            Vec3 position = extent_point(demo, STILL_POSITION);
            position.y = ground_under(&view, position, 0) + STILL_ALTITUDE;
            place_camera(
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
    position.y = ground_under(&view, position, 0) + altitude;
    place_camera(
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

fn double? time_bounds_build(Demo* demo, BenchmarkResult* result, float output_height) @local {
    double[] runs = result.scratch[:BOUNDS_BUILD_RUNS];
    foreach (&run : runs) {
        demo.assets.mark_texture_dirty(demo.desc.height_map);
        time::Clock started = clock::now();
        terrain::update(
            scene:                demo.scene,
            assets:               demo.assets,
            camera_node:          demo.camera_node,
            output_height_pixels: output_height,
        )!;
        *run = elapsed_ms(started);
    }
    return percentile(runs, 0.5f);
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
    InstancedMesh* batch = demo.scene.get(demo.terrain_node, InstancedMesh);
    TerrainRuntime* runtime = demo.scene.get(demo.terrain_node, TerrainRuntime);
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
        if (stamped) stamp_under(demo, demo.camera_node.local.position, BRUSH_RISE)!;

        demo.scene.update_world();
        demo.physics.update(TIME_STEP);
        demo.scene.update_world();
        uint revision = batch.revision;
        time::Clock selection_started = clock::now();
        terrain::update(
            scene:                demo.scene,
            assets:               demo.assets,
            camera_node:          demo.camera_node,
            output_height_pixels: output_height,
        )!;
        double selection_us = (double)(long)selection_started.to_now() / NANOSECONDS_PER_MICROSECOND;
        render_offscreen(
            renderer:    renderer,
            scene:       demo.scene,
            camera_node: demo.camera_node,
            view:        view,
            frame:       frame,
        )!;

        if (timed) {
            result.records[step] = {
                .selection_us  = selection_us,
                .frame_ms      = elapsed_ms(frame_started),
                .chunks        = batch.count,
                .upload_bytes  = renderer.stats.upload_bytes,
                .lod_switches  = runtime.lod_switches,
                .batch_changed = batch.revision != revision,
                .stamped       = stamped,
            };
            if (segment_step == frames - 1) result.chunks_per_level[segment.ordinal] = runtime.chunks_per_level;
        }
        // A frame's GPU timings arrive once its slot comes round again.
        if (frame >= WARMUP_FRAMES + render::FRAMES_IN_FLIGHT) {
            uint completed = frame - render::FRAMES_IN_FLIGHT - WARMUP_FRAMES;
            if (completed < measured) result.records[completed].gpu_ms = renderer.stats.gpu_pass_ms;
        }
    }
    result.level_count = runtime.level_count;

    end_stroke(demo.scene, demo.terrain_node);
    time::Clock recook_started = clock::now();
    demo.physics.update(TIME_STEP);
    result.physics_recook_ms = elapsed_ms(recook_started);
}

fn void print_edit_results(BenchmarkResult* result, FrameRecord[] edit) @local {
    usz stamps;
    foreach (record : edit) {
        if (!record.stamped) continue;
        result.scratch[stamps] = record.selection_us / MICROSECONDS_PER_MILLISECOND;
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

    bool still_gate = true;
    uint hover_switches;
    foreach (ordinal, name : SEGMENT_NAMES) {
        Segment segment = Segment::from_ordinal(ordinal);
        FrameRecord[] records = result.records[ordinal * frames:frames];
        double[] selection = gather(records, SELECTION_US, result.scratch);
        io::printfn(
            "selection_us segment=%s median=%.3f p99=%.3f",
            name,
            percentile(selection, 0.5f),
            percentile(selection, 0.99f),
        );
        double[] chunks = gather(records, CHUNKS, result.scratch);
        io::printfn("chunks segment=%s median=%.0f max=%.0f", name, percentile(chunks, 0.5f), percentile(chunks, 1.0f));
        io::printf("chunks_per_level segment=%s", name);
        foreach (level_chunks : result.chunks_per_level[ordinal][:result.level_count]) io::printf(" %d", level_chunks);
        io::printn();
        double[] uploads = gather(records, UPLOAD_BYTES, result.scratch);
        io::printfn(
            "upload_bytes segment=%s median=%.0f max=%.0f",
            name,
            percentile(uploads, 0.5f),
            percentile(uploads, 1.0f),
        );

        uint upload_frames;
        uint switches;
        uint revisions;
        foreach (index, record : records) {
            if (record.upload_bytes) upload_frames++;
            switches += record.lod_switches;
            if (index > 0 && record.batch_changed) revisions++;
            bool still_changed = record.upload_bytes || record.batch_changed;
            if (segment == Segment.STILL && index > 0 && still_changed) still_gate = false;
            if (segment == Segment.HOVER && index >= FRAMES_PER_SECOND) hover_switches += record.lod_switches;
        }
        io::printfn("upload_frames segment=%s %d", name, upload_frames);
        if (segment == Segment.STILL) io::printfn("batch_revisions segment=still %d", revisions);
        double switches_per_second = (double)switches * FRAMES_PER_SECOND / (double)frames;
        io::printfn("lod_switches_per_second segment=%s %.3f", name, switches_per_second);
        if (result.timestamps) {
            foreach (pass : REPORTED_PASSES) {
                double median = percentile(gather_pass(records, pass, result.scratch), 0.5f);
                io::printfn("gpu_ms segment=%s pass=%s median=%.4f", name, pass, median);
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
    io::printfn("lod_switches hover_after_first_second %d", hover_switches);
    io::printfn("gate still_uploads %s", still_gate ? "pass" : "fail");
    io::printfn("gate hover_switches %s", hover_switches == 0 ? "pass" : "fail");
    return still_gate && hover_switches == 0;
}

fn void? drop_benchmark_crates(Demo* demo) @local {
    HeightView view = terrain::height_view(demo.scene, demo.assets, demo.terrain_node.id)!;
    Vec3 center = demo.camera_node.local.position + look_direction(STILL_YAW, 0) * STILL_ALTITUDE;
    for (uint index = 0; index < CRATE_STACK_SIDE * CRATE_STACK_SIDE; index++) {
        Vec3 offset = { (float)(index % CRATE_STACK_SIDE), 0, (float)(index / CRATE_STACK_SIDE) };
        Vec3 position = center + (offset - (Vec3){ 1, 0, 1 }) * CRATE_STACK_SPACING;
        position.y = ground_under(&view, position, 0) + CRATE_DROP_HEIGHT;
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
    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!;
    terrain::register_terrain(&scene, &assets)!;
    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      physics::default_physics_desc(),
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
    result.bounds_build_ms = time_bounds_build(&demo, &result, (float)options.height)!;

    io::printfn(
        "# terrain size=%d layers=%d shading=%s shadows=%s lod_threshold=%g hysteresis=%g extent=%dx%d frames=%d "
          "terrain=%s",
        options.size,
        options.layers,
        options.shading == ShadingPath.DEFERRED ? "deferred" : "forward",
        options.traced_shadows ? "traced" : "atlas",
        options.lod_threshold,
        demo.desc.lod_hysteresis,
        options.width,
        options.height,
        options.segment_frames,
        options.hide_terrain ? "hidden" : "visible",
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

<* View a generated terrain interactively, or run the scripted benchmark. *>
fn int main(String[] args) {
    Options? parsed = parse_options(args);
    if (catch excuse = parsed) {
        if (excuse != c3d::UNSUPPORTED) {
            io::eprintfn("Invalid options: %s", excuse);
            io::eprintn("Use [--benchmark [frames]] [--gpu-timings] [--validation] [--shading forward|deferred] "
              "[--shadows atlas|traced] [--size 1025|2049|4097] [--layers 1|4] [--lod-threshold PIXELS] "
              "[--width W] [--height H] [--hide-terrain].");
        }
        return 1;
    }
    Options options = parsed;
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
