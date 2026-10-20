#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "multisample_heap.glsl"

layout(location = 0) out uint out_edge;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

bool channels_differ(vec4 sample_value, vec4 zero_value) {
    return any(greaterThan(abs(sample_value - zero_value), vec4(MSAA_EDGE_COLOR_TOLERANCE)));
}

// An edge is a pixel whose samples were not all written by one surface. The G-buffer is shaded once per pixel and
// primitive, so the samples of one primitive hold identical words and differ only in depth across its plane. Layers
// and flags compare exactly: a seam between a shadow receiver and a non-receiver is an edge.
void main() {
    LightingResolveRoot root = LightingResolveRoot(pc.fragment_root_gpu);
    ivec2 texel = ivec2(gl_FragCoord.xy);
    int samples = textureSamples(gpu_texture_ms_heap[nonuniformEXT(GPU_HEAP_SLOT(root.depth))]);
    float depth_zero = gpu_fetch_ms(root.depth, texel, 0).r;
    uint flags_zero = gpu_fetch_ms_uint(root.flags, texel, 0);
    uint layers_zero = gpu_fetch_ms_uint(root.layers, texel, 0);
    vec4 base_color_zero = gpu_fetch_ms(root.base_color_metallic, texel, 0);
    vec4 normal_zero = gpu_fetch_ms(root.normal_roughness, texel, 0);
    vec4 emissive_zero = gpu_fetch_ms(root.emissive_specular, texel, 0);

    bool edge = false;
    for (int sample_index = 1; sample_index < samples && !edge; sample_index++) {
        float depth = gpu_fetch_ms(root.depth, texel, sample_index).r;
        edge = abs(depth - depth_zero) > MSAA_EDGE_DEPTH_TOLERANCE * max(depth, depth_zero)
            || gpu_fetch_ms_uint(root.flags, texel, sample_index) != flags_zero
            || gpu_fetch_ms_uint(root.layers, texel, sample_index) != layers_zero
            || channels_differ(gpu_fetch_ms(root.base_color_metallic, texel, sample_index), base_color_zero)
            || channels_differ(gpu_fetch_ms(root.normal_roughness, texel, sample_index), normal_zero)
            || channels_differ(gpu_fetch_ms(root.emissive_specular, texel, sample_index), emissive_zero);
    }
    out_edge = edge ? 1u : 0u;
}
