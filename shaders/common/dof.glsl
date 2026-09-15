#ifndef C3D_DOF_GLSL
#define C3D_DOF_GLSL

const float DOF_BACKGROUND_DEPTH = 1e30;
const float DOF_COVERAGE_EPSILON = 1e-4;
const uint DOF_TAP_COUNT = 48u;

// Forward distance from reverse-Z depth; no geometry (depth 0) reads as infinitely far.
float dof_linear_depth(float depth, DofRoot root) {
    if (root.orthographic != 0u) return (root.proj_23 - depth) / root.proj_22;
    float denominator = depth + root.proj_22;
    return denominator > 0.0 ? root.proj_23 / denominator : DOF_BACKGROUND_DEPTH;
}

// Signed circle-of-confusion radius in half-resolution pixels: negative in front of focus.
float dof_signed_coc(float view_depth, DofRoot root) {
    float coc = root.aperture_scale * (view_depth - root.focus_distance) / view_depth;
    return clamp(coc, -root.max_coc, root.max_coc);
}

// Three rings of 8, 16 and 24 taps at radii 1/3, 2/3 and 1.
vec2 dof_disc_tap(uint index) {
    uint ring = index < 8u ? 0u : (index < 24u ? 1u : 2u);
    uint first = ring == 0u ? 0u : (ring == 1u ? 8u : 24u);
    uint count = ring == 0u ? 8u : (ring == 1u ? 16u : 24u);
    float radius = float(ring + 1u) / 3.0;
    float angle = 6.28318530718 * (float(index - first) + 0.5 * float(ring)) / float(count);
    return radius * vec2(cos(angle), sin(angle));
}

#endif
