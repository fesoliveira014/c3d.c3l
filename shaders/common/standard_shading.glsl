#ifndef C3D_STANDARD_SHADING_GLSL
#define C3D_STANDARD_SHADING_GLSL

#include "brdf.glsl"
#include "lights.glsl"
#include "shadows.glsl"
#include "ibl.glsl"
#include "ambient_occlusion.glsl"
#include "screen_space_gi.glsl"
#include "standard_surface.glsl"

vec3 standard_ambient_fill(
    FrameRoot frame,
    vec3 base_color,
    float metallic,
    float occlusion,
    float ambient_occlusion,
    vec4 screen_indirect
) {
    return frame.ambient.rgb * base_color * (1.0 - metallic)
        * screen_space_base_share(occlusion, ambient_occlusion, screen_indirect);
}

// Expanded in place rather than called: on an RTX 4090 the software-traced loop costs twice as much when it
// runs two calls below main.
#define STANDARD_LIGHT_LOOP(RADIANCE, FRAME, SURFACE, POSITION, SHADOW_NORMAL, LAYERS, RECEIVE_SHADOW) \
    { \
        float standard_view_depth = -((FRAME).view * vec4(POSITION, 1.0)).z; \
        LightList standard_lights = select_lights(FRAME, POSITION, standard_view_depth); \
        for (uint standard_index = 0u; standard_index < standard_lights.count; standard_index++) { \
            LightGpu standard_light = LightArray((FRAME).lights).values[ \
                selected_light_index(FRAME, standard_lights, standard_index)]; \
            if (((LAYERS) & standard_light.layers) == 0u) continue; \
            float standard_visibility = 1.0; \
            if ((RECEIVE_SHADOW) && light_casts_shadow(standard_light)) { \
                standard_visibility = shadow_visibility( \
                    FRAME, \
                    standard_light, \
                    POSITION, \
                    SHADOW_NORMAL, \
                    standard_view_depth \
                ); \
            } \
            RADIANCE += standard_visibility * evaluate_standard_light(standard_light, POSITION, SURFACE); \
        } \
    }

vec3 evaluate_standard_lights(
    FrameRoot frame,
    StandardSurface surface,
    vec3 world_position,
    vec3 shadow_normal,
    uint layers,
    bool receive_shadow
) {
    vec3 radiance = vec3(0.0);
    STANDARD_LIGHT_LOOP(radiance, frame, surface, world_position, shadow_normal, layers, receive_shadow)
    return radiance;
}

// Linear radiance without alpha; the caller passes it to material_output.
vec3 shade_standard_surface(
    FrameRoot frame,
    DrawRoot draw,
    StandardMaterialSample surface_sample,
    float specular_weight,
    vec3 world_position,
    ivec2 pixel
) {
    StandardSurface surface = prepare_surface(
        surface_sample.base_color.rgb,
        surface_sample.metallic,
        surface_sample.roughness,
        surface_sample.normal,
        surface_sample.view_direction,
        STANDARD_DIELECTRIC_REFLECTANCE * specular_weight,
        vec3(specular_weight)
    );
    float ambient_occlusion = draw_ambient_occlusion(frame, draw.flags, pixel);
    vec4 screen_indirect = draw_screen_space_indirect(frame, draw.flags, pixel);
    vec3 color = standard_ambient_fill(
        frame,
        surface_sample.base_color.rgb,
        surface_sample.metallic,
        surface_sample.occlusion,
        ambient_occlusion,
        screen_indirect
    ) + surface_sample.emissive;
    if (frame_has_indirect(frame)) {
        color += evaluate_environment(
            frame,
            world_position,
            surface,
            surface_sample.roughness,
            surface_sample.occlusion,
            ambient_occlusion,
            screen_indirect
        );
    }
    STANDARD_LIGHT_LOOP(
        color,
        frame,
        surface,
        world_position,
        surface_sample.offset_normal,
        draw.layers,
        (draw.flags & DRAW_RECEIVE_SHADOW) != 0u
    )
    return color;
}

#endif
