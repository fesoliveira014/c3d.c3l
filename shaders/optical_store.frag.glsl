#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"

layout(location = 0) out vec4 out_product;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    FrameRoot frame = FrameRoot(pc.fragment_root_gpu);
    OpticalShadowPassGpu pass = OpticalShadowPassGpu(OpticalShadowsGpu(frame.optical_shadows).pass);
    out_product = fetch_texture_2d(pass.source_product, ivec2(gl_FragCoord.xy));
}
