module water_example;

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
import c3d::landscape::foliage;
import c3d::landscape::terrain;
import c3d::landscape::water;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;
import landscape_foliage;
import landscape_ground;
import landscape_water_field;

// A quarter of the pixels: on an RTX 4090 at 2560 x 1440 the mirror view takes 0.721 against 0.815 ms still,
// 0.796 against 0.922 ms in orbit, and the frame 2.236 against 2.331 ms.
const float MIRROR_RENDER_SCALE @local = 0.5f;
const uint WATER_LAYER @local = 1 << 3; // beside the terrain and foliage bits; mirrors and captures leave it out
const uint FIXED_NODES @local = 24; // root, terrain, sun, cameras, lake, mirror and layer nodes, with room to spare
const uint TRACE_INSTANCE_CAPACITY @local = 16384; // path-traced trees at every map size; 3.4 MiB of trace table
const float CAMERA_FOV_DEGREES @local = 60;
const float CAMERA_NEAR @local = 0.1f;
const float CAMERA_FAR @local = 8000; // covers the 4 km diagonal of the largest map from its middle
const uint WINDOW_WIDTH @local = 1600;
const uint WINDOW_HEIGHT @local = 900;
const uint BENCHMARK_WIDTH @local = 2560;
const uint BENCHMARK_HEIGHT @local = 1440;
const uint DEFAULT_SEGMENT_FRAMES @local = 300;
const uint WARMUP_FRAMES @local = 60; // history, caches, the first uploads and the crates' splash settle first
const uint SETTLE_MIN_FRAMES @local = 300; // the crates' bob decays in about 3 s whatever the segment length
const uint GATE_FRAMES @local = 60;
const float GATE_TOLERANCE @local = 0.02f; // submerged fraction
const uint FRAMES_PER_SECOND @local = 60;
const float TIME_STEP @local = 1.0f / FRAMES_PER_SECOND;
const uint SAMPLE_BATCHES @local = 10;
const uint SAMPLES_PER_BATCH @local = 10_000; // 100,000 surface samples before the segments
const double NANOSECONDS_PER_MICROSECOND @local = 1_000;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const float PERCENT @local = 100;
const uint RGBA8_BYTES @local = 4;
const uint RGBA_CHANNELS @local = 4;
const float DISPLAY_GAMMA @local = 2.2f; // foam colours are authored linear and stored sRGB

const float LAKE_EXTENT @local = 120; // metres along each side: 97 x 97 vertices at the default cell size
const float LAKE_SEARCH_LOW @local = 0.2f; // share of the ground's extent; keeps the lake off the map edges
const float LAKE_SEARCH_HIGH @local = 0.8f;
const uint LAKE_SEARCH_STEPS @local = 13;
const uint LAKE_SEARCH_SAMPLES @local = 9; // height samples per side of a candidate square
const uint SHORE_SAMPLES @local = 64; // height samples along each edge of the lake square
const float SHORE_MARGIN @local = 0.5f; // metres the lowest edge ground stands above the water
const float BASIN_RADIUS @local = 55; // metres; inside the square, so its edges stay dry
const uint MAX_VIEWERS @local = 2; // --split puts two cameras side by side
const uint MAX_BODIES @local = 2; // the lake and, with --split, a pool
const float POOL_EXTENT @local = 60; // metres along each side; 49 x 49 vertices at the default cell size
const float POOL_BASIN_RADIUS @local = 27; // metres; inside the pool's square
const float POOL_SEARCH_DISTANCE @local = 110; // metres between the pool's and the lake's centres at least
const float POOL_LEVEL_GAP @local = 3; // metres under the lake's water at least; the lake's grass line clears the pool
const float OCEAN_EXTENT @local = 20000; // metres: 256 chunks of 80 m, 87,381 nodes; reaches past the far plane
const float OCEAN_DEPTH @local = 200; // metres below the sea: past the deepest ground under it
const float OCEAN_BED_CLEARANCE @local = 12; // metres between the sea and the highest ground under it
const float BASIN_DEPTH @local = 6; // metres of water over the bed at the centre
const float SHORE_CLEARANCE @local = 0.3f; // metres above the water under which no grass or tree grows

const float POND_WAVE_SPEED @local = 8; // metres per second: a ripple crosses the 55 m basin in about seven seconds
const float POND_DAMPING @local = 0.3f; // per second: the ripple loses half its height in about five seconds
const float POND_DISTORTION @local = 0.4f; // screen uv per unit of tilt: a ripple's slopes still bend the reflection
const float POND_REFRACTION @local = 0.1f;
const float SPECTRAL_LAKE_CELL_SIZE @local = 0.5f; // metres: a lake's fetch raises waves of a metre at most
const float SPECTRAL_LAKE_PATCH @local = 32; // metres: the tile; 12.5 cm per texel
const float STORM_WIND_SPEED @local = 18;
const float CALM_WIND_SPEED @local = 3;
const float SETTLE_TRANSITION_SECONDS @local = 1;
const float STIFF_WAVE_SPEED @local = 60; // metres per second: the benchmark's settle segment, which rings out quickly
const float STIFF_DAMPING @local = 3.2f; // per second: close to critical for the lake's slowest wave at that speed
const float RIPPLE_RADIUS @local = 3; // metres to the rim of a dropped ripple
const float RIPPLE_STRENGTH @local = 10; // metres per second downward at its centre
const float SHOT_DROP_OFFSET @local = -40; // metres west of the lake's centre: a shot's ripple falls by the west shore
const float SHOT_VIEW_OFFSET @local = -12; // metres west of the centre: the shot looks west at the ripple and the shore
const float SHOT_VIEW_HEIGHT @local = 3; // metres over the water
const float SHOT_VIEW_PITCH @local = -0.1f;
const float MAX_RIPPLE_AGE @local = 30; // seconds a shot may spread its ripple: 1,800 updates before its frames
const float CRATE_SIZE @local = 1;
const float CRATE_DENSITY @local = 600; // floats at 0.6 of its height
const float CRATE_DRAG @local = 3000; // newton-seconds per metre: a damping ratio near 0.4 at the density line
const float CRATE_DRAG_COEFFICIENT @local = 1; // near a cube's 1.05
const float CRATE_FIELD @local = 40; // metres across the crates' square; the bed lies 2.6 m down at its corners
const float CRATE_DROP_HEIGHT @local = 2;
const uint DEFAULT_CRATES @local = 16;
const uint MANY_CRATES @local = 256;
const Vec4 CRATE_COLOR @local = { 0.7f, 0.45f, 0.2f, 1 };
const float CRATE_ROUGHNESS @local = 0.7f;

const float STEADY_WIND_SPEED @local = 6;
const float WIND_HEADING_DEGREES @local = 30;
const float MAX_WIND_SPEED @local = 20;
const float SEA_TRANSITION_SECONDS @local = 4; // a gust takes a few wave periods to raise or flatten the sea
const uint SHOT_FRAMES @local = 8; // the sea state switches at the first, the crates and the mirror settle after

const uint SKY_WIDTH @local = 256; // equirectangular; 512 KiB of RGBA32_FLOAT
const uint SKY_HEIGHT @local = 128;
const Vec3 HORIZON_COLOR @local = { 0.75f, 0.85f, 1 };
const Vec3 ZENITH_COLOR @local = { 0.2f, 0.4f, 0.85f };
const Vec3 LOWER_SKY_COLOR @local = { 0.25f, 0.23f, 0.2f }; // below the horizon, where the ground is
const Vec3 SUN_DISC_COLOR @local = { 60, 55, 45 };
const float SUN_DISC_COSINE @local = 0.9995f; // about 3.6 degrees across

const uint RIPPLE_MAP_SIZE @local = 256; // 256 KiB and its mips; one tile covers 1 / RIPPLE_UV_SCALE metres
const float RIPPLE_UV_SCALE @local = 0.25f; // texture periods per metre
const float RIPPLE_SLOPE @local = 0.3f; // slope bound; the eight terms reach 0.6 of it at most; steeper ripples glint like chop
const uint FOAM_MAP_SIZE @local = 128;
const float FOAM_UV_SCALE @local = 0.5f;
const float FOAM_ROUGHNESS @local = 0.8f;
const Vec3 FOAM_LIGHT @local = { 0.95f, 0.97f, 1 };
const Vec3 FOAM_DARK @local = { 0.7f, 0.75f, 0.78f };

// No two terms are parallel and no length is an integer multiple of another, so the tile shows no lattice;
// the weight falls with the length.
const TileTerm[8] RIPPLE_TERMS @local = {
    { .cycles_u = 1, .cycles_v = -3, .weight = 1, .phase = 0 },
    { .cycles_u = 3, .cycles_v = -2, .weight = 0.82f, .phase = 2.4f },
    { .cycles_u = 4, .cycles_v = -1, .weight = 0.67f, .phase = 4.1f },
    { .cycles_u = 3, .cycles_v = -4, .weight = 0.5f, .phase = 1.1f },
    { .cycles_u = 5, .cycles_v = 3, .weight = 0.4f, .phase = 5.3f },
    { .cycles_u = 6, .cycles_v = 1, .weight = 0.37f, .phase = 3.3f },
    { .cycles_u = 5, .cycles_v = 6, .weight = 0.26f, .phase = 0.7f },
    { .cycles_u = 3, .cycles_v = 8, .weight = 0.23f, .phase = 4.8f },
};
const TileTerm[3] FOAM_TERMS @local = {
    { .cycles_u = 4, .cycles_v = 2, .weight = 1, .phase = 0.7f },
    { .cycles_u = -3, .cycles_v = 5, .weight = 0.8f, .phase = 2.4f },
    { .cycles_u = 7, .cycles_v = 6, .weight = 0.5f, .phase = 1.1f },
};

const float DIVE_BACK @local = 18; // metres from the lake's centre: inside the bowl, 4.5 m of water over the bed
const float DIVE_START_HEIGHT @local = 2; // metres over the water
const float DIVE_DEPTH @local = 3; // metres under it
const float DIVE_START_PITCH @local = -0.1f;
const float DIVE_END_PITCH @local = 0.9f; // radians up: the window's edge at 41 degrees of elevation is in the frame
const float DIVE_SECONDS @local = 8; // seconds for one descent; the loop goes down, then up
const float STILL_BACK @local = 0.4f; // share of the lake's extent the still camera stands back from the centre
const float STILL_HEIGHT @local = 6;
const float STILL_PITCH @local = -0.12f;
const float ORBIT_RADIUS @local = 80; // metres from the lake's centre, past its edges
const float ORBIT_HEIGHT @local = 30;
const float CAMERA_CLEARANCE @local = 2; // metres above the ground at least
const uint CAPTURE_SIZE @local = 384;
const Vec2 PANEL_POSITION @local = { 16, 16 };
const Vec2 PANEL_SIZE @local = { 440, 420 };
const Vec2 STATS_PANEL_POSITION @local = { 16, 452 };
const Vec2 STATS_PANEL_SIZE @local = { 440, 300 };
const Vec2 VIEW_STATS_POSITION @local = { 472, 16 };
const Vec2 VIEW_STATS_SIZE @local = { 420, 260 };
const Vec2 TARGETS_PANEL_POSITION @local = { 908, 16 };
const Vec2 TARGETS_PANEL_SIZE @local = { 420, 520 };
const ZString[MAX_VIEWERS] VIEWER_LABELS @local = { "main", "second" };
const ZString[MAX_BODIES][MAX_VIEWERS] MIRROR_LABELS @local = { // by viewer, then body
    { "mirror", "pool mirror" },
    { "second mirror", "second pool mirror" },
};
const String[Segment::len] SEGMENT_NAMES @local = { "still", "orbit", "waves", "settle" };

const Pass[10] REPORTED_PASSES @local = {
    Pass.DEPTH_PREPASS,
    Pass.GBUFFER,
    Pass.SHADOW_ATLAS,
    Pass.FORWARD_OPAQUE,
    Pass.LIGHTING,
    Pass.SCENE_SNAPSHOT,
    Pass.SCENE_READ,
    Pass.FOG,
    Pass.VELOCITY,
    Pass.TEMPORAL_AA,
};

