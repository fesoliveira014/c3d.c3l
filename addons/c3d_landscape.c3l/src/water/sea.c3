module c3d::landscape::water;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;

const float SEA_GRAVITY @private = 9.81f; // m/s^2
const float SEA_FETCH_HEIGHT @private = 1.6e-3f; // JONSWAP: g Hs / U^2 per square root of g F / U^2
const float SEA_FETCH_PERIOD @private = 0.286f; // JONSWAP: g Tp / U per cube root of g F / U^2
const float SEA_FULL_HEIGHT @private = 0.21f; // fully developed Pierson-Moskowitz: g Hs / U^2
const float SEA_PEAK_FREQUENCY @private = 0.877f; // fully developed Pierson-Moskowitz: peak frequency times U / g
const float SEA_FULL_PERIOD @private = 2 * (float)math::PI / SEA_PEAK_FREQUENCY; // g Tp / U at that peak frequency
const float SEA_WIND_LIMIT @private = 25; // m/s: the strongest wind the table draws; a harder one draws the same sea
const float SEA_CHOP @private = 2; // crest shift over amplitude, as the default calm waves have
const float SEA_STEEPNESS_LIMIT @private = 0.9f; // below the cusp at 1, so the mean stays valid at any fetch
const float SEA_SHORTEST_WAVELENGTH @private = 1; // metres: application geometry carries no cell size to bound it

<*
 Where a sea-state blend stands between set_sea_state and its last upload.
*>
enum SeaStage : char {
    IDLE,
    STARTING,
    BLENDING,
    SETTLING,
}

<*
 Blend from one wave set to another; written by set_sea_state and update.
*>
struct SeaBlend {
    SeaStage          stage;
    float             duration;  // seconds
    float             elapsed;   // seconds
    double            last_time; // seconds: the update before
    Wave[MAX_WAVES]   from;      // the set the blend leaves
    Wave[MAX_WAVES]   drawn;     // the set the last update uploaded
    Wave[MAX_WAVES]   bounding;  // the largest of from and the target per field: bounds every blended set
    double[MAX_WAVES] phase;     // cycles each wave has run, integrated from the update that started the blend
}

// Significant height and peak period of the sea a wind raises over a fetch.
struct SeaScales @private {
    float significant_height; // metres
    float peak_period;        // seconds
}

// One wave of the table, relative to the sea's peak wave.
struct SeaBand @private {
    float wavelength_share;
    float amplitude_share;   // of the significant height; the squares sum to about 1/8, the share four waves carry
    float spread_degrees;    // off the wind
}

const SeaBand[MAX_WAVES] SEA_BANDS @private = {
    { .wavelength_share = 1, .amplitude_share = 0.25f, .spread_degrees = 0 },
    { .wavelength_share = 0.5f, .amplitude_share = 0.18f, .spread_degrees = 20 },
    { .wavelength_share = 0.25f, .amplitude_share = 0.12f, .spread_degrees = -30 },
    { .wavelength_share = 0.125f, .amplitude_share = 0.08f, .spread_degrees = 45 },
};

<*
 Set a water body's waves to the sea the wind raises, blended over a time.
 @param [&inout] scene : "World matrices current."
 @param [&in] assets : "The store given to register_water; resolves a pending body's geometry."
 @param node : "Carries Water."
 @param wind_velocity : "World XZ metres per second; the waves travel along it."
 @param transition_seconds : "Zero switches at the next update."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
