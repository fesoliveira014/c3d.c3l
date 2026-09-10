module c3d::light;

import std::math;

<* Emission geometry of a punctual light. *>
enum LightKind {
    DIRECTIONAL, // mirrored as LIGHT_DIRECTIONAL in shaders/common/lights.glsl
    POINT, // mirrored as LIGHT_POINT in shaders/common/lights.glsl
    SPOT, // mirrored as LIGHT_SPOT in shaders/common/lights.glsl
}

<* Punctual emission attached to a scene node. *>
struct Light {
    LightKind kind;
    Vec3 color;
    float intensity;
    float range;
    float inner_cone;
    float outer_cone;
    uint layers;
    ShadowSettings shadow;
}

<*
 Parallel illumination along the node's negative Z axis.
 @param intensity : "Nonnegative irradiance scale."
 @param shadow : "Enables the default directional shadow settings."
 @require color.r >= 0, color.g >= 0, color.b >= 0
 @require math::is_finite(color.r), math::is_finite(color.g), math::is_finite(color.b)
 @require math::is_finite(intensity)
 @require intensity >= 0
 @pure
*>
fn Light directional(Vec3 color, float intensity, bool shadow = true) {
    ShadowSettings settings = SHADOW_SETTINGS_DEFAULT;
    settings.enabled = shadow;
    return { .kind = DIRECTIONAL, .color = color, .intensity = intensity, .layers = uint::max, .shadow = settings };
}

<*
 Omnidirectional illumination at the node's world position.
 @param intensity : "Nonnegative radiant intensity scale."
 @param range : "World units; zero means unbounded."
 @require color.r >= 0, color.g >= 0, color.b >= 0
 @require math::is_finite(color.r), math::is_finite(color.g), math::is_finite(color.b)
 @require math::is_finite(intensity)
 @require intensity >= 0, range >= 0, math::is_finite(range)
 @pure
*>
fn Light point(Vec3 color, float intensity, float range = 0) {
    ShadowSettings settings = SHADOW_SETTINGS_DEFAULT;
    settings.enabled = false;
    return { .kind = POINT, .color = color, .intensity = intensity, .range = range, .layers = uint::max, .shadow = settings };
}

<*
 Conical illumination along the node's negative Z axis.
 @param intensity : "Nonnegative radiant intensity scale."
 @param inner : "Cone half-angle in radians."
 @param outer : "Cone half-angle in radians."
 @param range : "World units; zero means unbounded."
 @require color.r >= 0, color.g >= 0, color.b >= 0
 @require math::is_finite(color.r), math::is_finite(color.g), math::is_finite(color.b)
 @require math::is_finite(intensity)
 @require intensity >= 0, range >= 0, math::is_finite(range)
 @require inner >= 0, inner < outer, outer <= (float)math::PI / 2
 @pure
*>
fn Light spot(
    Vec3 color,
    float intensity,
    float inner,
    float outer,
    float range = 0,
) {
    ShadowSettings settings = SHADOW_SETTINGS_DEFAULT;
    settings.enabled = false;
    return {
        .kind = SPOT,
        .color = color,
        .intensity = intensity,
        .range = range,
        .inner_cone = inner,
        .outer_cone = outer,
        .layers = uint::max,
        .shadow = settings,
    };
}
