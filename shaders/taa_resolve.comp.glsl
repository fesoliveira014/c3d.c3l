#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float BACKGROUND_DEPTH = 1e30;
const float FILTER_FALLOFF = 2.29; // Gaussian fit of Blackman-Harris over a one-pixel radius
const float VARIANCE_EPSILON = 1e-4;

float luma(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

vec3 to_ycocg(vec3 color) {
    return vec3(
        0.25 * color.r + 0.5 * color.g + 0.25 * color.b,
        0.5 * color.r - 0.5 * color.b,
        -0.25 * color.r + 0.5 * color.g - 0.25 * color.b);
}

vec3 from_ycocg(vec3 color) {
    return vec3(color.x + color.y - color.z, color.x + color.z, color.x - color.y - color.z);
}

// Forward distance from reverse-Z depth, the formula of dof_linear_depth; depth 0 reads as infinitely far.
float linear_depth(TaaRoot root, float depth) {
    if (root.orthographic != 0u) return (root.proj_23 - depth) / root.proj_22;
    float denominator = depth + root.proj_22;
    return denominator > 0.0 ? root.proj_23 / denominator : BACKGROUND_DEPTH;
}

// Playdead 2016: moves the history toward the box center until it lies inside the box.
vec3 clip_to_box(vec3 history, vec3 center, vec3 extent) {
    vec3 offset = history - center;
    vec3 units = abs(offset / max(extent, vec3(VARIANCE_EPSILON)));
    float largest = max(units.x, max(units.y, units.z));
    return largest > 1.0 ? center + offset / largest : history;
}

vec3 history_tap(TaaRoot root, vec2 uv) {
    return sample_texture_2d(root.history_color, root.sampler_index, uv).rgb;
}

// Jimenez 2016: a Catmull-Rom filter from five bilinear taps, corners dropped.
vec3 sample_history(TaaRoot root, vec2 uv) {
    vec2 position = uv * vec2(root.width, root.height);
    vec2 center = floor(position - 0.5) + 0.5;
    vec2 fraction = position - center;
    vec2 weight_0 = fraction * (-0.5 + fraction * (1.0 - 0.5 * fraction));
    vec2 weight_1 = 1.0 + fraction * fraction * (-2.5 + 1.5 * fraction);
    vec2 weight_2 = fraction * (0.5 + fraction * (2.0 - 1.5 * fraction));
    vec2 weight_3 = fraction * fraction * (-0.5 + 0.5 * fraction);
    vec2 weight_12 = weight_1 + weight_2;
    vec2 uv_0 = (center - 1.0) * root.texel;
    vec2 uv_3 = (center + 2.0) * root.texel;
    vec2 uv_12 = (center + weight_2 / weight_12) * root.texel;

    vec3 color = history_tap(root, vec2(uv_12.x, uv_0.y)) * (weight_12.x * weight_0.y)
        + history_tap(root, vec2(uv_0.x, uv_12.y)) * (weight_0.x * weight_12.y)
        + history_tap(root, uv_12) * (weight_12.x * weight_12.y)
        + history_tap(root, vec2(uv_3.x, uv_12.y)) * (weight_3.x * weight_12.y)
        + history_tap(root, vec2(uv_12.x, uv_3.y)) * (weight_12.x * weight_3.y);
    float total = weight_12.x * weight_0.y + weight_0.x * weight_12.y + weight_12.x * weight_12.y
        + weight_3.x * weight_12.y + weight_12.x * weight_3.y;
    return max(color / total, vec3(0.0));
}

// Any texel of the 2x2 footprint within the relative tolerance keeps the history.
bool depth_matches(TaaRoot root, vec2 history_uv, float expected_depth) {
    vec2 size = vec2(root.width, root.height);
    ivec2 base = ivec2(floor(history_uv * size - 0.5));
    ivec2 last = ivec2(root.width, root.height) - 1;
    float expected = linear_depth(root, expected_depth);
    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 2; x++) {
            ivec2 texel = clamp(base + ivec2(x, y), ivec2(0), last);
            float stored = load_storage_texture(root.history_depth, texel).r;
            if (expected_depth == 0.0 && stored == 0.0) return true;
            if (expected_depth == 0.0 || stored == 0.0) continue;
            if (abs(linear_depth(root, stored) - expected) <= root.depth_tolerance * expected) return true;
        }
    }
    return false;
}

