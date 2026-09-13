#ifndef C3D_SHEEN_GLSL
#define C3D_SHEEN_GLSL

#include "descriptor_heap.glsl"
#include "brdf.glsl"

float sheen_distribution(float normal_half, float roughness) {
    float perceptual = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
    float alpha = perceptual * perceptual;
    float sine_squared = max(1.0 - normal_half * normal_half, 0.0);
    return (2.0 + 1.0 / alpha) * pow(sine_squared, 0.5 / alpha) / (2.0 * PI);
}

float sheen_lambda_log(float cosine, float alpha) {
    float q = (1.0 - alpha) * (1.0 - alpha);
    float coefficient_a = mix(21.5473, 25.3245, q);
    float coefficient_b = mix(3.82987, 3.32435, q);
    float coefficient_c = mix(0.19823, 0.16801, q);
    float coefficient_d = mix(-1.97760, -1.27393, q);
    float coefficient_e = mix(-4.32054, -4.85967, q);
    return coefficient_a / (1.0 + coefficient_b * pow(cosine, coefficient_c))
        + coefficient_d * cosine + coefficient_e;
}

float sheen_lambda(float cosine, float alpha) {
    float logarithm = cosine < 0.5
        ? sheen_lambda_log(cosine, alpha)
        : 2.0 * sheen_lambda_log(0.5, alpha) - sheen_lambda_log(1.0 - cosine, alpha);
    return exp(logarithm);
}

float sheen_visibility(float normal_view, float normal_light, float roughness) {
    float perceptual = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
    float alpha = perceptual * perceptual;
    float lambda_view = sheen_lambda(normal_view, alpha);
    float lambda_light = sheen_lambda(normal_light, alpha);
    return 1.0 / ((1.0 + lambda_view + lambda_light) * 4.0 * normal_view * normal_light);
}

float sheen_albedo(
    uint texture_index,
    uint sampler_index,
    float normal_view,
    float roughness
) {
    vec2 coordinates = vec2(
        clamp(normal_view, 0.0, 1.0),
        clamp(max(roughness, MIN_PERCEPTUAL_ROUGHNESS), 0.0, 1.0)
    );
    return clamp(sample_texture_2d(texture_index, sampler_index, coordinates).r, 0.0, 1.0);
}

#endif
