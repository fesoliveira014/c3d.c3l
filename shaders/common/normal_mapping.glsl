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

bool surface_tangent_frame(
    vec3 normal,
    vec4 tangent,
    out vec3 tangent_direction,
    out vec3 bitangent
) {
    vec3 projected = tangent.xyz - normal * dot(normal, tangent.xyz);
    float length_squared = dot(projected, projected);
    if (length_squared == 0.0) return false;

    tangent_direction = projected * inversesqrt(length_squared);
    bitangent = cross(normal, tangent_direction) * tangent.w;
    return true;
}

vec3 tangent_normal(vec3 normal, vec4 tangent, vec3 mapped) {
    vec3 tangent_direction;
    vec3 bitangent;
    if (!surface_tangent_frame(normal, tangent, tangent_direction, bitangent)) return normal;

    vec3 result = tangent_direction * mapped.x + bitangent * mapped.y + normal * mapped.z;
    float result_length = dot(result, result);
    return result_length > 0.0 ? result * inversesqrt(result_length) : normal;
}

vec4 derivative_tangent(
    vec3 normal,
    vec3 position_dx,
    vec3 position_dy,
    vec2 uv_dx,
    vec2 uv_dy
) {
    float determinant_uv = uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x;
    if (determinant_uv == 0.0) return vec4(0.0);

    float orientation = determinant_uv < 0.0 ? -1.0 : 1.0;
    vec3 tangent = (position_dx * uv_dy.y - position_dy * uv_dx.y) * orientation;
    vec3 bitangent = (position_dy * uv_dx.x - position_dx * uv_dy.x) * orientation;
    float handedness = dot(cross(normal, tangent), bitangent);
    if (handedness == 0.0) return vec4(0.0);

    return vec4(tangent, handedness < 0.0 ? -1.0 : 1.0);
}

vec3 derivative_normal(
    vec3 normal,
    vec3 mapped,
    vec3 position_dx,
    vec3 position_dy,
    vec2 uv_dx,
    vec2 uv_dy
) {
    vec4 tangent = derivative_tangent(normal, position_dx, position_dy, uv_dx, uv_dy);
    if (tangent.w == 0.0) return normal;

    return tangent_normal(normal, tangent, mapped);
}

#endif
