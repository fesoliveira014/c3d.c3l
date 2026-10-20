#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
#include "proxy_skip_output.glsl"
#include "landscape/terrain_height.glsl"

layout(location = 5) in vec4 v_chunk; // x: the chunk's level, y: its morph toward the parent level

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    trace_proxy_skip_height = terrain_proxy_skip_height(TerrainParams(material.parameters), v_chunk.x, v_chunk.y);
    write_proxy_skip();
}
