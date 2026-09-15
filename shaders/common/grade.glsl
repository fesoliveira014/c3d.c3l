#ifndef C3D_GRADE_GLSL
#define C3D_GRADE_GLSL

const vec3 REC709_LUMA = vec3(0.2126, 0.7152, 0.0722);
const float MID_GRAY = 0.18;
const float SRGB_ENCODED_THRESHOLD = 0.04045;
const float SRGB_LINEAR_THRESHOLD = 0.0031308;
const float SRGB_LINEAR_SCALE = 12.92;
const float SRGB_OFFSET = 0.055;
const float SRGB_SCALE = 1.055;
const float SRGB_EXPONENT = 2.4;

const mat3 LINEAR_TO_LMS = mat3(
    0.390405, 0.0708416, 0.0231082,
    0.549941, 0.963172, 0.128021,
    0.00892632, 0.00135775, 0.936245);
const mat3 LMS_TO_LINEAR = mat3(
    2.85847, -0.210182, -0.0418120,
    -1.62879, 1.15820, -0.118169,
    -0.024891, 0.000324281, 1.06867);

const mat3 ACES_INPUT = mat3(
    0.59719, 0.07600, 0.02840,
    0.35458, 0.90834, 0.13383,
    0.04823, 0.01566, 0.83777);
const mat3 ACES_OUTPUT = mat3(
    1.60475, -0.10208, -0.00327,
    -0.53108, 1.10813, -0.07276,
    -0.07367, -0.00605, 1.07602);

const mat3 LINEAR_SRGB_TO_REC2020 = mat3(
    0.6274, 0.0691, 0.0164,
    0.3293, 0.9195, 0.0880,
    0.0433, 0.0113, 0.8956);
const mat3 REC2020_TO_LINEAR_SRGB = mat3(
    1.6605, -0.1246, -0.0182,
    -0.5876, 1.1329, -0.1006,
    -0.0728, -0.0083, 1.1187);
const mat3 AGX_INSET = mat3(
    0.856627153315983, 0.137318972929847, 0.11189821299995,
    0.0951212405381588, 0.761241990602591, 0.0767994186031903,
    0.0482516061458583, 0.101439036467562, 0.811302368396859);
const mat3 AGX_OUTSET = mat3(
    1.1271005818144368, -0.1413297634984383, -0.14132976349843826,
    -0.11060664309660323, 1.157823702216272, -0.11060664309660294,
    -0.016493938717834573, -0.016493938717834257, 1.2519364065950405);
const float AGX_MIN_EV = -12.47393;
const float AGX_MAX_EV = 4.026069;
const float AGX_OUTPUT_GAMMA = 2.2;

vec3 linear_to_srgb(vec3 color) {
    vec3 low = color * SRGB_LINEAR_SCALE;
    vec3 high = SRGB_SCALE * pow(color, vec3(1.0 / SRGB_EXPONENT)) - SRGB_OFFSET;
    return mix(high, low, lessThanEqual(color, vec3(SRGB_LINEAR_THRESHOLD)));
}

vec3 srgb_to_linear(vec3 encoded) {
    vec3 low = encoded / SRGB_LINEAR_SCALE;
    vec3 high = pow((encoded + SRGB_OFFSET) / SRGB_SCALE, vec3(SRGB_EXPONENT));
    return mix(high, low, lessThanEqual(encoded, vec3(SRGB_ENCODED_THRESHOLD)));
}

vec3 tonemap_reinhard(vec3 color) {
    return color / (1.0 + color);
}

vec3 aces_rrt_odt_fit(vec3 value) {
    vec3 a = value * (value + 0.0245786) - 0.000090537;
    vec3 b = value * (0.983729 * value + 0.4329510) + 0.238081;
    return a / b;
}

vec3 tonemap_aces(vec3 color) {
    vec3 fitted = aces_rrt_odt_fit(ACES_INPUT * color);
    return clamp(ACES_OUTPUT * fitted, 0.0, 1.0);
}

vec3 agx_contrast(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

vec3 tonemap_agx(vec3 color) {
    vec3 working = AGX_INSET * (LINEAR_SRGB_TO_REC2020 * color);
    working = log2(max(working, vec3(1e-10)));
    working = clamp((working - AGX_MIN_EV) / (AGX_MAX_EV - AGX_MIN_EV), 0.0, 1.0);
    working = AGX_OUTSET * agx_contrast(working);
    working = pow(max(working, vec3(0.0)), vec3(AGX_OUTPUT_GAMMA));
    return clamp(REC2020_TO_LINEAR_SRGB * working, 0.0, 1.0);
}

vec3 tonemap(vec3 color, uint operator_index) {
    switch (operator_index) {
        case TONEMAP_ACES: return tonemap_aces(color);
        case TONEMAP_AGX: return tonemap_agx(color);
        case TONEMAP_REINHARD: return tonemap_reinhard(color);
        default: return clamp(color, 0.0, 1.0);
    }
}

// Scene-linear in, display-linear [0, 1] out; the attachment encodes.
vec3 grade_color(vec3 color, vec2 uv, GradeGpu grade) {
    color *= grade.exposure;
    if (grade.bloom_texture != 0u) {
        color += grade.bloom_intensity * sample_texture_2d(grade.bloom_texture, grade.bloom_sampler, uv).rgb;
    }
    color = LMS_TO_LINEAR * (grade.balance.xyz * (LINEAR_TO_LMS * color));
    color = (color - MID_GRAY) * grade.contrast + MID_GRAY;
    float luma = dot(color, REC709_LUMA);
    color = luma + (color - luma) * grade.saturation;
    color = color * grade.gain.xyz + grade.lift.xyz * (1.0 - color);
    color = pow(max(color, vec3(0.0)), 1.0 / grade.gamma.xyz);
    color = tonemap(color, grade.tonemap);
    if (grade.lut_texture != 0u) {
        vec3 coordinate = linear_to_srgb(color) * grade.lut_scale + grade.lut_offset;
        color = srgb_to_linear(sample_texture_3d(grade.lut_texture, grade.lut_sampler, coordinate).rgb);
    }
    return color;
}

// Perceptual luma of display-linear color, the FXAA edge metric.
float display_luma(vec3 color) {
    return sqrt(dot(color, REC709_LUMA));
}

#endif
