#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "lights.glsl"
#include "material_alpha.glsl"
#include "standard_shading.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer MirrorParams {
    vec4 base_color;
    float reflectance;
    float roughness;
};

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    MirrorParams params = MirrorParams(material.parameters);

    vec3 normal = normalize(v_normal);
    StandardMaterialSample surface_sample;
    surface_sample.base_color = params.base_color;
    surface_sample.metallic = 0.0;
    surface_sample.roughness = params.roughness;
    surface_sample.occlusion = 1.0;
    surface_sample.emissive = vec3(0.0);
    surface_sample.normal = normal;
    surface_sample.offset_normal = normal;
    surface_sample.view_direction = standard_view_direction(frame, v_world_pos);
    vec3 shaded = shade_standard_surface(frame, draw, surface_sample, 1.0, v_world_pos, ivec2(gl_FragCoord.xy));

    // The mirror view projects a point on the plane to the pixel this view draws it at.
    vec2 screen_uv = gl_FragCoord.xy / frame.camera_params.zw;
    TextureMapGpu mirror = material.slots[0];
    vec3 reflected = sample_texture_2d_implicit(mirror.texture_index, mirror.sampler_index, screen_uv).rgb;
    out_color = material_output(mix(shaded, reflected, params.reflectance), 1.0, material.flags);
}
