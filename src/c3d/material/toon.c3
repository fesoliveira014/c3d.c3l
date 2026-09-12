module c3d::material;

import c3d;
import std::math;

<* Default bands, base color and optional surface rim. *>
const ToonParams TOON_PARAMS_DEFAULT = {
    .color = { 1, 1, 1, 1 },
    .map = { .transform = UV_TRANSFORM_IDENTITY },
    .steps = 4,
    .rim_color = { 1, 1, 1 },
    .rim_power = 2,
}; // Four diffuse bands; zero rim strength avoids a default glow.

<* Quantized diffuse factors and an optional intensity ramp. *>
struct ToonParams {
    Vec4 color;
    TextureSlot map;
    uint steps;
    TextureId gradient_map;
    Vec3 rim_color;
    float rim_strength;
    float rim_power;
}

<*
 Diffuse bands with smooth indirect fill and optional rim lighting.
 @require params.color.r >= 0, params.color.r <= 1
 @require params.color.g >= 0, params.color.g <= 1
 @require params.color.b >= 0, params.color.b <= 1
 @require params.color.a >= 0, params.color.a <= 1
 @require params.steps >= 2
 @require params.rim_color.r >= 0, params.rim_color.g >= 0, params.rim_color.b >= 0
 @require math::is_finite(params.rim_color.r), math::is_finite(params.rim_color.g), math::is_finite(params.rim_color.b)
 @require params.rim_strength >= 0, math::is_finite(params.rim_strength)
 @require params.rim_power > 0, math::is_finite(params.rim_power)
 @pure
*>
fn Material toon(ToonParams params = TOON_PARAMS_DEFAULT, MaterialCommon common = MATERIAL_COMMON_DEFAULT) {
    return { .kind = MaterialKind.TOON, .common = common, .toon = params };
}
