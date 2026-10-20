module c3d::landscape::water;

import c3d;
import c3d::asset;
import c3d::landscape @public;
import c3d::material;
import c3d::maths;
import std::math;

<*
 Texels along each side of a spectral surface's field.
*>
const uint SPECTRAL_SIZE = 256; // 8 passes per axis; mirrored as SIZE and, halved, as HALF_SIZE in the compute stages

<*
 Components of a spectrum the CPU twin evaluates.
*>
const uint SPECTRAL_TWIN_WAVES = 64; // 32 B and one sine each per query and view; more narrows the bound at that cost

<*
 Standard deviations of height a spectral surface's bounds and medium offset span.
*>
const float SPECTRAL_ENVELOPE_SIGMAS = 5; // the extremes of a Gaussian field rarely pass it; a lower value clips crests

<*
 Standard deviations of the omitted components' height the twin's bound spans.
*>
const float SPECTRAL_BOUND_SIGMAS = 3; // a Gaussian error passes it at about 0.3 % of points

<*
 Seconds after which a spectral surface repeats.
*>
const float SPECTRAL_PERIOD = 1000; // frequencies are whole cycles of it, so phases stay in float range at any time

<*
 Wind in node-local metres per second a spectral surface follows until a sea state is set.
*>
const Vec2 DEFAULT_SPECTRAL_WIND = { 8, 0 }; // a moderate breeze along +X

<*
 Seed a default spectrum draws its amplitudes and phases from.
*>
const uint DEFAULT_SPECTRUM_SEED = 382; // any fixed value: default seas repeat from run to run

<*
 Metres one tile of a default spectrum covers.
*>
const float DEFAULT_PATCH_SIZE = 256; // several peak wavelengths of a moderate breeze, one metre per texel

<*
 Horizontal displacement scale a default spectrum draws with.
*>
const float DEFAULT_CHOPPINESS = 1; // full Tessendorf shift: crests sharpen and fold only at slopes near one

const float SPECTRAL_CUT_TEXELS @private = 4; // shortest wavelength in texels: shorter ones sample poorly
const float SPECTRUM_PEAK_ENHANCEMENT @private = 3.3f; // JONSWAP gamma
const float SPECTRUM_SIGMA_BELOW @private = 0.07f; // JONSWAP width below the peak frequency
const float SPECTRUM_SIGMA_ABOVE @private = 0.09f; // JONSWAP width above it
const double SPECTRUM_LOWEST_RATIO @private = 0.2; // frequencies under this share of the peak carry no energy
const double SPECTRUM_HIGHEST_RATIO @private = 10; // and over this multiple of it, less than a part in 1e4
const uint SPECTRUM_INTEGRATION_STEPS @private = 4096; // trapezoids over the normalising integral
const uint TABLE_FLOATS @private = 4; // the table texel: Gaussian pair, then the two root amplitudes
const uint FIELD_TEXTURES @private = 7; // displacement, slope, previous displacement and two pairs of FFT work images
const float TWO_PI @private = 2 * (float)math::PI;

<*
 How far a spectral surface's sea-state blend has come.
*>
enum SpectralStage : char {
    IDLE,
    STARTING,
    BLENDING,
}

<*
 One component of a spectrum as the CPU twin keeps it.
*>
struct SpectralWave {
    Vec2  wave_vector;     // radians per metre, node-local
    float steps;           // whole cycles of SPECTRAL_PERIOD the component runs per period
    float phase_offset;    // cycles of the sine form's phase at time zero
    float gauss_magnitude; // length of the Gaussian pair; times the root amplitude it is half the height amplitude
    float left;            // root amplitude in the spectrum the blend leaves
    float right;           // and in the one it reaches
    uint  column;          // table texel of the component
    uint  row;
}

<*
 Table, field images, sea-state blend and CPU twin of a spectral water body, written by the library.
*>
struct SpectralState {
    TextureId                         table;        // owned: Gaussian pair, left and right root amplitudes per texel
    TextureId                         displacement; // owned: this frame's x, y and z displacement
    TextureId                         slope;        // owned: slope along x and z
    TextureId                         previous;     // owned: last frame's displacement
    TextureId[2]                      work_a;       // owned: FFT ping-pong, two complex fields per texel
    TextureId[2]                      work_b;       // owned: FFT ping-pong, a third complex field per texel
    float                             cut;          // radians per metre above which the spectrum holds no component
    SpectralStage                     stage;
    float                             blend;        // share of the way from the left spectrum to the right
    float                             duration;     // seconds
    float                             elapsed;      // seconds
    double                            last_time;
    float                             period_share; // share of SPECTRAL_PERIOD the last update's time is into
    bool                              primed;       // the GPU wrote the field once
    float                             sigma;        // metres: height deviation of the spectrum, or of the larger of two
    float                             envelope;     // metres: the extreme of height the bounds span
    float                             bound;        // metres: the twin's reported agreement with the drawn surface
    uint                              twin_count;
    SpectralWave[SPECTRAL_TWIN_WAVES] twin;
}

