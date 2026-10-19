#ifndef LANDSCAPE_WATER_WAVES_GLSL
#define LANDSCAPE_WATER_WAVES_GLSL

#include "constants.glsl"

const uint WATER_MAX_WAVES = 4u; // mirrored as MAX_WAVES in water/water.c3
const uint WATER_MARCH = 1u; // mirrored as MARCH_FLAG in water/waves.c3
const float WATER_FADE_FULL_CELLS = 4.0; // mirrored as FADE_FULL_CELLS in water/material.c3; drawn whole
const float WATER_FADE_NONE_CELLS = 2.0; // mirrored as NYQUIST_CELLS in water/material.c3; a wave this short is gone

// Mirrors WaveGpu in water/waves.c3.
struct WaterWave {
    vec2 direction;
    float amplitude;
    float cycles_per_metre;
    float cycles_per_second;
    float shift;
    float phase_offset;
    float _pad0;
};

// Mirrors WaterParams in water/waves.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer WaterParams {
    WaterWave waves[WATER_MAX_WAVES];
    WaterWave previous[WATER_MAX_WAVES];
    vec4 scroll_origin;
    vec4 scroll_velocity;
    uint wave_count;
    float scroll_time;
    float refraction_strength;
    float reflection_distortion;
    float foam_depth;
    float foam_crest;
    uint flags;
    float cell_size;
    float roughness;
    float _pad0;
    float _pad1;
    float _pad2;
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
    float cycles = dot(wave.direction, rest) * wave.cycles_per_metre - time * wave.cycles_per_second
        + wave.phase_offset;
    return 2.0 * PI * fract(cycles);
}

vec3 water_displacement(WaterWave wave, float angle) {
    vec2 shift = wave.direction * (wave.shift * cos(angle));
    return vec3(shift.x, wave.amplitude * sin(angle), shift.y);
}

// The wave as a vertex spacing of cell metres resolves it: amplitude and crest shift fade out as the wavelength falls
// from FULL to NONE spacings. A zero spacing keeps every wave whole.
WaterWave water_faded(WaterWave wave, float cell) {
    if (cell > 0.0) {
        float spacings = 1.0 / (wave.cycles_per_metre * cell);
        float share = clamp(
            (spacings - WATER_FADE_NONE_CELLS) / (WATER_FADE_FULL_CELLS - WATER_FADE_NONE_CELLS),
            0.0,
            1.0
        );
        wave.amplitude *= share;
        wave.shift *= share;
    }
    return wave;
}

WaterSurfacePoint water_surface_point(WaterParams params, vec2 rest, float time, float cell) {
    vec3 offset = vec3(0.0);
    vec2 slope = vec2(0.0);
    mat2 jacobian = mat2(1.0);
    for (uint index = 0u; index < params.wave_count; index++) {
        WaterWave wave = water_faded(params.waves[index], cell);
        float angle = water_wave_angle(wave, rest, time);
        float sine = sin(angle);
        float cosine = cos(angle);
        vec2 gradient = (2.0 * PI * wave.cycles_per_metre) * wave.direction;
        offset += water_displacement(wave, angle);
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

WaterSurfacePoint water_surface_point(WaterParams params, vec2 rest, float time) {
    return water_surface_point(params, rest, time, 0.0);
}

// Where the waves of the current or the previous update draw a rest point at a time, position only.
vec3 water_displaced_position(WaterParams params, bool previous, vec2 rest, float time, float cell) {
    vec3 offset = vec3(0.0);
    for (uint index = 0u; index < params.wave_count; index++) {
        WaterWave wave = params.waves[index];
        if (previous) wave = params.previous[index];
        wave = water_faded(wave, cell);
        offset += water_displacement(wave, water_wave_angle(wave, rest, time));
    }
    return vec3(rest.x, 0.0, rest.y) + offset;
}

// Where the previous update's waves drew a rest point at the previous frame's time.
vec3 water_previous_position(WaterParams params, vec2 rest, float time) {
    return water_displaced_position(params, true, rest, time, 0.0);
}

#endif
