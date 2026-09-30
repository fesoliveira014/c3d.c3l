module c3d::light;

import std::math;

<*
 Light haze at its node's height, halving every 35 metres above it.
*>
const HeightFog HEIGHT_FOG_DEFAULT = {
    .density      = 0.002f,
    .falloff      = 0.02f,
    .albedo       = { 1, 1, 1 },
    .max_distance = 200,
    .anisotropy   = 0.3f,
};

<*
 Rise below which the fog integral takes its series.
*>
const float FOG_SERIES_THRESHOLD = 1e-2f; // float (1 - e^-x) / x loses 1.4e-3 at 1e-5, the series 7e-8; twin in fog.glsl

<*
 Exponential height fog; density is referenced to its node's world y, rotation and scale are ignored.
*>
struct HeightFog {
    float density;      // extinction per metre at the node's world y
    float falloff;      // per metre of height; zero is uniform fog
    Vec3  albedo;       // scattered share of the extinction
    float max_distance; // metres of view the volumetric fog covers
    float anisotropy;   // Henyey-Greenstein g of the volumetric fog's sun light, in (-1, 1)
}

<*
 Whether the fog can be drawn.
 @param [&in] fog : "Component to check."
 @pure
*>
fn bool height_fog_valid(HeightFog* fog) {
    float[2] rates = { fog.density, fog.falloff };
    foreach (rate : rates) {
        if (!math::is_finite(rate) || rate < 0) return false;
    }
    foreach (channel : fog.albedo) {
        if (!math::is_finite(channel) || channel < 0) return false;
    }
    if (!math::is_finite(fog.anisotropy) || math::abs(fog.anisotropy) >= 1) return false;
    return math::is_finite(fog.max_distance) && fog.max_distance > 0;
}

<*
 Share of the level integral a sloped ray keeps, (1 - e^-rise) / rise.
 @param rise : "Falloff times the height travelled, in e-folds; negative downward."
 @pure
*>
fn float fog_rise_factor(float rise) {
    if (math::abs(rise) < FOG_SERIES_THRESHOLD) return 1 - rise * 0.5f + rise * rise / 6;
    return (1 - math::exp(-rise)) / rise;
}

<*
 Optical depth of the fog along a segment.
 @param [&in] fog : "Valid."
 @param base_height : "World y of the fog's node."
 @param direction : "Unit vector."
 @param distance : "Metres along the direction."
 @pure
*>
fn float height_fog_optical_depth(
    HeightFog* fog,
    float base_height,
    Vec3 origin,
    Vec3 direction,
    float distance,
) {
    float density = fog.density * math::exp(-fog.falloff * (origin.y - base_height));
    return density * distance * fog_rise_factor(fog.falloff * direction.y * distance);
}

<*
 Transmittance of the fog along a segment.
 @param [&in] fog : "Valid."
 @param base_height : "World y of the fog's node."
 @param direction : "Unit vector."
 @param distance : "Metres along the direction."
 @pure
*>
fn float height_fog_transmittance(
    HeightFog* fog,
    float base_height,
    Vec3 origin,
    Vec3 direction,
    float distance,
) {
    float optical_depth = height_fog_optical_depth(
        fog:         fog,
        base_height: base_height,
        origin:      origin,
        direction:   direction,
        distance:    distance,
    );
    return math::exp(-optical_depth);
}

<*
 Transmittance of the fog from a point to infinity along a direction.
 @param [&in] fog : "Valid."
 @param base_height : "World y of the fog's node."
 @param direction : "Unit vector."
 @return "Zero at and below the horizon, unless the density is zero."
 @pure
*>
fn float height_fog_limit_transmittance(
    HeightFog* fog,
    float base_height,
    Vec3 origin,
    Vec3 direction,
) {
    float density = fog.density * math::exp(-fog.falloff * (origin.y - base_height));
    float rise = fog.falloff * direction.y;
    if (rise > 0) return math::exp(-density / rise);
    return density > 0 ? 0 : 1;
}
