#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "texture_fetch.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Mirrors SpectrumEvolveRoot in water_gpu/spectral.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer EvolveRoot {
    float share_of_period;
    float blend;
    float patch_size;
    float choppiness;
    float omega_step;
    float _pad0;
    float _pad1;
    float _pad2;
};

const int SIZE = 256; // mirrored as SPECTRAL_SIZE in water/spectrum.c3
const float GRAVITY = 9.81; // mirrored as SEA_GRAVITY in water/sea.c3
const float TWO_PI = 6.28318530718;

vec2 complex_multiply(vec2 first, vec2 second) {
    return vec2(first.x * second.x - first.y * second.y, first.x * second.y + first.y * second.x);
}

vec2 complex_times_i(vec2 value) {
    return vec2(-value.y, value.x);
}

// The field of the spectrum at the time, one texel per lattice vector: h(k) = h0(k) e^{-i w t} + conj(h0(-k)) e^{i w t}
// and, as complex pairs the inverse transform splits into real fields,
//   first.xy  = height + i x displacement, first.zw = z displacement + i slope along x, second.xy = slope along z.
// Twin of the components SpectralWave keeps in water/spectrum.c3.
void main() {
    DispatchRoot root = DispatchRoot(pc.root_gpu);
    DispatchTexturesGpu textures = DispatchTexturesGpu(root.textures);
    EvolveRoot evolve = EvolveRoot(root.parameters);

    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 partner = (SIZE - texel) & (SIZE - 1);
    vec4 own = fetch_texture_2d(textures.slots[0].texture_index, texel);
    vec4 opposite = fetch_texture_2d(textures.slots[0].texture_index, partner);
    vec2 amplitude = own.xy * mix(own.z, own.w, evolve.blend);
    vec2 opposite_amplitude = opposite.xy * mix(opposite.z, opposite.w, evolve.blend);

    ivec2 lattice = ivec2(texel.x < SIZE / 2 ? texel.x : texel.x - SIZE, texel.y < SIZE / 2 ? texel.y : texel.y - SIZE);
    vec2 wave_vector = vec2(lattice) * (TWO_PI / evolve.patch_size);
    float wave_number = length(wave_vector);
    vec4 first = vec4(0.0);
    vec4 second = vec4(0.0);
    if (wave_number > 0.0) {
        float steps = round(sqrt(GRAVITY * wave_number) / evolve.omega_step);
        float phase = TWO_PI * fract(steps * evolve.share_of_period);
        vec2 leaving = vec2(cos(phase), -sin(phase));
        vec2 height = complex_multiply(amplitude, leaving)
            + complex_multiply(vec2(opposite_amplitude.x, -opposite_amplitude.y), vec2(leaving.x, -leaving.y));

        vec2 direction = wave_vector / wave_number;
        vec2 raised = complex_times_i(height);
        vec2 shift_x = raised * (evolve.choppiness * direction.x);
        vec2 shift_z = raised * (evolve.choppiness * direction.y);
        vec2 slope_x = raised * wave_vector.x;
        vec2 slope_z = raised * wave_vector.y;
        first = vec4(height + complex_times_i(shift_x), shift_z + complex_times_i(slope_x));
        second = vec4(slope_z, 0.0, 0.0);
    }
    store_storage_texture(textures.slots[1].texture_index, texel, first);
    store_storage_texture(textures.slots[2].texture_index, texel, second);
}