*>
fn void? set_sea_state(
    Scene* scene,
    AssetStore* assets,
    Entity node,
    Vec2 wind_velocity,
    float transition_seconds,
) {
    if (!scene.world.is_alive(node) || !scene.world.has(node, Water)) return c3d::INVALID_ID~;
    if (!math::is_finite(wind_velocity.x) || !math::is_finite(wind_velocity.y)) return c3d::INVALID_ARGUMENT~;
    if (!(transition_seconds >= 0) || !math::is_finite(transition_seconds)) return c3d::INVALID_ARGUMENT~;

    Water* water = scene.world.get(node, Water);
    if (water.desc.wave_model == WaterWaveModel.SIMULATED) return c3d::UNSUPPORTED~;
    if (water.desc.wave_model == WaterWaveModel.SPECTRAL) {
        if (!scene.world.has(node, WaterRuntime)) return c3d::UNSUPPORTED~;

        WaterRuntime* runtime = scene.world.get(node, WaterRuntime);
        Vec3 local_wind = maths::transform_dir(
            maths::inverse_affine(scene.node(node).world),
            { wind_velocity.x, 0, wind_velocity.y },
        );
        blend_spectral(
            assets:             assets,
            runtime:            runtime,
            wind_velocity:      { local_wind.x, local_wind.z },
            transition_seconds: transition_seconds,
        );
        place_bounds(scene, scene.node(node), runtime);
        return;
    }

    Mat4 world = scene.node(node).world;
    if (!scene.world.has(node, WaterRuntime)) {
        if (water.desc.geometry.generation && !assets.geometries.is_live(water.desc.geometry)) {
            return c3d::INVALID_ID~;
        }

        Aabb rest = rest_bounds(assets, &water.desc);
        water.desc.waves = sea_waves(
            desc:          &water.desc,
            rest_min:      { rest.min.x, rest.min.z },
            rest_max:      { rest.max.x, rest.max.z },
            world:         world,
            wind_velocity: wind_velocity,
        );
        water.desc.wave_count = MAX_WAVES;
        return;
    }

    WaterRuntime* runtime = scene.world.get(node, WaterRuntime);
    Wave[MAX_WAVES] target = sea_waves(
        desc:          &runtime.desc,
        rest_min:      runtime.rest_min,
        rest_max:      runtime.rest_max,
        world:         world,
        wind_velocity: wind_velocity,
    );
    blend_to(
        scene:              scene,
        node:               node,
        target:             target,
        transition_seconds: transition_seconds,
    );
}

fn void blend_to(
    Scene* scene,
    Entity node,
    Wave[MAX_WAVES] target,
    float transition_seconds,
) @private {
    Water* water = scene.world.get(node, Water);
    WaterRuntime* runtime = scene.world.get(node, WaterRuntime);
    begin_blend(
        blend:              &runtime.sea,
        leaving:            runtime.desc.waves[:runtime.desc.wave_count],
        target:             target,
        transition_seconds: transition_seconds,
    );
    runtime.desc.waves = target;
    runtime.desc.wave_count = MAX_WAVES;
    water.desc.waves = target;
    water.desc.wave_count = MAX_WAVES;
    place_bounds(scene, scene.node(node), runtime);
}

fn SeaScales sea_scales(float speed, float fetch) @private {
    float fetch_ratio = SEA_GRAVITY * fetch / (speed * speed);
    float height_ratio = min(SEA_FETCH_HEIGHT * math::sqrt(fetch_ratio), SEA_FULL_HEIGHT);
    float period_ratio = min(SEA_FETCH_PERIOD * math::pow(fetch_ratio, 1.0f / 3), SEA_FULL_PERIOD);
    return {
        .significant_height = height_ratio * speed * speed / SEA_GRAVITY,
        .peak_period        = period_ratio * speed / SEA_GRAVITY,
    };
}

