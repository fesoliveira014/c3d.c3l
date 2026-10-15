#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "gbuffer.glsl"
#include "texture_fetch.glsl"
#include "screen_space_gi.glsl"
#include "rt_reflection.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float RT_REFLECTION_HISTORY_WEIGHT = 0.9; // share of the history kept per frame; about ten frames
const float RT_REFLECTION_HISTORY_ROUGHNESS = 0.25; // roughness at which the weight is full; the blur's skip ends here
const float RT_REFLECTION_CLAMP_SIGMA = 1.0; // standard deviations of the 3 x 3 neighbourhood the history may stray
const float RT_REFLECTION_DEPTH_TOLERANCE = 0.05; // relative linear depth, TAA's default
const float RT_REFLECTION_VELOCITY_THRESHOLD = 2.0; // full-resolution pixels a frame, TAA's default

vec3 rt_reflection_to_ycocg(vec3 color) {
    return vec3(
        0.25 * color.r + 0.5 * color.g + 0.25 * color.b,
        0.5 * color.r - 0.5 * color.b,
        -0.25 * color.r + 0.5 * color.g - 0.25 * color.b
    );
}

vec3 rt_reflection_from_ycocg(vec3 color) {
    return vec3(color.x + color.y - color.z, color.x + color.z, color.x - color.y - color.z);
}

// The history texel's surface, read from the current G-buffer at its position, must resemble the pixel's.
bool rt_reflection_same_material(
    RtReflectionTemporalRoot root,
    ivec2 history_texel,
    float roughness,
    float specular_weight
) {
    float history_roughness = fetch_texture_2d(root.normal_roughness, history_texel).b;
    float history_specular_weight = fetch_texture_2d(root.emissive_specular, history_texel).a;
    return abs(history_roughness - roughness) <= RT_REFLECTION_ROUGHNESS_TOLERANCE
        && abs(history_specular_weight - specular_weight) <= RT_REFLECTION_SPECULAR_TOLERANCE;
}

// Reprojected history in rgb, scaled to the current pre-exposure, and the share of it the pixel may keep in alpha.
vec4 rt_reflection_reproject(RtReflectionTemporalRoot root, ivec2 extent, ivec2 texel, float roughness) {
    vec4 velocity = fetch_texture_2d(root.velocity, texel);
    // The frame's jitter stays out: samples taken under different jitters accumulate at one texel.
    vec2 previous_uv = (vec2(texel) + 0.5) / vec2(extent) - velocity.xy;
    if (!ssgi_uv_inside(previous_uv)) return vec4(0.0);

    ivec2 history_texel = clamp(ivec2(floor(previous_uv * vec2(extent))), ivec2(0), extent - 1);
    float specular_weight = fetch_texture_2d(root.emissive_specular, texel).a;
    if (!rt_reflection_same_material(root, history_texel, roughness, specular_weight)) return vec4(0.0);

    // Untraced texels hold zero radiance and zero alpha, so the filtered alpha is the traced share of the footprint.
    vec4 history = sample_texture_2d(root.history, root.sampler_index, previous_uv);
    if (history.a <= 0.0) return vec4(0.0);

    bool depth_match = ssgi_depth_matches(
        FrameRoot(root.frame),
        root.previous_depth,
        previous_uv,
        velocity.z,
        RT_REFLECTION_DEPTH_TOLERANCE
    );
    float velocity_pixels = length(velocity.xy * vec2(extent));
    float confidence = ssgi_history_confidence(depth_match, velocity_pixels, RT_REFLECTION_VELOCITY_THRESHOLD)
        * (1.0 - clamp(velocity.a, 0.0, 1.0))
        * history.a;
    return vec4(history.rgb / history.a * root.pre_exposure_ratio, confidence);
}

void main() {
    RtReflectionTemporalRoot root = RtReflectionTemporalRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    ivec2 texel = ivec2(pixel);
    ivec2 extent = ivec2(root.width, root.height);
    store_storage_texture(root.output_depth, texel, vec4(fetch_texture_2d(root.depth, texel).r, 0.0, 0.0, 0.0));

    vec4 current = load_storage_texture(root.current, texel);
    float roughness = fetch_texture_2d(root.normal_roughness, texel).b;
    // The half-resolution reconstruction does not test the threshold; a pixel past it is untraced, as in the trace.
    if (current.a == 0.0 || roughness > root.max_roughness) {
        store_storage_texture(root.output_texture, texel, vec4(0.0));
        return;
    }

    float history_weight = RT_REFLECTION_HISTORY_WEIGHT * clamp(roughness / RT_REFLECTION_HISTORY_ROUGHNESS, 0.0, 1.0);
    vec3 result = current.rgb;
    if (history_weight > 0.0 && (root.flags & RT_REFLECTION_TEMPORAL_FLAG_HISTORY_VALID) != 0u) {
        vec4 history = rt_reflection_reproject(root, extent, texel, roughness);
        if (history.a > 0.0) {
            vec3 sum = vec3(0.0);
            vec3 sum_squares = vec3(0.0);
            float traced = 0.0;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    ivec2 tap = clamp(texel + ivec2(x, y), ivec2(0), extent - 1);
                    vec4 neighbour = load_storage_texture(root.current, tap);
                    if (neighbour.a == 0.0) continue;

                    vec3 converted = rt_reflection_to_ycocg(neighbour.rgb);
                    sum += converted;
                    sum_squares += converted * converted;
                    traced += 1.0;
                }
            }

            vec3 mean = sum / traced;
            vec3 deviation = sqrt(max(sum_squares / traced - mean * mean, vec3(0.0)));
            vec3 reach = RT_REFLECTION_CLAMP_SIGMA * deviation;
            vec3 clamped = clamp(rt_reflection_to_ycocg(history.rgb), mean - reach, mean + reach);
            result = mix(current.rgb, rt_reflection_from_ycocg(clamped), history_weight * history.a);
        }
    }

    store_storage_texture(root.output_texture, texel, vec4(result, 1.0));
}