// The spectrum's scales in the node-local frame, with the wave number past which components are dropped.
struct SeaSpectrum @private {
    float significant_height; // metres
    float peak_frequency;     // radians per second
    float heading;            // radians of the waves' travel
    float cut;                // radians per metre
}

fn uint table_index(uint column, uint row) @private => row * SPECTRAL_SIZE + column;

// A table texel's wave vector: the lattice index counts from the zero frequency, negative past the Nyquist one.
fn Vec2 lattice_vector(uint column, uint row, float patch_size) @private {
    int half = (int)SPECTRAL_SIZE / 2;
    int across = (int)column < half ? (int)column : (int)column - (int)SPECTRAL_SIZE;
    int down = (int)row < half ? (int)row : (int)row - (int)SPECTRAL_SIZE;
    return (Vec2){ (float)across, (float)down } * (TWO_PI / patch_size);
}

// Component frequencies are whole steps of the repeat period; mirrored in water_spectrum_evolve.comp.glsl.
fn float frequency_steps(float wave_number) @private {
    float omega_step = TWO_PI / SPECTRAL_PERIOD;
    return math::round(math::sqrt(SEA_GRAVITY * wave_number) / omega_step);
}

// Wave number past which a body's vertex lattice and the field's texels cannot hold a wave.
fn float spectral_cut(WaterDesc* desc) @private {
    float shortest = SPECTRAL_CUT_TEXELS * desc.spectrum.patch_size / (float)SPECTRAL_SIZE;
    if (desc.mode == WaterMode.OCEAN) {
        shortest = max(shortest, FADE_FULL_CELLS * desc.cell_size);
    } else if (!desc.geometry.generation) {
        shortest = max(shortest, NYQUIST_CELLS * desc.cell_size);
    }
    return TWO_PI / shortest;
}

// A node-local wind over the body's fetch; a calm wind raises nothing.
fn SeaSpectrum sea_spectrum(Vec2 wind_velocity, Vec2 rest_min, Vec2 rest_max, float cut) @private {
    float speed = min(wind_velocity.length(), SEA_WIND_LIMIT);
    if (!(speed > 0)) return { .cut = cut };

    Vec2 direction = wind_velocity / wind_velocity.length();
    SeaScales scales = sea_scales(speed, fetch_length(rest_min, rest_max, direction));
    return {
        .significant_height = scales.significant_height,
        .peak_frequency     = TWO_PI / scales.peak_period,
        .heading            = math::atan2(direction.y, direction.x),
        .cut                = cut,
    };
}

fn double jonswap_shape(double frequency, double peak) @private {
    double ratio = peak / frequency;
    double sigma = frequency <= peak ? (double)SPECTRUM_SIGMA_BELOW : (double)SPECTRUM_SIGMA_ABOVE;
    double offset = (frequency - peak) / (sigma * peak);
    double enhancement = math::pow((double)SPECTRUM_PEAK_ENHANCEMENT, math::exp(-0.5 * offset * offset));
    return math::pow(frequency, -5.0) * math::exp(-1.25 * ratio * ratio * ratio * ratio) * enhancement;
}

// The integral of the shape over a band of frequencies, clipped to the band the spectrum carries.
fn double jonswap_area(double peak, double low, double high) @private {
    low = max(low, peak * SPECTRUM_LOWEST_RATIO);
    high = min(high, peak * SPECTRUM_HIGHEST_RATIO);
    if (!(high > low)) return 0;

    double step = (high - low) / (double)SPECTRUM_INTEGRATION_STEPS;
    double area = 0.5 * (jonswap_shape(low, peak) + jonswap_shape(high, peak));
    for (uint index = 1; index < SPECTRUM_INTEGRATION_STEPS; index++) {
        area += jonswap_shape(low + step * (double)index, peak);
    }
    return area * step;
}