const Pass[2] TRACE_PASSES @local = {
    Pass.TRACE_POSE,
    Pass.ACCELERATION_BUILD,
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
    ORBIT,
    WAVES,
    SETTLE,
}

enum Reflection @local {
    PLANAR,
    MARCH,
    ENV,
}

enum Metric @local {
    FRAME_MS,
    UPLOAD_BYTES,
    MIRROR_MS,
    MIRROR_SHADOW_MS,
    MIRROR_SHADOW_SHARE,
}

// A whole number of periods across the tile along each axis, so the field repeats without seams.
struct TileTerm @local {
    int   cycles_u;
    int   cycles_v;
    float weight;
    float phase;
}

struct Options @local {
    bool        benchmark;
    bool        split;
    uint        segment_frames;
    bool        gpu_timings;
    bool        validation;
    ShadingPath shading;
    uint        size;
    Reflection  reflection;
    float       mirror_scale;
    uint        crates;
    Vec3        current;
    bool        ssgi;
    bool        sky;
    bool        volumetric_fog;
    bool        traced;
    bool        capture;
    bool        ripples;
    bool        sea_state;
    bool        ocean;
    bool        dive;
    bool        simulated;  // bodies simulate their surface; ripples come from the R key, a shot or the benchmark
    bool        spectral;   // bodies draw a spectrum the GPU evolves; the wind sets it
    float       ripple_age; // seconds a shot lets its ripple spread
    float       dive_at;    // share of the descent a shot stands at; negative follows the clock
    float       wind_speed;
    String      shot;
    uint        width;
    uint        height;
}

struct Mirror @local {
    RenderTargetId target;
    ViewId         view;
    uint           width;
    uint           height;
    MirrorState    state;  // BELOW while the viewer is under the water: the view is not rendered
}

struct Capture @local {
    Node*          camera_node;
    RenderTargetId target;
    ViewId         view;
}

// One camera and the view it draws; its index is the mirror slot of every body.
struct Viewer @local {
    Node*  camera_node;
    ViewId view;
}

struct Body @local {
    Node*               node;
    Vec3                centre;  // at the water level
    WaterDesc           desc;    // the application's desc; set_desc hands every edit to the library
    Mirror[MAX_VIEWERS] mirrors; // by viewer
}

struct Exclusion @local {
    Vec2  centre;
    float distance; // metres around the centre where no site lies; zero excludes nothing
    float ceiling;  // highest water level a site may have
}

struct Demo @local {
    Options             options;
    AssetStore*         assets;
    Scene*              scene;
    PhysicsWorld*       physics;
    Ground              ground;
    Viewer[MAX_VIEWERS] viewers;
    uint                viewer_count;
    Body[MAX_BODIES]    bodies; // the lake, then with --split a pool; the body index is its view texture slot
    uint                body_count;
    uint[<2>]           output_size; // the window or target the viewers split
    MaterialId          ripples;
    MaterialId          foam;
    Reflection          reflection;
    float               mirror_scale;
    Capture             capture;
    Node*[]             crates;
    WaterFluid          fluid; // view and time are the physics update's first step
    double              water_update_us;
    double              field_us;            // CPU time water_gpu::update took to record the last frame's passes
    uint                simulation_bytes;    // texture bytes the last update uploaded for the lake's simulation
    uint                simulation_revision; // that texture's revision after the last update
    bool                simulation_awake;
    uint                spectral_bytes;      // texture bytes the last frame uploaded for the lake's spectrum
    uint                spectral_revision;   // the spectrum table's revision after the last frame
}

struct Controls @local {
    Reflection reflection;
    bool       full_mirror;
    bool       calm;
    bool       ripples;
    float      wind_heading_degrees;
    float      wind_speed;
}

struct FrameRecord @local {
    double                    frame_ms;
    double                    physics_us;
    double                    water_update_us;
    double                    field_us;
    uint                      steps;
    uint                      upload_bytes;
    uint                      dispatches;
    uint                      simulation_bytes;
    bool                      simulation_awake;
    uint                      spectral_bytes;
    uint                      shadow_sets_recorded;
    uint                      shadow_sets_shared;
    float[render::PASS_COUNT] frame_gpu_ms;
    float[render::PASS_COUNT] main_gpu_ms;
    float[render::PASS_COUNT] mirror_gpu_ms;
}

struct BenchmarkResult @local {
    FrameRecord[] records;
    double[]      scratch;
    double        sample_ns;
    double        settle_sum;
    uint          settle_count;
    float         settle_worst;
    bool          timestamps;
}

fn Vec3 wind_velocity(float speed, float heading_degrees) @local {
    float heading = math::deg_to_rad(heading_degrees);
    return { math::sin(heading) * speed, 0, math::cos(heading) * speed };
}

fn char unit_to_byte(float value) @local => (char)(math::clamp(value, 0.0f, 1.0f) * (float)char::max + 0.5f);

fn double elapsed_ms(time::Clock started) @local => (double)(long)started.to_now() / NANOSECONDS_PER_MILLISECOND;

fn double frame_time(uint frame) @local => (double)frame * TIME_STEP;

// ----------------------------------------------------------------------------- assets

fn float tile_angle(TileTerm term, float u, float v) @local {
    return 2 * (float)math::PI * ((float)term.cycles_u * u + (float)term.cycles_v * v) + term.phase;
}

fn float tile_value(TileTerm[] terms, float u, float v) @local {
    float value;
    float total;
    foreach (term : terms) {
        value += term.weight * math::sin(tile_angle(term, u, v));
        total += term.weight;
    }
    return 0.5f + 0.5f * value / total;
}

// The gradient of the sum of sines over one tile, scaled so its largest possible length is 1.
fn Vec2 tile_gradient(TileTerm[] terms, float u, float v) @local {
    Vec2 gradient;
    float bound;
    foreach (term : terms) {
        Vec2 cycles = { (float)term.cycles_u, (float)term.cycles_v };
        gradient += cycles * (term.weight * math::cos(tile_angle(term, u, v)));
        bound += term.weight * cycles.length();
    }
    return gradient / bound;
}

fn MaterialId? add_ripples(AssetStore* assets) @local {
    TextureId normal_map;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)RIPPLE_MAP_SIZE * RIPPLE_MAP_SIZE * RGBA8_BYTES);
        for (uint row = 0; row < RIPPLE_MAP_SIZE; row++) {
            for (uint column = 0; column < RIPPLE_MAP_SIZE; column++) {
                float u = (float)column / (float)RIPPLE_MAP_SIZE;
                float v = (float)row / (float)RIPPLE_MAP_SIZE;
                Vec2 slope = tile_gradient(RIPPLE_TERMS[..], u, v) * RIPPLE_SLOPE;
                Vec3 normal = (Vec3){ -slope.x, -slope.y, 1 }.normalize();
                usz offset = ((usz)row * RIPPLE_MAP_SIZE + column) * RGBA8_BYTES;
                pixels[offset] = unit_to_byte(normal.x * 0.5f + 0.5f);
                pixels[offset + 1] = unit_to_byte(normal.y * 0.5f + 0.5f);
                pixels[offset + 2] = unit_to_byte(normal.z * 0.5f + 0.5f);
                pixels[offset + 3] = char::max;
            }
        }
        TextureDesc desc = material::texture_2d_desc(
            width:      RIPPLE_MAP_SIZE,
            height:     RIPPLE_MAP_SIZE,
            format:     RGBA8_UNORM,
            debug_name: "water_ripples",
        );
        normal_map = assets.add_texture(desc, pixels, "water/ripples")!;
    };
    // The water stage reads the normal map alone, at the rest position in metres through this transform.
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.normal_map = material::texture_slot(
        texture:   normal_map,
        transform: { .scale = { RIPPLE_UV_SCALE, RIPPLE_UV_SCALE } },
    );
    return assets.add_material(material::standard(params), "water/ripple_material");
}

fn MaterialId? add_foam(AssetStore* assets) @local {
    TextureId base_color;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)FOAM_MAP_SIZE * FOAM_MAP_SIZE * RGBA8_BYTES);
        for (uint row = 0; row < FOAM_MAP_SIZE; row++) {
            for (uint column = 0; column < FOAM_MAP_SIZE; column++) {
                float value = tile_value(FOAM_TERMS[..], (float)column / FOAM_MAP_SIZE, (float)row / FOAM_MAP_SIZE);
                Vec3 color = FOAM_DARK + (FOAM_LIGHT - FOAM_DARK) * value;
                usz offset = ((usz)row * FOAM_MAP_SIZE + column) * RGBA8_BYTES;
                pixels[offset] = unit_to_byte(math::pow(color.x, 1 / DISPLAY_GAMMA));
                pixels[offset + 1] = unit_to_byte(math::pow(color.y, 1 / DISPLAY_GAMMA));
                pixels[offset + 2] = unit_to_byte(math::pow(color.z, 1 / DISPLAY_GAMMA));
                pixels[offset + 3] = char::max;
            }
        }
        TextureDesc desc = material::texture_2d_desc(
            width:      FOAM_MAP_SIZE,
            height:     FOAM_MAP_SIZE,
            format:     RGBA8_SRGB,
            debug_name: "water_foam",
        );
        base_color = assets.add_texture(desc, pixels, "water/foam")!;
    };
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.metallic = 0;
    params.roughness = FOAM_ROUGHNESS;
    params.base_color_map = material::texture_slot(
        texture:   base_color,
        transform: { .scale = { FOAM_UV_SCALE, FOAM_UV_SCALE } },
    );
    return assets.add_material(material::standard(params), "water/foam_material");
}

// Laid out as environment_source.comp.glsl samples it: longitude along u, the angle from +Y along v.
fn EnvironmentId? add_sky(AssetStore* assets) @local {
    TextureId source;
    Vec3 towards_sun = -landscape_ground::SUN_DIRECTION.normalize();
    @pool() {
        usz channels = (usz)SKY_WIDTH * SKY_HEIGHT * RGBA_CHANNELS;
        char[] pixels = alloc::new_array(tmem, char, (sz)(channels * float::size));
        float[] radiance = ((float*)pixels.ptr)[:channels];
        for (uint row = 0; row < SKY_HEIGHT; row++) {
            for (uint column = 0; column < SKY_WIDTH; column++) {
                float longitude = (((float)column + 0.5f) / SKY_WIDTH - 0.5f) * 2 * (float)math::PI;
                float polar = ((float)row + 0.5f) / SKY_HEIGHT * (float)math::PI;
                Vec3 direction = {
                    math::sin(polar) * math::cos(longitude),
                    math::cos(polar),
                    math::sin(polar) * math::sin(longitude),
                };
                Vec3 color = LOWER_SKY_COLOR;
                if (direction.y >= 0) color = HORIZON_COLOR + (ZENITH_COLOR - HORIZON_COLOR) * math::sqrt(direction.y);
                if (direction.dot(towards_sun) >= SUN_DISC_COSINE) color = SUN_DISC_COLOR;
                usz offset = ((usz)row * SKY_WIDTH + column) * RGBA_CHANNELS;
                radiance[offset] = color.x;
                radiance[offset + 1] = color.y;
                radiance[offset + 2] = color.z;
                radiance[offset + 3] = 1;
            }
        }
        TextureDesc desc = material::texture_2d_desc(
            width:      SKY_WIDTH,
            height:     SKY_HEIGHT,
            format:     RGBA32_FLOAT,
            debug_name: "water_sky",
        );
        source = assets.add_texture(desc, pixels, "water/sky")!;
    };
    return assets.add_environment(light::texture_environment(source), "water/environment");
}

// ----------------------------------------------------------------------------- ground

