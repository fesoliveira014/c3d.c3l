module c3d::landscape::water;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::landscape::terrain @public;
import c3d::maths;
import c3d::scene;
import std::math;

const uint MARCH_FLAG @private = 1; // mirrored as WATER_MARCH in landscape/water_waves.glsl

<*
 One wave as the vertex stage reads it, packed from a Wave.
*>
struct WaveGpu {
    Vec2  direction;
    float amplitude;         // metres
    float cycles_per_metre;  // along direction
    float cycles_per_second;
    float shift;             // metres of horizontal crest shift at full phase
    float _pad0;
    float _pad1;
}

$assert WaveGpu::size == 32;

struct WaterParams @private {
    WaveGpu[MAX_WAVES] waves; // mirrored as WaterParams in landscape/water_waves.glsl
    Vec4               absorption;
    Vec4               scatter;
    Vec4               scroll_origin;
    Vec4               scroll_velocity;
    uint               wave_count;
    float              scroll_time;
    float              refraction_strength;
    float              reflection_distortion;
    float              foam_depth;
    float              foam_crest;
    uint               flags;
    float              _pad0;
}

$assert WaterParams::size == 224;

<*
 World-space copy of one water body's waves and pose at the moment it was taken.
*>
struct SurfaceView {
    WaveGpu[MAX_WAVES] waves;
    uint               wave_count;
    Vec2               rest_min;         // node-local XZ of the rest surface
    Vec2               rest_max;
    Mat4               world;            // node world matrix when the view was taken
    Mat4               local_from_world;
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
    return {
        .waves            = params.waves,
        .wave_count       = params.wave_count,
        .rest_min         = runtime.rest_min,
        .rest_max         = runtime.rest_max,
        .world            = world,
        .local_from_world = maths::inverse_affine(world),
    };
}

<*
 World height of the drawn surface on the vertical through a point.
 @param [&in] view
 @param time : "Seconds; the FrameInfo.time the surface is drawn at."
 @return? NOT_FOUND
*>
fn float? sample_surface(
    SurfaceView* view,
    float world_x,
    float world_z,
    double time,
) {
    Vec3 local = maths::transform_point(view.local_from_world, { world_x, 0, world_z });
    float drawn_time = shader_time(time);
    WaveGpu[] waves = view.waves[:view.wave_count];
    Vec2 query = { local.x, local.z };
    Vec2 rest = query;
    for (uint iteration = 0; iteration < WAVE_INVERSION_ITERATIONS; iteration++) {
        rest = query - horizontal_shift(waves, rest, drawn_time);
    }
    if (rest.x < view.rest_min.x || rest.y < view.rest_min.y || rest.x > view.rest_max.x || rest.y > view.rest_max.y) {
        return NOT_FOUND~;
    }
    return maths::transform_point(view.world, { local.x, wave_height(waves, rest, drawn_time), local.z }).y;
}

// Twin of write_frame_root's (float)info.time in render/view.c3: queries see the time the stage sees.
fn float shader_time(double time) @private => (float)time;

// Twin of water_wave_angle in landscape/water_waves.glsl.
fn float wave_angle(WaveGpu* wave, Vec2 rest, float time) @private {
    float cycles = wave.direction.dot(rest) * wave.cycles_per_metre - time * wave.cycles_per_second;
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

// The scroll segment belongs to update: a desc edit keeps it.
fn WaterParams pack_params(WaterDesc* desc, WaterParams scroll) @private {
    Vec3 absorption = desc.absorption_color;
    Vec3 scatter = desc.scatter_color;
    WaterParams params = {
        .absorption            = { absorption.x, absorption.y, absorption.z, desc.absorption_distance },
        .scatter               = { scatter.x, scatter.y, scatter.z, desc.roughness },
        .scroll_origin         = scroll.scroll_origin,
        .scroll_velocity       = scroll.scroll_velocity,
        .wave_count            = desc.wave_count,
        .scroll_time           = scroll.scroll_time,
        .refraction_strength   = desc.refraction_strength,
        .reflection_distortion = desc.reflection_distortion,
        .foam_depth            = desc.foam_depth,
        .foam_crest            = desc.foam_crest,
        .flags                 = desc.march_reflections ? MARCH_FLAG : 0,
    };
    for (uint index = 0; index < desc.wave_count; index++) {
        params.waves[index] = pack_wave(&desc.waves[index], desc.wave_count);
    }
    return params;
}

fn float total_amplitude(WaterDesc* desc) @private {
    float total;
    foreach (&wave : desc.waves[:desc.wave_count]) total += wave.amplitude;
    return total;
}

fn float largest_shift(WaterDesc* desc) @private {
    float total;
    foreach (&wave : desc.waves[:desc.wave_count]) total += pack_wave(wave, desc.wave_count).shift;
    return total;
}
