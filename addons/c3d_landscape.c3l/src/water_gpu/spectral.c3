module c3d::landscape::water_gpu @feat(C3D_LANDSCAPE_GPU);

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::landscape @public;
import c3d::landscape::water;
import c3d::material;
import c3d::render;
import c3d::scene;
import std::math;

const uint FFT_PASSES_PER_AXIS @private = 8; // log2 of the field size; one dispatch each
const uint GROUP_EDGE @private = 8; // mirrored as local_size_x and local_size_y in the three stages
const float INVERSE_SIGN @private = 1; // the sign of the transform's exponent; a forward transform takes minus one
const String EVOLVE_KEY @private = "c3d_landscape/water_spectrum_evolve";
const String FFT_KEY @private = "c3d_landscape/water_spectrum_fft";
const String FINALIZE_KEY @private = "c3d_landscape/water_spectrum_finalize";

$assert water::SPECTRAL_SIZE == 1 << FFT_PASSES_PER_AXIS;

<*
 Compute dispatches update records for each spectral water body.
*>
const uint DISPATCHES_PER_BODY = 2 + 2 * FFT_PASSES_PER_AXIS; // the evolve, a pass per bit per axis and the split

// Mirrors EvolveRoot in water_spectrum_evolve.comp.glsl.
struct EvolveRoot @private {
    float share_of_period;
    float blend;
    float patch_size;
    float choppiness;
    float omega_step;
    float _pad0;
    float _pad1;
    float _pad2;
}

$assert EvolveRoot::size == 32;

// Mirrors FftRoot in water_spectrum_fft.comp.glsl.
struct FftRoot @private {
    uint  span;
    uint  vertical;
    float sign;
    uint  _pad0;
}

$assert FftRoot::size == 16;

// Mirrors FinalizeRoot in water_spectrum_finalize.comp.glsl.
struct FinalizeRoot @private {
    uint first_frame;
    uint _pad0;
    uint _pad1;
    uint _pad2;
}

$assert FinalizeRoot::size == 16;

struct Stages @private {
    ComputeShaderId evolve;
    ComputeShaderId fft;
    ComputeShaderId finalize;
}

<*
 Evolve and transform every spectral water body's field for this frame.
 Call once per frame after water::update, before prepare_scene_trace and drawing.
 @param [&inout] renderer : "Frame open; no overlay open."
 @param [&inout] scene : "Registered with register_water."
 @param [&inout] assets : "The store given to register_water."
 @require renderer.frame_open
 @return? AssetStore.add_compute_shader!, Renderer.dispatch!
*>
fn void? update(Renderer* renderer, Scene* scene, AssetStore* assets) {
    Stages stages;
    bool ready;
    fault failure;
    scene.@each(WaterRuntime; entity, runtime) {
        if (runtime.spectral && !failure) {
            if (!ready) {
                Stages? found = add_stages(assets);
                if (catch excuse = found) {
                    failure = excuse;
                } else {
                    stages = found;
                    ready = true;
                }
            }
            if (ready && !failure) {
                if (catch excuse = record_body(renderer, &stages, runtime)) failure = excuse;
            }
        }
    };
    if (failure) return failure~;
}

// One set of stages per store, shared by every body.
fn Stages? add_stages(AssetStore* assets) @private {
    return {
        .evolve   = stage(assets, EVOLVE_KEY, landscape::WATER_SPECTRUM_EVOLVE_SPIRV[..])!,
        .fft      = stage(assets, FFT_KEY, landscape::WATER_SPECTRUM_FFT_SPIRV[..])!,
        .finalize = stage(assets, FINALIZE_KEY, landscape::WATER_SPECTRUM_FINALIZE_SPIRV[..])!,
    };
}

fn ComputeShaderId? stage(AssetStore* assets, String key, char[] spirv) @private {
    if (try found = assets.find_compute_shader(key)) return found;

    ComputeShaderDesc desc = { .compute = spirv };
    return assets.add_compute_shader(&desc, key);
}

fn uint groups_for(uint texels) @private => (texels + GROUP_EDGE - 1) / GROUP_EDGE;

fn void? record_body(Renderer* renderer, Stages* stages, WaterRuntime* runtime) @private {
    SpectralState* state = runtime.spectral;
    uint groups = groups_for(water::SPECTRAL_SIZE);

    EvolveRoot evolve = {
        .share_of_period = state.period_share,
        .blend           = state.blend,
        .patch_size      = runtime.desc.spectrum.patch_size,
        .choppiness      = runtime.desc.spectrum.choppiness,
        .omega_step      = 2 * (float)math::PI / water::SPECTRAL_PERIOD,
    };
    DispatchTexture[3] evolve_textures = {
        render::read_texture(state.table),
        render::write_texture(state.work_a[0]),
        render::write_texture(state.work_b[0]),
    };
    renderer.dispatch({
        .shader   = stages.evolve,
        .root     = material::@as_bytes(evolve),
        .groups   = { groups, groups, 1 },
        .textures = evolve_textures[..],
    })!;

    // The span doubles along an axis; the images swap each pass, so the result of the sixteenth is in the first pair.
    for (uint pass = 0; pass < 2 * FFT_PASSES_PER_AXIS; pass++) {
        FftRoot fft = {
            .span     = 1u << (pass % FFT_PASSES_PER_AXIS),
            .vertical = pass / FFT_PASSES_PER_AXIS,
            .sign     = INVERSE_SIGN,
        };
        uint source = pass % 2;
        DispatchTexture[4] fft_textures = {
            render::read_texture(state.work_a[source]),
            render::read_texture(state.work_b[source]),
            render::write_texture(state.work_a[1 - source]),
            render::write_texture(state.work_b[1 - source]),
        };
        renderer.dispatch({
            .shader   = stages.fft,
            .root     = material::@as_bytes(fft),
            .groups   = { groups_for(water::SPECTRAL_SIZE / 2), groups, 1 },
            .textures = fft_textures[..],
        })!;
    }

    FinalizeRoot finalize = { .first_frame = state.primed ? 0 : 1 };
    DispatchTexture[5] finalize_textures = {
        render::read_texture(state.work_a[0]),
        render::read_texture(state.work_b[0]),
        render::write_texture(state.displacement, access: DispatchAccess.READ_WRITE),
        render::write_texture(state.previous),
        render::write_texture(state.slope),
    };
    renderer.dispatch({
        .shader   = stages.finalize,
        .root     = material::@as_bytes(finalize),
        .groups   = { groups, groups, 1 },
        .textures = finalize_textures[..],
    })!;
    state.primed = true;
}