// The candidate square whose ground varies least: the water sits on the flattest ground of the search grid.
fn Vec2? find_site(
    HeightView* view,
    float ground_extent,
    float extent,
    Exclusion exclusion,
) @local {
    Vec2 best;
    float best_range = float::max;
    float step = (LAKE_SEARCH_HIGH - LAKE_SEARCH_LOW) / (float)(LAKE_SEARCH_STEPS - 1);
    float sample_step = extent / (float)(LAKE_SEARCH_SAMPLES - 1);
    for (uint row = 0; row < LAKE_SEARCH_STEPS; row++) {
        for (uint column = 0; column < LAKE_SEARCH_STEPS; column++) {
            Vec2 centre = { LAKE_SEARCH_LOW + step * (float)column, LAKE_SEARCH_LOW + step * (float)row };
            centre *= ground_extent;
            if (exclusion.distance > 0) {
                if ((centre - exclusion.centre).length() < exclusion.distance) continue;
                if (water_level(view, centre, extent) > exclusion.ceiling) continue;
            }
            float low = float::max;
            float high = -float::max;
            for (uint z = 0; z < LAKE_SEARCH_SAMPLES; z++) {
                for (uint x = 0; x < LAKE_SEARCH_SAMPLES; x++) {
                    float sample_x = centre.x - extent / 2 + sample_step * (float)x;
                    float sample_z = centre.y - extent / 2 + sample_step * (float)z;
                    float height = terrain::sample_height(view, sample_x, sample_z) ?? low;
                    low = math::min(low, height);
                    high = math::max(high, height);
                }
            }
            if (high - low < best_range) {
                best_range = high - low;
                best = centre;
            }
        }
    }
    if (best_range == float::max) return NOT_FOUND~;
    return best;
}

// The lowest ground along the square's edges, less a margin: every edge meets dry ground.
fn float water_level(HeightView* view, Vec2 centre, float extent) @local {
    float lowest = float::max;
    float half = extent / 2;
    for (uint sample = 0; sample <= SHORE_SAMPLES; sample++) {
        float along = -half + extent * (float)sample / (float)SHORE_SAMPLES;
        Vec2[4] edge_points = {
            { centre.x + along, centre.y - half },
            { centre.x + along, centre.y + half },
            { centre.x - half, centre.y + along },
            { centre.x + half, centre.y + along },
        };
        foreach (point : edge_points) {
            lowest = math::min(lowest, terrain::sample_height(view, point.x, point.y) ?? lowest);
        }
    }
    return lowest - SHORE_MARGIN;
}

// A cosine bowl BASIN_DEPTH under the level at the centre, reaching the level at the radius; nothing is raised.
fn void? carve_basin(
    Scene* scene,
    AssetStore* assets,
    Ground* ground,
    Vec2 centre,
    float level,
    float radius,
) @local {
    TextureAsset* record = assets.texture(ground.desc.height_map);
    uint side = record.desc.width;
    ushort* texels = (ushort*)record.pixels.ptr;
    float units_per_metre = (float)ushort::max / ground.desc.height_scale;
    Vec3 local = maths::transform_point(maths::inverse_affine(ground.node.world), { centre.x, level, centre.y });
    float cell_size = ground.desc.cell_size;
    float radius_texels = radius / cell_size;
    uint first_x = (uint)math::max(math::floor(local.x / cell_size - radius_texels), 0.0f);
    uint first_z = (uint)math::max(math::floor(local.z / cell_size - radius_texels), 0.0f);
    uint last_x = min((uint)math::ceil(local.x / cell_size + radius_texels), side - 1);
    uint last_z = min((uint)math::ceil(local.z / cell_size + radius_texels), side - 1);
    for (uint z = first_z; z <= last_z; z++) {
        for (uint x = first_x; x <= last_x; x++) {
            float distance = (Vec2){ (float)x * cell_size - local.x, (float)z * cell_size - local.z }.length();
            if (distance >= radius) continue;
            float depth = BASIN_DEPTH * 0.5f * (1 + math::cos((float)math::PI * distance / radius));
            float bed = math::max((local.y - depth) * units_per_metre, 0.0f);
            usz index = (usz)z * side + x;
            texels[index] = (ushort)math::min((float)texels[index], bed);
        }
    }
    terrain::mark_dirty(
        scene:  scene,
        assets: assets,
        node:   ground.node,
        rect:   {
            .x       = first_x,
            .z       = first_z,
            .columns = last_x - first_x + 1,
            .rows    = last_z - first_z + 1,
        },
    )!;
}

// The node's transform places the collider and the drawn surface alike.
fn void? add_terrain_collider(Scene* scene, PhysicsWorld* physics, Node* node) @local {
    TerrainCollisionInput input = terrain::collision_input(scene, node.id)!;
    ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
    collider.height_field = { .source = TEXTURE, .texture = input.height_map };
    collider.local.scale = input.scale;
    return physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1]);
}

fn void? add_foliage_layer(
    Scene* scene,
    AssetStore* assets,
    Ground* ground,
    FoliageDesc desc,
    float level,
) @local {
    Node* node = scene.add_node(name: "foliage")!;
    node.local = ground.node.local;
    node.layers = landscape_foliage::FOLIAGE_LAYER;
    scene.update_world();
    desc.rules.min_altitude = level + SHORE_CLEARANCE;
    foliage::add_foliage(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   desc,
    )!;
}

// ----------------------------------------------------------------------------- water

fn void? add_body(
    Demo* demo,
    Vec2 site,
    float level,
    float extent,
) @local {
    Scene* scene = demo.scene;
    uint index = demo.body_count;
    WaterDesc desc = water::default_water_desc();
    desc.extent = extent;
    if (demo.options.ocean) {
        desc.mode = OCEAN;
        desc.depth = OCEAN_DEPTH;
        desc.wave_count = 0; // flat until the sea state: the lake's 3.5 m wave is under an ocean's four-cell floor
    }
    if (demo.options.spectral) {
        desc.wave_model = SPECTRAL;
        desc.wave_count = 0;
        if (!demo.options.ocean) {
            desc.cell_size = SPECTRAL_LAKE_CELL_SIZE;
            desc.spectrum.patch_size = SPECTRAL_LAKE_PATCH;
        }
    }
    if (demo.options.simulated) {
        desc.wave_model = SIMULATED;
        desc.wave_count = 0;
        desc.simulation = { .wave_speed = POND_WAVE_SPEED, .damping = POND_DAMPING };
        desc.ground = demo.ground.node.id;
        desc.reflection_distortion = POND_DISTORTION;
        desc.refraction_strength = POND_REFRACTION;
    }
    desc.ripples = demo.options.ripples ? demo.ripples : (MaterialId){};
    desc.foam = demo.foam;
    desc.march_reflections = demo.options.reflection != Reflection.ENV;
    desc.max_mirrors = demo.viewer_count;
    desc.reflection_view_slot = index;
    desc.trace = demo.options.traced;

    Node* node = scene.add_node(name: demo.options.ocean ? "sea" : (index == 0 ? "lake" : "pool"))!;
    node.local.position = { site.x, level, site.y };
    node.layers = WATER_LAYER;
    scene.update_world();
    water::add_water(
        scene:  scene,
        assets: demo.assets,
        node:   node,
        desc:   desc,
    )!;

    demo.bodies[index] = { .node = node, .centre = { site.x, level, site.y }, .desc = desc };
    demo.body_count = index + 1;
}

fn void? add_crates(Demo* demo) @local {
    GeometryId box;
    @pool() {
        Geometry crate = geometry::box(tmem, CRATE_SIZE, CRATE_SIZE, CRATE_SIZE);
        box = demo.assets.add_geometry(&crate, "water/crate")!;
    };
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = CRATE_COLOR;
    params.metallic = 0;
    params.roughness = CRATE_ROUGHNESS;
    MaterialId wood = demo.assets.add_material(material::standard(params), "water/crate_material")!;

    uint count = demo.options.crates;
    uint side = (uint)math::round(math::sqrt((float)count));
    for (uint index = 0; index < count; index++) {
        Vec2 share = { ((float)(index % side) + 0.5f) / side - 0.5f, ((float)(index / side) + 0.5f) / side - 0.5f };
        Node* node = demo.scene.add_mesh(box, wood, name: "crate")!;
        Vec3 offset = { share.x * CRATE_FIELD, CRATE_DROP_HEIGHT, share.y * CRATE_FIELD };
        node.local.position = demo.bodies[0].centre + offset;
        demo.scene.update_world();
        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = { CRATE_SIZE * 0.5f, CRATE_SIZE * 0.5f, CRATE_SIZE * 0.5f };
        collider.density = CRATE_DENSITY;
        demo.physics.add_body(node, physics::default_body_desc(DYNAMIC), (&collider)[:1])!;
        demo.scene.add(node, (Buoyancy){
            .fluid_density    = physics::DEFAULT_FLUID_DENSITY,
            .linear_drag      = CRATE_DRAG,
            .drag_coefficient = CRATE_DRAG_COEFFICIENT,
        });
        demo.crates[index] = node;
    }
}

fn float mean_submerged_fraction(Demo* demo) @local {
    float sum;
    foreach (crate : demo.crates) sum += demo.scene.get(crate, Buoyancy).submerged_fraction;
    return sum / (float)demo.crates.len;
}

// docs/water.md's mirror view: its own target and the body's clip plane, once after the first update_mirror.
fn Mirror? create_mirror(
    Renderer* renderer,
    Scene* scene,
    Node* body,
    uint[<2>] size,
    float render_scale,
    bool volumetric_fog,
) @local {
    RenderTargetId target = render::create_render_target(
        renderer,
        render::render_target_desc(size.x, size.y),
    )!;
    ViewDesc desc = render::texture_view_desc(target);
    desc.render_scale = render_scale;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.volumetric_fog = volumetric_fog;
    desc.clip_plane = scene.get(body, WaterRuntime).clip_plane;
    ViewId view = render::create_view(renderer, desc)!;
    return { .target = target, .view = view, .width = size.x, .height = size.y };
}

// Zero extent covers the whole output; a split halves it, the right half taking the odd column.
fn PixelRect viewer_viewport(Demo* demo, uint index, uint[<2>] output_size) @local {
    if (!demo.options.split) return {};
    uint left = output_size.x / 2;
    if (index == 0) return { .width = left, .height = output_size.y };
    return { .x = left, .width = output_size.x - left, .height = output_size.y };
}

fn bool same_viewport(PixelRect first, PixelRect second) @local {
    return first.x == second.x && first.y == second.y && first.width == second.width && first.height == second.height;
}

// The lens carries the viewer's aspect, so the mirror's projection at its scaled extent equals the viewer's.
// Viewports, aspects and mirror targets follow the output; a view is configured only when its viewport changes.
fn void? follow_viewports(Demo* demo, Renderer* renderer, uint[<2>] output_size) @local {
    foreach (viewer_index, &viewer : demo.viewers[:demo.viewer_count]) {
        PixelRect viewport = viewer_viewport(demo, (uint)viewer_index, output_size);
        uint[<2>] size = viewport.width ? (uint[<2>]){ viewport.width, viewport.height } : output_size;
        ViewDesc current = renderer.views.get(viewer.view).desc;
        if (!same_viewport(current.viewport, viewport)) {
            current.viewport = viewport;
            render::configure_view(renderer, viewer.view, current)!;
        }
        demo.scene.get(viewer.camera_node, Camera).aspect = (float)size.x / (float)size.y;

        foreach (&body : demo.bodies[:demo.body_count]) {
            Mirror* mirror = &body.mirrors[viewer_index];
            if (!mirror.target.generation || (mirror.width == size.x && mirror.height == size.y)) continue;
            render::resize_render_target(
                renderer: renderer,
                target:   mirror.target,
                width:    size.x,
                height:   size.y,
            )!;
            mirror.width = size.x;
            mirror.height = size.y;
        }
    }
}

// docs/water.md's per-frame lines, after update_mirror and before begin_frame: set_desc and a moved body move
// the plane.
fn void? follow_clip_plane(
    Renderer* renderer,
    Scene* scene,
    Node* body,
    ViewId mirror_view,
) @local {
    Plane clip_plane = scene.get(body, WaterRuntime).clip_plane;
    ViewDesc current = renderer.views.get(mirror_view).desc;
    if (clip_plane.normal != current.clip_plane.normal || clip_plane.d != current.clip_plane.d) {
        current.clip_plane = clip_plane;
        render::configure_view(renderer, mirror_view, current)!;
    }
}

// docs/water.md's frame: the mirror before the view that shows the water, fitted to that view's camera.
fn void? render_mirror(
    Renderer* renderer,
    Scene* scene,
    Node* body,
    uint slot,
    ViewId mirror_view,
    Node* viewing_camera,
) @local {
    Node* mirror = scene.node(scene.get(body, WaterRuntime).mirrors[slot]);
    renderer.render_view(
        scene:         scene,
        camera_node:   mirror,
        view:          mirror_view,
        shadow_camera: viewing_camera,
    )!;
    renderer.finish_view(mirror_view)!;
}

