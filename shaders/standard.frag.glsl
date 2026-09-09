#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "brdf.glsl"
#include "lights.glsl"

const uint MATERIAL_ALPHA_MASK = 1u; // mirrored as MaterialFlags.alpha_mask
const uint MATERIAL_DOUBLE_SIDED = 2u; // mirrored as MaterialFlags.double_sided

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    StandardMaterialGpu material = StandardMaterialGpu(draw.material);
    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u && material.base_color.a < material.alpha_cutoff) discard;

    vec3 normal = normalize(v_normal);
    if ((material.flags & MATERIAL_DOUBLE_SIDED) != 0u && !gl_FrontFacing) normal = -normal;
    StandardSurface surface = prepare_standard_surface(
        material.base_color.rgb,
        material.metallic,
        material.roughness,
        normal,
        standard_view_direction(frame, v_world_pos)
    );
    vec3 color = frame.ambient.rgb * material.base_color.rgb * (1.0 - material.metallic);
    color += material.emissive_strength.rgb * material.emissive_strength.w;

    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        if ((draw.layers & light.layers) == 0u) continue;

        color += evaluate_standard_light(light, v_world_pos, surface);
    }
    out_color = vec4(color, material.base_color.a);
}
