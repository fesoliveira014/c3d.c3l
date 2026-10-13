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

const float RT_REFLECTION_BLUR_STEP = 2.0; // texels between taps at roughness 1; wider smooths more grain and bleeds across edges
const int RT_REFLECTION_BLUR_RADIUS = 2; // taps each side; a 5x5 kernel

void main() {
    RtReflectionBlurRoot root = RtReflectionBlurRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    ivec2 texel = ivec2(pixel);
    vec4 centre = load_storage_texture(root.input_texture, texel);
    vec4 centre_normal_roughness = fetch_texture_2d(root.normal_roughness, texel);
    float roughness = centre_normal_roughness.b;
    float step_texels = roughness * RT_REFLECTION_BLUR_STEP;
    if (centre.a == 0.0 || step_texels < 0.5) {
        store_storage_texture(root.output_texture, texel, centre);
        return;
    }

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 extent = ivec2(root.width, root.height);
    vec3 normal = decode_octahedral(centre_normal_roughness.rg);
    float specular_weight = fetch_texture_2d(root.emissive_specular, texel).a;
    float centre_distance = view_distance(frame, fetch_texture_2d(root.depth, texel).r);
    vec3 total = vec3(0.0);
    float weight_sum = 0.0;
    for (int y = -RT_REFLECTION_BLUR_RADIUS; y <= RT_REFLECTION_BLUR_RADIUS; y++) {
        for (int x = -RT_REFLECTION_BLUR_RADIUS; x <= RT_REFLECTION_BLUR_RADIUS; x++) {
            ivec2 tap = clamp(texel + ivec2(round(vec2(x, y) * step_texels)), ivec2(0), extent - 1);
            vec4 tap_value = load_storage_texture(root.input_texture, tap);
            if (tap_value.a == 0.0) continue;

            vec4 tap_normal_roughness = fetch_texture_2d(root.normal_roughness, tap);
            if (abs(tap_normal_roughness.b - roughness) > RT_REFLECTION_ROUGHNESS_TOLERANCE) continue;

            float tap_specular_weight = fetch_texture_2d(root.emissive_specular, tap).a;
            if (abs(tap_specular_weight - specular_weight) > RT_REFLECTION_SPECULAR_TOLERANCE) continue;

            float weight = rt_reflection_tap_weight(
                frame,
                centre_distance,
                normal,
                fetch_texture_2d(root.depth, tap).r,
                tap_normal_roughness.rg
            );
            total += weight * tap_value.rgb;
            weight_sum += weight;
        }
    }

    store_storage_texture(root.output_texture, texel, vec4(total / weight_sum, 1.0));
}