// Root amplitude per table texel: half the standard deviation of the component's height at the lattice vector, from
// the JONSWAP frequency spectrum, a cosine-squared spread about the heading and deep-water dispersion. Texels past the
// cut, on the zero frequency and on the Nyquist row and column hold zero. The lattice samples a narrow peak coarsely,
// so the roots are scaled until their variance is the share of the sea's the lattice and the cut leave in band.
fn void spectral_roots(SeaSpectrum* sea, float patch_size, float[] roots) @private {
    roots[..] = 0;
    if (!(sea.significant_height > 0)) return;

    double peak = sea.peak_frequency;
    double lattice_step = (double)(TWO_PI / patch_size);
    double lattice_area = lattice_step * lattice_step;
    uint nyquist = SPECTRAL_SIZE / 2;
    double captured;
    for (uint row = 0; row < SPECTRAL_SIZE; row++) {
        for (uint column = 0; column < SPECTRAL_SIZE; column++) {
            if (column == nyquist || row == nyquist) continue;

            Vec2 wave_vector = lattice_vector(column, row, patch_size);
            float wave_number = wave_vector.length();
            if (!(wave_number > 0) || wave_number > sea.cut) continue;

            double cosine = math::cos(math::atan2(wave_vector.y, wave_vector.x) - sea.heading);
            if (!(cosine > 0)) continue;

            double frequency = math::sqrt(SEA_GRAVITY * (double)wave_number);
            double spread = 2.0 / math::PI * cosine * cosine;
            double density = jonswap_shape(frequency, peak) * spread * (SEA_GRAVITY / (2 * frequency)) / wave_number;
            roots[table_index(column, row)] = (float)(density * lattice_area);
            captured += density * lattice_area;
        }
    }
    if (!(captured > 0)) return;

    double deviation = sea.significant_height / 4.0;
    double lowest = math::sqrt(SEA_GRAVITY * 0.5 * lattice_step);
    double highest = math::sqrt(SEA_GRAVITY * (double)sea.cut);
    double in_band = jonswap_area(peak, lowest, highest) / jonswap_area(peak, 0, double::inf);
    double rescale = deviation * deviation * in_band / captured;
    foreach (&root : roots) *root = (float)(0.5 * math::sqrt((double)*root * rescale));
}

// The table texel as a pointer: the Gaussian pair, then the left and right root amplitudes.
fn float[TABLE_FLOATS]* table_texels(AssetStore* assets, SpectralState* state) @private {
    return (float[TABLE_FLOATS]*)assets.texture(state.table).pixels.ptr;
}

// Variance of the height of the texel's component: twice the squared magnitude of h0, at the larger root amplitude.
fn double component_variance(float[TABLE_FLOATS]* texel, bool both) @private {
    float root = both ? max((*texel)[2], (*texel)[3]) : (*texel)[3];
    double magnitude = (double)(*texel)[0] * (*texel)[0] + (double)(*texel)[1] * (*texel)[1];
    return 2.0 * magnitude * (double)root * root;
}

// Picks the strongest components for the twin and sets the sigma, the envelope and the bound from the rest.
// `both` takes the larger of the two spectra per texel, which bounds every blended state between them.
fn void analyse_spectrum(AssetStore* assets, SpectralState* state, WaterDesc* desc, bool both) @private {
    float[TABLE_FLOATS]* texels = table_texels(assets, state);
    float patch_size = desc.spectrum.patch_size;
    double[SPECTRAL_TWIN_WAVES] strengths;
    uint count;
    uint weakest;
    double total;
    for (uint row = 0; row < SPECTRAL_SIZE; row++) {
        for (uint column = 0; column < SPECTRAL_SIZE; column++) {
            float[TABLE_FLOATS]* texel = &texels[table_index(column, row)];
            double variance = component_variance(texel, both);
            total += variance;
            if (!(variance > 0)) continue;

            bool room = count < SPECTRAL_TWIN_WAVES;
            if (!room && variance <= strengths[weakest]) continue;

            uint slot = room ? count++ : weakest;
            strengths[slot] = variance;
            Vec2 wave_vector = lattice_vector(column, row, patch_size);
            state.twin[slot] = {
                .wave_vector     = wave_vector,
                .steps           = frequency_steps(wave_vector.length()),
                .phase_offset    = math::atan2((*texel)[1], (*texel)[0]) / TWO_PI + 0.25f,
                .gauss_magnitude = math::sqrt((*texel)[0] * (*texel)[0] + (*texel)[1] * (*texel)[1]),
                .left            = (*texel)[2],
                .right           = (*texel)[3],
                .column          = column,
                .row             = row,
            };
            if (count == SPECTRAL_TWIN_WAVES) {
                weakest = 0;
                for (uint candidate = 1; candidate < count; candidate++) {
                    if (strengths[candidate] < strengths[weakest]) weakest = candidate;
                }
            }
        }
    }

    double twin;
    foreach (strength : strengths[:count]) twin += strength;
    state.twin_count = count;
    state.sigma = (float)math::sqrt(total);
    state.envelope = SPECTRAL_ENVELOPE_SIGMAS * state.sigma;
    state.bound = SPECTRAL_BOUND_SIGMAS * (float)math::sqrt(max(total - twin, 0.0));
}

