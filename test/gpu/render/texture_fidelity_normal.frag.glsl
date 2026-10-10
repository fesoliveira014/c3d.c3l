#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "vertex_pull.glsl"
#include "custom_material.glsl"
#include "standard_surface.glsl"

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
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    StandardMaterialSample sampled = sample_standard_material(
        custom_reference(material, 0u), GeometryRoot(draw.geometry),
        v_world_pos, v_normal, v_tangent, v_uv0, v_uv1,
        vec3(0.0, 0.0, 1.0), !gl_FrontFacing
    );
    out_color = vec4(sampled.normal, 1.0);
}
