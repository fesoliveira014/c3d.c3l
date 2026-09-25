#ifndef C3D_SAMPLING_GLSL
#define C3D_SAMPLING_GLSL

#include "constants.glsl"
#include "brdf.glsl"

const float GOLDEN_RATIO_CONJUGATE = 0.618034;
const float VNDF_MIN_VIEW_Z = 1e-4; // grazing G-buffer normals can face away from the eye

// z up; density cos(theta) / PI.
vec3 cosine_sample_hemisphere(vec2 u) {
    float radius = sqrt(u.x);
    float phi = 2.0 * PI * u.y;
    return vec3(radius * cos(phi), radius * sin(phi), sqrt(max(1.0 - u.x, 0.0)));
}

// Duff et al. 2017; columns tangent, bitangent, normal. GLSL sign(0.0) is 0, so the sign is explicit.
mat3 tangent_frame(vec3 normal) {
    float sign_z = normal.z >= 0.0 ? 1.0 : -1.0;
    float a = -1.0 / (sign_z + normal.z);
    float b = normal.x * normal.y * a;
    vec3 tangent = vec3(1.0 + sign_z * normal.x * normal.x * a, sign_z * b, -sign_z * normal.x);
    vec3 bitangent = vec3(b, sign_z + normal.y * normal.y * a, -normal.y);
    return mat3(tangent, bitangent, normal);
}

// Dupuy and Benyoub 2023, visible GGX normals by spherical caps; a unit half vector in tangent space.
vec3 sample_ggx_vndf(vec2 u, vec3 view_tangent, float alpha) {
    vec3 view = vec3(view_tangent.xy, max(view_tangent.z, VNDF_MIN_VIEW_Z));
    vec3 stretched = normalize(vec3(view.xy * alpha, view.z));
    float phi = 2.0 * PI * u.x;
    float z = (1.0 - u.y) * (1.0 + stretched.z) - stretched.z;
    float sin_theta = sqrt(max(1.0 - z * z, 0.0));
    vec3 half_stretched = vec3(sin_theta * cos(phi), sin_theta * sin(phi), z) + stretched;
    return normalize(vec3(half_stretched.xy * alpha, max(half_stretched.z, 0.0)));
}

float cosine_hemisphere_pdf(float cosine) {
    return max(cosine, 0.0) / PI;
}

float smith_g1(float normal_view, float alpha_squared) {
    return 2.0 * normal_view
        / (normal_view + sqrt(alpha_squared + (1.0 - alpha_squared) * normal_view * normal_view));
}

// Density of the direction sample_ggx_vndf reflects, under the same view clamp.
float ggx_vndf_pdf(float normal_view, float normal_half, float alpha_squared) {
    float view = max(normal_view, VNDF_MIN_VIEW_Z);
    return distribution_ggx(normal_half, alpha_squared) * smith_g1(view, alpha_squared) / (4.0 * view);
}

#endif
