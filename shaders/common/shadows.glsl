#ifndef C3D_SHADOWS_GLSL
#define C3D_SHADOWS_GLSL

#include "buffer_reference.glsl"
#include "descriptor_heap.glsl"
#include "lights.glsl"
#ifdef RT_SHADOWS
#if !defined(SCENE_TRACE_BVH) && !defined(SCENE_TRACE_RAY_QUERY)
#define SCENE_TRACE_RAY_QUERY
#endif
#include "scene_trace.glsl"
#endif

GPU_DECLARE_READONLY_ARRAY_REF(ShadowArray, ShadowGpu);

// Atlas UV and depth of the point; false where the layer's map or depth range does not hold it.
bool shadow_layer_coordinates(ShadowGpu shadow, vec3 sample_position, out vec3 coordinates) {
    vec4 projected = shadow.view_proj * vec4(sample_position, 1.0);
    if (projected.w <= 0.0) return false;

    vec3 ndc = projected.xyz / projected.w;
    // The atlas uses a negative-height viewport, so NDC +Y maps to texture V=0.
    vec2 uv = vec2(ndc.x + 1.0, 1.0 - ndc.y) * 0.5;
    coordinates = vec3(uv, ndc.z);
    return !(any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))
        || ndc.z < 0.0 || ndc.z > 1.0);
}

float filter_shadow_visibility(ShadowGpu shadow, vec3 coordinates) {
    float visibility = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            visibility += sample_shadow_2d(shadow.texture_index, shadow.sampler_index,
                vec3(coordinates.xy + vec2(x, y) * shadow.texel_size, coordinates.z));
        }
    }
    return visibility / 9.0;
}

float sample_shadow_visibility(ShadowGpu shadow, vec3 sample_position) {
    vec3 coordinates;
    if (!shadow_layer_coordinates(shadow, sample_position, coordinates)) return 1.0;
    return filter_shadow_visibility(shadow, coordinates);
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

#ifdef RT_SHADOWS
const float RT_SHADOW_FAR = 1.0e4; // world units; directional rays stop here

float ray_shadow_visibility(FrameRoot frame, LightGpu light, vec3 world_position, vec3 normal) {
    vec3 origin = world_position + normal * TRACE_SURFACE_OFFSET;
    vec3 direction = -light.direction_cos_outer.xyz;
    float t_max = RT_SHADOW_FAR;
    if (light.kind != LIGHT_DIRECTIONAL) {
        vec3 to_light = light.position_range.xyz - origin;
        t_max = length(to_light);
        if (t_max == 0.0) return 1.0;
        direction = to_light / t_max;
    }
    bool occluded = trace_scene_any(
        SceneTraceRoot(frame.trace),
        origin,
        direction,
        t_max,
        TRACE_MASK_SHADOW_CASTER
    );
    return occluded ? 0.0 : 1.0;
}
#endif

float shadow_visibility(FrameRoot frame, LightGpu light, vec3 world_position, vec3 normal, float view_depth) {
#ifdef RT_SHADOWS
    if ((light.flags & LIGHT_RT_SHADOW) != 0u && (frame.flags & FRAME_TRACE_PRESENT) != 0u) {
        return ray_shadow_visibility(frame, light, world_position, normal);
    }
#endif
    if (light.shadow_count == 0u) return 1.0;

    if (light.kind == LIGHT_DIRECTIONAL) {
        // A set fitted to another camera can miss a receiver in its selected cascade; coarser ones may hold it.
        bool fell_through = false;
        for (uint cascade = 0u; cascade < light.shadow_count; cascade++) {
            ShadowGpu shadow = ShadowArray(frame.shadows).values[light.shadow_first + cascade];
            if (view_depth > shadow.split_depth) continue;
            vec3 coordinates;
            if (!shadow_layer_coordinates(shadow, world_position + normal * shadow.normal_bias, coordinates)) {
                fell_through = true;
                continue;
            }
            float visibility = filter_shadow_visibility(shadow, coordinates);
            if (fell_through || view_depth <= shadow.blend_depth) return visibility;
            ShadowGpu next = ShadowArray(frame.shadows).values[light.shadow_first + cascade + 1u];
            vec3 next_coordinates;
            if (!shadow_layer_coordinates(next, world_position + normal * next.normal_bias, next_coordinates)) {
                return visibility;
            }
            float next_visibility = filter_shadow_visibility(next, next_coordinates);
            // Positive here: blend_depth < view_depth <= split_depth.
            float weight = (view_depth - shadow.blend_depth) / (shadow.split_depth - shadow.blend_depth);
            return mix(visibility, next_visibility, weight);
        }
        return 1.0;
    }

    ShadowGpu first = ShadowArray(frame.shadows).values[light.shadow_first];
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