// Without a planar mirror the stage marches the snapshot; the environment source also turns the march off.
fn void? apply_reflection(Demo* demo, Reflection reflection) @local {
    bool march = reflection != Reflection.ENV;
    foreach (&body : demo.bodies[:demo.body_count]) {
        if (march == body.desc.march_reflections) continue;
        body.desc.march_reflections = march;
        set_water_desc(demo, body)!;
    }
    demo.reflection = reflection;
}

fn void? set_water_desc(Demo* demo, Body* body) @local {
    return water::set_desc(
        scene:  demo.scene,
        assets: demo.assets,
        node:   body.node,
        desc:   body.desc,
    );
}

fn void? set_calm(Demo* demo, bool calm) @local {
    WaterDesc defaults = water::default_water_desc();
    foreach (&body : demo.bodies[:demo.body_count]) {
        for (uint index = 0; index < body.desc.wave_count; index++) {
            body.desc.waves[index].amplitude = calm ? defaults.waves[index].amplitude : 0;
        }
        set_water_desc(demo, body)!;
    }
}

// The desc copy follows the library's write, so later edits through set_desc keep the sea.
fn void? apply_sea_state(Demo* demo, Vec3 wind, float transition_seconds) @local {
    foreach (&body : demo.bodies[:demo.body_count]) {
        water::set_sea_state(
            scene:              demo.scene,
            assets:             demo.assets,
            node:               body.node.id,
            wind_velocity:      { wind.x, wind.z },
            transition_seconds: transition_seconds,
        )!;
        body.desc = demo.scene.get(body.node, Water).desc;
    }
}

fn void? set_ripples(Demo* demo, bool ripples) @local {
    foreach (&body : demo.bodies[:demo.body_count]) {
        body.desc.ripples = ripples ? demo.ripples : (MaterialId){};
        set_water_desc(demo, body)!;
    }
}

// A faster, more damped pond, so the ripple of the benchmark's waves segment dies within the settle segment.
fn void? stiffen_ponds(Demo* demo) @local {
    foreach (&body : demo.bodies[:demo.body_count]) {
        body.desc.simulation = { .wave_speed = STIFF_WAVE_SPEED, .damping = STIFF_DAMPING };
        set_water_desc(demo, body)!;
    }
}

// Where a ray from the position along the direction meets each body's rest plane, the ripple's centre there.
fn void? drop_ripples(Demo* demo, Vec3 origin, Vec3 direction) @local {
    if (direction.y >= 0) return;
    foreach (&body : demo.bodies[:demo.body_count]) {
        Vec3 point = origin + direction * ((body.centre.y - origin.y) / direction.y);
        water::add_impulse(
            scene:          demo.scene,
            node:           body.node.id,
            world_position: point,
            radius:         RIPPLE_RADIUS,
            strength:       RIPPLE_STRENGTH,
        )!;
    }
}

// Texture bytes the update just uploaded for the lake's simulation, and whether the lake is still stepping.
fn void track_simulation(Demo* demo) @local {
    if (!demo.options.simulated) return;
    SimulationState* state = demo.scene.get(demo.bodies[0].node, WaterRuntime).simulation;
    TextureAsset* texture = demo.assets.texture(state.texture);
    demo.simulation_bytes = texture.header.revision != demo.simulation_revision ? (uint)texture.pixels.len : 0;
    demo.simulation_revision = texture.header.revision;
    demo.simulation_awake = state.awake;
}

// Texture bytes the last frame uploaded for the lake's spectrum, which only a sea-state change rewrites.
fn void track_spectrum(Demo* demo) @local {
    if (!demo.options.spectral) return;
    SpectralState* state = demo.scene.get(demo.bodies[0].node, WaterRuntime).spectral;
    TextureAsset* table = demo.assets.texture(state.table);
    demo.spectral_bytes = table.header.revision != demo.spectral_revision ? (uint)table.pixels.len : 0;
    demo.spectral_revision = table.header.revision;
}

// The capture has no mirror of its own, so it leaves the water out.
fn Capture? create_capture(Renderer* renderer, Demo* demo) @local {
    Camera lens = camera::perspective_deg(CAMERA_FOV_DEGREES, CAMERA_NEAR, CAMERA_FAR);
    lens.layers &= ~WATER_LAYER;
    Node* node = demo.scene.add_camera(lens, name: "capture")!;
    HeightView view = terrain::height_view(demo.scene, demo.assets, demo.ground.node.id)!;
    Vec3 centre = demo.bodies[0].centre;
    Vec3 position = centre + (Vec3){ ORBIT_RADIUS, 0, 0 };
    float ground = landscape_ground::ground_under(&view, position, centre.y);
    position.y = math::max(centre.y + STILL_HEIGHT, ground + CAMERA_CLEARANCE);
    landscape_ground::place_camera(
        camera_node: node,
        position:    position,
        yaw:         -(float)math::PI / 2,
        pitch:       STILL_PITCH,
    );
    RenderTargetId target = render::create_render_target(
        renderer,
        render::render_target_desc(CAPTURE_SIZE, CAPTURE_SIZE),
    )!;
    ViewId capture_view = render::create_view(renderer, render::texture_view_desc(target))!;
    return { .camera_node = node, .target = target, .view = capture_view };
}

// ----------------------------------------------------------------------------- setup

fn uint grid_cells(float extent, float cell_size) @local {
    uint side = (uint)math::ceil(extent / cell_size);
    return side * side;
}

fn uint instance_batches(float extent) @local {
    return grid_cells(extent, foliage::DEFAULT_CELL_SIZE) + grid_cells(extent, landscape_foliage::TREE_CELL_SIZE) + 1;
}

fn Scene create_demo_scene(Options options) @local {
    float extent = (float)(options.size - 1) * landscape_ground::CELL_SIZE;
    return scene::create_scene(mem, { .max_nodes = FIXED_NODES + instance_batches(extent) + options.crates });
}

fn RendererDesc renderer_desc(Options options, bool validation, ZString application_name) @local {
    float extent = (float)(options.size - 1) * landscape_ground::CELL_SIZE;
    return {
        .validation            = validation,
        .gpu_timings           = options.gpu_timings,
        .application_name      = application_name,
        .ray_tracing_pipelines = options.traced,
        .max_trace_instances   = options.traced ? TRACE_INSTANCE_CAPACITY : 0,
        .max_instance_batches  = instance_batches(extent),
    };
}

fn ViewDesc main_view_desc(ViewDesc desc, Options options) @local {
    desc.shading = options.shading;
    desc.post.anti_aliasing = AntiAliasing.TAA;
    if (options.ssgi) desc.screen_space_gi = render::SCREEN_SPACE_GI_DEFAULT;
    desc.volumetric_fog = options.volumetric_fog && !options.traced;
    if (options.traced) {
        desc.shading = ShadingPath.PATH_TRACED;
        desc.post.anti_aliasing = AntiAliasing.NONE;
    }
    return desc;
}

// The second viewer faces the pool from the same stand-off the interactive camera keeps from the lake.
fn void? place_second_viewer(Demo* demo) @local {
    HeightView view = terrain::height_view(demo.scene, demo.assets, demo.ground.node.id)!;
    Vec3 centre = demo.bodies[1].centre;
    Vec3 position = centre - (Vec3){ STILL_BACK * POOL_EXTENT, 0, 0 };
    float ground = landscape_ground::ground_under(&view, position, centre.y);
    position.y = math::max(centre.y + STILL_HEIGHT, ground + CAMERA_CLEARANCE);
    landscape_ground::place_camera(
        camera_node: demo.viewers[1].camera_node,
        position:    position,
        yaw:         (float)math::PI / 2,
        pitch:       STILL_PITCH,
    );
}

fn void? add_lake_scene(Demo* demo) @local {
    Scene* scene = demo.scene;
    AssetStore* assets = demo.assets;
    HeightView view = terrain::height_view(scene, assets, demo.ground.node.id)!;
    Vec2 site = find_site(
        view:          &view,
        ground_extent: demo.ground.extent,
        extent:        LAKE_EXTENT,
        exclusion:     {},
    )!;
    float level = water_level(&view, site, LAKE_EXTENT);
    carve_basin(
        scene:  scene,
        assets: assets,
        ground: &demo.ground,
        centre: site,
        level:  level,
        radius: BASIN_RADIUS,
    )!;

    Vec2 pool_site;
    float pool_level;
    if (demo.options.split) {
        pool_site = find_site(
            view:          &view,
            ground_extent: demo.ground.extent,
            extent:        POOL_EXTENT,
            exclusion:     {
                .centre   = site,
                .distance = POOL_SEARCH_DISTANCE,
                .ceiling  = level - POOL_LEVEL_GAP,
            },
        )!;
        pool_level = water_level(&view, pool_site, POOL_EXTENT);
        carve_basin(
            scene:  scene,
            assets: assets,
            ground: &demo.ground,
            centre: pool_site,
            level:  pool_level,
            radius: POOL_BASIN_RADIUS,
        )!;
    }

    landscape_ground::add_sun_and_sky(scene, false, demo.options.sky)!;
    EnvironmentId sky = add_sky(assets)!;
    scene.environment = sky;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = sky;

    FoliageDesc grass = landscape_foliage::grass_layer_desc(assets, &demo.ground)!;
    add_foliage_layer(
        scene:  scene,
        assets: assets,
        ground: &demo.ground,
        desc:   grass,
        level:  level,
    )!;
    float fade_end = landscape_foliage::DEFAULT_TREE_FADE_END;
    FoliageDesc trees = landscape_foliage::tree_layer_desc(assets, &demo.ground, fade_end)!;
    add_foliage_layer(
        scene:  scene,
        assets: assets,
        ground: &demo.ground,
        desc:   trees,
        level:  level,
    )!;
    // Built after the carve, so the collider cooks the basin once.
    add_terrain_collider(scene, demo.physics, demo.ground.node)!;

    demo.ripples = add_ripples(assets)!;
    demo.foam = add_foam(assets)!;
    add_body(
        demo:   demo,
        site:   site,
        level:  level,
        extent: LAKE_EXTENT,
    )!;
    if (demo.options.split) {
        add_body(
            demo:   demo,
            site:   pool_site,
            level:  pool_level,
            extent: POOL_EXTENT,
        )!;
    }
}

// The ground sinks under the sea, so the water reaches the horizon over a bed no one stands on.
fn void? add_ocean_scene(Demo* demo) @local {
    Scene* scene = demo.scene;
    AssetStore* assets = demo.assets;
    TerrainHeightRange range = terrain::height_range(scene, demo.ground.node.id)!;
    demo.ground.node.local.position.y -= range.maximum + OCEAN_BED_CLEARANCE;
    scene.update_world();

    landscape_ground::add_sun_and_sky(scene, false, demo.options.sky)!;
    EnvironmentId sky = add_sky(assets)!;
    scene.environment = sky;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = sky;
    add_terrain_collider(scene, demo.physics, demo.ground.node)!;

    demo.ripples = add_ripples(assets)!;
    demo.foam = add_foam(assets)!;
    add_body(
        demo:   demo,
        site:   { demo.ground.extent / 2, demo.ground.extent / 2 },
        level:  0,
        extent: OCEAN_EXTENT,
    )!;
}

fn void? build_demo(Demo* demo) @local {
    Scene* scene = demo.scene;
    AssetStore* assets = demo.assets;
    demo.viewer_count = demo.options.split ? 2 : 1;
    demo.ground = landscape_ground::add_ground(
        scene:         scene,
        assets:        assets,
        size:          demo.options.size,
        layers:        landscape_ground::LAYER_COUNT,
        lod_threshold: terrain::DEFAULT_LOD_THRESHOLD,
    )!;
    if (demo.options.ocean) {
        add_ocean_scene(demo)!;
    } else {
        add_lake_scene(demo)!;
    }

    foreach (index, &viewer : demo.viewers[:demo.viewer_count]) {
        viewer.camera_node = scene.add_camera(
            camera::perspective_deg(CAMERA_FOV_DEGREES, CAMERA_NEAR, CAMERA_FAR),
            name: index == 0 ? "camera" : "second_camera",
        )!;
    }

    add_crates(demo)!;
    demo.physics.set_fluid_sampler(&water::fluid_sample, &demo.fluid);
    scene.update_world();
    if (demo.options.split) {
        place_second_viewer(demo)!;
        scene.update_world();
    }
}

