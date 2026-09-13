#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "vertex_pull.glsl"
#include "standard_surface.glsl"
#include "brdf.glsl"
#include "ibl.glsl"
#include "lights.glsl"
#include "material_alpha.glsl"
#include "shadows.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
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

    // Derivatives and implicit-LOD samples must retain helper lanes across cutouts.
    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u
        && material_sample.base_color.a < material.alpha_cutoff) discard;

    StandardSurface surface = prepare_standard_surface(
        material_sample.base_color.rgb,
        material_sample.metallic,
        material_sample.roughness,
        material_sample.normal,
        material_sample.view_direction
    );
    vec3 color = frame.ambient.rgb * material_sample.base_color.rgb
        * (1.0 - material_sample.metallic) * material_sample.occlusion
        + material_sample.emissive;
    if (frame.environment != 0ul) {
        EnvironmentGpu environment = EnvironmentGpu(frame.environment);
        color += evaluate_environment(
            environment,
            surface,
            material_sample.roughness,
            material_sample.occlusion
        );
    }
    float view_depth = -(frame.view * vec4(v_world_pos, 1.0)).z;
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        if ((draw.layers & light.layers) == 0u) continue;
        float visibility = 1.0;
        if ((draw.flags & DRAW_RECEIVE_SHADOW) != 0u && light.shadow_count != 0u) {
            visibility = shadow_visibility(
                frame,
                light,
                v_world_pos,
                material_sample.offset_normal,
                view_depth
            );
        }
        color += visibility * evaluate_standard_light(light, v_world_pos, surface);
    }
    out_color = material_output(color, material_sample.base_color.a, material.flags);
}
