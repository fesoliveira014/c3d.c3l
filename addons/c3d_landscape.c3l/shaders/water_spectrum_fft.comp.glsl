#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "texture_fetch.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Mirrors SpectrumFftRoot in water_gpu/spectral.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FftRoot {
    uint span;
    uint vertical;
    float sign;
    uint _pad0;
};

const uint HALF_SIZE = 128u; // half of SPECTRAL_SIZE in water/spectrum.c3
const float TWO_PI = 6.28318530718;

vec2 complex_multiply(vec2 first, vec2 second) {
    return vec2(first.x * second.x - first.y * second.y, first.x * second.y + first.y * second.x);
}

// The texel at a position along the line the pass transforms.
ivec2 along(uint position, uint line, uint vertical) {
    return vertical == 0u ? ivec2(int(position), int(line)) : ivec2(int(line), int(position));
}

// One radix-2 Stockham step of the inverse transform over three complex fields: the butterfly index runs over half the
// line and the span is the length of the sub-transforms already done. Reads the in images, writes the out images.
void main() {
    DispatchRoot root = DispatchRoot(pc.root_gpu);
    DispatchTexturesGpu textures = DispatchTexturesGpu(root.textures);
    FftRoot fft = FftRoot(root.parameters);

    uint butterfly = gl_GlobalInvocationID.x;
    uint line = gl_GlobalInvocationID.y;
    uint low = butterfly % fft.span;
    float angle = fft.sign * TWO_PI * float(low) / float(2u * fft.span);
    vec2 twiddle = vec2(cos(angle), sin(angle));
    uint destination = (butterfly / fft.span) * 2u * fft.span + low;

    ivec2 near = along(butterfly, line, fft.vertical);
    ivec2 far = along(butterfly + HALF_SIZE, line, fft.vertical);
    vec4 near_a = fetch_texture_2d(textures.slots[0].texture_index, near);
    vec4 far_a = fetch_texture_2d(textures.slots[0].texture_index, far);
    vec4 near_b = fetch_texture_2d(textures.slots[1].texture_index, near);
    vec4 far_b = fetch_texture_2d(textures.slots[1].texture_index, far);

    vec2 turned_first = complex_multiply(far_a.xy, twiddle);
    vec2 turned_second = complex_multiply(far_a.zw, twiddle);
    vec2 turned_third = complex_multiply(far_b.xy, twiddle);
    ivec2 sum_texel = along(destination, line, fft.vertical);
    ivec2 difference_texel = along(destination + fft.span, line, fft.vertical);
    store_storage_texture(
        textures.slots[2].texture_index,
        sum_texel,
        vec4(near_a.xy + turned_first, near_a.zw + turned_second)
    );
    store_storage_texture(
        textures.slots[2].texture_index,
        difference_texel,
        vec4(near_a.xy - turned_first, near_a.zw - turned_second)
    );
    store_storage_texture(textures.slots[3].texture_index, sum_texel, vec4(near_b.xy + turned_third, 0.0, 0.0));
    store_storage_texture(textures.slots[3].texture_index, difference_texel, vec4(near_b.xy - turned_third, 0.0, 0.0));
}