// The table: unit Gaussian pairs from the seed, and the roots of the sea the wind raises on both sides of the blend.
fn SpectralState*? create_spectral(AssetStore* assets, WaterDesc* desc, Vec2 rest_min, Vec2 rest_max) @private {
    Allocator allocator = assets.allocator;
    sz count = (sz)SPECTRAL_SIZE * SPECTRAL_SIZE;

    SeaSpectrum sea = sea_spectrum(DEFAULT_SPECTRAL_WIND, rest_min, rest_max, spectral_cut(desc));
    char[] pixels = alloc::new_array(allocator, char, count * TABLE_FLOATS * float::size);
    @pool() {
        float[] roots = alloc::new_array(tmem, float, count);
        spectral_roots(&sea, desc.spectrum.patch_size, roots);
        float[TABLE_FLOATS]* texels = (float[TABLE_FLOATS]*)pixels.ptr;
        foreach (index, &texel : texels[:count]) {
            Vec2 gauss = landscape::gaussian_pair(desc.spectrum.seed, (uint)index);
            *texel = { gauss.x, gauss.y, roots[index], roots[index] };
        }
    };

    TextureDesc table_desc = material::texture_2d_desc(SPECTRAL_SIZE, SPECTRAL_SIZE, RGBA32_FLOAT, "water_spectrum");
    table_desc.generate_mips = false;
    TextureId? added = assets.add_texture_owned(table_desc, pixels);
    if (catch excuse = added) {
        alloc::free(allocator, pixels.ptr);
        return excuse~;
    }
    TextureId table = added;
    defer catch assets.remove_texture(table);

    SpectralState* state = alloc::new(allocator, SpectralState);
    defer catch alloc::free(allocator, state);
    *state = { .table = table, .cut = sea.cut, .blend = 1 };
    add_field_textures(assets, state)!;
    analyse_spectrum(assets, state, desc, false);
    return state;
}

fn TextureId? add_field_texture(AssetStore* assets, PixelFormat format, ZString name) @private {
    TextureDesc desc = material::texture_2d_desc(SPECTRAL_SIZE, SPECTRAL_SIZE, format, name);
    desc.generate_mips = false;
    return assets.add_texture_empty(desc);
}

// All or nothing: the textures already added are removed when one fails.
fn void? add_field_textures(AssetStore* assets, SpectralState* state) @private {
    TextureId*[FIELD_TEXTURES] slots = {
        &state.displacement, &state.slope, &state.previous,
        &state.work_a[0], &state.work_a[1], &state.work_b[0], &state.work_b[1],
    };
    ZString[FIELD_TEXTURES] names = {
        "water_displacement", "water_slope", "water_displacement_previous",
        "water_spectrum_a0", "water_spectrum_a1", "water_spectrum_b0", "water_spectrum_b1",
    };
    PixelFormat[FIELD_TEXTURES] formats = {
        RGBA16_FLOAT, RGBA16_FLOAT, RGBA16_FLOAT, RGBA32_FLOAT, RGBA32_FLOAT, RGBA32_FLOAT, RGBA32_FLOAT,
    };
    foreach (index, name : names) {
        TextureId? added = add_field_texture(assets, formats[index], name);
        if (catch excuse = added) {
            foreach (earlier : slots[:index]) assets.remove_texture(*earlier);
            return excuse~;
        }
        *slots[index] = added;
    }
}

fn void release_spectral(AssetStore* assets, SpectralState* state) @private {
    TextureId[FIELD_TEXTURES + 1] owned = {
        state.displacement, state.slope, state.previous,
        state.work_a[0], state.work_a[1], state.work_b[0], state.work_b[1],
        state.table,
    };
    foreach (texture : owned) {
        if (assets.textures.is_live(texture)) assets.remove_texture(texture);
    }
    alloc::free(assets.allocator, state);
}

