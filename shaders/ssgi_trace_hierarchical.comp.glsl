#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "constants.glsl"
#include "gbuffer.glsl"
#include "noise.glsl"
#include "sampling.glsl"
#include "texture_fetch.glsl"
#include "ambient_occlusion.glsl"
#include "ao_estimate.glsl"
#include "screen_space_gi.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const uint SSGI_SECOND_SEQUENCE = 7u;  // offsets the second noise stream so the two coordinates decorrelate
const uint SSGI_STEP_SEQUENCE = 13u;   // offsets the step jitter stream

const uint SSGI_SAMPLE_BLOCK = 16u;
const uint SSGI_LINEAR_PREFIX = 8u;

// These bounds keep the certified projection and distance arithmetic finite.
const float SSGI_MIN_NORMAL = 1.1754943508222875e-38;
const float SSGI_SAFE_MAGNITUDE = 4294967296.0;
const float SSGI_MIN_DENOMINATOR = 2.3283064365386963e-10;
const float SSGI_DIVISION_ENVELOPE = 9.5367431640625e-7;
const float SSGI_PROJECTION_ENVELOPE = 7.62939453125e-6;
const float SSGI_ABSOLUTE_POSITION_ERROR = 1.88079096131566e-37;

// Outward rounding must remain conservative when subnormal values flush to zero.
vec2 ssgi_lower(vec2 value) {
    uvec2 bits = floatBitsToUint(value);
    uvec2 increment = mix(uvec2(0xffffffffu), uvec2(1u), lessThan(value, vec2(0.0)));

    return mix(uintBitsToFloat(bits + increment), vec2(-SSGI_MIN_NORMAL),
        lessThanEqual(abs(value), vec2(SSGI_MIN_NORMAL)));
}

vec2 ssgi_upper(vec2 value) {
    uvec2 bits = floatBitsToUint(value);
    uvec2 increment = mix(uvec2(1u), uvec2(0xffffffffu), lessThan(value, vec2(0.0)));

    return mix(uintBitsToFloat(bits + increment), vec2(SSGI_MIN_NORMAL),
        lessThanEqual(abs(value), vec2(SSGI_MIN_NORMAL)));
}

bool ssgi_interval_supported(mat4 projection, vec3 position, vec3 step_delta) {
    const uint magnitude_mask = 0x7fffffffu;
    const uint maximum_magnitude = 0x4f800000u;

    uvec4 coefficients = floatBitsToUint(vec4(
        projection[0][0], projection[1][1], projection[2][0], projection[2][1]
    )) & magnitude_mask;
    uvec4 translation = floatBitsToUint(projection[3]);
    uint depth_scale = floatBitsToUint(projection[2][2]);

    // Encoding checks also reject nonfinite inputs without relying on denormal comparisons.
    return all(lessThanEqual(floatBitsToUint(position) & magnitude_mask, uvec3(maximum_magnitude)))
        && all(lessThanEqual(floatBitsToUint(step_delta) & magnitude_mask, uvec3(maximum_magnitude)))
        && all(lessThanEqual(coefficients, uvec4(maximum_magnitude)))
        && all(lessThanEqual(translation & magnitude_mask, uvec4(maximum_magnitude)))
        && (depth_scale & magnitude_mask) <= maximum_magnitude
        && (depth_scale <= maximum_magnitude || (depth_scale & magnitude_mask) == 0u)
        && translation.z >= 0x1f800000u && translation.z <= maximum_magnitude

        // The enclosure assumes perspective projection without XY shear or translation.
        && (floatBitsToUint(projection[1][0]) & magnitude_mask) == 0u
        && (floatBitsToUint(projection[0][1]) & magnitude_mask) == 0u
        && (floatBitsToUint(projection[0][3]) & magnitude_mask) == 0u
        && (floatBitsToUint(projection[1][3]) & magnitude_mask) == 0u
        && floatBitsToUint(projection[2][3]) == 0xbf800000u
        && (translation.w & magnitude_mask) == 0u
        && all(equal(translation.xy & magnitude_mask, uvec2(0u)));
}