fn Wave[MAX_WAVES] sea_waves(
    WaterDesc* desc,
    Vec2 rest_min,
    Vec2 rest_max,
    Mat4 world,
    Vec2 wind_velocity,
) @private {
    Vec3 local_wind = maths::transform_dir(maths::inverse_affine(world), { wind_velocity.x, 0, wind_velocity.y });
    float heading = math::atan2(local_wind.z, local_wind.x);
    Vec2 direction = { math::cos(heading), math::sin(heading) };
    float horizontal_scale = maths::transform_dir(world, { direction.x, 0, direction.y }).length();
    float vertical_scale = maths::transform_dir(world, { 0, 1, 0 }).length();
    float speed = min(wind_velocity.length(), SEA_WIND_LIMIT);
    float shortest = SEA_SHORTEST_WAVELENGTH;
    if (desc.mode == WaterMode.OCEAN) {
        shortest = max(shortest, FADE_FULL_CELLS * desc.cell_size);
    } else if (!desc.geometry.generation) {
        shortest = max(shortest, NYQUIST_CELLS * desc.cell_size);
    }

    float significant_height;
    float peak_wavelength;
    if (speed > 0) {
        float fetch = fetch_length(rest_min, rest_max, direction) * horizontal_scale;
        SeaScales scales = sea_scales(speed, fetch);
        significant_height = scales.significant_height;
        peak_wavelength = SEA_GRAVITY * scales.peak_period * scales.peak_period / (2 * (float)math::PI);
    }

    Wave[MAX_WAVES] waves;
    foreach (index, &wave : waves) {
        SeaBand band = SEA_BANDS[index];
        float angle = heading + math::deg_to_rad(band.spread_degrees);
        wave.amplitude = band.amplitude_share * significant_height / vertical_scale;
        wave.wavelength = max(band.wavelength_share * peak_wavelength / horizontal_scale, shortest);
        wave.speed = math::sqrt(SEA_GRAVITY * wave.wavelength / (2 * (float)math::PI * horizontal_scale));
        wave.direction = { math::cos(angle), math::sin(angle) };
        wave.steepness = SEA_CHOP * 2 * (float)math::PI * MAX_WAVES * wave.amplitude / wave.wavelength;
        wave.steepness = min(wave.steepness, SEA_STEEPNESS_LIMIT);
    }
    return waves;
}

// The chord of the rest rectangle through its centre along a node-local unit direction; unbounded without an area.
fn float fetch_length(Vec2 rest_min, Vec2 rest_max, Vec2 direction) @private {
    Vec2 half = (rest_max - rest_min) / 2;
    if (!(half.x > 0 && half.y > 0)) return float::inf;
    return 2 * min(half.x / math::abs(direction.x), half.y / math::abs(direction.y));
}

// A wave count change must not change the shift the leaving waves carry: it is baked in as 1 / count.
fn void begin_blend(
    SeaBlend* blend,
    Wave[] leaving,
    Wave[MAX_WAVES] target,
    float transition_seconds,
) @private {
    if (blend.stage == SeaStage.IDLE) {
        foreach (index, &wave : blend.from) {
            if (index < leaving.len) {
                *wave = leaving[index];
                wave.steepness *= (float)MAX_WAVES / (float)leaving.len;
            } else {
                *wave = target[index];
                wave.amplitude = 0;
                wave.steepness = 0;
            }
        }
        blend.stage = SeaStage.STARTING;
    } else if (blend.stage != SeaStage.STARTING) {
        blend.from = blend.drawn;
        blend.stage = SeaStage.BLENDING;
    }

    blend.duration = transition_seconds;
    blend.elapsed = 0;
    foreach (index, &wave : blend.bounding) {
        *wave = blend.from[index];
        wave.amplitude = max(blend.from[index].amplitude, target[index].amplitude);
        wave.wavelength = max(blend.from[index].wavelength, target[index].wavelength);
        wave.steepness = max(blend.from[index].steepness, target[index].steepness);
    }
}

// While a blend runs its envelope bounds every set drawn; otherwise the desc's waves do.
fn Wave[] bounding_waves(WaterRuntime* runtime) @private {
    if (runtime.sea.stage == SeaStage.STARTING || runtime.sea.stage == SeaStage.BLENDING) {
        return runtime.sea.bounding[..];
    }
    return runtime.desc.waves[:runtime.desc.wave_count];
}

fn void place_bounds(Scene* scene, Node* node, WaterRuntime* runtime) @private {
    write_medium(scene, node, runtime);
    if (runtime.desc.mode == WaterMode.OCEAN) {
        place_ocean_bounds(
            scene:    scene,
            node:     node,
            ocean:    &runtime.ocean,
            desc:     &runtime.desc,
            waves:    bounding_waves(runtime),
            envelope: spectral_envelope(runtime),
        );
        return;
    }

    Aabb rest = {
        .min = { runtime.rest_min.x, 0, runtime.rest_min.y },
        .max = { runtime.rest_max.x, 0, runtime.rest_max.y },
    };
    scene.get(node, Mesh).local_bounds = drawn_bounds(
        rest:     rest,
        desc:     &runtime.desc,
        waves:    bounding_waves(runtime),
        envelope: spectral_envelope(runtime),
    );
}