// The coordinates of the field a rest point at the node-local origin samples: half a texel, so a texel's centre is
// its lattice point, plus the world position of the node, folded in a double, for an ocean.
fn Vec2 field_offset(WaterDesc* desc, Mat4 inverse, double[<2>] anchor) @private {
    double texel = 0.5 / SPECTRAL_SIZE;
    if (desc.mode != WaterMode.OCEAN) return { (float)texel, (float)texel };

    double patch = desc.spectrum.patch_size;
    double local_x = (double)inverse.m00 * anchor.x + (double)inverse.m02 * anchor.y;
    double local_z = (double)inverse.m20 * anchor.x + (double)inverse.m22 * anchor.y;
    double across = local_x / patch;
    double down = local_z / patch;
    return { (float)(texel + across - math::floor(across)), (float)(texel + down - math::floor(down)) };
}

// Seconds into the repeat period as a share of it.
fn float fold_into_period(double time) @private {
    double cycles = time / SPECTRAL_PERIOD;
    return (float)(cycles - math::floor(cycles));
}

// Moves the blend to the new sea state: the spectrum it has reached becomes the left side of the table.
fn void blend_spectral(
    AssetStore* assets,
    WaterRuntime* runtime,
    Vec2 wind_velocity,
    float transition_seconds,
) @private {
    SpectralState* state = runtime.spectral;
    sz count = (sz)SPECTRAL_SIZE * SPECTRAL_SIZE;
    SeaSpectrum sea = sea_spectrum(wind_velocity, runtime.rest_min, runtime.rest_max, state.cut);
    float[TABLE_FLOATS]* texels = table_texels(assets, state);
    @pool() {
        float[] roots = alloc::new_array(tmem, float, count);
        spectral_roots(&sea, runtime.desc.spectrum.patch_size, roots);
        foreach (index, &texel : texels[:count]) {
            (*texel)[2] += ((*texel)[3] - (*texel)[2]) * state.blend;
            (*texel)[3] = roots[index];
        }
    };
    assets.mark_texture_dirty(state.table);

    state.stage = SpectralStage.STARTING;
    state.blend = 0;
    state.duration = transition_seconds;
    analyse_spectrum(assets, state, &runtime.desc, true);
    runtime.spectral_bound = state.bound;
}

// Moves the clock, the blend and, once a blend ends, the twin and the bounds.
fn void advance_spectral(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    WaterRuntime* runtime,
    double time,
    OceanMove move,
) @private {
    SpectralState* state = runtime.spectral;
    state.period_share = fold_into_period(time);
    if (move.moved) {
        WaterParams* params = assets.@custom_params(runtime.material, WaterParams);
        params.field_offset = field_offset(&runtime.desc, move.inverse, runtime.ocean.anchor);
        assets.mark_material_dirty(runtime.material);
    }
    if (state.stage == SpectralStage.IDLE) return;

    if (state.stage == SpectralStage.STARTING) {
        state.last_time = time;
        state.elapsed = 0;
        state.stage = SpectralStage.BLENDING;
    }
    state.elapsed += (float)max(time - state.last_time, 0.0);
    state.last_time = time;
    state.blend = state.duration > 0 ? min(state.elapsed / state.duration, 1.0f) : 1;
    if (state.blend < 1) return;

    state.stage = SpectralStage.IDLE;
    analyse_spectrum(assets, state, &runtime.desc, false);
    runtime.spectral_bound = state.bound;
    place_bounds(scene, node, runtime);
}

// The twin's components as Gerstner terms at the state's blend, the anchor of an ocean folded into their phases.
fn void fill_spectral_view(WaterRuntime* runtime, Mat4 inverse, SurfaceView* view) @private {
    SpectralState* state = runtime.spectral;
    bool ocean = runtime.desc.mode == WaterMode.OCEAN;
    foreach (index, &component : state.twin[:state.twin_count]) {
        float root = component.left + (component.right - component.left) * state.blend;
        float amplitude = 2 * component.gauss_magnitude * root;
        float wave_number = component.wave_vector.length();
        WaveGpu wave = {
            .direction         = component.wave_vector / wave_number,
            .amplitude         = amplitude,
            .cycles_per_metre  = wave_number / TWO_PI,
            .cycles_per_second = component.steps / SPECTRAL_PERIOD,
            .shift             = runtime.desc.spectrum.choppiness * amplitude,
            .phase_offset      = component.phase_offset,
        };
        if (ocean) {
            double cycles = anchor_cycles(&wave, inverse, runtime.ocean.anchor) + (double)wave.phase_offset;
            wave.phase_offset = (float)(cycles - math::floor(cycles));
        }
        view.waves[index] = wave;
    }
    view.wave_count = state.twin_count;
    view.period = SPECTRAL_PERIOD;
}
