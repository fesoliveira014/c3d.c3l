#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "constants.glsl"
#include "gbuffer.glsl"
#include "noise.glsl"
#include "ambient_occlusion.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const uint SSAO_SLICE_COUNT = 2u;        // directions per texel; each costs 2 * SSAO_STEP_COUNT depth fetches
const uint SSAO_STEP_COUNT = 4u;         // steps per side; 16 fetches per texel at 2 slices
const float SSAO_FALLOFF_FRACTION = 0.6; // outer share of the radius where occluders fade out; hides the cut-off ring
const float SSAO_MIN_STEP_PIXELS = 1.3;  // first step clears the centre texel; avoids self-occlusion
const float HALF_PI = 0.5 * PI;

vec3 view_position(
    FrameRoot frame,
    ivec2 texel,
    ivec2 extent,
    float depth
) {
    vec2 uv = (vec2(texel) + 0.5) / vec2(extent);
    return (frame.view * vec4(reconstruct_world_position(frame, uv, depth), 1.0)).xyz;
}

// Per axis the neighbour on the same surface: the one nearer in view distance.
vec3 neighbour_offset(
    FrameRoot frame,
    SsaoRoot root,
    ivec2 texel,
    ivec2 extent,
    ivec2 axis_step,
    vec3 position
) {
    ivec2 forward_texel = clamp(texel + axis_step, ivec2(0), extent - 1);
    ivec2 backward_texel = clamp(texel - axis_step, ivec2(0), extent - 1);
    float forward_depth = fetch_texture_2d(root.depth, forward_texel).r;
    float backward_depth = fetch_texture_2d(root.depth, backward_texel).r;
    float centre_distance = -position.z;
    float forward_gap = forward_depth == 0.0 ? 1e30 : abs(view_distance(frame, forward_depth) - centre_distance);
    float backward_gap = backward_depth == 0.0 ? 1e30 : abs(view_distance(frame, backward_depth) - centre_distance);
    if (forward_gap <= backward_gap) {
        if (forward_depth == 0.0) return vec3(0.0);
        return view_position(frame, forward_texel, extent, forward_depth) - position;
    }
    return position - view_position(frame, backward_texel, extent, backward_depth);
}

vec3 reconstructed_normal(
    FrameRoot frame,
    SsaoRoot root,
    ivec2 texel,
    ivec2 extent,
    vec3 position,
    vec3 view_vector
) {
    vec3 right = neighbour_offset(frame, root, texel, extent, ivec2(1, 0), position);
    vec3 down = neighbour_offset(frame, root, texel, extent, ivec2(0, 1), position);
    vec3 normal = cross(down, right);
    float normal_length = length(normal);
    if (normal_length == 0.0) return view_vector;
    normal /= normal_length;
    return dot(normal, view_vector) < 0.0 ? -normal : normal;
}

// Jimenez 2016, cosine-weighted visibility between two horizon angles.
float slice_visibility(float horizon_0, float horizon_1, float normal_angle) {
    float cos_normal = cos(normal_angle);
    float sin_normal = sin(normal_angle);
    float arc_0 = cos_normal + 2.0 * horizon_0 * sin_normal - cos(2.0 * horizon_0 - normal_angle);
    float arc_1 = cos_normal + 2.0 * horizon_1 * sin_normal - cos(2.0 * horizon_1 - normal_angle);
    return 0.25 * (arc_0 + arc_1);
}

