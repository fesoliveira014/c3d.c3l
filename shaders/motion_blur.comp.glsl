#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float MINIMUM_VELOCITY = 0.5; // pixels; below it the pixel is copied through
const float SOFT_DEPTH_EXTENT = 0.002; // reverse-Z units; about one meter at five meters with a 0.1 near plane

vec2 velocity_pixels(MotionBlurRoot root, vec2 uv) {
    vec2 velocity = sample_texture_2d(root.velocity_texture, root.sampler_index, uv).rg
        * vec2(root.width, root.height) * root.shutter;
    float speed = length(velocity);
    return speed > root.max_velocity ? velocity * (root.max_velocity / speed) : velocity;
}

vec2 tile_velocity_pixels(MotionBlurRoot root, uvec2 texel) {
    vec2 velocity = load_storage_texture(root.tile_texture, ivec2(texel / POST_TILE_SIZE)).rg
        * vec2(root.width, root.height) * root.shutter;
    float speed = length(velocity);
    return speed > root.max_velocity ? velocity * (root.max_velocity / speed) : velocity;
}

float cone(float distance, float speed) {
    return clamp(1.0 - distance / max(speed, MINIMUM_VELOCITY), 0.0, 1.0);
}

float cylinder(float distance, float speed) {
    return 1.0 - smoothstep(0.95 * speed, 1.05 * speed, distance);
}

// One when the second depth is in front of the first; reverse-Z, larger is closer.
float in_front(float reference, float other) {
    return clamp(1.0 + (other - reference) / SOFT_DEPTH_EXTENT, 0.0, 1.0);
}

float jitter(uvec2 texel) {
    uint hash = texel.x * 1664525u + texel.y * 1013904223u;
    hash ^= hash >> 16;
    hash *= 2246822519u;
    return float(hash & 0xFFFFu) / 65536.0;
}

// McGuire 2012: samples along the tile's dominant motion, weighted by cone, cylinder and depth order.
void main() {
    MotionBlurRoot root = MotionBlurRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    vec2 uv = (vec2(texel) + 0.5) * root.texel;
    vec4 center = sample_texture_2d(root.color_texture, root.sampler_index, uv);
    vec2 neighborhood = tile_velocity_pixels(root, texel);
    float neighborhood_speed = length(neighborhood);
    if (neighborhood_speed < MINIMUM_VELOCITY) {
        store_storage_texture(root.output_texture, ivec2(texel), center);
        return;
    }

    float center_depth = sample_texture_2d(root.depth_texture, root.sampler_index, uv).r;
    float center_speed = length(velocity_pixels(root, uv));
    float weight = 1.0 / max(center_speed, MINIMUM_VELOCITY);
    vec3 sum = center.rgb * weight;
    float offset = jitter(texel);
    for (uint index = 0u; index < root.samples; index++) {
        float t = mix(-1.0, 1.0, (float(index) + offset) / float(root.samples));
        vec2 tap_uv = uv + neighborhood * t * root.texel;
        float distance = abs(t * neighborhood_speed);
        float tap_depth = sample_texture_2d(root.depth_texture, root.sampler_index, tap_uv).r;
        float tap_speed = length(velocity_pixels(root, tap_uv));
        float front = in_front(center_depth, tap_depth);
        float behind = in_front(tap_depth, center_depth);
        float tap_weight = front * cone(distance, tap_speed) + behind * cone(distance, center_speed)
            + cylinder(distance, tap_speed) * cylinder(distance, center_speed) * 2.0;
        sum += sample_texture_2d(root.color_texture, root.sampler_index, tap_uv).rgb * tap_weight;
        weight += tap_weight;
    }
    store_storage_texture(root.output_texture, ivec2(texel), vec4(sum / weight, center.a));
}
