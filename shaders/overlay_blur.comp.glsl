#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// The Gaussian ends about three deviations out, so its weight at the last tap is near one percent.
const float BLUR_SIGMA_PER_RADIUS = 1.0 / 3.0;
const float BLUR_MIN_SIGMA = 0.5; // a radius of one would otherwise weight its side taps near zero

void main() {
    OverlayBlurRoot root = OverlayBlurRoot(pc.root_gpu);
    uvec2 local = gl_GlobalInvocationID.xy;
    if (local.x >= root.region_width || local.y >= root.region_height) return;

    ivec2 texel = ivec2(root.region_x, root.region_y) + ivec2(local);
    ivec2 last = ivec2(root.box_width, root.box_height) - 1;
    ivec2 source = ivec2(root.source_x, root.source_y);
    ivec2 axis = root.vertical != 0u ? ivec2(0, 1) : ivec2(1, 0);

    float sigma = max(float(root.radius) * BLUR_SIGMA_PER_RADIUS, BLUR_MIN_SIGMA);
    float exponent_scale = -0.5 / (sigma * sigma);
    vec4 sum = vec4(0.0);
    float weight_sum = 0.0;
    for (int offset = -int(root.radius); offset <= int(root.radius); offset++) {
        float weight = exp(exponent_scale * float(offset * offset));
        ivec2 tap = clamp(texel + axis * offset, ivec2(0), last);
        sum += weight * fetch_texture_2d(root.input_texture, source + tap);
        weight_sum += weight;
    }

    store_storage_texture(root.output_texture, texel, sum / weight_sum);
}