// The mirrors' first placement needs the cameras where the frames will put them.
fn void? prepare_views(Demo* demo, Renderer* renderer, uint[<2>] output_size) @local {
    follow_viewports(demo, renderer, output_size)!;
    demo.output_size = output_size;
    demo.scene.update_world();
    place_mirrors(demo)!;

    foreach (viewer_index, &viewer : demo.viewers[:demo.viewer_count]) {
        PixelRect viewport = viewer_viewport(demo, (uint)viewer_index, output_size);
        uint[<2>] size = viewport.width ? (uint[<2>]){ viewport.width, viewport.height } : output_size;
        foreach (&body : demo.bodies[:demo.body_count]) {
            body.mirrors[viewer_index] = create_mirror(
                renderer:       renderer,
                scene:          demo.scene,
                body:           body.node,
                size:           size,
                render_scale:   demo.mirror_scale,
                volumetric_fog: demo.options.volumetric_fog,
            )!;
        }
    }

    apply_reflection(demo, demo.options.reflection)!;
    if (demo.options.capture) demo.capture = create_capture(renderer, demo)!;
}

// Each viewer owns the mirror slot of its own index on every body.
fn void? place_mirrors(Demo* demo) @local {
    foreach (viewer_index, &viewer : demo.viewers[:demo.viewer_count]) {
        foreach (&body : demo.bodies[:demo.body_count]) {
            body.mirrors[viewer_index].state = water::update_mirror(
                scene:          demo.scene,
                body:           body.node.id,
                slot:           (uint)viewer_index,
                viewing_camera: viewer.camera_node.id,
            )!;
        }
    }
}

// The sea follows the viewer in snap steps, so no level's vertices slide under the waves.
fn void follow_ocean(Demo* demo) @local {
    if (!demo.options.ocean) return;

    Body* sea = &demo.bodies[0];
    float step = water::ocean_snap_step(&sea.desc);
    Vec3 eye = demo.viewers[0].camera_node.local.position;
    sea.node.local.position.x = math::round(eye.x / step) * step;
    sea.node.local.position.z = math::round(eye.z / step) * step;
}

// The frame order of docs/water.md, after the cameras moved and before begin_frame.
fn double? step_scene(
    Demo* demo,
    Renderer* renderer,
    Vec3 wind,
    double time,
    float delta,
) @local {
    Scene* scene = demo.scene;
    follow_ocean(demo);
    scene.update_world();
    terrain::update(scene, demo.assets)!;
    foliage::update(scene, demo.assets, wind)!;
    time::Clock water_started = clock::now();
    water::update(
        scene:         scene,
        assets:        demo.assets,
        wind_velocity: wind,
        time:          time,
    );
    demo.water_update_us = (double)(long)water_started.to_now() / NANOSECONDS_PER_MICROSECOND;
    track_simulation(demo);
    track_spectrum(demo);

    place_mirrors(demo)!;
    foreach (&body : demo.bodies[:demo.body_count]) {
        foreach (&mirror : body.mirrors[:demo.viewer_count]) {
            follow_clip_plane(
                renderer:    renderer,
                scene:       scene,
                body:        body.node,
                mirror_view: mirror.view,
            )!;
        }
    }

    demo.fluid = {
        .view    = water::surface_view(scene, demo.assets, demo.bodies[0].node.id)!,
        .time    = time,
        .current = demo.options.current,
    };

    time::Clock started = clock::now();
    demo.physics.update(delta);
    double physics_us = (double)(long)started.to_now() / NANOSECONDS_PER_MICROSECOND;
    scene.update_world();
    return physics_us;
}

// docs/water.md's render order: each viewer's mirrors, the textures it is given, then the viewer itself. The
// capture renders last: a view with another shadow key between mirror and main would make main re-record.
fn void? render_views(Demo* demo, Renderer* renderer) @local {
    time::Clock fields_started = clock::now();
    landscape_water_field::update(renderer, demo.scene, demo.assets)!;
    demo.field_us = (double)(long)fields_started.to_now() / NANOSECONDS_PER_MICROSECOND;

    foreach (viewer_index, &viewer : demo.viewers[:demo.viewer_count]) {
        foreach (&body : demo.bodies[:demo.body_count]) {
            RenderTargetId target;
            Mirror* mirror = &body.mirrors[viewer_index];
            if (demo.reflection == Reflection.PLANAR && mirror.state == MirrorState.PLACED) {
                render_mirror(
                    renderer:       renderer,
                    scene:          demo.scene,
                    body:           body.node,
                    slot:           (uint)viewer_index,
                    mirror_view:    mirror.view,
                    viewing_camera: viewer.camera_node,
                )!;
                target = mirror.target;
            }
            renderer.set_view_texture(viewer.view, body.desc.reflection_view_slot, target)!;
        }

        renderer.render_view(demo.scene, viewer.camera_node, viewer.view)!;
        renderer.finish_view(viewer.view)!;
    }

    if (!demo.options.capture) return;
    renderer.render_view(demo.scene, demo.capture.camera_node, demo.capture.view)!;
    return renderer.finish_view(demo.capture.view);
}

// ----------------------------------------------------------------------------- options

fn String? option_value(String[] args, usz* index) @local {
    if (*index + 1 >= args.len) return c3d::INVALID_ARGUMENT~;
    (*index)++;
    return args[*index];
}

fn Vec3? parse_current(String text) @local {
    sz comma = text.index_of_char(',')!;
    return { text[:comma].to_float()!, 0, text[comma + 1..].to_float()! };
}

