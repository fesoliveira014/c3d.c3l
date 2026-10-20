#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "multisample_heap.glsl"

// PROXY_SKIP selects the unsigned-integer form, which copies a packed word.
#ifdef PROXY_SKIP
layout(location = 0) out uint out_word;
#else
layout(location = 0) out vec4 out_color;
#endif

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    CompositeRoot root = CompositeRoot(pc.fragment_root_gpu);
#ifdef PROXY_SKIP
    out_word = gpu_fetch_ms_uint(root.source_texture, ivec2(gl_FragCoord.xy), 0);
#else
    out_color = gpu_fetch_ms(root.source_texture, ivec2(gl_FragCoord.xy), 0);
#endif
}
