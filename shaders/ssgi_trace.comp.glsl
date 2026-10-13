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

#ifdef HI_Z
const float SSGI_START_STEPS = 64.0;   // the gap before the first test is one step of the longest linear march
const float SSGI_CELL_EPSILON = 1e-3;  // level-0 texels; carries a ray over the cell boundary it stopped at
const float SSGI_NEVER = 1e30;         // exit parameter of a ray that does not move along an axis

// A ray in level-0 texel space: x and y are texel positions, z is the reverse-Z depth. Depth is linear
// in screen space for perspective and orthographic projections alike.
struct SsgiRay {
    vec3 origin;
    vec3 delta;  // change over the parameter range 0 to 1
    float end;   // largest parameter inside the screen
};

// Reverse-Z depth at a forward distance; the inverse of view_distance.
float depth_at_distance(FrameRoot frame, float distance) {
    if (frame.proj[3][3] != 0.0) return frame.proj[3][2] - frame.proj[2][2] * distance;
    return frame.proj[3][2] / distance - frame.proj[2][2];
}

float ssgi_pyramid_depth(uint pyramid, ivec2 cell, int level) {
    return texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(pyramid))], cell, level).r;
}

vec3 ssgi_screen_point(FrameRoot frame, vec3 view_point, vec2 screen) {
    vec4 clip = frame.proj * vec4(view_point, 1.0);
    vec2 uv = (clip.xy / clip.w) * vec2(0.5, -0.5) + 0.5;
    return vec3(uv * screen, clip.z / clip.w);
}

// Parameter at which a ray leaves the interval [low, high] along one axis.
float ssgi_axis_exit(float origin, float delta, float low, float high) {
    if (delta > 0.0) return (high - origin) / delta;
    if (delta < 0.0) return (low - origin) / delta;
    return SSGI_NEVER;
}

// The segment from start to end view-space units along the direction, clipped to the screen and the near plane.
SsgiRay ssgi_screen_ray(FrameRoot frame, vec3 position, vec3 direction, float start, float end, vec2 screen) {
    SsgiRay ray = SsgiRay(vec3(0.0), vec3(0.0), 0.0);
    if (frame.proj[3][3] == 0.0 && direction.z > 0.0) {
        end = min(end, (-view_distance(frame, 1.0) - position.z) / direction.z);
    }
    if (end <= start) return ray;

    vec3 from = ssgi_screen_point(frame, position + direction * start, screen);
    vec3 to = ssgi_screen_point(frame, position + direction * end, screen);
    if (any(lessThan(from.xy, vec2(0.0))) || any(greaterThanEqual(from.xy, screen))) return ray;

    ray.origin = from;
    ray.delta = to - from;
    ray.end = min(1.0, min(
        ssgi_axis_exit(from.x, ray.delta.x, 0.0, screen.x),
        ssgi_axis_exit(from.y, ray.delta.y, 0.0, screen.y)));
    return ray;
}
#endif

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
#ifdef HI_Z
    ivec2 pyramid_extent = texture_extent(root.depth_pyramid);
    vec2 screen = vec2(extent) * 0.5;
    float start_distance = root.max_distance / SSGI_START_STEPS;
#else
    float step_length = root.max_distance / float(root.max_steps);
#endif
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
#ifdef HI_Z
        SsgiRay march = ssgi_screen_ray(
            frame, position, direction, start_distance * (1.0 - step_offset), root.max_distance, screen);
        float cursor = 0.0;
        uint level = 0u;
#endif
        for (uint step_index = 1u; step_index <= root.max_steps; step_index++) {
#ifdef HI_Z
            if (cursor >= march.end) break;

            vec3 current = march.origin + march.delta * cursor;
            ivec2 level_extent = max(pyramid_extent >> level, ivec2(1));
            float cell_size = float(1 << level);
            ivec2 cell = clamp(ivec2(floor(current.xy / cell_size)), ivec2(0), level_extent - 1);
            vec2 cell_low = vec2(cell) * cell_size;
            vec2 cell_high = mix(vec2(cell + 1) * cell_size, screen, equal(cell, level_extent - 1));
            float cell_exit = min(march.end, min(
                ssgi_axis_exit(march.origin.x, march.delta.x, cell_low.x, cell_high.x),
                ssgi_axis_exit(march.origin.y, march.delta.y, cell_low.y, cell_high.y)));
            float after_cell = cell_exit + SSGI_CELL_EPSILON / max(abs(march.delta.x), abs(march.delta.y));
            float nearest = ssgi_pyramid_depth(root.depth_pyramid, cell, int(level));
            float exit_depth = march.origin.z + march.delta.z * cell_exit;
            if (current.z >= nearest && exit_depth >= nearest) {
                cursor = after_cell;
                level = min(level + 1u, root.pyramid_levels - 1u);
                continue;
            }

            float crossing = current.z < nearest ? cursor : (nearest - march.origin.z) / march.delta.z;
            crossing = clamp(crossing, cursor, cell_exit);
            if (level > 0u) {
                cursor = crossing;
                level--;
                continue;
            }

            // Test halfway into the part of the cell where the ray is behind the nearest surface and within
            // the thickness of it.
            float crossing_depth = march.origin.z + march.delta.z * crossing;
            float slab_depth = depth_at_distance(frame, view_distance(frame, crossing_depth) + root.thickness);
            float span = cell_exit - crossing;
            if (march.delta.z < 0.0) span = min(span, (slab_depth - crossing_depth) / march.delta.z);
            vec3 test = march.origin + march.delta * (crossing + 0.5 * span);
            ivec2 hit_texel = clamp(ivec2(floor(test.xy * 2.0)), ivec2(0), extent - 1);
            float stored_depth = fetch_texture_2d(root.depth, hit_texel).r;
            cursor = after_cell;
            if (stored_depth == 0.0) continue;
            float behind = view_distance(frame, test.z) - view_distance(frame, stored_depth);
#else
            vec3 point = position + direction * step_length * (float(step_index) - step_offset);
            vec4 clip = frame.proj * vec4(point, 1.0);
            if (clip.w <= 0.0) break;
            vec2 uv = (clip.xy / clip.w) * vec2(0.5, -0.5) + 0.5;
            if (!ssgi_uv_inside(uv)) break;
            ivec2 hit_texel = min(ivec2(uv * vec2(extent)), extent - 1);
            float stored_depth = fetch_texture_2d(root.depth, hit_texel).r;
            if (stored_depth == 0.0) continue;
            float behind = -point.z - view_distance(frame, stored_depth);
#endif
            if (behind <= 0.0 || behind >= root.thickness) continue;

            vec2 hit_uv = (vec2(hit_texel) + 0.5) / vec2(extent);
            vec4 velocity = fetch_texture_2d(root.velocity, hit_texel);
            vec2 previous_uv = ssgi_previous_uv(frame, hit_uv, velocity);
            vec3 hit_position = ao_view_position(frame, hit_texel, extent, stored_depth);
            bool faces = dot(surface_normal(root, frame, hit_texel, stored_depth, hit_position), -direction) > 0.0;
            if (faces && ssgi_uv_inside(previous_uv)
                && ssgi_depth_matches(frame, root.previous_depth, previous_uv, velocity.z, root.depth_tolerance)) {
                sum += sample_texture_2d(root.previous_color, root.sampler_index, previous_uv).rgb
                    * frame.pre_exposure_ratio;
                hits += 1.0;
            }
            break;
        }
    }
    float rays = float(root.rays);
    store_storage_texture(root.output_texture, ivec2(pixel), vec4(PI * sum / rays, hits / rays));
}
