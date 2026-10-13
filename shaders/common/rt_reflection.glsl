#ifndef C3D_RT_REFLECTION_GLSL
#define C3D_RT_REFLECTION_GLSL

#include "gbuffer.glsl"

const float RT_REFLECTION_DEPTH_FRACTION = 0.05; // relative depth gap at which a tap's weight falls to e^-1
const float RT_REFLECTION_NORMAL_POWER = 16.0; // rejects taps across creases
const float RT_REFLECTION_ROUGHNESS_TOLERANCE = 0.1; // taps on a visibly different material are skipped
const float RT_REFLECTION_SPECULAR_TOLERANCE = 0.1; // taps across a specular-weight edge are skipped

// Pixel of each 2 x 2 block a half-resolution trace takes, by phase; the size is RT_REFLECTION_HALF_PHASES in C3.
const ivec2 RT_REFLECTION_HALF_OFFSETS[4] = ivec2[4](ivec2(0, 0), ivec2(1, 1), ivec2(1, 0), ivec2(0, 1));

// Weight of a tap from its depth gap to the centre pixel and the angle between their normals.
float rt_reflection_tap_weight(
    FrameRoot frame,
    float centre_distance,
    vec3 centre_normal,
    float tap_depth,
    vec2 tap_encoded_normal
) {
    float gap = abs(view_distance(frame, tap_depth) - centre_distance);
    float facing = max(dot(centre_normal, decode_octahedral(tap_encoded_normal)), 0.0);
    return exp(-gap / (RT_REFLECTION_DEPTH_FRACTION * centre_distance)) * pow(facing, RT_REFLECTION_NORMAL_POWER);
}

#endif
