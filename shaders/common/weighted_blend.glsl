#ifndef C3D_WEIGHTED_BLEND_GLSL
#define C3D_WEIGHTED_BLEND_GLSL

const float WEIGHTED_COLOR_MAX = 64.0; // straight HDR clamp; with WEIGHT_SCALE one fragment adds at most ~3000 of 65504
const float WEIGHT_SCALE = 1.0 / 64.0; // lower sinks faint far layers into subnormals; least weight stays above epsilon
const float WEIGHTED_EPSILON = 1e-8; // below the smallest RGBA16F value, so it only guards an empty sum
const float WEIGHTED_ACCUM_MAX = 65504.0; // the RGBA16F maximum; an overflowed sum returns to it before the division

// McGuire and Bavoil 2013, equation (7), on positive view-space depth.
float weighted_blend_weight(FrameRoot frame, vec3 world_position, float coverage) {
    float view_depth = -(frame.view * vec4(world_position, 1.0)).z;
    float near_term = view_depth / 5.0;
    float far_term = view_depth / 200.0;
    float far_square = far_term * far_term;
    float depth_weight = clamp(10.0 / (1e-5 + near_term * near_term + far_square * far_square * far_square), 1e-2, 3e3);
    return coverage * depth_weight * WEIGHT_SCALE;
}

vec4 weighted_blend_color(FrameRoot frame, vec4 premultiplied, vec3 world_position) {
    float coverage = premultiplied.a;
    vec3 straight = coverage > 0.0 ? min(premultiplied.rgb / coverage, vec3(WEIGHTED_COLOR_MAX)) : vec3(0.0);
    float weight = weighted_blend_weight(frame, world_position, coverage);
    return vec4(straight * coverage * weight, coverage * weight);
}

vec4 weighted_composite_color(vec4 accumulated, float revealage) {
    vec4 bounded = min(accumulated, vec4(WEIGHTED_ACCUM_MAX));
    vec3 average = min(bounded.rgb / max(bounded.a, WEIGHTED_EPSILON), vec3(WEIGHTED_COLOR_MAX));
    return vec4(average * (1.0 - revealage), 1.0 - revealage);
}

#endif