// Uploads the blended waves each update while a blend runs, then once more so the previous waves catch up.
// A move of an ocean's anchor folds into the previous waves too, so the velocity form sees the same world surface.
fn void advance_sea(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    WaterRuntime* runtime,
    double time,
    OceanMove move,
) @private {
    SeaBlend* blend = &runtime.sea;
    if (blend.stage == SeaStage.IDLE && !move.moved) return;

    WaterParams* params = assets.@custom_params(runtime.material, WaterParams);
    params.previous = params.waves;
    if (move.moved) {
        anchor_waves(params.previous[:params.wave_count], move.inverse, move.delta);
        anchor_ripples(
            assets:  assets,
            runtime: runtime,
            params:  params,
            move:    move,
        );
    }

    if (blend.stage == SeaStage.IDLE) {
        params.waves = params.previous;
    } else if (blend.stage == SeaStage.SETTLING) {
        blend.stage = SeaStage.IDLE;
        if (move.moved) params.waves = params.previous;
    } else {
        if (blend.stage == SeaStage.STARTING) start_blend(blend, params, time);
        blend_step(
            blend:  blend,
            target: runtime.desc.waves[:MAX_WAVES],
            params: params,
            time:   time,
            move:   move,
        );
        if (blend.stage == SeaStage.SETTLING) place_bounds(scene, node, runtime);
    }
    assets.mark_material_dirty(runtime.material);
}

fn void start_blend(SeaBlend* blend, WaterParams* params, double time) @private {
    double drawn_time = (double)shader_time(time);
    blend.phase = {};
    foreach (index, &wave : params.waves[:params.wave_count]) {
        blend.phase[index] = drawn_time * (double)wave.cycles_per_second - (double)wave.phase_offset;
    }
    blend.last_time = time;
    blend.stage = SeaStage.BLENDING;
}

fn void blend_step(
    SeaBlend* blend,
    Wave[] target,
    WaterParams* params,
    double time,
    OceanMove move,
) @private {
    double step = max(time - blend.last_time, 0.0);
    blend.last_time = time;
    blend.elapsed += (float)step;
    float fraction = blend.duration > 0 ? min(blend.elapsed / blend.duration, 1.0f) : 1;

    double drawn_time = (double)shader_time(time);
    foreach (index, &packed : params.waves[:MAX_WAVES]) {
        blend.drawn[index] = target[index];
        if (fraction < 1) blend.drawn[index] = blend_wave(&blend.from[index], &target[index], fraction);

        WaveGpu next = pack_wave(&blend.drawn[index], MAX_WAVES);
        blend.phase[index] += step * 0.5 * ((double)packed.cycles_per_second + (double)next.cycles_per_second);
        if (move.moved) blend.phase[index] -= anchor_cycles(&next, move.inverse, move.delta);
        double cycles = drawn_time * (double)next.cycles_per_second - blend.phase[index];
        next.phase_offset = (float)(cycles - math::floor(cycles));
        *packed = next;
    }
    params.wave_count = MAX_WAVES;
    if (fraction >= 1) blend.stage = SeaStage.SETTLING;
}

fn Wave blend_wave(Wave* from, Wave* to, float fraction) @private {
    float start = math::atan2(from.direction.y, from.direction.x);
    float turn = math::atan2(to.direction.y, to.direction.x) - start;
    turn -= 2 * (float)math::PI * math::round(turn / (2 * (float)math::PI));
    float angle = start + turn * fraction;
    return {
        .amplitude  = from.amplitude + (to.amplitude - from.amplitude) * fraction,
        .wavelength = from.wavelength + (to.wavelength - from.wavelength) * fraction,
        .speed      = from.speed + (to.speed - from.speed) * fraction,
        .direction  = { math::cos(angle), math::sin(angle) },
        .steepness  = from.steepness + (to.steepness - from.steepness) * fraction,
    };
}