fn Options? parse_options(String[] args) @local {
    Options options = {
        .segment_frames = DEFAULT_SEGMENT_FRAMES,
        .shading        = ShadingPath.FORWARD,
        .size           = landscape_ground::DEFAULT_MAP_SIZE,
        .reflection     = Reflection.PLANAR,
        .mirror_scale   = MIRROR_RENDER_SCALE,
        .crates         = DEFAULT_CRATES,
        .ripples        = true,
        .wind_speed     = STEADY_WIND_SPEED,
    };
    bool waves_chosen;
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
                    io::eprintn("--gpu-timings needs GPU profiling: python3 scripts/build.py --target water "
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
            case "--size":
                options.size = option_value(args, &index)!.to_uint()!;
                if (!landscape_ground::is_map_size(options.size)) return c3d::INVALID_ARGUMENT~;
            case "--reflection":
                switch (option_value(args, &index)!) {
                    case "planar": options.reflection = Reflection.PLANAR;
                    case "march": options.reflection = Reflection.MARCH;
                    case "env": options.reflection = Reflection.ENV;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--mirror-scale":
                switch (option_value(args, &index)!) {
                    case "0.5": options.mirror_scale = 0.5f;
                    case "1": options.mirror_scale = 1;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--crates":
                options.crates = option_value(args, &index)!.to_uint()!;
                if (options.crates != DEFAULT_CRATES && options.crates != MANY_CRATES) return c3d::INVALID_ARGUMENT~;
            case "--current": options.current = parse_current(option_value(args, &index)!)!;
            case "--ssgi": options.ssgi = true;
            case "--traced": options.traced = true;
            case "--capture": options.capture = true;
            case "--split": options.split = true;
            case "--ripples":
                switch (option_value(args, &index)!) {
                    case "on": options.ripples = true;
                    case "off": options.ripples = false;
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--waves":
                waves_chosen = true;
                switch (option_value(args, &index)!) {
                    case "gerstner":
                        options.simulated = false;
                        options.spectral = false;
                    case "simulated":
                        options.simulated = true;
                        options.spectral = false;
                    case "spectral":
                        $if !landscape_water_field::ENABLED:
                            io::eprintn("--waves spectral needs the gated build: "
                              "python3 scripts/build.py --example water_gpu");
                            return c3d::UNSUPPORTED~;
                        $else
                            options.simulated = false;
                            options.spectral = true;
                        $endif
                    default: return c3d::INVALID_ARGUMENT~;
                }
            case "--ripple-age":
                options.ripple_age = option_value(args, &index)!.to_float()!;
                if (!(options.ripple_age >= 0 && options.ripple_age <= MAX_RIPPLE_AGE)) return c3d::INVALID_ARGUMENT~;
            case "--sea-state": options.sea_state = true;
            case "--ocean": options.ocean = true;
            case "--dive":
                options.dive = true;
                options.dive_at = -1;
                if (index + 1 < args.len) {
                    if (try share = args[index + 1].to_float()) {
                        if (!(share >= 0 && share <= 1)) return c3d::INVALID_ARGUMENT~;
                        options.dive_at = share;
                        index++;
                    }
                }
            case "--wind":
                options.wind_speed = option_value(args, &index)!.to_float()!;
                if (!(options.wind_speed >= 0 && options.wind_speed <= MAX_WIND_SPEED)) return c3d::INVALID_ARGUMENT~;
            case "--shot": options.shot = option_value(args, &index)!;
            case "--sky": options.sky = true;
            case "--volumetric-fog": options.volumetric_fog = true;
            case "--width": options.width = option_value(args, &index)!.to_uint()!;
            case "--height": options.height = option_value(args, &index)!.to_uint()!;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    $if landscape_water_field::ENABLED:
        // Four analytic waves show far-field regularity at high wind; the spectral sea does not.
        if (options.ocean && !waves_chosen) options.spectral = true;
    $endif
    if (options.volumetric_fog && !options.sky) return c3d::INVALID_ARGUMENT~;
    if (options.ocean && (options.split || options.traced)) return c3d::INVALID_ARGUMENT~;
    if (options.simulated && (options.ocean || options.sea_state)) return c3d::INVALID_ARGUMENT~;
    if (options.ripple_age > 0 && !(options.simulated && options.shot.len)) return c3d::INVALID_ARGUMENT~;
    if (options.ocean) {
        options.sea_state = true;
        options.crates = 0;
    }
    if (options.spectral) options.sea_state = true;
    if (options.benchmark && options.current != (Vec3){}) return c3d::INVALID_ARGUMENT~;
    if (options.dive && options.benchmark) return c3d::INVALID_ARGUMENT~;
    if (options.shot.len && options.benchmark) return c3d::INVALID_ARGUMENT~;
    bool offscreen = options.benchmark || options.shot.len;
    if (!options.width) options.width = offscreen ? BENCHMARK_WIDTH : WINDOW_WIDTH;
    if (!options.height) options.height = offscreen ? BENCHMARK_HEIGHT : WINDOW_HEIGHT;
    return options;
}

// ----------------------------------------------------------------------------- interactive

fn void? water_panel(
    Demo* demo,
    Renderer* renderer,
    Controls* controls,
    double physics_us,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    Controls before = *controls;
    if (imgui::begin("Water", null, {})) {
        imgui::text("Right drag looks, WASD move, Shift fast; F flies, Q and E sink and rise");
        imgui::text("B raises the ground under the camera");
        imgui::separator_text("Reflection");
        if (imgui::radio_button("Planar", controls.reflection == Reflection.PLANAR)) controls.reflection = PLANAR;
        imgui::same_line();
        if (imgui::radio_button("March", controls.reflection == Reflection.MARCH)) controls.reflection = MARCH;
        imgui::same_line();
        if (imgui::radio_button("Environment", controls.reflection == Reflection.ENV)) controls.reflection = ENV;
        imgui::checkbox("Full-resolution mirror", &controls.full_mirror);
        imgui::separator_text("Surface");
        if (!demo.options.sea_state && !demo.options.simulated) {
            imgui::checkbox("Calm waves (off: zero amplitudes)", &controls.calm);
        }
        if (demo.options.simulated) imgui::text("R drops a ripple where the camera looks");
        if (demo.options.spectral) {
            SpectralState* state = demo.scene.get(demo.bodies[0].node, WaterRuntime).spectral;
            imgui::text("Spectral: sigma %.3f m, twin bound %.3f m", state.sigma, state.bound);
        }
        imgui::checkbox("Ripples", &controls.ripples);
        imgui::slider_float(
            label: "Wind heading",
            v:     &controls.wind_heading_degrees,
            v_min: 0,
            v_max: 360,
        );
        imgui::slider_float(
            label: "Wind speed",
            v:     &controls.wind_speed,
            v_min: 0,
            v_max: MAX_WIND_SPEED,
        );
        if (demo.crates.len) {
            imgui::separator_text("Crates");
            imgui::text(
                "%u crates, mean submerged fraction %.3f (expected %.2f)",
                (uint)demo.crates.len,
                mean_submerged_fraction(demo),
                CRATE_DENSITY / physics::DEFAULT_FLUID_DENSITY,
            );
        }
        imgui::text("physics.update %.1f us per step", physics_us);
        imgui::text("Scene snapshots %u, upload %u bytes", renderer.stats.scene_snapshots, renderer.stats.upload_bytes);
    }
    imgui::end();

    if (controls.reflection != before.reflection) apply_reflection(demo, controls.reflection)!;
    if (controls.full_mirror != before.full_mirror) {
        foreach (&body : demo.bodies[:demo.body_count]) {
            foreach (&mirror : body.mirrors[:demo.viewer_count]) {
                ViewDesc desc = renderer.views.get(mirror.view).desc;
                desc.render_scale = controls.full_mirror ? 1 : MIRROR_RENDER_SCALE;
                render::configure_view(renderer, mirror.view, desc)!;
            }
        }
    }
    if (controls.calm != before.calm) set_calm(demo, controls.calm)!;
    if (controls.ripples != before.ripples) set_ripples(demo, controls.ripples)!;
    bool wind_changed = controls.wind_speed != before.wind_speed
        || controls.wind_heading_degrees != before.wind_heading_degrees;
    if (demo.options.sea_state && wind_changed) {
        apply_sea_state(
            demo:               demo,
            wind:               wind_velocity(controls.wind_speed, controls.wind_heading_degrees),
            transition_seconds: SEA_TRANSITION_SECONDS,
        )!;
    }
}

fn void view_stats_panel(Demo* demo, Renderer* renderer) @local {
    ViewId[MAX_VIEWERS * (1 + MAX_BODIES) + 1] views;
    ZString[MAX_VIEWERS * (1 + MAX_BODIES) + 1] labels;
    usz count;
    foreach (viewer_index, &viewer : demo.viewers[:demo.viewer_count]) {
        views[count] = viewer.view;
        labels[count++] = VIEWER_LABELS[viewer_index];
        foreach (body_index, &body : demo.bodies[:demo.body_count]) {
            views[count] = body.mirrors[viewer_index].view;
            labels[count++] = MIRROR_LABELS[viewer_index][body_index];
        }
    }
    if (demo.options.capture) {
        views[count] = demo.capture.view;
        labels[count++] = "capture";
    }

    imgui::set_next_window_pos(VIEW_STATS_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(VIEW_STATS_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("View stats", null, {})) gui::view_stats_table(renderer, views[:count], labels[:count]);
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
        render_views(demo, renderer)!;
        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    return renderer.end_frame();
}

fn void? follow_output_size(Demo* demo, Renderer* renderer) @local {
    uint[<2>] size = { renderer.output_width, renderer.output_height };
    if (!size.x || !size.y || size == demo.output_size) return;
    follow_viewports(demo, renderer, size)!;
    demo.output_size = size;
}

fn void? run_interactive(Options options) @local {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d water", options.width, options.height))!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      renderer_desc(options, true, "c3d_water"),
    )!;
    defer render::destroy_renderer(&renderer);
    Scene scene = create_demo_scene(options);
    defer scene::destroy_scene(&scene);
    terrain::register_terrain(&scene, &assets)!;
    foliage::register_foliage(&scene)!;
    water::register_water(&scene, &assets)!;
    physics::register_physics(&scene)!;
    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      physics::default_physics_desc(),
    )!;
    defer physics::destroy_physics_world(&physics);

    Demo demo = {
        .options      = options,
        .assets       = &assets,
        .scene        = &scene,
        .physics      = &physics,
        .mirror_scale = options.mirror_scale,
        .crates       = alloc::new_array(mem, Node*, (sz)options.crates),
    };
    defer alloc::free(mem, demo.crates.ptr);
    build_demo(&demo)!;
    Vec3 start = demo.bodies[0].centre - (Vec3){ STILL_BACK * LAKE_EXTENT, -STILL_HEIGHT, 0 };
    FlyCamera fly_camera = { .position = start, .yaw = (float)math::PI / 2, .pitch = STILL_PITCH, .flying = true };
    landscape_ground::place_camera(
        camera_node: demo.viewers[0].camera_node,
        position:    fly_camera.position,
        yaw:         fly_camera.yaw,
        pitch:       fly_camera.pitch,
    );
    demo.viewers[0].view = renderer.default_view;
    render::configure_view(&renderer, renderer.default_view, main_view_desc(render::default_view_desc(), options))!;
    if (options.split) {
        demo.viewers[1].view = render::create_view(
            &renderer,
            main_view_desc(render::default_view_desc(), options),
        )!;
    }
    prepare_views(&demo, &renderer, { max(renderer.output_width, 1u), max(renderer.output_height, 1u) })!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    TargetsPanelState targets = gui::default_targets_panel_state();

    Controls controls = {
        .reflection           = options.reflection,
        .full_mirror          = options.mirror_scale == 1,
        .calm                 = true,
        .ripples              = options.ripples,
        .wind_heading_degrees = WIND_HEADING_DEGREES,
        .wind_speed           = options.wind_speed,
    };
    if (options.sea_state) {
        apply_sea_state(
            demo:               &demo,
            wind:               wind_velocity(controls.wind_speed, controls.wind_heading_degrees),
            transition_seconds: 0,
        )!;
    }
    renderer.prepare_scene(&scene)!;
    Brush brush;
    bool painting;
    double physics_us;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        water_panel(
            demo:       &demo,
            renderer:   &renderer,
            controls:   &controls,
            physics_us: physics_us,
        )!;

        HeightView view = terrain::height_view(&scene, &assets, demo.ground.node.id)!;
        bool held = !input.keyboard_captured_by_gui && input.key_down(platform::Scancode.B);
        if (!input.keyboard_captured_by_gui && input.key_pressed(platform::Scancode.F)) {
            fly_camera.flying = !fly_camera.flying;
        }
        bool can_drop = demo.options.simulated && !options.dive && !input.keyboard_captured_by_gui;
        if (can_drop && input.key_pressed(platform::Scancode.R)) {
            drop_ripples(
                demo:      &demo,
                origin:    fly_camera.position,
                direction: landscape_ground::look_direction(fly_camera.yaw, fly_camera.pitch),
            )!;
        }
        float rise = brush.rise(held, delta);
        if (rise > 0) {
            landscape_ground::stamp_under(
                scene:        &scene,
                assets:       &assets,
                terrain_node: demo.ground.node,
                position:     fly_camera.position,
                rise:         rise,
            )!;
        }
        // The terrain example's stroke end: the collider re-cooks once the brush lifts.
        if (painting && !held) scene.get(demo.ground.node, PhysicsBody).mark_changed();
        painting = held;
        if (options.dive) {
            place_dive(&demo, dive_share(options, window.clock.total));
        } else {
            landscape_ground::apply_fly_camera(
                fly_camera: &fly_camera,
                input:      input,
                view:       &view,
                delta:      delta,
            );
            landscape_ground::place_camera(
                camera_node: demo.viewers[0].camera_node,
                position:    fly_camera.position,
                yaw:         fly_camera.yaw,
                pitch:       fly_camera.pitch,
            );
        }
        physics_us = step_scene(
            demo:     &demo,
            renderer: &renderer,
            wind:     wind_velocity(controls.wind_speed, controls.wind_heading_degrees),
            time:     window.clock.total,
            delta:    delta,
        )! / (double)max(physics.steps_last_update, 1u);

        view_stats_panel(&demo, &renderer);
        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(&renderer)!;
        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::targets_panel(
            renderer:    &renderer,
            view:        renderer.default_view,
            state:       &targets,
            environment: scene.environment,
        )!;
        gui_renderer.finish_frame();

        platform::sync_window(&window, &renderer);
        follow_output_size(&demo, &renderer)!;
        draw_frame(
            demo:         &demo,
            renderer:     &renderer,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = delta },
        )!;
    }
}

// ----------------------------------------------------------------------------- benchmark

fn uint segment_frames(Options options, Segment segment) @local {
    if (segment == Segment.SETTLE) return max(options.segment_frames, SETTLE_MIN_FRAMES);
    return options.segment_frames;
}

fn uint segment_start(Options options, Segment segment) @local {
    uint start;
    for (uint ordinal = 0; ordinal < (uint)segment.ordinal; ordinal++) {
        start += segment_frames(options, Segment::from_ordinal(ordinal));
    }
    return start;
}

fn uint measured_frames(Options options) @local {
    return segment_start(options, Segment.SETTLE) + segment_frames(options, Segment.SETTLE);
}

fn Segment segment_of(Options options, uint step) @local {
    Segment segment = Segment.STILL;
    for (uint ordinal = 1; ordinal < Segment::len; ordinal++) {
        Segment candidate = Segment::from_ordinal(ordinal);
        if (step >= segment_start(options, candidate)) segment = candidate;
    }
    return segment;
}

// The dive's camera at a share of the descent: from over the water, looking across it, to under it, looking up.
fn void place_dive(Demo* demo, float share) @local {
    float eased = share * share * (3 - 2 * share);
    Vec3 centre = demo.bodies[0].centre;
    Vec3 position = centre - (Vec3){ DIVE_BACK, 0, 0 };
    position.y += DIVE_START_HEIGHT - (DIVE_START_HEIGHT + DIVE_DEPTH) * eased;
    landscape_ground::place_camera(
        camera_node: demo.viewers[0].camera_node,
        position:    position,
        yaw:         (float)math::PI / 2,
        pitch:       DIVE_START_PITCH + (DIVE_END_PITCH - DIVE_START_PITCH) * eased,
    );
}

// A shot stands at its share; the loop descends and rises once per two DIVE_SECONDS.
fn float dive_share(Options options, double time) @local {
    if (options.dive_at >= 0) return options.dive_at;
    float cycle = (float)(time / DIVE_SECONDS);
    float phase = cycle - math::floor(cycle * 0.5f) * 2;
    return phase < 1 ? phase : 2 - phase;
}

fn void place_ripple_view(Demo* demo) @local {
    landscape_ground::place_camera(
        camera_node: demo.viewers[0].camera_node,
        position:    demo.bodies[0].centre + (Vec3){ SHOT_VIEW_OFFSET, SHOT_VIEW_HEIGHT, 0 },
        yaw:         -(float)math::PI / 2,
        pitch:       SHOT_VIEW_PITCH,
    );
}

fn void? pose_segment(
    Demo* demo,
    Segment segment,
    uint step,
    uint frames,
) @local {
    HeightView view = terrain::height_view(demo.scene, demo.assets, demo.ground.node.id)!;
    Vec3 centre = demo.bodies[0].centre;
    Vec3 position = centre - (Vec3){ STILL_BACK * LAKE_EXTENT, 0, 0 };
    float yaw = (float)math::PI / 2;
    float pitch = STILL_PITCH;
    float height = STILL_HEIGHT;
    if (segment == Segment.ORBIT) {
        float angle = 2 * (float)math::PI * (float)step / (float)frames;
        position = centre + (Vec3){ math::sin(angle) * ORBIT_RADIUS, 0, math::cos(angle) * ORBIT_RADIUS };
        yaw = math::atan2(centre.x - position.x, centre.z - position.z);
        pitch = -math::atan(ORBIT_HEIGHT / ORBIT_RADIUS);
        height = ORBIT_HEIGHT;
    }
    float ground = landscape_ground::ground_under(&view, position, centre.y);
    position.y = math::max(centre.y + height, ground + CAMERA_CLEARANCE);
    landscape_ground::place_camera(
        camera_node: demo.viewers[0].camera_node,
        position:    position,
        yaw:         yaw,
        pitch:       pitch,
    );
}

fn void? render_offscreen(
    Demo* demo,
    Renderer* renderer,
    uint frame,
) @local {
    renderer.begin_frame({ .time = frame_time(frame), .delta = TIME_STEP })!;
    defer catch render::abort_frame(renderer);
    render_views(demo, renderer)!;
    return renderer.end_frame();
}

fn double? time_samples(Demo* demo) @local {
    SurfaceView view = water::surface_view(demo.scene, demo.assets, demo.bodies[0].node.id)!;
    double[SAMPLE_BATCHES] batches;
    float sum;
    float reach = LAKE_EXTENT * 0.45f;
    foreach (batch, &nanoseconds : batches) {
        time::Clock started = clock::now();
        for (uint sample = 0; sample < SAMPLES_PER_BATCH; sample++) {
            float share = (float)sample / (float)SAMPLES_PER_BATCH;
            float x = demo.bodies[0].centre.x + reach * math::sin(share * 97);
            float z = demo.bodies[0].centre.z + reach * math::cos(share * 61);
            sum += water::sample_surface(
                view:    &view,
                world_x: x,
                world_z: z,
                time:    (double)batch + share,
            )!;
        }
        *nanoseconds = (double)(long)started.to_now() / (double)SAMPLES_PER_BATCH;
    }
    // The heights feed the check, so no sample is optimised away.
    if (!math::is_finite(sum)) return c3d::INVALID_ARGUMENT~;
    return percentile(batches[..], 0.5f);
}

fn void track_settle(Demo* demo, BenchmarkResult* result) @local {
    float expected = CRATE_DENSITY / physics::DEFAULT_FLUID_DENSITY;
    foreach (crate : demo.crates) {
        float fraction = demo.scene.get(crate, Buoyancy).submerged_fraction;
        result.settle_sum += fraction;
        result.settle_count++;
        if (math::abs(fraction - expected) > math::abs(result.settle_worst - expected)) result.settle_worst = fraction;
    }
}

fn void? run_segments(
    Demo* demo,
    Renderer* renderer,
    BenchmarkResult* result,
) @local {
    Options options = demo.options;
    uint measured = measured_frames(options);
    uint settle_start = segment_start(options, Segment.SETTLE);
    uint settle_frames = segment_frames(options, Segment.SETTLE);
    Vec3 wind = wind_velocity(options.wind_speed, WIND_HEADING_DEGREES);

    for (uint frame = 0; frame < WARMUP_FRAMES + measured + render::FRAMES_IN_FLIGHT; frame++) {
        bool timed = frame >= WARMUP_FRAMES && frame < WARMUP_FRAMES + measured;
        uint step = timed ? frame - WARMUP_FRAMES : 0;
        Segment segment = timed ? segment_of(options, step) : Segment.STILL;
        uint segment_step = step - segment_start(options, segment);
        if (frame >= WARMUP_FRAMES + measured) segment = Segment.SETTLE;
        if (timed && step == settle_start) {
            if (options.spectral) {
                apply_sea_state(
                    demo:               demo,
                    wind:               wind_velocity(0, WIND_HEADING_DEGREES),
                    transition_seconds: SETTLE_TRANSITION_SECONDS,
                )!;
            } else {
                set_calm(demo, false)!;
            }
            if (options.simulated) stiffen_ponds(demo)!;
        }
        if (timed && options.spectral && step == segment_start(options, Segment.WAVES)) {
            apply_sea_state(
                demo:               demo,
                wind:               wind_velocity(STORM_WIND_SPEED, WIND_HEADING_DEGREES),
                transition_seconds: SEA_TRANSITION_SECONDS,
            )!;
        }
        if (timed && options.simulated && step == segment_start(options, Segment.WAVES)) {
            drop_ripples(
                demo:      demo,
                origin:    demo.bodies[0].centre + (Vec3){ 0, 1, 0 },
                direction: { 0, -1, 0 },
            )!;
        }
        time::Clock frame_started = clock::now();
        pose_segment(
            demo:    demo,
            segment: segment,
            step:    segment_step,
            frames:  segment_frames(options, segment),
        )!;
        double physics_us = step_scene(
            demo:     demo,
            renderer: renderer,
            wind:     wind,
            time:     frame_time(frame),
            delta:    TIME_STEP,
        )!;
        render_offscreen(
            demo:     demo,
            renderer: renderer,
            frame:    frame,
        )!;
        double frame_ms = elapsed_ms(frame_started);

        if (timed) {
            result.records[step] = {
                .frame_ms             = frame_ms,
                .physics_us           = physics_us,
                .water_update_us      = demo.water_update_us,
                .field_us             = demo.field_us,
                .steps                = demo.physics.steps_last_update,
                .upload_bytes         = renderer.stats.upload_bytes,
                .dispatches           = renderer.stats.dispatches,
                .simulation_bytes     = demo.simulation_bytes,
                .simulation_awake     = demo.simulation_awake,
                .spectral_bytes       = demo.spectral_bytes,
                .shadow_sets_recorded = renderer.stats.shadow_sets_recorded,
                .shadow_sets_shared   = renderer.stats.shadow_sets_shared,
            };
            if (segment == Segment.SETTLE && segment_step >= settle_frames - GATE_FRAMES) track_settle(demo, result);
        }
        // A frame's GPU timings arrive once its slot comes round again.
        if (frame >= WARMUP_FRAMES + render::FRAMES_IN_FLIGHT) {
            uint completed = frame - render::FRAMES_IN_FLIGHT - WARMUP_FRAMES;
            if (completed < measured) {
                FrameRecord* record = &result.records[completed];
                record.frame_gpu_ms = renderer.stats.gpu_pass_ms;
                record.main_gpu_ms = renderer.view_stats(demo.viewers[0].view)!.gpu_pass_ms;
                record.mirror_gpu_ms = renderer.view_stats(demo.bodies[0].mirrors[0].view)!.gpu_pass_ms;
            }
        }
    }
}

fn double percentile(double[] samples, float share) @local {
    if (!samples.len) return 0;
    sort::quicksort(samples);
    return samples[(usz)math::round(share * (float)(samples.len - 1))];
}

fn float pass_sum(float[render::PASS_COUNT] passes) @local {
    float sum;
    foreach (pass_ms : passes) sum += pass_ms;
    return sum;
}

fn double metric_value(FrameRecord* record, Metric metric) @local {
    switch (metric) {
        case FRAME_MS: return record.frame_ms;
        case UPLOAD_BYTES: return (double)record.upload_bytes;
        case MIRROR_MS: return (double)pass_sum(record.mirror_gpu_ms);
        case MIRROR_SHADOW_MS: return (double)record.mirror_gpu_ms[Pass.SHADOW_ATLAS.ordinal];
        case MIRROR_SHADOW_SHARE:
            float frame_ms = pass_sum(record.frame_gpu_ms);
            if (frame_ms <= 0) return 0;
            return (double)(record.mirror_gpu_ms[Pass.SHADOW_ATLAS.ordinal] / frame_ms * PERCENT);
    }
}

fn double[] gather(FrameRecord[] records, Metric metric, double[] scratch) @local {
    foreach (index, &record : records) scratch[index] = metric_value(record, metric);
    return scratch[:records.len];
}

fn double[] gather_pass(FrameRecord[] records, Pass pass, double[] scratch) @local {
    foreach (index, record : records) scratch[index] = (double)record.main_gpu_ms[pass.ordinal];
    return scratch[:records.len];
}

fn double[] gather_frame_pass(FrameRecord[] records, Pass pass, double[] scratch) @local {
    foreach (index, record : records) scratch[index] = (double)record.frame_gpu_ms[pass.ordinal];
    return scratch[:records.len];
}

fn double[] gather_step_us(FrameRecord[] records, double[] scratch) @local {
    usz count;
    foreach (record : records) {
        if (!record.steps) continue;
        scratch[count] = record.physics_us / (double)record.steps;
        count++;
    }
    return scratch[:count];
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

fn void print_sky_passes(
    FrameRecord[] records,
    String segment_name,
    bool mirrored,
    double[] scratch,
) @local {
    foreach (pass : SKY_PASSES) {
        double median = percentile(gather_pass(records, pass, scratch), 0.5f);
        io::printfn("gpu_ms view=main segment=%s pass=%s median=%.4f", segment_name, pass, median);
        if (!mirrored) continue;
        foreach (index, record : records) scratch[index] = (double)record.mirror_gpu_ms[pass.ordinal];
        median = percentile(scratch[:records.len], 0.5f);
        io::printfn("gpu_ms view=mirror segment=%s pass=%s median=%.4f", segment_name, pass, median);
    }
}

// The simulation's CPU step and texture upload over the frames it uploaded.
fn void print_simulation(FrameRecord[] records, String segment_name, double[] scratch) @local {
    usz count;
    uint bytes;
    foreach (record : records) {
        if (!record.simulation_bytes) continue;
        scratch[count++] = record.water_update_us;
        bytes = max(bytes, record.simulation_bytes);
    }
    if (!count) {
        io::printfn("simulation segment=%s upload_frames=0", segment_name);
        return;
    }
    io::printfn(
        "simulation segment=%s upload_frames=%d update_us median=%.1f p99=%.1f upload_bytes=%d",
        segment_name,
        count,
        percentile(scratch[:count], 0.5f),
        percentile(scratch[:count], 0.99f),
        bytes,
    );
}

// The passes water_gpu::update records for the frame and the table it uploads when the sea state changes.
fn void print_spectral(FrameRecord[] records, String segment_name, double[] scratch) @local {
    usz upload_frames;
    uint bytes;
    foreach (index, record : records) {
        scratch[index] = record.field_us;
        if (!record.spectral_bytes) continue;

        upload_frames++;
        bytes = max(bytes, record.spectral_bytes);
    }
    io::printfn(
        "spectral segment=%s dispatches=%d record_us median=%.1f p99=%.1f table_upload_frames=%d table_upload_bytes=%d",
        segment_name,
        records[^1].dispatches,
        percentile(scratch[:records.len], 0.5f),
        percentile(scratch[:records.len], 0.99f),
        upload_frames,
        bytes,
    );
}

// Every frame records the passes of each spectral body, and no more.
fn bool spectral_gate(Demo* demo, FrameRecord[] records) @local {
    foreach (record : records) {
        if (record.dispatches != demo.body_count * landscape_water_field::DISPATCHES_PER_BODY) return false;
    }
    return true;
}

// Once the pond has settled no frame uploads: the first asleep frame after the ripple is dropped starts the quiet.
fn bool simulation_gate(Options options, FrameRecord[] records) @local {
    bool settled;
    foreach (record : records[segment_start(options, Segment.WAVES)..]) {
        if (!settled) {
            settled = !record.simulation_awake;
        } else if (record.simulation_bytes) {
            return false;
        }
    }
    return settled;
}

fn bool print_results(Demo* demo, BenchmarkResult* result) @local {
    Options options = demo.options;
    io::printfn("sample_ns median=%.1f", result.sample_ns);
    bool steady_gate = true;
    foreach (ordinal, name : SEGMENT_NAMES) {
        Segment segment = Segment::from_ordinal(ordinal);
        FrameRecord[] records = result.records[segment_start(options, segment):segment_frames(options, segment)];
        if (result.timestamps) {
            bool mirrored = demo.reflection == Reflection.PLANAR;
            if (mirrored && (segment == Segment.STILL || segment == Segment.ORBIT)) {
                io::printfn(
                    "gpu_ms view=mirror segment=%s total=%.4f shadow_atlas=%.4f shadow_share=%.2f",
                    name,
                    percentile(gather(records, MIRROR_MS, result.scratch), 0.5f),
                    percentile(gather(records, MIRROR_SHADOW_MS, result.scratch), 0.5f),
                    percentile(gather(records, MIRROR_SHADOW_SHARE, result.scratch), 0.5f),
                );
            }
            foreach (pass : REPORTED_PASSES) {
                if (options.sky && pass == Pass.FOG) continue; // the sky passes report it, with the mirror's
                double median = percentile(gather_pass(records, pass, result.scratch), 0.5f);
                io::printfn("gpu_ms view=main segment=%s pass=%s median=%.4f", name, pass, median);
            }
            if (options.spectral) {
                double median = percentile(gather_frame_pass(records, Pass.CUSTOM_COMPUTE, result.scratch), 0.5f);
                io::printfn("gpu_ms view=frame segment=%s pass=%s median=%.4f", name, Pass.CUSTOM_COMPUTE, median);
            }
            if (options.traced) {
                foreach (pass : TRACE_PASSES) {
                    double median = percentile(gather_frame_pass(records, pass, result.scratch), 0.5f);
                    io::printfn("gpu_ms view=frame segment=%s pass=%s median=%.4f", name, pass, median);
                }
            }
            if (options.sky) {
                print_sky_passes(
                    records:      records,
                    segment_name: name,
                    mirrored:     mirrored,
                    scratch:      result.scratch,
                );
            }
        }
        print_median_p99("frame_ms", name, gather(records, FRAME_MS, result.scratch));
        FrameRecord last = records[^1];
        io::printfn(
            "shadow_sets segment=%s recorded=%d shared=%d",
            name,
            last.shadow_sets_recorded,
            last.shadow_sets_shared,
        );
        if (segment == Segment.WAVES) {
            double[] step_us = gather_step_us(records, result.scratch);
            io::printfn(
                "buoyancy_us segment=waves crates=%d samples=%d median=%.3f p99=%.3f",
                options.crates,
                options.crates * physics::BUOYANCY_CELLS,
                percentile(step_us, 0.5f),
                percentile(step_us, 0.99f),
            );
        }
        if (segment == Segment.STILL) {
            double[] uploads = gather(records, UPLOAD_BYTES, result.scratch);
            io::printfn(
                "upload_bytes segment=still median=%.0f max=%.0f",
                percentile(uploads, 0.5f),
                percentile(uploads, 1.0f),
            );
            uint upload_frames;
            foreach (index, record : records) {
                if (index > 0 && record.upload_bytes) upload_frames++;
            }
            io::printfn("upload_frames segment=still %d", upload_frames);
            steady_gate = upload_frames == 0;
        }
        if (options.simulated) {
            print_simulation(
                records:      records,
                segment_name: name,
                scratch:      result.scratch,
            );
        }
        if (options.spectral) {
            print_spectral(
                records:      records,
                segment_name: name,
                scratch:      result.scratch,
            );
        }
    }
    float expected = CRATE_DENSITY / physics::DEFAULT_FLUID_DENSITY;
    double mean = result.settle_count ? result.settle_sum / (double)result.settle_count : 0;
    io::printfn(
        "submerged segment=settle mean=%.4f worst=%.4f expected=%.2f",
        mean,
        result.settle_worst,
        expected,
    );
    bool crated = demo.crates.len > 0;
    bool density_gate = !crated
      || (result.settle_count > 0 && math::abs(result.settle_worst - expected) <= GATE_TOLERANCE);
    bool settle_gate = !options.simulated || simulation_gate(options, result.records);
    bool dispatch_gate = !options.spectral || spectral_gate(demo, result.records);
    io::printfn("gate steady_uploads %s", steady_gate ? "pass" : "fail");
    if (options.spectral) io::printfn("gate spectral_dispatches %s", dispatch_gate ? "pass" : "fail");
    if (options.simulated) io::printfn("gate simulation_uploads_stop_once_settled %s", settle_gate ? "pass" : "fail");
    io::printfn("gate crates_at_density_line %s", !crated ? "skipped: no crates" : (density_gate ? "pass" : "fail"));
    return steady_gate && density_gate && settle_gate && dispatch_gate;
}

fn String reflection_name(Reflection reflection) @local {
    switch (reflection) {
        case PLANAR: return "planar";
        case MARCH: return "march";
        case ENV: return "env";
    }
}

fn void print_header(Options options) @local {
    io::printfn(
        "# water size=%d shading=%s reflection=%s mirror_scale=%g crates=%d ripples=%s foliage=%s ssgi=%s "
          "extent=%dx%d frames=%d sky=%s volumetric_fog=%s split=%s waves=%s",
        options.size,
        options.shading == ShadingPath.DEFERRED ? "deferred" : "forward",
        reflection_name(options.reflection),
        options.mirror_scale,
        options.crates,
        options.ripples ? "on" : "off",
        options.ocean ? "none" : "both",
        options.ssgi ? "on" : "off",
        options.width,
        options.height,
        options.segment_frames,
        options.sky ? "on" : "off",
        options.volumetric_fog ? "on" : "off",
        options.split ? "on" : "off",
        options.spectral ? "spectral" : (options.simulated ? "simulated" : "gerstner"),
    );
}

fn bool? run_benchmark(Options options) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      renderer_desc(options, options.validation, "c3d_water_benchmark"),
    )!;
    defer render::destroy_renderer(&renderer);
    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc:     render::render_target_desc(options.width, options.height, PixelFormat.RGBA8_UNORM),
    )!;
    ViewId[MAX_VIEWERS] main_views;
    foreach (&main_view : main_views[:options.split ? 2 : 1]) {
        *main_view = render::create_view(
            renderer: &renderer,
            desc:     main_view_desc(render::texture_view_desc(target, OutputMode.DISPLAY_LDR), options),
        )!;
    }
    Scene scene = create_demo_scene(options);
    defer scene::destroy_scene(&scene);
    terrain::register_terrain(&scene, &assets)!;
    foliage::register_foliage(&scene)!;
    water::register_water(&scene, &assets)!;
    physics::register_physics(&scene)!;
    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      physics::default_physics_desc(),
    )!;
    defer physics::destroy_physics_world(&physics);

    Demo demo = {
        .options      = options,
        .assets       = &assets,
        .scene        = &scene,
        .physics      = &physics,
        .mirror_scale = options.mirror_scale,
        .crates       = alloc::new_array(mem, Node*, (sz)options.crates),
    };
    defer alloc::free(mem, demo.crates.ptr);
    build_demo(&demo)!;
    if (options.sea_state) {
        apply_sea_state(
            demo:               &demo,
            wind:               wind_velocity(options.wind_speed, WIND_HEADING_DEGREES),
            transition_seconds: 0,
        )!;
    }
    foreach (index, &viewer : demo.viewers[:demo.viewer_count]) viewer.view = main_views[index];
    print_header(options);
    if (options.spectral) {
        WaterRuntime* sea = demo.scene.get(demo.bodies[0].node, WaterRuntime);
        io::printfn(
            "# spectrum sigma=%.4f envelope=%.4f bound=%.4f twin_waves=%d",
            sea.spectral.sigma,
            sea.spectral.envelope,
            sea.spectral_bound,
            sea.spectral.twin_count,
        );
    }
    pose_segment(
        demo:    &demo,
        segment: Segment.STILL,
        step:    0,
        frames:  options.segment_frames,
    )!;
    prepare_views(&demo, &renderer, { options.width, options.height })!;

    uint measured = measured_frames(options);
    BenchmarkResult result = {
        .records      = alloc::new_array(mem, FrameRecord, (sz)measured),
        .scratch      = alloc::new_array(mem, double, (sz)measured),
        .settle_worst = CRATE_DENSITY / physics::DEFAULT_FLUID_DENSITY,
        .timestamps   = renderer.timestamps_enabled,
    };
    defer alloc::free(mem, result.records.ptr);
    defer alloc::free(mem, result.scratch.ptr);
    result.sample_ns = time_samples(&demo)!;
    renderer.prepare_scene(&scene)!;

    run_segments(
        demo:     &demo,
        renderer: &renderer,
        result:   &result,
    )!;
    render::wait_frames(&renderer)!;
    return print_results(&demo, &result);
}

