#ifndef C3D_SHADOWS_GLSL
#define C3D_SHADOWS_GLSL

#include "buffer_reference.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(ShadowArray, ShadowGpu);

float shadow_visibility(FrameRoot frame, LightGpu light, vec3 world_position, vec3 normal, float view_depth) {
    for (uint cascade = 0u; cascade < light.shadow_count; cascade++) {
        ShadowGpu shadow = ShadowArray(frame.shadows).values[light.shadow_first + cascade];
        if (view_depth > shadow.split_depth) continue;
        vec4 projected = shadow.view_proj * vec4(world_position + normal * shadow.normal_bias, 1.0);
        vec3 ndc = projected.xyz / projected.w;
        // The atlas uses a negative-height viewport, so NDC +Y maps to texture V=0.
        vec2 uv = vec2(ndc.x + 1.0, 1.0 - ndc.y) * 0.5;
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))) || ndc.z < 0.0 || ndc.z > 1.0) return 1.0;
        float visibility = 0.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                visibility += sample_shadow_2d(shadow.texture_index, shadow.sampler_index,
                    vec3(uv + vec2(x, y) * shadow.texel_size, ndc.z));
            }
        }
        return visibility / 9.0;
    }
    return 1.0;
}

#endif
