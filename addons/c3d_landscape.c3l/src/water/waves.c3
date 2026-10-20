module c3d::landscape::water;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::landscape::terrain @public;
import c3d::maths;
import c3d::scene;
import std::math;

const uint MARCH_FLAG @private = 1; // mirrored as WATER_MARCH in landscape/water_waves.glsl
const uint SIMULATED_FLAG @private = 2; // mirrored as WATER_SIMULATED in landscape/water_waves.glsl
const uint BACKFACE_FLAG @private = 8; // measurement; mirrored as WATER_DEBUG_BACKFACE in water.frag.glsl
const uint BACKFACE_DISTANCE_FLAG @private = 16; // measurement; mirrored as WATER_DEBUG_BACKFACE_DISTANCE
const uint SPECTRAL_FLAG @private = 4; // mirrored as WATER_SPECTRAL in landscape/water_waves.glsl

<*
 One wave as the vertex stage reads it, packed from a Wave.
*>
struct WaveGpu {
    Vec2  direction;
    float amplitude;         // metres
    float cycles_per_metre;  // along direction
    float cycles_per_second;
    float shift;             // metres of horizontal crest shift at full phase
    float phase_offset;      // cycles added to the phase; keeps a sea state's phase continuous
    float _pad0;
}

$assert WaveGpu::size == 32;

struct WaterParams @private {
    WaveGpu[MAX_WAVES] waves; // mirrored as WaterParams in landscape/water_waves.glsl
    WaveGpu[MAX_WAVES] previous; // the waves of the update before; the velocity form reads them
    Vec4               scroll_origin;
    Vec4               scroll_velocity;
    uint               wave_count;
    float              scroll_time;
    float              refraction_strength;
    float              reflection_distortion;
    float              foam_depth;
    float              foam_crest;
    uint               flags;
    float              cell_size; // metres between the finest vertices of an ocean; zero for a body
    float              roughness;
    uint               grid_texels;  // vertices along a simulated body's side; zero otherwise
    float              grid_spacing; // metres between them
    float              field_scale;  // field coordinates per metre of a spectral body; zero otherwise
    Vec2               field_offset; // field coordinates of the node-local origin
    Vec2               _pad0;
}

$assert WaterParams::size == 352;

<*
 World-space copy of one water body's waves and pose at the moment it was taken.
 A simulated body's view borrows its grid: it answers the surface of the last update until the body is removed.
*>
struct SurfaceView {
    WaveGpu[SPECTRAL_TWIN_WAVES] waves;            // a spectral body's twin components, or the Gerstner waves
    uint                         wave_count;
    float                        period;           // seconds a spectral surface repeats after; zero otherwise
    Vec2                         rest_min;         // node-local XZ of the rest surface
    Vec2                         rest_max;
    Mat4                         world;            // node world matrix when the view was taken
    Mat4                         local_from_world;
    SimulationState*             simulation;       // borrowed from the body; null unless the wave model is SIMULATED
}

<*
 Surface height, normal, velocity and inversion residual at a world point.
*>
struct WaterSample {
    float height;
    Vec3  normal;
    Vec3  velocity; // Gerstner orbital velocity of the surface point
    float residual; // metres: length of the last horizontal inversion step, which bounds the rest point's error
}

// A rest point and the length in metres of the step that produced it.
struct RestPoint @private {
    Vec2  point;
    float residual;
}

// Local-space derivatives of a drawn point's position by its rest position and by time.
struct SurfaceFrame @private {
    Vec3 tangent;   // by rest x
    Vec3 bitangent; // by rest z
    Vec3 velocity;  // by time
}

<*
 View of the node's water surface in world space.
 @param [&in] scene
 @param [&in] assets
 @return? c3d::INVALID_ID
 @require !scene.world.is_alive(node) || terrain::upright_rigid(scene.node(node).world) : "No tilt, no scale."
