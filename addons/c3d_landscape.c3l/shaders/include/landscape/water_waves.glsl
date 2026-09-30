#ifndef LANDSCAPE_WATER_WAVES_GLSL
#define LANDSCAPE_WATER_WAVES_GLSL

#include "constants.glsl"

const uint WATER_MAX_WAVES = 4u; // mirrored as MAX_WAVES in water/water.c3
const uint WATER_MARCH = 1u; // mirrored as MARCH_FLAG in water/waves.c3

// Mirrors WaveGpu in water/waves.c3.
struct WaterWave {
    vec2 direction;
    float amplitude;
    float cycles_per_metre;
    float cycles_per_second;
    float shift;
    float _pad0;
    float _pad1;
};

// Mirrors WaterParams in water/waves.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer WaterParams {
    WaterWave waves[WATER_MAX_WAVES];
    vec4 absorption;
    vec4 scatter;
    vec4 scroll_origin;
    vec4 scroll_velocity;
    uint wave_count;
    float scroll_time;
    float refraction_strength;
    float reflection_distortion;
    float foam_depth;
    float foam_crest;
    uint flags;
    float _pad0;
};

struct WaterSurfacePoint {
    vec3 position;
    vec3 normal;
    vec3 tangent;
    float crest;
};

// sin and cos are specified only near [-pi, pi]: the phase is reduced to one cycle first, as wave_angle in
// water/waves.c3 does.
float water_wave_angle(WaterWave wave, vec2 rest, float time) {
    float cycles = dot(wave.direction, rest) * wave.cycles_per_metre - time * wave.cycles_per_second;
    return 2.0 * PI * fract(cycles);
}

WaterSurfacePoint water_surface_point(WaterParams params, vec2 rest, float time) {
    vec3 offset = vec3(0.0);
    vec2 slope = vec2(0.0);
    mat2 jacobian = mat2(1.0);
    for (uint index = 0u; index < params.wave_count; index++) {
        WaterWave wave = params.waves[index];
        float angle = water_wave_angle(wave, rest, time);
        float sine = sin(angle);
        float cosine = cos(angle);
        vec2 gradient = (2.0 * PI * wave.cycles_per_metre) * wave.direction;
        vec2 shift = wave.direction * (wave.shift * cosine);
        offset += vec3(shift.x, wave.amplitude * sine, shift.y);
        slope += (wave.amplitude * cosine) * gradient;
        jacobian -= (wave.shift * sine) * outerProduct(wave.direction, gradient);
    }
    WaterSurfacePoint point;
    point.position = vec3(rest.x, 0.0, rest.y) + offset;
    point.tangent = normalize(vec3(jacobian[0].x, slope.x, jacobian[0].y));
    vec3 bitangent = vec3(jacobian[1].x, slope.y, jacobian[1].y);
    point.normal = normalize(cross(bitangent, point.tangent));
    // The horizontal map compresses toward a crest: a shrinking Jacobian is the crest factor.
    point.crest = clamp(1.0 - determinant(jacobian), 0.0, 1.0);
    return point;
}

#endif
