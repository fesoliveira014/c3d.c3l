#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
#include "standard_shading.glsl"
#include "shader_package/surface.glsl"

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
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    StandardMaterialSample surface_sample = package_surface(
        SurfaceParams(material.parameters),
        normalize(v_normal),
        standard_view_direction(frame, v_world_pos)
    );
    vec3 color = shade_standard_surface(frame, draw, surface_sample, 1.0, v_world_pos, ivec2(gl_FragCoord.xy));
    out_color = material_output(color, surface_sample.base_color.a, material.flags);
}
