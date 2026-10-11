#ifndef C3D_TRACE_MEDIUM_GLSL
#define C3D_TRACE_MEDIUM_GLSL

#include "fog.glsl"

const uint TRACE_MEDIUM_STEPS = 64u; // Midpoint integration costs 64 table samples per finite atmosphere connection.

FogTerms trace_atmosphere_segment(
    FrameRoot frame,
    SkyFogGpu sky,
    vec3 origin,
    vec3 direction,
    float distance
) {
    FogTerms terms = fog_none();
    if ((sky.flags & SKY_FOG_ATMOSPHERE) == 0u || distance == 0.0) return terms;

    SkyScattering scattering = integrate_sky_scattering(
        sky,
        max(origin.y + frame.origin.y, 0.0),
        direction,
        sky.sun_direction_cos_radius.xyz,
        distance,
        TRACE_MEDIUM_STEPS,
        false,
        false
    );
    terms.transmittance = scattering.transmittance;
    terms.inscatter = scattering.luminance * sky.sun_illuminance.rgb;
    return terms;
}

FogTerms trace_medium_segment(
    FrameRoot frame,
    vec3 origin,
    vec3 direction,
    float distance
) {
    if (frame.sky_fog == 0ul) return fog_none();

    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    FogTerms height = height_fog_segment(frame, sky, origin, direction, 0.0, distance);
    FogTerms atmosphere = trace_atmosphere_segment(frame, sky, origin, direction, distance);
    return fog_compose(height, atmosphere);
}

vec3 trace_segment_radiance(
    FrameRoot frame,
    vec3 origin,
    vec3 direction,
    float distance,
    vec3 radiance
) {
    if (frame.sky_fog == 0ul) return radiance;

    FogTerms terms = trace_medium_segment(frame, origin, direction, distance);
    return terms.transmittance * radiance + terms.inscatter;
}

vec3 trace_background_radiance(
    FrameRoot frame,
    vec3 origin,
    vec3 direction,
    vec3 radiance
) {
    if (frame.sky_fog == 0ul) return radiance;

    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    if ((sky.flags & SKY_FOG_HEIGHT_FOG) == 0u) return radiance;

    FogTerms terms = height_fog_to_infinity(frame, sky, origin, direction);
    return terms.transmittance * radiance + terms.inscatter;
}

#endif
