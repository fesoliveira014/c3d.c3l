#ifndef C3D_SHADOWS_GLSL
#define C3D_SHADOWS_GLSL

#include "buffer_reference.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(ShadowArray, ShadowGpu);

float sample_shadow_visibility(ShadowGpu shadow, vec3 sample_position) {
    vec4 projected = shadow.view_proj * vec4(sample_position, 1.0);
    if (projected.w <= 0.0) return 1.0;

    vec3 ndc = projected.xyz / projected.w;
    // The atlas uses a negative-height viewport, so NDC +Y maps to texture V=0.
    vec2 uv = vec2(ndc.x + 1.0, 1.0 - ndc.y) * 0.5;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))
        || ndc.z < 0.0 || ndc.z > 1.0) return 1.0;

    float visibility = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            visibility += sample_shadow_2d(shadow.texture_index, shadow.sampler_index,
                vec3(uv + vec2(x, y) * shadow.texel_size, ndc.z));
        }
    }
    return visibility / 9.0;
}

uint point_shadow_face(vec3 direction) {
    vec3 magnitude = abs(direction);
    if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) {
        return direction.x >= 0.0 ? SHADOW_FACE_POSITIVE_X : SHADOW_FACE_NEGATIVE_X;
    }
    if (magnitude.y >= magnitude.z) {
        return direction.y >= 0.0 ? SHADOW_FACE_POSITIVE_Y : SHADOW_FACE_NEGATIVE_Y;
    }
    return direction.z >= 0.0 ? SHADOW_FACE_POSITIVE_Z : SHADOW_FACE_NEGATIVE_Z;
}

float shadow_visibility(FrameRoot frame, LightGpu light, vec3 world_position, vec3 normal, float view_depth) {
    if (light.shadow_count == 0u) return 1.0;

    ShadowGpu first = ShadowArray(frame.shadows).values[light.shadow_first];
    if (light.kind == LIGHT_DIRECTIONAL) {
        for (uint cascade = 0u; cascade < light.shadow_count; cascade++) {
            ShadowGpu shadow = ShadowArray(frame.shadows).values[light.shadow_first + cascade];
            if (view_depth > shadow.split_depth) continue;
            return sample_shadow_visibility(shadow, world_position + normal * shadow.normal_bias);
        }
        return 1.0;
    }

    vec3 receiver_direction = world_position - light.position_range.xyz;
    if (length(receiver_direction) > first.max_distance) return 1.0;

    vec3 sample_position = world_position + normal * first.normal_bias;
    if (light.kind == LIGHT_SPOT) return sample_shadow_visibility(first, sample_position);

    if (light.kind == LIGHT_POINT) {
        vec3 sample_direction = sample_position - light.position_range.xyz;
        if (dot(sample_direction, sample_direction) == 0.0) return 1.0;
        uint face = point_shadow_face(sample_direction);
        ShadowGpu shadow = ShadowArray(frame.shadows).values[light.shadow_first + face];
        return sample_shadow_visibility(shadow, sample_position);
    }
    return 1.0;
}

#endif