vec2 ssgi_quotient_lower(vec2 minimum, vec2 maximum, vec2 denominator) {
    precise vec2 lower = minimum / mix(
        vec2(denominator.x), vec2(denominator.y), greaterThanEqual(minimum, vec2(0.0))
    );
    precise vec2 upper = maximum / mix(
        vec2(denominator.y), vec2(denominator.x), greaterThanEqual(maximum, vec2(0.0))
    );

    // Widen the quotient by the permitted division error before rounding outward.
    precise vec2 padding_value = max(abs(lower), abs(upper)) * SSGI_DIVISION_ENVELOPE;
    vec2 padding = ssgi_upper(padding_value);
    precise vec2 result = lower - padding;
    return ssgi_lower(result);
}

bool ssgi_distance_lower(FrameRoot frame, float depth, out float lower) {
    if (frame.proj[3][3] != 0.0) return false;

    vec2 numerator = vec2(frame.proj[3][2]);
    precise vec2 denominator = vec2(depth + frame.proj[2][2]);
    denominator = vec2(ssgi_lower(denominator).x, ssgi_upper(denominator).y);
    if (denominator.x < SSGI_MIN_DENOMINATOR) return false;

    lower = min(
        ssgi_quotient_lower(vec2(numerator.x), vec2(numerator.y), denominator).x, 1099511627776.0
    );
    return true;
}

float ssgi_pyramid_depth(uint pyramid, ivec2 texel, uint level) {
    return texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(pyramid))], texel, int(level)).r;
}

bool ssgi_interval_clear(
    SsgiTraceRoot root,
    FrameRoot frame,
    ivec2 extent,
    vec3 position,
    vec3 step_delta,
    float step_offset,
    uint first_step,
    uint last_step
) {
    if (any(greaterThan(extent, ivec2(16777216)))) return false;

    precise vec3 first_point = position + step_delta * (float(first_step) - step_offset);
    precise vec3 last_point = position + step_delta * (float(last_step) - step_offset);
    precise vec4 first_clip = frame.proj * vec4(first_point, 1.0);
    precise vec4 last_clip = frame.proj * vec4(last_point, 1.0);

    // Reject intervals whose rounding envelope could reach or cross the camera plane.
    precise vec3 position_scale = abs(position) + abs(step_delta) * (float(last_step) + 1.0);
    float minimum_w = min(first_clip.w, last_clip.w);
    float w_scale = frame.proj[3][3] != 0.0 ? 0.0 : position_scale.z;
    precise float w_error = SSGI_DIVISION_ENVELOPE * w_scale + SSGI_ABSOLUTE_POSITION_ERROR;
    if (minimum_w < SSGI_MIN_DENOMINATOR || minimum_w <= 8.0 * w_error) return false;

    precise float denominator = minimum_w * 0.5;
    vec2 diagonal = vec2(frame.proj[0][0], frame.proj[1][1]);
    vec2 shift = frame.proj[2].xy;
    precise vec2 clip_scale = abs(diagonal) * position_scale.xy
        + abs(shift) * position_scale.z + abs(frame.proj[3].xy);
    precise vec2 quotient_scale = clip_scale / denominator;
    precise float relative_w = w_scale / denominator;
    if (any(greaterThan(quotient_scale, vec2(SSGI_SAFE_MAGNITUDE)))
        || relative_w > SSGI_SAFE_MAGNITUDE) return false;

    // Positive clip W puts projected extrema at the endpoints; padding covers leaf rounding.
    precise vec2 uv_error = SSGI_PROJECTION_ENVELOPE * (quotient_scale * (1.0 + relative_w) + 1.0);
    precise vec2 first_uv = first_clip.xy / first_clip.w * vec2(0.5, -0.5) + 0.5;
    precise vec2 last_uv = last_clip.xy / last_clip.w * vec2(0.5, -0.5) + 0.5;
    precise vec2 uv_minimum = min(first_uv, last_uv) - uv_error;
    precise vec2 uv_maximum = max(first_uv, last_uv) + uv_error;

    // A viewport crossing must remain an ordered leaf termination.
    if (!ssgi_uv_inside(uv_minimum) || !ssgi_uv_inside(uv_maximum)) return false;

    precise vec2 pixel_minimum = uv_minimum * vec2(extent);
    precise vec2 pixel_maximum = uv_maximum * vec2(extent);
    ivec2 minimum = clamp(ivec2(pixel_minimum), ivec2(0), extent - 1);
    ivec2 maximum = min(ivec2(pixel_maximum), extent - 1);

    ivec2 span = maximum - minimum;
    uint diameter = uint(max(span.x, span.y));
    uint level = min(uint(findMSB(max(diameter, 1u) - 1u) + 1), root.pyramid_levels - 1u);

    // Clamping preserves the reducer's ownership of leftover rows and columns.
    ivec2 mip_extent = textureSize(
        gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.depth_pyramid))], int(level)
    );
    ivec2 first = min(minimum >> level, mip_extent - 1);
    ivec2 last = min(maximum >> level, mip_extent - 1);
    if (any(greaterThan(last - first, ivec2(1)))) return false;

    float nearest = ssgi_pyramid_depth(root.depth_pyramid, first, level);
    if (last.x != first.x) nearest = max(
        nearest, ssgi_pyramid_depth(root.depth_pyramid, ivec2(last.x, first.y), level)
    );
    if (last.y != first.y) {
        nearest = max(nearest, ssgi_pyramid_depth(root.depth_pyramid, ivec2(first.x, last.y), level));
        if (last.x != first.x) nearest = max(nearest, ssgi_pyramid_depth(root.depth_pyramid, last, level));
    }

    // Strict separation excludes every thickness-qualified sample in the block.
    precise float farthest = max(-first_point.z, -last_point.z)
        + SSGI_DIVISION_ENVELOPE * position_scale.z + SSGI_ABSOLUTE_POSITION_ERROR;
    if (nearest == 0.0) return frame.proj[2][2] == 0.0;
    if (floatBitsToUint(nearest) < 0x00800000u) return false;

    float nearest_lower;
    return ssgi_distance_lower(frame, nearest, nearest_lower) && farthest < nearest_lower;
}