void main() {
    SsaoRoot root = SsaoRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 extent = texture_extent(root.depth);
    ivec2 texel = ao_depth_texel(ivec2(pixel), ivec2(root.width, root.height), extent);
    float depth = fetch_texture_2d(root.depth, texel).r;
    if (depth == 0.0) {
        store_storage_texture(root.output_texture, ivec2(pixel), vec4(1.0));
        return;
    }

    vec3 position = view_position(frame, texel, extent, depth);
    bool orthographic = frame.proj[3][3] != 0.0;
    vec3 view_vector = orthographic ? vec3(0.0, 0.0, 1.0) : normalize(-position);
    vec3 normal = root.normals != 0u
        ? normalize(mat3(frame.view) * decode_octahedral(fetch_texture_2d(root.normals, texel).rg))
        : reconstructed_normal(frame, root, texel, extent, position, view_vector);

    float projected_scale = frame.proj[0][0] * 0.5 * float(extent.x);
    float radius_pixels = root.radius * projected_scale / (orthographic ? 1.0 : -position.z);
    if (radius_pixels < 1.0) {
        store_storage_texture(root.output_texture, ivec2(pixel), vec4(1.0));
        return;
    }
    vec2 radius_uv = radius_pixels / vec2(extent);
    vec2 centre_uv = (vec2(texel) + 0.5) / vec2(extent);
    float min_step = SSAO_MIN_STEP_PIXELS / radius_pixels;
    float slice_noise = interleaved_gradient_noise(vec2(pixel), root.noise_frame);
    float step_noise = interleaved_gradient_noise(vec2(pixel.yx), root.noise_frame);
    float falloff_range = root.radius * SSAO_FALLOFF_FRACTION;
    float falloff_from = root.radius - falloff_range;

    float visibility = 0.0;
    for (uint slice = 0u; slice < SSAO_SLICE_COUNT; slice++) {
        float phi = (float(slice) + slice_noise) * PI / float(SSAO_SLICE_COUNT);
        vec3 direction = vec3(cos(phi), sin(phi), 0.0);
        vec2 omega_uv = vec2(direction.x, -direction.y) * radius_uv;
        vec3 ortho_direction = direction - dot(direction, view_vector) * view_vector;
        vec3 axis = normalize(cross(ortho_direction, view_vector));
        vec3 projected_normal = normal - axis * dot(normal, axis);
        float projected_length = length(projected_normal);
        float cos_normal = clamp(dot(projected_normal, view_vector) / projected_length, 0.0, 1.0);
        float normal_angle = sign(dot(ortho_direction, projected_normal)) * acos(cos_normal);

        // The +omega side bounds the positive horizon angle, the -omega side the negative one.
        float start_plus = cos(normal_angle + HALF_PI);
        float start_minus = cos(normal_angle - HALF_PI);
        float horizon_plus = start_plus;
        float horizon_minus = start_minus;
        for (uint step_index = 0u; step_index < SSAO_STEP_COUNT; step_index++) {
            float fraction = (float(step_index) + step_noise) / float(SSAO_STEP_COUNT);
            float distance_fraction = max(fraction * fraction, min_step);
            for (int side = 0; side < 2; side++) {
                float sign_of_side = side == 0 ? 1.0 : -1.0;
                vec2 sample_uv = centre_uv + sign_of_side * distance_fraction * omega_uv;
                if (any(lessThan(sample_uv, vec2(0.0))) || any(greaterThanEqual(sample_uv, vec2(1.0)))) continue;
                ivec2 sample_texel = ivec2(sample_uv * vec2(extent));
                float sample_depth = fetch_texture_2d(root.depth, sample_texel).r;
                if (sample_depth == 0.0) continue;

                vec3 delta = view_position(frame, sample_texel, extent, sample_depth) - position;
                float sample_distance = length(delta);
                if (sample_distance == 0.0) continue;
                float weight = clamp(1.0 - (sample_distance - falloff_from) / falloff_range, 0.0, 1.0);
                float start = side == 0 ? start_plus : start_minus;
                float horizon = mix(start, dot(delta / sample_distance, view_vector), weight);
                if (side == 0) {
                    horizon_plus = max(horizon_plus, horizon);
                } else {
                    horizon_minus = max(horizon_minus, horizon);
                }
            }
        }
        float horizon_1 = acos(clamp(horizon_plus, -1.0, 1.0));
        float horizon_0 = -acos(clamp(horizon_minus, -1.0, 1.0));
        horizon_1 = normal_angle + clamp(horizon_1 - normal_angle, -HALF_PI, HALF_PI);
        horizon_0 = normal_angle + clamp(horizon_0 - normal_angle, -HALF_PI, HALF_PI);
        visibility += projected_length * slice_visibility(horizon_0, horizon_1, normal_angle);
    }
    visibility = clamp(visibility / float(SSAO_SLICE_COUNT), 0.0, 1.0);
    float occlusion = clamp(1.0 - root.intensity * (1.0 - visibility), 0.0, 1.0);
    store_storage_texture(root.output_texture, ivec2(pixel), vec4(occlusion));
}
