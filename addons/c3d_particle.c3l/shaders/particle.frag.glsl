#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
#include "scene_snapshot.glsl"
#include "ibl.glsl"
#include "fog.glsl"

const uint PARTICLE_UNLIT = 0u; // mirrored by ParticleLighting.UNLIT in material.c3
const uint PARTICLE_AMBIENT = 1u; // mirrored by ParticleLighting.AMBIENT in material.c3

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 5) in vec4 v_color;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ParticleParams {
    vec4 color;
    float soft_distance;
    uint lighting;
    uint _pad0;
    uint _pad1;
};

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    ParticleParams params = ParticleParams(material.parameters);
    material_mip_bias = frame.mip_bias;
    vec4 color = v_color * params.color;
    if (custom_slot_present(material, 0u)) color *= sample_custom_map(material, 0u, v_uv0, v_uv1);
    if (params.soft_distance > 0.0) {
        color.a *= clamp(scene_depth_gap(frame, gl_FragCoord) / params.soft_distance, 0.0, 1.0);
    }
    if (params.lighting == PARTICLE_AMBIENT) {
        vec3 view_direction = normalize(frame.camera_position.xyz - v_world_pos);
        color.rgb *= frame.ambient.rgb
            + indirect_diffuse_irradiance(frame, v_world_pos, normalize(v_normal), view_direction);
    }
    color.rgb = apply_material_fog(frame, v_world_pos, color.rgb, material.flags);
    out_color = material_output(color.rgb, color.a, material.flags);
}