// Precise leaf operations use the same arithmetic contract as the rejection bounds.
vec3 ssgi_perspective_delta(vec3 direction, float step_length) {
    precise vec3 delta = direction * step_length;
    return delta;
}

vec3 ssgi_perspective_point(
    vec3 position,
    vec3 delta,
    uint step,
    float offset
) {
    precise vec3 point = position + delta * (float(step) - offset);
    return point;
}

vec4 ssgi_perspective_clip(mat4 projection, vec3 point) {
    precise vec4 clip = projection * vec4(point, 1.0);
    return clip;
}

vec2 ssgi_perspective_uv(vec4 clip) {
    precise vec2 uv = (clip.xy / clip.w) * vec2(0.5, -0.5) + 0.5;
    return uv;
}

float ssgi_perspective_behind(FrameRoot frame, float point_z, float depth) {
    precise float denominator = depth + frame.proj[2][2];
    precise float minimum_denominator = frame.proj[3][2] * 9.094947017729282e-13;

    if (denominator <= 0.0) {
        precise float behind = -point_z - BACKGROUND_VIEW_DISTANCE;
        return behind;
    }

    // The distance cap lies beyond every supported ray point, so it cannot create a hit.
    precise float distance = denominator >= minimum_denominator
        ? frame.proj[3][2] / denominator : 1099511627776.0;
    precise float behind = -point_z - distance;
    return behind;
}

vec3 surface_normal(
    SsgiTraceRoot root,
    FrameRoot frame,
    ivec2 texel,
    float depth,
    vec3 position
) {
    bool orthographic = frame.proj[3][3] != 0.0;
    vec3 view_vector = orthographic ? vec3(0.0, 0.0, 1.0) : normalize(-position);

    if ((root.flags & SSGI_FLAG_GBUFFER_NORMALS) != 0u) {
        vec4 gbuffer_normal = fetch_texture_2d(root.normals, texel);
        if (ao_gbuffer_normal_written(gbuffer_normal)) {
            return normalize(mat3(frame.view) * decode_octahedral(gbuffer_normal.rg));
        }
    }

    return ao_reconstructed_normal(frame, root.depth, texel, depth, view_vector);
}

