#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float EPSILON = 1e-4;

vec3 fetch(BloomRoot root, vec2 uv) {
    return sample_texture_2d(root.input_texture, root.sampler_index, uv).rgb;
}

// Soft threshold on the brightest channel; Unity's knee curve.
vec3 soft_threshold(BloomRoot root, vec3 color) {
    float brightness = max(color.r, max(color.g, color.b));
    float soft = clamp(brightness - root.threshold + root.knee, 0.0, 2.0 * root.knee);
    soft = soft * soft / (4.0 * root.knee + EPSILON);
    float contribution = max(soft, brightness - root.threshold) / max(brightness, EPSILON);
    return color * contribution;
}

float karis_weight(vec3 color) {
    return 1.0 / (1.0 + dot(color, vec3(0.2126, 0.7152, 0.0722)));
}

// Average of a 2x2 group; the prefilter weights each sample by inverse luma to suppress fireflies.
vec3 group_average(BloomRoot root, vec3 a, vec3 b, vec3 c, vec3 d) {
    if (root.prefilter == 0u) return (a + b + c + d) * 0.25;
    a = soft_threshold(root, a);
    b = soft_threshold(root, b);
    c = soft_threshold(root, c);
    d = soft_threshold(root, d);
    float wa = karis_weight(a);
    float wb = karis_weight(b);
    float wc = karis_weight(c);
    float wd = karis_weight(d);
    return (a * wa + b * wb + c * wc + d * wd) / (wa + wb + wc + wd);
}

void main() {
    BloomRoot root = BloomRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    vec2 uv = (vec2(texel) + 0.5) / vec2(root.width, root.height);
    vec2 step = root.input_texel;

    vec3 a = fetch(root, uv + step * vec2(-2.0, -2.0));
    vec3 b = fetch(root, uv + step * vec2(0.0, -2.0));
    vec3 c = fetch(root, uv + step * vec2(2.0, -2.0));
    vec3 d = fetch(root, uv + step * vec2(-1.0, -1.0));
    vec3 e = fetch(root, uv + step * vec2(1.0, -1.0));
    vec3 f = fetch(root, uv + step * vec2(-2.0, 0.0));
    vec3 g = fetch(root, uv);
    vec3 h = fetch(root, uv + step * vec2(2.0, 0.0));
    vec3 i = fetch(root, uv + step * vec2(-1.0, 1.0));
    vec3 j = fetch(root, uv + step * vec2(1.0, 1.0));
    vec3 k = fetch(root, uv + step * vec2(-2.0, 2.0));
    vec3 l = fetch(root, uv + step * vec2(0.0, 2.0));
    vec3 m = fetch(root, uv + step * vec2(2.0, 2.0));

    // Five 2x2 groups: the center one at half weight, the four corner ones at an eighth each.
    vec3 result = group_average(root, d, e, i, j) * 0.5;
    result += group_average(root, a, b, f, g) * 0.125;
    result += group_average(root, b, c, g, h) * 0.125;
    result += group_average(root, f, g, k, l) * 0.125;
    result += group_average(root, g, h, l, m) * 0.125;
    store_storage_texture(root.output_texture, ivec2(texel), vec4(result, 1.0));
}
