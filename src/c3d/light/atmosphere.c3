module c3d::light;

import std::math;

<*
 Earth's sea-level atmosphere in metres, seen from the surface.
*>
const Atmosphere ATMOSPHERE_EARTH = {
    .planet_radius         = 6_360_000,
    .atmosphere_height     = 100_000,
    .rayleigh_scattering   = { 5.802e-6f, 13.558e-6f, 33.1e-6f },
    .rayleigh_scale_height = 8_000,
    .mie_scattering        = 3.996e-6f,
    .mie_absorption        = 0.444e-6f,
    .mie_scale_height      = 1_200,
    .mie_anisotropy        = 0.8f,
    .ozone_absorption      = { 0.650e-6f, 1.881e-6f, 0.085e-6f },
    .ozone_center_altitude = 25_000,
    .ozone_half_width      = 15_000,
    .ground_albedo         = { 0.3f, 0.3f, 0.3f },
    .sun_angular_radius    = 0.004675f,
    .observer_altitude     = 0,
};

<*
 Steps of the CPU transmittance integral.
*>
const uint ATMOSPHERE_TRANSMITTANCE_STEPS = 64; // 0.35 % worst, 0.7 µs; mirrored as SKY_TRANSMITTANCE_STEPS in atmosphere.glsl

<*
 Planet, air and sun disc of a sky; its sun is the directional Light on the same node.
*>
struct Atmosphere {
    float planet_radius;         // metres; world y = 0 lies on the surface
    float atmosphere_height;     // metres above the surface
    Vec3  rayleigh_scattering;   // per metre at the surface
    float rayleigh_scale_height; // metres
    float mie_scattering;        // per metre at the surface
    float mie_absorption;        // per metre at the surface
    float mie_scale_height;      // metres
    float mie_anisotropy;        // Henyey-Greenstein g
    Vec3  ozone_absorption;      // per metre at the layer centre
    float ozone_center_altitude; // metres
    float ozone_half_width;      // metres; the layer thins to zero over it
    Vec3  ground_albedo;
    float sun_angular_radius;    // radians
    float observer_altitude;     // metres; the image-based lighting is seen from here
}

<*
 Whether the atmosphere can draw and light a sky.
 @param [&in] atmosphere : "Component to check."
 @pure
*>
fn bool atmosphere_valid(Atmosphere* atmosphere) {
    float[6] lengths = {
        atmosphere.planet_radius,
        atmosphere.atmosphere_height,
        atmosphere.rayleigh_scale_height,
        atmosphere.mie_scale_height,
        atmosphere.ozone_half_width,
        atmosphere.sun_angular_radius,
    };
    foreach (length : lengths) {
        if (!math::is_finite(length) || length <= 0) return false;
    }
    Vec3[3] spectra = { atmosphere.rayleigh_scattering, atmosphere.ozone_absorption, atmosphere.ground_albedo };
    foreach (spectrum : spectra) {
        foreach (channel : spectrum) {
            if (!math::is_finite(channel) || channel < 0) return false;
        }
    }
    foreach (albedo : atmosphere.ground_albedo) {
        if (albedo > 1) return false;
    }
    float[3] coefficients = { atmosphere.mie_scattering, atmosphere.mie_absorption, atmosphere.ozone_center_altitude };
    foreach (coefficient : coefficients) {
        if (!math::is_finite(coefficient) || coefficient < 0) return false;
    }
    if (!math::is_finite(atmosphere.mie_anisotropy) || math::abs(atmosphere.mie_anisotropy) >= 1) return false;
    if (atmosphere.sun_angular_radius >= (float)math::PI / 2) return false;
    float observer = atmosphere.observer_altitude;
    return math::is_finite(observer) && observer >= 0 && observer < atmosphere.atmosphere_height;
}

<*
 Transmittance from an altitude to the top of the atmosphere along a direction.
 @param [&in] atmosphere : "Valid."
 @param altitude : "Metres above the surface; clamped into the atmosphere."
 @param cos_zenith : "Cosine between the direction and the local up."
 @return "Zero where the direction meets the ground."
 @require cos_zenith >= -1 && cos_zenith <= 1
 @pure
*>
fn Vec3 atmosphere_transmittance(Atmosphere* atmosphere, float altitude, float cos_zenith) {
    float ground = atmosphere.planet_radius;
    float height = math::clamp(altitude, 0.0f, atmosphere.atmosphere_height);
    float radius = ground + height;
    // r² - R² and top² - r² in altitude form: squares of radii near 6.4e6 m lose metres in float.
    float lift = height * (2 * ground + height);
    float headroom = (atmosphere.atmosphere_height - height) * (2 * ground + atmosphere.atmosphere_height + height);
    float along_up = radius * cos_zenith;
    if (cos_zenith < 0 && along_up * along_up - lift >= 0) return {};

    float step = (math::sqrt(along_up * along_up + headroom) - along_up) / ATMOSPHERE_TRANSMITTANCE_STEPS;
    Vec3 optical_depth;
    for (uint index = 0; index < ATMOSPHERE_TRANSMITTANCE_STEPS; index++) {
        float along = ((float)index + 0.5f) * step;
        float climb = lift + along * along + 2 * along_up * along;
        float sample_altitude = climb / (math::sqrt(radius * radius + along * along + 2 * along_up * along) + ground);
        optical_depth += atmosphere_extinction(atmosphere, sample_altitude) * step;
    }
    return { math::exp(-optical_depth.x), math::exp(-optical_depth.y), math::exp(-optical_depth.z) };
}

<*
 Direct light a sun delivers through the atmosphere at an altitude.
 @param [&in] atmosphere : "Valid."
 @param [&in] sun : "Directional light on the atmosphere's node."
 @param to_sun : "Unit vector toward the sun."
 @param altitude : "Metres above the surface; clamped into the atmosphere."
 @return "Colour times intensity times transmittance; exactly zero below the horizon."
 @pure
*>
fn Vec3 sun_radiance(
    Atmosphere* atmosphere,
    Light* sun,
    Vec3 to_sun,
    float altitude,
) {
    Vec3 transmittance = atmosphere_transmittance(atmosphere, altitude, math::clamp(to_sun.y, -1.0f, 1.0f));
    return sun.color * sun.intensity * transmittance;
}

<*
 @pure
*>
fn Vec3 atmosphere_extinction(Atmosphere* atmosphere, float altitude) @local {
    float rayleigh = math::exp(-altitude / atmosphere.rayleigh_scale_height);
    float mie = math::exp(-altitude / atmosphere.mie_scale_height);
    float ozone_offset = math::abs(altitude - atmosphere.ozone_center_altitude);
    float ozone = math::max(0.0f, 1 - ozone_offset / atmosphere.ozone_half_width);
    return atmosphere.rayleigh_scattering * rayleigh
        + (atmosphere.mie_scattering + atmosphere.mie_absorption) * mie
        + atmosphere.ozone_absorption * ozone;
}
