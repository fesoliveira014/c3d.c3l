#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "material_maps.glsl"
#include "transmission.glsl"

layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
#ifdef VERTEX_COLOR
layout(location = 5) in vec4 v_color;
#endif

layout(location = 0) out vec4 out_transmittance;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

// Light share a caster passes per channel, multiplied into the layer's cleared-to-one image.
void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    TranslucentCasterGpu caster = TranslucentCasterGpu(draw.material);
    material_mip_bias = FrameRoot(draw.frame).mip_bias;
    vec4 base = caster.color;
    if ((caster.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
        base *= sample_map(caster.map, caster.map_flags, MATERIAL_MAP_BASE_COLOR, v_uv0, v_uv1);
    }
#ifdef VERTEX_COLOR
    base *= v_color;
#endif
    if ((caster.flags & MATERIAL_ALPHA_MASK) != 0u && base.a < caster.alpha_cutoff) discard;

    float coverage = (caster.flags & MATERIAL_ALPHA_BLEND) != 0u ? clamp(base.a, 0.0, 1.0) : 1.0;
    vec3 passed = vec3(0.0);
    if (caster.transmission > 0.0) {
        FrameRoot frame = FrameRoot(draw.frame);
        // The shadow camera looks along the light, so the volume is crossed along the view axis.
        vec3 light_axis = vec3(frame.view[0][2], frame.view[1][2], frame.view[2][2]);
        float crossing = length(transmission_ray(light_axis, caster.thickness, draw.model));
        passed = volume_attenuation(
            caster.transmission * base.rgb,
            crossing,
            caster.attenuation_color_distance.rgb,
            caster.attenuation_color_distance.w
        );
    }
    out_transmittance = vec4((1.0 - coverage) + coverage * passed, 1.0);
}
