#ifndef C3D_NORMAL_MAPPING_GLSL
#define C3D_NORMAL_MAPPING_GLSL

const float NORMAL_RECIPROCAL_RANGE = 18446744073709551616.0; // power-of-two conditioning avoids flushed reciprocal subnormals

vec4 world_tangent(mat4 model, vec4 tangent) {
    float orientation = determinant(mat3(model)) < 0.0 ? -1.0 : 1.0;
    vec3 direction = mat3(model) * tangent.xyz;
    float length_squared = dot(direction, direction);

    return vec4(length_squared > 0.0 ? direction * inversesqrt(length_squared) : direction, tangent.w * orientation);
}

vec3 decode_normal(vec3 encoded, float scale, bool rg) {
    vec3 mapped = encoded - 0.5;
    if (rg) {
        mapped.z = sqrt(max(0.0, 0.25 - dot(mapped.xy, mapped.xy)));
        if (scale == 0.0) return vec3(0.0, 0.0, 1.0);
    }

    if (mapped.x == 0.0 && mapped.y == 0.0) {
        return vec3(0.0, 0.0, mapped.z < 0.0 ? -1.0 : 1.0);
    }

    if (mapped.z == 0.0 && scale != 0.0) {
        mapped.xy *= sign(scale);
    } else if (abs(scale) > 1.0) {
        mapped.xy *= sign(scale);
        mapped.z /= abs(scale);
    } else {
        mapped.xy *= scale;
    }

    float largest = max(max(abs(mapped.x), abs(mapped.y)), abs(mapped.z));
    if (largest == 0.0) return vec3(0.0, 0.0, 1.0);

    if (largest > NORMAL_RECIPROCAL_RANGE) {
        mapped *= 1.0 / NORMAL_RECIPROCAL_RANGE;
        largest *= 1.0 / NORMAL_RECIPROCAL_RANGE;
    }

    return normalize(mapped / largest);
}

vec3 decode_normal(vec3 encoded, float scale) {
    return decode_normal(encoded, scale, false);
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
    if (dot(tangent.xyz, tangent.xyz) == 0.0) return normalize(normal);

    vec3 bitangent = cross(normal, tangent.xyz) * tangent.w;
    vec3 result = tangent.xyz * mapped.x + bitangent * mapped.y + normal * mapped.z;
    float result_length = dot(result, result);
    return result_length > 0.0 ? result * inversesqrt(result_length) : normalize(normal);
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

    vec3 direction;
    vec3 bitangent;
    if (!surface_tangent_frame(normal, tangent, direction, bitangent)) return normal;

    return tangent_normal(normal, vec4(direction, tangent.w), mapped);
}

#endif