*>
fn SurfaceView? surface_view(Scene* scene, AssetStore* assets, Entity node) {
    if (!scene.world.is_alive(node) || !scene.world.has(node, WaterRuntime)) return c3d::INVALID_ID~;
    WaterRuntime* runtime = scene.world.get(node, WaterRuntime);
    if (!assets.materials.is_live(runtime.material)) return c3d::INVALID_ID~;
    // The pool read keeps the store read-only; AssetStore.material takes it as inout.
    WaterParams* params = (WaterParams*)assets.materials.get(runtime.material).data.custom.param_block.ptr;
    Mat4 world = scene.node(node).world;
    SurfaceView view = {
        .wave_count       = params.wave_count,
        .rest_min         = runtime.rest_min,
        .rest_max         = runtime.rest_max,
        .world            = world,
        .local_from_world = maths::inverse_affine(world),
        .simulation       = runtime.simulation,
    };
    view.waves[:MAX_WAVES] = params.waves[..];
    if (runtime.spectral) fill_spectral_view(runtime, view.local_from_world, &view);
    return view;
}

<*
 World height of the drawn surface on the vertical through a point.
 @param [&in] view
 @param time : "Seconds; the FrameInfo.time the surface is drawn at; a simulated surface ignores it."
 @return? NOT_FOUND
*>
fn float? sample_surface(
    SurfaceView* view,
    float world_x,
    float world_z,
    double time,
) {
    if (view.simulation) return simulated_height(view, world_x, world_z);

    Vec3 local = maths::transform_point(view.local_from_world, { world_x, 0, world_z });
    float drawn_time = view_time(view, time);
    RestPoint rest = rest_point(view, local, drawn_time)!;
    WaveGpu[] waves = view.waves[:view.wave_count];
    return maths::transform_point(view.world, { local.x, wave_height(waves, rest.point, drawn_time), local.z }).y;
}

<*
 Sample height, normal and velocity of the surface at a world point and time.
 @param [&in] view
 @param time : "Seconds; the FrameInfo.time the surface is drawn at; a simulated surface ignores it."
 @return? NOT_FOUND
*>
fn WaterSample? sample_surface_detail(
    SurfaceView* view,
    float world_x,
    float world_z,
    double time,
) {
    if (view.simulation) return simulated_detail(view, world_x, world_z);

    Vec3 local = maths::transform_point(view.local_from_world, { world_x, 0, world_z });
    float drawn_time = view_time(view, time);
    RestPoint rest = rest_point(view, local, drawn_time)!;
    WaveGpu[] waves = view.waves[:view.wave_count];
    SurfaceFrame frame = wave_frame(waves, rest.point, drawn_time);
    float local_height = wave_height(waves, rest.point, drawn_time);
    float height = maths::transform_point(view.world, { local.x, local_height, local.z }).y;

    return {
        .height   = height,
        .normal   = maths::transform_dir(view.world, frame.bitangent.cross(frame.tangent).normalize()),
        .velocity = maths::transform_dir(view.world, frame.velocity),
        .residual = rest.residual,
    };
}

// The rest point drawn over the local point, by the same fixed-point inversion for every query.
fn RestPoint? rest_point(SurfaceView* view, Vec3 local, float drawn_time) @private {
    WaveGpu[] waves = view.waves[:view.wave_count];
    Vec2 query = { local.x, local.z };
    Vec2 rest = query;
    float residual;
    for (uint iteration = 0; iteration < MAX_INVERSION_ITERATIONS; iteration++) {
        Vec2 next = query - horizontal_shift(waves, rest, drawn_time);
        residual = (next - rest).length();
        rest = next;
        if (residual < WATER_QUERY_TOLERANCE) break;
    }

    if (rest.x < view.rest_min.x || rest.y < view.rest_min.y || rest.x > view.rest_max.x || rest.y > view.rest_max.y) {
        return NOT_FOUND~;
    }

    return { .point = rest, .residual = residual };
}

// Twin of write_frame_root's (float)info.time in render/view.c3: queries see the time the stage sees.
fn float shader_time(double time) @private => (float)time;

// A spectral surface repeats after its period: its frequencies are whole cycles of it, so the time folds exactly.
fn float view_time(SurfaceView* view, double time) @private {
    if (!(view.period > 0)) return shader_time(time);

    double cycles = time / view.period;
    return (float)((cycles - math::floor(cycles)) * view.period);
}

// Twin of water_wave_angle in landscape/water_waves.glsl.
fn float wave_angle(WaveGpu* wave, Vec2 rest, float time) @private {
    float cycles = wave.direction.dot(rest) * wave.cycles_per_metre - time * wave.cycles_per_second
        + wave.phase_offset;
    return (float)math::PI * 2 * (cycles - math::floor(cycles));
}

