#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "vertex_pull.glsl"
#include "material_alpha.glsl"
#include "fog.glsl"
#include "standard_shading.glsl"
#include "decals.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 5) in vec4 v_color;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    vec3 position_dx = dFdx(v_world_pos);
    vec3 position_dy = dFdy(v_world_pos);
    float view_depth = -(frame.view * vec4(v_world_pos, 1.0)).z;
    material_mip_bias = frame.mip_bias;
    StandardMaterialRoot material_root = StandardMaterialRoot(draw.material);
    StandardMaterialGpu material = material_root.material;
    StandardMaterialSample material_sample = sample_standard_material(
        material,
        GeometryRoot(draw.geometry),
        v_world_pos,
        v_normal,
        v_tangent,
        v_uv0,
        v_uv1,
        standard_view_direction(frame, v_world_pos),
        !gl_FrontFacing
    );

    material_sample.base_color *= v_color;
    apply_decals(
        frame,
        draw,
        material.flags,
        v_world_pos,
        view_depth,
        position_dx,
        position_dy,
        material_sample);
    // Derivatives and implicit-LOD samples must retain helper lanes across cutouts.
    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u
        && material_sample.base_color.a < material.alpha_cutoff) discard;

    vec3 color = shade_standard_surface(frame, draw, material_sample, 1.0, v_world_pos, ivec2(gl_FragCoord.xy));
    if ((material.flags & MATERIAL_ALPHA_BLEND) != 0u) {
        color = apply_material_fog(frame, v_world_pos, color, material.flags);
    }
    out_color = material_output(color, material_sample.base_color.a, material.flags);
}