void main() {
    TaaRoot root = TaaRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    vec2 size = vec2(root.width, root.height);
    vec2 uv = (vec2(texel) + 0.5) * root.texel;
    vec2 jitter_pixels = root.jitter_uv * size;

    vec3 mean = vec3(0.0);
    vec3 moment = vec3(0.0);
    vec3 filtered = vec3(0.0);
    float filter_weight = 0.0;
    float nearest_depth = -1.0;
    vec2 nearest_uv = uv;
    float center_depth = 0.0;
    float center_alpha = 1.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 offset = vec2(x, y);
            vec2 tap_uv = uv + offset * root.texel;
            vec4 tap = sample_texture_2d(root.color_texture, root.sampler_index, tap_uv);
            vec3 color = tap.rgb;
            float depth = sample_texture_2d(root.depth_texture, root.sampler_index, tap_uv).r;
            vec3 converted = to_ycocg(color);
            mean += converted;
            moment += converted * converted;
            vec2 tap_distance = offset - jitter_pixels;
            float weight = exp(-FILTER_FALLOFF * dot(tap_distance, tap_distance));
            filtered += color * weight;
            filter_weight += weight;
            if (depth > nearest_depth) {
                nearest_depth = depth;
                nearest_uv = tap_uv;
            }
            if (x == 0 && y == 0) {
                center_depth = depth;
                center_alpha = tap.a;
            }
        }
    }
    mean /= 9.0;
    vec3 deviation = sqrt(max(moment / 9.0 - mean * mean, vec3(0.0)));
    vec3 current = filtered / filter_weight;

    vec4 motion = sample_texture_2d(root.velocity_texture, root.sampler_index, nearest_uv);
    vec2 velocity = motion.xy;
    vec2 center_velocity = sample_texture_2d(root.velocity_texture, root.sampler_index, uv).xy;
    vec2 history_uv = uv - velocity;
    bool inside = all(greaterThanEqual(history_uv, vec2(0.0))) && all(lessThanEqual(history_uv, vec2(1.0)));

    float depth_rejection = 0.0;
    float velocity_rejection = 0.0;
    float confidence = 0.0;
    vec3 history = current;
    if (root.history_valid != 0u && inside) {
        depth_rejection = depth_matches(root, history_uv, motion.z) ? 0.0 : 1.0;
        ivec2 history_texel = clamp(ivec2(history_uv * size), ivec2(0), ivec2(root.width, root.height) - 1);
        vec2 previous_velocity = load_storage_texture(root.history_velocity, history_texel).xy;
        float difference = length((velocity - previous_velocity) * size);
        velocity_rejection = smoothstep(root.velocity_threshold, 2.0 * root.velocity_threshold, difference);
        confidence = (1.0 - depth_rejection) * (1.0 - velocity_rejection);
        vec3 clipped = clip_to_box(to_ycocg(sample_history(root, history_uv)), mean, root.clip_gamma * deviation);
        history = from_ycocg(clipped);
    }

    float current_share = 1.0 - (1.0 - root.current_weight) * confidence;
    float current_weight = current_share / (1.0 + luma(current));
    float history_weight = (1.0 - current_share) / (1.0 + luma(history));
    vec3 resolved = (current * current_weight + history * history_weight) / (current_weight + history_weight);

    ivec2 target = ivec2(texel);
    store_storage_texture(root.output_color, target, vec4(resolved, center_alpha));
    store_storage_texture(root.output_depth, target, vec4(center_depth, 0.0, 0.0, 0.0));
    store_storage_texture(root.output_velocity, target, vec4(center_velocity, 0.0, 0.0));

    if (root.debug == TAA_DEBUG_VELOCITY) {
        vec2 shown = 0.5 + velocity * size / (2.0 * float(TAA_DEBUG_VELOCITY_RANGE));
        store_storage_texture(root.debug_texture, target, vec4(clamp(shown, 0.0, 1.0), 0.0, 1.0));
    } else if (root.debug == TAA_DEBUG_REJECTION) {
        float missing = root.history_valid != 0u && inside ? 0.0 : 1.0;
        store_storage_texture(root.debug_texture, target, vec4(depth_rejection, velocity_rejection, missing, 1.0));
    } else if (root.debug == TAA_DEBUG_HISTORY_WEIGHT) {
        store_storage_texture(root.debug_texture, target, vec4(vec3(1.0 - current_share), 1.0));
    }
}
