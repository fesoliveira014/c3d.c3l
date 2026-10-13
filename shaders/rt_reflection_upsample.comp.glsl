#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "gbuffer.glsl"
#include "texture_fetch.glsl"
#include "rt_reflection.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float RT_REFLECTION_UPSAMPLE_MIN_WEIGHT = 0.02; // footprint share below which no tap stands for the pixel

void main() {
    RtReflectionUpsampleRoot root = RtReflectionUpsampleRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    ivec2 texel = ivec2(pixel);
    float depth = fetch_texture_2d(root.depth, texel).r;
    float specular_weight = fetch_texture_2d(root.emissive_specular, texel).a;
    if (depth == 0.0 || specular_weight == 0.0) {
        store_storage_texture(root.output_texture, texel, vec4(0.0));
        return;
    }

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 extent = ivec2(root.width, root.height);
    ivec2 input_extent = ivec2(root.input_width, root.input_height);
    vec4 centre_normal_roughness = fetch_texture_2d(root.normal_roughness, texel);
    vec3 normal = decode_octahedral(centre_normal_roughness.rg);
    float roughness = centre_normal_roughness.b;
    float centre_distance = view_distance(frame, depth);

    // Half texel t holds the pixel 2t + block_offset, so the four texels around a pixel start at its floor.
    ivec2 block_offset = RT_REFLECTION_HALF_OFFSETS[root.offset];
    vec2 lattice = vec2(texel - block_offset) * 0.5;
    ivec2 base = ivec2(floor(lattice));
    vec2 fraction = lattice - vec2(base);
    vec3 total = vec3(0.0);
    float weight_sum = 0.0;
    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 2; x++) {
            ivec2 half_texel = base + ivec2(x, y);
            if (any(lessThan(half_texel, ivec2(0))) || any(greaterThanEqual(half_texel, input_extent))) continue;

            vec4 tap_value = load_storage_texture(root.input_texture, half_texel);
            if (tap_value.a == 0.0) continue;

            ivec2 traced = min(half_texel * 2 + block_offset, extent - 1);
            vec4 tap_normal_roughness = fetch_texture_2d(root.normal_roughness, traced);
            if (abs(tap_normal_roughness.b - roughness) > RT_REFLECTION_ROUGHNESS_TOLERANCE) continue;

            float tap_specular_weight = fetch_texture_2d(root.emissive_specular, traced).a;
            if (abs(tap_specular_weight - specular_weight) > RT_REFLECTION_SPECULAR_TOLERANCE) continue;

            float bilinear = (x == 0 ? 1.0 - fraction.x : fraction.x) * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = bilinear * rt_reflection_tap_weight(
                frame,
                centre_distance,
                normal,
                fetch_texture_2d(root.depth, traced).r,
                tap_normal_roughness.rg
            );
            total += weight * tap_value.rgb;
            weight_sum += weight;
        }
    }

    vec4 result = weight_sum >= RT_REFLECTION_UPSAMPLE_MIN_WEIGHT ? vec4(total / weight_sum, 1.0) : vec4(0.0);
    store_storage_texture(root.output_texture, texel, result);
}
