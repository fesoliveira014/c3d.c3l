#ifndef C3D_NORMAL_MAPPING_GLSL
#define C3D_NORMAL_MAPPING_GLSL

vec4 world_tangent(mat4 model, vec4 tangent) {
    float orientation = determinant(mat3(model)) < 0.0 ? -1.0 : 1.0;
    return vec4(mat3(model) * tangent.xyz, tangent.w * orientation);
}

vec3 decode_normal(vec3 encoded, float scale) {
    vec3 mapped = encoded * 2.0 - 1.0;
    mapped.xy *= scale;
    float largest = max(max(abs(mapped.x), abs(mapped.y)), abs(mapped.z));
    if (largest == 0.0) return vec3(0.0, 0.0, 1.0);
    return normalize(mapped / largest);
}

vec3 tangent_normal(vec3 normal, vec4 tangent, vec3 mapped) {
    vec3 projected = tangent.xyz - normal * dot(normal, tangent.xyz);
    float length_squared = dot(projected, projected);
    if (length_squared == 0.0) return normal;

    vec3 tangent_direction = projected * inversesqrt(length_squared);
    vec3 bitangent = cross(normal, tangent_direction) * tangent.w;
    vec3 result = tangent_direction * mapped.x + bitangent * mapped.y + normal * mapped.z;
    float result_length = dot(result, result);
    return result_length > 0.0 ? result * inversesqrt(result_length) : normal;
}

vec3 derivative_normal(
    vec3 normal,
    vec3 mapped,
    vec3 position_dx,
    vec3 position_dy,
    vec2 uv_dx,
    vec2 uv_dy
) {
    float determinant_uv = uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x;
    if (determinant_uv == 0.0) return normal;

    float orientation = determinant_uv < 0.0 ? -1.0 : 1.0;
    vec3 tangent = (position_dx * uv_dy.y - position_dy * uv_dx.y) * orientation;
    vec3 bitangent = (position_dy * uv_dx.x - position_dx * uv_dy.x) * orientation;
    float handedness = dot(cross(normal, tangent), bitangent);
    if (handedness == 0.0) return normal;

    return tangent_normal(normal, vec4(tangent, handedness < 0.0 ? -1.0 : 1.0), mapped);
}

#endif