void main() {
    SsgiTraceRoot root = SsgiTraceRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 extent = texture_extent(root.depth);
    ivec2 texel = ao_depth_texel(ivec2(pixel), ivec2(root.width, root.height), extent);
    float depth = fetch_texture_2d(root.depth, texel).r;

    // Without a previous frame there is no lit colour to read; the consumers keep the base term.
    if (depth == 0.0 || (root.flags & SSGI_FLAG_HISTORY_VALID) == 0u) {
        store_storage_texture(root.output_texture, ivec2(pixel), vec4(0.0));
        return;
    }

    vec3 position = ao_view_position(frame, texel, extent, depth);
    vec3 normal = surface_normal(root, frame, texel, depth, position);
    mat3 basis = tangent_frame(normal);
    float step_length = root.max_distance / float(root.max_steps);

    vec3 sum = vec3(0.0);
    float hits = 0.0;

    for (uint ray = 0u; ray < root.rays; ray++) {
        uint sequence = root.noise_frame * root.rays + ray;
        vec2 u = vec2(
            interleaved_gradient_noise(vec2(pixel), sequence),
            interleaved_gradient_noise(vec2(pixel.yx), sequence + SSGI_SECOND_SEQUENCE)
        );

        vec3 direction = basis * cosine_sample_hemisphere(u);
        float step_offset = interleaved_gradient_noise(vec2(pixel), sequence + SSGI_STEP_SEQUENCE);
        vec3 step_delta = ssgi_perspective_delta(direction, step_length);
        bool interval_supported = ssgi_interval_supported(frame.proj, position, step_delta);
        uint block_end = 0u;

        for (uint step_index = 1u; step_index <= root.max_steps; step_index++) {
            if (interval_supported && step_index > SSGI_LINEAR_PREFIX && step_index > block_end) {
                block_end = min(step_index + SSGI_SAMPLE_BLOCK - 1u, root.max_steps);
                if (ssgi_interval_clear(
                    root,
                    frame,
                    extent,
                    position,
                    step_delta,
                    step_offset,
                    step_index,
                    block_end
                )) {
                    step_index = block_end;
                    continue;
                }
            }

            vec3 point;
            vec4 clip;
            if (interval_supported) {
                point = ssgi_perspective_point(position, step_delta, step_index, step_offset);
                clip = ssgi_perspective_clip(frame.proj, point);
            } else {
                point = position + direction * step_length * (float(step_index) - step_offset);
                clip = frame.proj * vec4(point, 1.0);
            }
            if (clip.w <= 0.0) break;

            vec2 uv = interval_supported ? ssgi_perspective_uv(clip)
                : (clip.xy / clip.w) * vec2(0.5, -0.5) + 0.5;
            if (!ssgi_uv_inside(uv)) break;

            ivec2 hit_texel = min(ivec2(uv * vec2(extent)), extent - 1);
            float stored_depth = fetch_texture_2d(root.depth, hit_texel).r;
            if (stored_depth == 0.0) continue;

            float behind = interval_supported ? ssgi_perspective_behind(frame, point.z, stored_depth)
                : -point.z - view_distance(frame, stored_depth);
            if (behind <= 0.0 || behind >= root.thickness) continue;

            vec2 hit_uv = (vec2(hit_texel) + 0.5) / vec2(extent);
            vec4 velocity = fetch_texture_2d(root.velocity, hit_texel);
            vec2 previous_uv = ssgi_previous_uv(frame, hit_uv, velocity);
            vec3 hit_position = ao_view_position(frame, hit_texel, extent, stored_depth);
            bool faces = dot(
                surface_normal(root, frame, hit_texel, stored_depth, hit_position), -direction
            ) > 0.0;

            if (faces && ssgi_uv_inside(previous_uv)
                && ssgi_depth_matches(frame, root.previous_depth, previous_uv, velocity.z, root.depth_tolerance)) {
                sum += sample_texture_2d(root.previous_color, root.sampler_index, previous_uv).rgb
                    * frame.pre_exposure_ratio;
                hits += 1.0;
            }

            // A geometric hit terminates the ray even when facing or history rejects its contribution.
            break;
        }
    }

    float rays = float(root.rays);
    store_storage_texture(root.output_texture, ivec2(pixel), vec4(PI * sum / rays, hits / rays));
}
