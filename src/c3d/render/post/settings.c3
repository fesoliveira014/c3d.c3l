module c3d::render::post;

import c3d;
import c3d::shader;
import gpu;
import std::math;

const float WHITE_BALANCE_RANGE @private = 100.0f / 65.0f; // unit inputs span the same chromaticity shift as a [-100, 100] control
const float D65_X @private = 0.31271f;
const float WARM_SHIFT @private = 0.1f;
const float COOL_SHIFT @private = 0.05f;
const float TINT_SHIFT @private = 0.05f;
const Vec3 D65_LMS @private = { 0.949237f, 1.03542f, 1.08728f };

<*
 Bloom levels a view may allocate.
*>
const uint BLOOM_MAX_LEVELS = 8; // eight halvings reach 5 px from 1280; more levels only widen the glow

<*
 Motion-blur taps a pixel may take.
*>
const uint MOTION_BLUR_MAX_SAMPLES = 32; // two color, depth and velocity reads per tap bound the filter cost

const float SENSOR_HEIGHT @private = 0.024f; // 35 mm frame; focal_length and aperture read as camera settings

<*
 Display tone mapping operator.
*>
enum Tonemap {
    NONE,
    ACES,
    AGX,
    REINHARD,
}

$assert Tonemap.NONE.ordinal == shader::TONEMAP_NONE;
$assert Tonemap.ACES.ordinal == shader::TONEMAP_ACES;
$assert Tonemap.AGX.ordinal == shader::TONEMAP_AGX;
$assert Tonemap.REINHARD.ordinal == shader::TONEMAP_REINHARD;

<*
 Display grading applied to scene-linear color before output encoding.
*>
struct GradeParams {
    Tonemap   tonemap;
    float     contrast;
    float     saturation;
    float     temperature;
    float     tint;
    Vec3      lift;
    Vec3      gamma;
    Vec3      gain;
    TextureId lut;
}

<*
 Bright-pass glow added to scene-linear color before grading.
*>
struct BloomParams {
    float threshold;
    float knee;
    float intensity;
    uint  levels;
}

<*
 Thin-lens focus: distances in meters, aperture an f-number, max_coc a half-resolution pixel radius.
*>
struct DofParams {
    float focus_distance;
    float focal_length;
    float aperture;
    float max_coc;
}

<*
 Blur along screen motion: shutter as a fraction of the rendered interval, max_velocity in pixels.
*>
struct MotionBlurParams {
    float shutter;
    uint  samples;
    float max_velocity;
}

<*
 Display processing of one view; a zeroed value is not neutral.
*>
struct PostStack {
    GradeParams      grade;
    bool             fxaa;
    bool             bloom;
    BloomParams      bloom_params;
    bool             depth_of_field;
    DofParams        dof_params;
    bool             motion_blur;
    MotionBlurParams motion_blur_params;
}

<*
 Neutral grading with ACES and FXAA enabled and every effect off.
*>
fn PostStack default_post_stack() {
    return {
        .grade = {
            .tonemap    = Tonemap.ACES,
            .contrast   = 1,
            .saturation = 1,
            .gamma      = { 1, 1, 1 },
            .gain       = { 1, 1, 1 },
        },
        .fxaa = true,
        .bloom_params = { .threshold = 1, .knee = 0.5f, .intensity = 0.05f, .levels = 5 },
        .dof_params   = { .focus_distance = 5, .focal_length = 0.05f, .aperture = 2.8f, .max_coc = 16 },
        .motion_blur_params = { .shutter = 0.5f, .samples = 12, .max_velocity = 32 },
    };
}

<*
 Whether every enabled effect's parameters are in range.
 @param [&in] stack : "Read only."
 @pure
*>
fn bool post_stack_valid(PostStack* stack) {
    if (stack.bloom && (stack.bloom_params.levels == 0 || stack.bloom_params.levels > BLOOM_MAX_LEVELS)) return false;
    if (stack.depth_of_field && !dof_params_valid(&stack.dof_params)) return false;
    if (stack.motion_blur && !motion_blur_params_valid(&stack.motion_blur_params)) return false;
    return true;
}

<*
 Tiles of POST_TILE_SIZE pixels covering an extent.
 @pure
*>
fn uint tile_count(uint extent) {
    return (extent + shader::POST_TILE_SIZE - 1) / shader::POST_TILE_SIZE;
}

<*
 Half-resolution pixels of circle-of-confusion radius per unit of (depth - focus) / depth.
 @param [&in] params : "Focal length below the focus distance."
 @param half_height : "Pixels of the half-resolution layers."
 @pure
*>
fn float dof_aperture_scale(DofParams* params, uint half_height) {
    float lens = params.focal_length * params.focal_length
      / (params.aperture * (params.focus_distance - params.focal_length));
    return 0.5f * lens * (float)half_height / SENSOR_HEIGHT;
}