<* Render a few frames offscreen and write the last one as a PNG. *>
fn void? run_shot(Options options) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      renderer_desc(options, options.validation, "c3d_water_shot"),
    )!;
    defer render::destroy_renderer(&renderer);
    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc:     render::render_target_desc(options.width, options.height, PixelFormat.RGBA8_UNORM),
    )!;
    ViewDesc view_desc = main_view_desc(render::texture_view_desc(target, OutputMode.DISPLAY_LDR), options);
    view_desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId main_view = render::create_view(renderer: &renderer, desc: view_desc)!;
    Scene scene = create_demo_scene(options);
    defer scene::destroy_scene(&scene);
    terrain::register_terrain(&scene, &assets)!;
    foliage::register_foliage(&scene)!;
    water::register_water(&scene, &assets)!;
    physics::register_physics(&scene)!;
    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      physics::default_physics_desc(),
    )!;
    defer physics::destroy_physics_world(&physics);

    Demo demo = {
        .options      = options,
        .assets       = &assets,
        .scene        = &scene,
        .physics      = &physics,
        .mirror_scale = options.mirror_scale,
        .crates       = alloc::new_array(mem, Node*, (sz)options.crates),
    };
    defer alloc::free(mem, demo.crates.ptr);
    build_demo(&demo)!;
    demo.viewers[0].view = main_view;
    Vec3 wind = wind_velocity(options.wind_speed, WIND_HEADING_DEGREES);
    if (options.sea_state) {
        apply_sea_state(
            demo:               &demo,
            wind:               wind,
            transition_seconds: 0,
        )!;
    }
    if (options.dive) {
        place_dive(&demo, dive_share(options, 0));
    } else if (options.simulated) {
        place_ripple_view(&demo);
    } else {
        pose_segment(
            demo:    &demo,
            segment: Segment.STILL,
            step:    0,
            frames:  options.segment_frames,
        )!;
    }
    prepare_views(&demo, &renderer, { options.width, options.height })!;
    renderer.prepare_scene(&scene)!;

    uint lead_frames = (uint)math::round(options.ripple_age / TIME_STEP);
    for (uint frame = 0; frame < lead_frames + SHOT_FRAMES; frame++) {
        step_scene(
            demo:     &demo,
            renderer: &renderer,
            wind:     wind,
            time:     frame_time(frame),
            delta:    TIME_STEP,
        )!;
        if (options.simulated && frame == 0) {
            drop_ripples(
                demo:      &demo,
                origin:    demo.bodies[0].centre + (Vec3){ SHOT_DROP_OFFSET, 1, 0 },
                direction: { 0, -1, 0 },
            )!;
        }
        if (frame < lead_frames) continue;

        render_offscreen(
            demo:     &demo,
            renderer: &renderer,
            frame:    frame,
        )!;
    }
    render::wait_frames(&renderer)!;

    char[] pixels = alloc::new_array(mem, char, (sz)options.width * options.height * RGBA8_BYTES);
    defer alloc::free(mem, pixels.ptr);
    renderer.read_render_target(target, pixels)!;
    image::write_png(
        path:   options.shot,
        width:  options.width,
        height: options.height,
        pixels: pixels,
    )!;
}