fn Vec2 horizontal_shift(WaveGpu[] waves, Vec2 rest, float time) @private {
    Vec2 shift;
    foreach (&wave : waves) shift += wave.direction * (wave.shift * math::cos(wave_angle(wave, rest, time)));
    return shift;
}

fn float wave_height(WaveGpu[] waves, Vec2 rest, float time) @private {
    float height;
    foreach (&wave : waves) height += wave.amplitude * math::sin(wave_angle(wave, rest, time));
    return height;
}

fn SurfaceFrame wave_frame(WaveGpu[] waves, Vec2 rest, float time) @private {
    SurfaceFrame frame = { .tangent = { 1, 0, 0 }, .bitangent = { 0, 0, 1 } };
    foreach (&wave : waves) {
        float angle = wave_angle(wave, rest, time);
        Vec2 crest_shift = wave.direction * (wave.shift * math::sin(angle));
        Vec3 per_radian = { -crest_shift.x, wave.amplitude * math::cos(angle), -crest_shift.y };
        Vec2 radians_per_metre = wave.direction * ((float)math::PI * 2 * wave.cycles_per_metre);
        float radians_per_second = (float)math::PI * 2 * wave.cycles_per_second;
        frame.tangent += per_radian * radians_per_metre.x;
        frame.bitangent += per_radian * radians_per_metre.y;
        frame.velocity -= per_radian * radians_per_second;
    }
    return frame;
}

fn WaveGpu pack_wave(Wave* wave, uint wave_count) @private {
    float cycles_per_metre = 1 / wave.wavelength;
    return {
        .direction         = wave.direction,
        .amplitude         = wave.amplitude,
        .cycles_per_metre  = cycles_per_metre,
        .cycles_per_second = wave.speed * cycles_per_metre,
        .shift             = wave.steepness * wave.wavelength / ((float)math::PI * 2 * wave_count),
    };
}

// The scroll segment and the phase offsets belong to update: a desc edit keeps them.
fn WaterParams pack_params(WaterDesc* desc, WaterParams kept) @private {
    WaterParams params = {
        .scroll_origin         = kept.scroll_origin,
        .scroll_velocity       = kept.scroll_velocity,
        .wave_count            = desc.wave_model == WaterWaveModel.GERSTNER ? desc.wave_count : 0,
        .scroll_time           = kept.scroll_time,
        .refraction_strength   = desc.refraction_strength,
        .reflection_distortion = desc.reflection_distortion,
        .foam_depth            = desc.foam_depth,
        .foam_crest            = desc.foam_crest,
        .flags                 = (desc.march_reflections ? MARCH_FLAG : 0)
            | (desc.wave_model == WaterWaveModel.SIMULATED ? SIMULATED_FLAG : 0)
            | (desc.wave_model == WaterWaveModel.SPECTRAL ? SPECTRAL_FLAG : 0)
            | (sea_debug.tint_back_faces ? BACKFACE_FLAG : 0)
            | (sea_debug.tint_back_distance ? BACKFACE_DISTANCE_FLAG : 0),
        .cell_size             = desc.mode == WaterMode.OCEAN ? desc.cell_size : 0,
        .roughness             = desc.roughness,
        .field_offset          = kept.field_offset,
    };
    if (desc.wave_model == WaterWaveModel.SIMULATED) {
        params.grid_texels = simulation_cells(desc) + 1;
        params.grid_spacing = simulation_spacing(desc);
    }
    if (desc.wave_model == WaterWaveModel.SPECTRAL) params.field_scale = 1 / desc.spectrum.patch_size;
    for (uint index = 0; index < params.wave_count; index++) {
        params.waves[index] = pack_wave(&desc.waves[index], desc.wave_count);
        params.waves[index].phase_offset = kept.waves[index].phase_offset;
    }
    params.previous = params.waves;
    return params;
}

fn float total_amplitude(Wave[] waves) @private {
    float total;
    foreach (&wave : waves) total += wave.amplitude;
    return total;
}

fn float largest_shift(Wave[] waves) @private {
    float total;
    foreach (&wave : waves) total += pack_wave(wave, (uint)waves.len).shift;
    return total;
}