<*
 Signed circle-of-confusion radius; negative in front of the focus distance.
 @param [&in] params : "Supplies focus_distance and max_coc."
 @param view_depth : "Forward distance in meters, positive."
 @pure
*>
fn float dof_coc(DofParams* params, float aperture_scale, float view_depth) {
    float coc = aperture_scale * (view_depth - params.focus_distance) / view_depth;
    return math::clamp(coc, -params.max_coc, params.max_coc);
}

<*
 Extent of one bloom level, halving from the working resolution.
 @pure
*>
fn uint bloom_level_extent(uint extent, uint level) {
    uint halved = extent >> (level + 1);
    return halved ? halved : 1;
}

<*
 LMS channel multipliers of the white balance; neutral inputs give one.
 @param temperature : "Blue to amber in [-1, 1]."
 @param tint : "Green to magenta in [-1, 1]."
 @pure
*>
fn Vec3 white_balance_coefficients(float temperature, float tint) {
    float warmth = temperature * WHITE_BALANCE_RANGE;
    float shift = tint * WHITE_BALANCE_RANGE;
    float x = D65_X - warmth * (warmth < 0 ? WARM_SHIFT : COOL_SHIFT);
    float y = standard_illuminant_y(x) + shift * TINT_SHIFT;
    return D65_LMS / cie_xy_to_lms(x, y);
}

<*
 Texel-center scale of a LUT lookup coordinate.
 @require size > 1
 @pure
*>
fn float lut_scale(uint size) {
    return (float)(size - 1) / (float)size;
}

<*
 Texel-center offset of a LUT lookup coordinate.
 @require size > 1
 @pure
*>
fn float lut_offset(uint size) {
    return 0.5f / (float)size;
}

<*
 Pack grading and the camera exposure into the shader layout.
 @param [&out] gpu_grade : "Overwritten whole."
 @param [&in] params : "CPU grading."
 @param lut_texture : "Zero without a LUT."
 @param lut_size : "Edge texel count of the LUT; ignored without one."
 @param bloom_texture : "Zero without bloom."
*>
fn void write_grade_gpu(
    GradeGpu* gpu_grade,
    GradeParams* params,
    float camera_exposure,
    gpu::TextureIndex lut_texture = (gpu::TextureIndex)0,
    gpu::SamplerIndex lut_sampler = (gpu::SamplerIndex)0,
    uint lut_size = 0,
    gpu::TextureIndex bloom_texture = (gpu::TextureIndex)0,
    gpu::SamplerIndex bloom_sampler = (gpu::SamplerIndex)0,
    float bloom_intensity = 0,
) {
    Vec3 balance = white_balance_coefficients(params.temperature, params.tint);
    bool lut = lut_texture != (gpu::TextureIndex)0;
    *gpu_grade = {
        .exposure    = camera_exposure,
        .contrast    = params.contrast,
        .saturation  = params.saturation,
        .tonemap     = (uint)params.tonemap.ordinal,
        .balance     = { balance.x, balance.y, balance.z, 0 },
        .lift        = { params.lift.x, params.lift.y, params.lift.z, 0 },
        .gamma       = { params.gamma.x, params.gamma.y, params.gamma.z, 0 },
        .gain        = { params.gain.x, params.gain.y, params.gain.z, 0 },
        .lut_texture = lut ? lut_texture : (gpu::TextureIndex)0,
        .lut_sampler = lut ? lut_sampler : (gpu::SamplerIndex)0,
        .lut_scale   = lut ? lut_scale(lut_size) : 0,
        .lut_offset  = lut ? lut_offset(lut_size) : 0,
        .bloom_texture   = bloom_texture,
        .bloom_sampler   = bloom_texture ? bloom_sampler : (gpu::SamplerIndex)0,
        .bloom_intensity = bloom_texture ? bloom_intensity : 0,
    };
}

<*
 @pure
*>
fn bool dof_params_valid(DofParams* params) @private {
    return params.focal_length > 0 && params.aperture > 0 && params.max_coc > 0
      && params.focus_distance > params.focal_length;
}

<*
 @pure
*>
fn bool motion_blur_params_valid(MotionBlurParams* params) @private {
    return params.samples > 0 && params.samples <= MOTION_BLUR_MAX_SAMPLES && params.max_velocity > 0
      && params.shutter >= 0;
}

<*
 @pure
*>
fn float standard_illuminant_y(float x) @private {
    return 2.87f * x - 3 * x * x - 0.27509507f;
}

<*
 @pure
*>
fn Vec3 cie_xy_to_lms(float x, float y) @private {
    float big_x = x / y;
    float big_z = (1 - x - y) / y;
    return {
        0.7328f * big_x + 0.4296f - 0.1624f * big_z,
        -0.7036f * big_x + 1.6975f + 0.0061f * big_z,
        0.0030f * big_x + 0.0136f + 0.9834f * big_z,
    };
}
