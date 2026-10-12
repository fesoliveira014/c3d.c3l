#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"
#include "ambient_occlusion.glsl"
#include "fog.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float CLOUD_UPSAMPLE_DEPTH_FRACTION = 0.1; // relative depth gap at which a tap's weight is e^-1; the AO blur's
const float CLOUD_UPSAMPLE_TENT_RADIUS = 2.0;    // input texels; the 4x4 footprint around the source position
const float CLOUD_UPSAMPLE_MIN_WEIGHT = 1e-5;

float cloud_surface_distance(FrameRoot frame, float depth) {
    return depth == 0.0 ? BACKGROUND_VIEW_DISTANCE : view_distance(frame, depth);
}

// Composites the half-resolution layer over the scene in place: scene * T + S, with S carried through the aerial
// perspective to the cloud's distance, the stage the view's fog pass then applies to the pixel's own depth.
void main() {
    CloudsCompositeRoot root = CloudsCompositeRoot(pc.root_gpu);
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(root.width) || pixel.y >= int(root.height)) return;

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 output_extent = ivec2(root.width, root.height);
    ivec2 cloud_extent = ivec2(root.cloud_width, root.cloud_height);
    ivec2 depth_extent = texture_extent(root.depth);
    float depth = fetch_texture_2d(root.depth, pixel).r;
    float centre_distance = cloud_surface_distance(frame, depth);

    vec2 source = (vec2(pixel) + 0.5) * vec2(cloud_extent) / vec2(output_extent) - 0.5;
    ivec2 first = ivec2(floor(source)) - 1;
    vec4 total = vec4(0.0);
    float cloud_distance_total = 0.0;
    float cloud_weight_sum = 0.0;
    float weight_sum = 0.0;
    vec4 nearest_cloud = vec4(0.0, 0.0, 0.0, 1.0);
    float nearest_distance = 0.0;
    float nearest_gap = BACKGROUND_VIEW_DISTANCE;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            ivec2 tap = first + ivec2(x, y);
            if (any(lessThan(tap, ivec2(0))) || any(greaterThanEqual(tap, cloud_extent))) continue;
            vec2 offset = abs(vec2(tap) - source) / CLOUD_UPSAMPLE_TENT_RADIUS;
            float tent = max(0.0, 1.0 - offset.x) * max(0.0, 1.0 - offset.y);
            if (tent == 0.0) continue;

            float tap_depth = fetch_texture_2d(root.depth, ao_depth_texel(tap, cloud_extent, depth_extent)).r;
            float gap = abs(cloud_surface_distance(frame, tap_depth) - centre_distance);
            vec4 tap_cloud = load_storage_texture(root.clouds, tap);
            float tap_distance = load_storage_texture(root.distance_texture, tap).r;
            if (gap < nearest_gap) {
                nearest_gap = gap;
                nearest_cloud = tap_cloud;
                nearest_distance = tap_distance;
            }
            float weight = tent * exp(-gap / (CLOUD_UPSAMPLE_DEPTH_FRACTION * centre_distance));
            float cloud_weight = weight * (1.0 - tap_cloud.a);
            total += weight * tap_cloud;
            cloud_distance_total += cloud_weight * tap_distance;
            cloud_weight_sum += cloud_weight;
            weight_sum += weight;
        }
    }
    vec4 cloud = nearest_cloud;
    float cloud_distance = nearest_distance;
    if (weight_sum > CLOUD_UPSAMPLE_MIN_WEIGHT) {
        cloud = total / weight_sum;
        cloud_distance = cloud_weight_sum > CLOUD_UPSAMPLE_MIN_WEIGHT ? cloud_distance_total / cloud_weight_sum : 0.0;
    }
    if (cloud.a >= 1.0) return;

    vec3 scattered = cloud.rgb;
    if (frame.sky_fog != 0ul) {
        SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
        vec2 uv = (vec2(pixel) + 0.5) / vec2(output_extent);
        vec3 ray_origin;
        vec3 ray_direction;
        fog_pixel_ray(frame, uv, ray_origin, ray_direction);
        FogTerms to_cloud = aerial_perspective_terms(sky, uv, ray_direction.y, cloud_distance);
        FogTerms to_scene = fog_none();
        if (depth != 0.0) {
            float scene_distance;
            vec3 scene_origin;
            vec3 scene_direction;
            vec3 scene_position = reconstruct_world_position(frame, uv, depth);
            fog_view_ray(frame, scene_position, scene_origin, scene_direction, scene_distance);
            to_scene = aerial_perspective_terms(sky, uv, ray_direction.y, scene_distance);
        }
        vec3 in_front = (1.0 - cloud.a) * (to_cloud.inscatter - to_scene.inscatter);
        scattered = (to_cloud.transmittance * scattered + in_front)
            / max(to_scene.transmittance, vec3(FOG_TRANSMITTANCE_FLOOR));
    }
    vec4 color = load_storage_texture(root.color, pixel);
    store_storage_texture(root.color, pixel, vec4(color.rgb * cloud.a + scattered, color.a));
}
