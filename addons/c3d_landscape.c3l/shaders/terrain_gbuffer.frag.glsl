#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "gbuffer_output.glsl"
#include "landscape/terrain_surface.glsl"
#include "decals.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 5) in vec4 v_chunk; // x: the chunk's level, y: its morph toward the parent level

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
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    trace_proxy_skip_height = terrain_proxy_skip_height(TerrainParams(material.parameters), v_chunk.x, v_chunk.y);
    StandardMaterialSample surface_sample = terrain_surface(material, draw, frame, v_world_pos, v_uv0, v_uv1);
    apply_decals(
        frame,
        draw,
        material.flags,
        v_world_pos,
        view_depth,
        position_dx,
        position_dy,
        surface_sample);
    write_gbuffer(surface_sample, 1.0, draw);
}
