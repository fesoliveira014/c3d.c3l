#ifndef C3D_LIGHTS_GLSL
#define C3D_LIGHTS_GLSL

#include "buffer_reference.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(LightArray, LightGpu);

const uint LIGHT_DIRECTIONAL = 0u; // mirrored as LightKind.DIRECTIONAL
const uint LIGHT_POINT = 1u; // mirrored as LightKind.POINT
const uint LIGHT_SPOT = 2u; // mirrored as LightKind.SPOT
const float MIN_LIGHT_DISTANCE_SQUARED = 0.0001; // bounds the point-source singularity within 0.01 world units
const float MIN_CONE_COSINE_DELTA = 0.001; // keeps subpixel narrow cones numerically bounded

struct LightSample {
    vec3 direction;
    vec3 radiance;
};

vec3 standard_view_direction(FrameRoot frame, vec3 position) {
    if (frame.proj[3][3] != 0.0) return normalize(frame.inv_view_proj[2].xyz);
    return normalize(frame.camera_position.xyz - position);
}

float range_attenuation(float distance_squared, float range) {
    float window = 1.0;
    if (range > 0.0) {
        float ratio_squared = distance_squared / (range * range);
        window = max(1.0 - ratio_squared * ratio_squared, 0.0);
    }
    return window / max(distance_squared, MIN_LIGHT_DISTANCE_SQUARED);
}

float spot_attenuation(float cosine, float cos_inner, float cos_outer) {
    float angular = clamp((cosine - cos_outer) / max(cos_inner - cos_outer, MIN_CONE_COSINE_DELTA), 0.0, 1.0);
    return angular * angular;
}

LightSample sample_light(LightGpu light, vec3 position) {
    LightSample light_sample = LightSample(vec3(0.0), vec3(0.0));
    float attenuation = 1.0;
    if (light.kind == LIGHT_DIRECTIONAL) {
        light_sample.direction = -light.direction_cos_outer.xyz;
    } else {
        vec3 offset = light.position_range.xyz - position;
        float distance_squared = dot(offset, offset);
        if (distance_squared == 0.0) return light_sample;

        light_sample.direction = offset * inversesqrt(distance_squared);
        attenuation = range_attenuation(distance_squared, light.position_range.w);
        if (light.kind == LIGHT_SPOT) {
            attenuation *= spot_attenuation(
                dot(light.direction_cos_outer.xyz, -light_sample.direction),
                light.cos_inner,
                light.direction_cos_outer.w
            );
        }
    }

    light_sample.radiance = light.color_intensity.rgb * light.color_intensity.w * attenuation;
    return light_sample;
}

vec3 evaluate_standard_light(
    LightGpu light,
    vec3 position,
    StandardSurface surface
) {
    LightSample light_sample = sample_light(light, position);
    return evaluate_standard_brdf(surface, light_sample.direction) * light_sample.radiance;
}

#endif
