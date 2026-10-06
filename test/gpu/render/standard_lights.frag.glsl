#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
#include "standard_shading.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

const vec3 RECEIVER_COLOR = vec3(0.8);

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    vec3 normal = normalize(v_normal);
    StandardSurface surface = prepare_surface(
        RECEIVER_COLOR,
        0.0,
        1.0,
        normal,
        standard_view_direction(frame, v_world_pos),
        STANDARD_DIELECTRIC_REFLECTANCE,
        vec3(1.0)
    );
    vec3 color = evaluate_standard_lights(
        frame,
        surface,
        v_world_pos,
        normal,
        draw.layers,
        (draw.flags & DRAW_RECEIVE_SHADOW) != 0u
    );
    out_color = material_output(color, 1.0, material.flags);
}
