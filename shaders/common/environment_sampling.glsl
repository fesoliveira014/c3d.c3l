#ifndef C3D_ENVIRONMENT_SAMPLING_GLSL
#define C3D_ENVIRONMENT_SAMPLING_GLSL

float environment_radical_inverse(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

vec2 environment_hammersley(uint index, uint count) {
    return vec2(float(index) / float(count), environment_radical_inverse(index));
}

vec3 environment_sample_ggx(
    uint index,
    uint count,
    float roughness,
    vec3 normal
) {
    vec2 sample_point = environment_hammersley(index, count);
    float alpha = roughness * roughness;
    float alpha_squared = alpha * alpha;
    float phi = 2.0 * BRDF_PI * sample_point.x;
    float cosine = sqrt((1.0 - sample_point.y)
        / (1.0 + (alpha_squared - 1.0) * sample_point.y));
    float sine = sqrt(max(1.0 - cosine * cosine, 0.0));
    vec3 tangent_sample = vec3(cos(phi) * sine, sin(phi) * sine, cosine);

    vec3 reference = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(reference, normal));
    vec3 bitangent = cross(normal, tangent);
    return normalize(tangent * tangent_sample.x + bitangent * tangent_sample.y
        + normal * tangent_sample.z);
}

#endif
