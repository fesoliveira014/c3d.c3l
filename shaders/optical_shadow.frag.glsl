#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"
#include "standard_surface.glsl"
#include "optical_surface.glsl"
#include "lights.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 5) in vec4 v_color;
layout(location = 7) flat in vec3 v_optical_model_scale;
layout(location = 0) out vec4 out_product;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    OpticalShadowPassGpu pass = OpticalShadowPassGpu(OpticalShadowsGpu(frame.optical_shadows).pass);
    PhysicalMaterialGpu material = PhysicalMaterialGpu(draw.material);
    vec3 to_light = pass.light_position_kind.w == float(LIGHT_DIRECTIONAL)
        ? -pass.light_direction.xyz : normalize(pass.light_position_kind.xyz - v_world_pos);
    StandardMaterialSample sampled = sample_standard_material(
        material.standard,
        GeometryRoot(draw.geometry),
        v_world_pos,
        v_normal,
        v_tangent,
        v_uv0,
        v_uv1,
        to_light,
        !gl_FrontFacing
    );
    sampled.base_color *= v_color;
    OpticalSurface surface = optical_surface(
        material, sampled.base_color, sampled.metallic, sampled.normal, v_uv0, v_uv1
    );
    if ((surface.flags & MATERIAL_ALPHA_MASK) != 0u
        && surface.base_coverage.a < material.standard.alpha_cutoff) discard;

    if (pass.phase == OPTICAL_SHADOW_OPAQUE) {
        if ((surface.flags & MATERIAL_ALPHA_BLEND) != 0u || surface.transmission > 0.0) discard;

        out_product = vec4(gl_FragCoord.z);
        return;
    }
    if (surface.transmission == 0.0) discard;

    ivec2 pixel = ivec2(gl_FragCoord.xy);
    if (pass.phase == OPTICAL_SHADOW_CAPTURE) {
        if (pass.previous_depth != 0u
            && gl_FragCoord.z >= fetch_texture_2d(pass.previous_depth, pixel).r) discard;

        out_product = vec4(gl_FragCoord.z);
        return;
    }
    if (gl_FragCoord.z != fetch_texture_2d(pass.selected_depth, pixel).r) discard;

    out_product = vec4(optical_surface_throughput(surface, to_light, v_optical_model_scale), 1.0);
}