<* Water over a generated landscape with floating crates, interactively, as the scripted benchmark or as one frame. *>
fn int main(String[] args) {
    Options? parsed = parse_options(args);
    if (catch excuse = parsed) {
        if (excuse != c3d::UNSUPPORTED) {
            io::eprintfn("Invalid options: %s", excuse);
            io::eprintn("Use [--benchmark [frames]] [--gpu-timings] [--validation] [--shading forward|deferred] "
              "[--size 1025|2049|4097] [--reflection planar|march|env] [--mirror-scale 0.5|1] [--crates 16|256] "
              "[--current X,Z] [--ssgi] [--traced] [--capture] [--split] [--ripples on|off] [--width W] [--height H] "
              "[--sky] [--volumetric-fog] [--sea-state] [--ocean] [--dive [SHARE]] [--wind SPEED] "
              "[--waves gerstner|simulated|spectral] [--ripple-age SECONDS] [--shot FILE.png].");
        }
        return 1;
    }
    Options options = parsed;
    if (options.shot.len) {
        if (catch excuse = run_shot(options)) {
            io::eprintfn("water shot failed: %s", excuse);
            return 1;
        }
        return 0;
    }
    if (!options.benchmark) {
        if (catch excuse = run_interactive(options)) {
            io::eprintfn("water example failed: %s", excuse);
            return 1;
        }
        return 0;
    }
    bool? gates = run_benchmark(options);
    if (catch excuse = gates) {
        io::eprintfn("water benchmark failed: %s", excuse);
        return 1;
    }
    return gates ? 0 : 1;
}
