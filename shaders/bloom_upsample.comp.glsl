#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

vec3 fetch(BloomRoot root, vec2 uv) {
    return sample_texture_2d(root.input_texture, root.sampler_index, uv).rgb;
}

void main() {
    BloomRoot root = BloomRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    vec2 uv = (vec2(texel) + 0.5) / vec2(root.width, root.height);
    vec2 step = root.input_texel;

    vec3 tent = fetch(root, uv + step * vec2(-1.0, -1.0));
    tent += fetch(root, uv + step * vec2(0.0, -1.0)) * 2.0;
    tent += fetch(root, uv + step * vec2(1.0, -1.0));
    tent += fetch(root, uv + step * vec2(-1.0, 0.0)) * 2.0;
    tent += fetch(root, uv) * 4.0;
    tent += fetch(root, uv + step * vec2(1.0, 0.0)) * 2.0;
    tent += fetch(root, uv + step * vec2(-1.0, 1.0));
    tent += fetch(root, uv + step * vec2(0.0, 1.0)) * 2.0;
    tent += fetch(root, uv + step * vec2(1.0, 1.0));
    tent /= 16.0;

    vec4 accumulated = load_storage_texture(root.output_texture, ivec2(texel));
    store_storage_texture(root.output_texture, ivec2(texel), vec4(accumulated.rgb + tent, 1.0));
}
