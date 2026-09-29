#ifndef C3D_INSTANCE_EFFECTS_GLSL
#define C3D_INSTANCE_EFFECTS_GLSL

#include "constants.glsl"

// Any share in [0, 1] keeps |swing| <= 1, which the sway reach and the cull margin assume.
#define SWAY_HARMONIC_SHARE 0.3
#define SWAY_HARMONIC_PHASE 1.3

// Geometry base centre under the instance matrix: the collapse point and the gust sample point.
vec3 instance_anchor(InstanceEffectsGpu effects, mat4 model) {
    return (model * vec4(effects.anchor.xyz, 1.0)).xyz;
}

// mirrored as render::instance_fade_scale
float instance_fade_scale(InstanceEffectsGpu effects, vec3 anchor, float seed) {
    float band = effects.fade_end - effects.fade_start;
    float vanish = effects.fade_start + effects.fade_transition + seed * (band - effects.fade_transition);
    return clamp((vanish - distance(anchor, effects.fade_origin.xyz)) / effects.fade_transition, 0.0, 1.0);
}

vec3 sway_offset(SwayGpu sway, vec3 anchor, float seed, float bend_weight) {
    vec3 direction = sway.direction_amplitude.xyz;
    float cycles = sway.phase + seed * sway.variation - dot(anchor, direction) * sway.waves_per_unit;
    // Integer harmonics only: the phase the CPU wraps into [0, 1] leaves no seam.
    float angle = 2.0 * PI * fract(cycles);
    float swing = (1.0 - SWAY_HARMONIC_SHARE) * sin(angle) + SWAY_HARMONIC_SHARE * sin(3.0 * angle + SWAY_HARMONIC_PHASE);
    return direction * (sway.direction_amplitude.w * bend_weight * (sway.lean + (1.0 - sway.lean) * swing));
}

#endif
