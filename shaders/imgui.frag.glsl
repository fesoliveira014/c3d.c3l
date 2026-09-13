#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 0) out vec4 out_color;

// ImGui authors vertex colors in sRGB; the swapchain encodes on write, so decode once here.
vec3 srgb_to_linear(vec3 encoded) {
    vec3 low = encoded / 12.92;
    vec3 high = pow((encoded + 0.055) / 1.055, vec3(2.4));
    return mix(low, high, step(0.04045, encoded));
}

void main() {
    GuiFragmentRoot root = GuiFragmentRoot(pc.fragment_root_gpu);
    vec4 color = vec4(srgb_to_linear(v_color.rgb), v_color.a);
    out_color = sample_texture_2d(root.source_texture, root.source_sampler, v_uv) * color;
}
