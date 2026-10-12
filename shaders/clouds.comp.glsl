#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"
#include "ambient_occlusion.glsl"
#include "fog.glsl"
#include "noise.glsl"
#include "cloud_density.glsl"

#ifdef TEMPORAL
layout(local_size_x = CLOUD_TEMPORAL_GROUP, local_size_y = CLOUD_TEMPORAL_GROUP) in;
#else
layout(local_size_x = 8, local_size_y = 8) in;
#endif

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float CLOUD_MAX_MARCH = 60000.0;       // metres of deck one ray marches from its entry; the air hides the rest
const float CLOUD_MIN_TRANSMITTANCE = 0.02;  // a ray this dark adds under 2 % of its radiance by marching on
const float CLOUD_PARALLEL_LIMIT = 1e-4;     // vertical cosine under which a ray runs parallel to a slab
const float CLOUD_BACK_LOBE_SHARE = 0.3;     // fixed blend of the back lobe into the phase function
const float CLOUD_POWDER = 0.5;              // darkening of the thinnest fringe, as a share of its radiance
const float CLOUD_POWDER_LENGTH = 400.0;     // metres of path over which a fringe still reads as thin
const float CLOUD_AMBIENT_FLOOR = 0.4;       // share of the sky light that reaches the bottom of the layer
const float CLOUD_LIGHT_MAX_LENGTH = 4000.0; // metres toward the sun the light march covers at most
const uint CLOUD_SCATTER_OCTAVES = 3u;       // multiple-scattering octaves; each halves extinction, weight, anisotropy

float cloud_henyey_greenstein(float cos_angle, float anisotropy) {
    float squared = anisotropy * anisotropy;
    float denominator = 1.0 + squared - 2.0 * anisotropy * cos_angle;
    return (1.0 - squared) / (4.0 * PI * denominator * sqrt(denominator));
}

// Forward lobe of the layer's anisotropy blended with a back lobe of minus half of it.
float cloud_phase(float cos_angle, float anisotropy) {
    return mix(
        cloud_henyey_greenstein(cos_angle, anisotropy),
        cloud_henyey_greenstein(cos_angle, -0.5 * anisotropy),
        CLOUD_BACK_LOBE_SHARE
    );
}

// Sunlight left after a cloud's optical depth: Wrenninge's octaves of multiple scattering.
float cloud_sun_energy(float optical_depth, float cos_angle, float anisotropy) {
    float energy = 0.0;
    float scale = 1.0;
    for (uint octave = 0u; octave < CLOUD_SCATTER_OCTAVES; octave++) {
        energy += scale * exp(-optical_depth * scale) * cloud_phase(cos_angle, anisotropy * scale);
        scale *= 0.5;
    }
    return energy;
}

// Roots of a ray against the sphere at a shell altitude, from a start inside the same planet-centred frame.
bool cloud_sphere_roots(
    float planet_radius,
    float altitude,
    float cos_zenith,
    float shell,
    out float near_root,
    out float far_root
) {
    float along_up = (planet_radius + altitude) * cos_zenith;
    float discriminant = along_up * along_up - (altitude - shell) * (2.0 * planet_radius + altitude + shell);
    near_root = 0.0;
    far_root = 0.0;
    if (discriminant < 0.0) return false;
    float root = sqrt(discriminant);
    near_root = -along_up - root;
    far_root = -along_up + root;
    return true;
}

// The span of a ray inside the layer: between the shells around the camera's planet, else between two planes.
bool cloud_interval(CloudsRoot root, float altitude, float cos_zenith, out float start, out float end) {
    start = 0.0;
    end = CLOUD_MAX_MARCH;
    if (root.planet_radius == 0.0) {
        if (abs(cos_zenith) < CLOUD_PARALLEL_LIMIT) return altitude >= root.bottom && altitude <= root.top;
        float to_bottom = (root.bottom - altitude) / cos_zenith;
        float to_top = (root.top - altitude) / cos_zenith;
        start = max(min(to_bottom, to_top), 0.0);
        end = min(max(to_bottom, to_top), start + CLOUD_MAX_MARCH);
        return end > start;
    }

    float top_near;
    float top_far;
    if (!cloud_sphere_roots(root.planet_radius, altitude, cos_zenith, root.top, top_near, top_far)) return false;
    if (top_far <= 0.0) return false;
    start = max(top_near, 0.0);
    end = top_far;

    float bottom_near;
    float bottom_far;
    if (cloud_sphere_roots(root.planet_radius, altitude, cos_zenith, root.bottom, bottom_near, bottom_far)
        && bottom_far > 0.0) {
        if (bottom_near <= start) start = max(start, bottom_far);
        else end = min(end, bottom_near);
    }

    float ground_near;
    float ground_far;
    if (cloud_sphere_roots(root.planet_radius, altitude, cos_zenith, 0.0, ground_near, ground_far)
        && ground_near > 0.0 && ground_near < start) {
        return false;
    }

    end = min(end, start + CLOUD_MAX_MARCH);
    return end > start;
}

// Altitude after a distance along a ray; a difference of near-equal radii in float would lose metres.
float cloud_altitude_along(float planet_radius, float altitude, float cos_zenith, float distance) {
    if (planet_radius == 0.0) return altitude + cos_zenith * distance;
    float radius = planet_radius + altitude;
    float lift = distance * distance + 2.0 * radius * cos_zenith * distance;
    return altitude + lift / (sqrt(max(radius * radius + lift, 0.0)) + radius);
}

// Optical depth from a point of the layer along the sun until the ray leaves the layer.
float cloud_light_depth(CloudsRoot root, vec2 horizontal, float altitude, float sun_up) {
    float leave = (sun_up > 0.0 ? root.top - altitude : altitude - root.bottom)
        / max(abs(sun_up), CLOUD_SUN_FLOOR);
    float step_length = min(leave, CLOUD_LIGHT_MAX_LENGTH) / float(CLOUD_LIGHT_STEPS);
    float optical_depth = 0.0;
    for (uint step = 0u; step < CLOUD_LIGHT_STEPS; step++) {
        float along = (float(step) + 0.5) * step_length;
        vec2 shifted = horizontal + root.sun_direction.xz * along;
        optical_depth += cloud_density(root, shifted, altitude + sun_up * along, false) * step_length;
    }
    return optical_depth;
}

void store_clouds(CloudsRoot root, ivec2 pixel, vec3 scattered, float transmittance, float distance) {
    store_storage_texture(root.output_texture, pixel, vec4(scattered, transmittance));
    store_storage_texture(root.distance_texture, pixel, vec4(distance));
}

// One half-resolution pixel: the radiance the layer scatters toward the camera and what it lets through, up to the
// scene depth the pixel samples, and the distance of the cloud along the ray. The ray leaves the pixel's centre by
// pixel_offset, in pixels.
vec4 march_clouds(CloudsRoot root, ivec2 pixel, float frame_jitter, vec2 pixel_offset, out float cloud_distance) {
    FrameRoot frame = FrameRoot(root.frame);
    ivec2 extent = ivec2(root.width, root.height);
    vec2 uv = (vec2(pixel) + 0.5 + pixel_offset) / vec2(extent);
    vec3 origin;
    vec3 direction;
    fog_pixel_ray(frame, uv, origin, direction);

    ivec2 depth_extent = texture_extent(root.depth);
    ivec2 depth_texel = ao_depth_texel(pixel, extent, depth_extent);
    float depth = fetch_texture_2d(root.depth, depth_texel).r;
    float scene_distance = BACKGROUND_VIEW_DISTANCE;
    if (depth != 0.0) {
        vec2 depth_uv = (vec2(depth_texel) + 0.5) / vec2(depth_extent);
        scene_distance = length(reconstruct_world_position(frame, depth_uv, depth) - origin);
    }

    float altitude = origin.y + frame.origin.y;
    float start;
    float end;
    cloud_distance = 0.0;
    if (!cloud_interval(root, altitude, direction.y, start, end) || min(end, scene_distance) <= start) {
        return vec4(0.0, 0.0, 0.0, 1.0);
    }
    end = min(end, scene_distance);

    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    bool atmosphere = frame.sky_fog != 0ul && (sky.flags & SKY_FOG_ATMOSPHERE) != 0u;
    vec3 ambient = frame.ambient.rgb;
    if (atmosphere) ambient = sky_view_radiance(sky, vec3(0.0, 1.0, 0.0), false) * sky.sun_illuminance.rgb;

    vec3 to_sun = root.sun_direction.xyz;
    float cos_view_sun = dot(direction, to_sun);
    float step_length = (end - start) / float(CLOUD_STEPS);
    float jitter = interleaved_gradient_noise(vec2(pixel), 0u);
#ifdef TEMPORAL
    jitter = fract(jitter + frame_jitter);
#endif
    vec3 scattered = vec3(0.0);
    float transmittance = 1.0;
    float weighted_distance = 0.0;
    float weight_sum = 0.0;
    for (uint step = 0u; step < CLOUD_STEPS; step++) {
        float along = start + (float(step) + jitter) * step_length;
        float sample_altitude = cloud_altitude_along(root.planet_radius, altitude, direction.y, along);
        vec2 horizontal = (origin + direction * along).xz + frame.origin.xz;
        float extinction = cloud_density(root, horizontal, sample_altitude, true);
        if (extinction <= 0.0) continue;

        vec3 up = root.planet_radius == 0.0
            ? vec3(0.0, 1.0, 0.0)
            : normalize(vec3(0.0, root.planet_radius + altitude, 0.0) + direction * along);
        float sun_up = dot(to_sun, up);
        vec3 sunlight = root.sun_illuminance.rgb;
        if (atmosphere) sunlight *= sky_transmittance(sky, max(sample_altitude, 0.0), sun_up);
        float optical_depth = cloud_light_depth(root, horizontal, sample_altitude, sun_up);
        float powder = 1.0 - CLOUD_POWDER * exp(-extinction * CLOUD_POWDER_LENGTH);
        float fraction = clamp((sample_altitude - root.bottom) / (root.top - root.bottom), 0.0, 1.0);
        vec3 source = root.albedo * (
            sunlight * (cloud_sun_energy(optical_depth, cos_view_sun, root.anisotropy) * powder)
            + ambient * mix(CLOUD_AMBIENT_FLOOR, 1.0, fraction)
        );

        float step_transmittance = exp(-extinction * step_length);
        float weight = transmittance * (1.0 - step_transmittance);
        scattered += source * weight;
        weighted_distance += along * weight;
        weight_sum += weight;
        transmittance *= step_transmittance;
        if (transmittance < CLOUD_MIN_TRANSMITTANCE) break;
    }
    cloud_distance = weight_sum > 0.0 ? weighted_distance / weight_sum : 0.0;
    return vec4(scattered, transmittance);
}

#ifdef TEMPORAL
const uint CLOUD_TILE = CLOUD_TEMPORAL_GROUP + 2u;
const uint CLOUD_TILE_CELLS = CLOUD_TILE * CLOUD_TILE;
const uint CLOUD_GROUP_CELLS = CLOUD_TEMPORAL_GROUP * CLOUD_TEMPORAL_GROUP;

shared vec4 tile_cloud[CLOUD_TILE_CELLS];
shared float tile_distance[CLOUD_TILE_CELLS];

vec4 cloud_history_tap(CloudsTemporalRoot temporal, vec2 uv) {
    return sample_texture_2d(temporal.history, temporal.history_sampler, uv);
}

// Jimenez 2016: a Catmull-Rom filter from five bilinear taps, corners dropped. Wind and camera shift the history a
// fraction of a texel every frame, and a bilinear read blurs it more with each.
vec4 cloud_history_sample(CloudsTemporalRoot temporal, vec2 uv, vec2 size) {
    vec2 position = uv * size;
    vec2 center = floor(position - 0.5) + 0.5;
    vec2 fraction = position - center;
    vec2 weight_0 = fraction * (-0.5 + fraction * (1.0 - 0.5 * fraction));
    vec2 weight_1 = 1.0 + fraction * fraction * (-2.5 + 1.5 * fraction);
    vec2 weight_2 = fraction * (0.5 + fraction * (2.0 - 1.5 * fraction));
    vec2 weight_3 = fraction * fraction * (-0.5 + 0.5 * fraction);
    vec2 weight_12 = weight_1 + weight_2;
    vec2 uv_0 = (center - 1.0) / size;
    vec2 uv_3 = (center + 2.0) / size;
    vec2 uv_12 = (center + weight_2 / weight_12) / size;

    vec4 sum = cloud_history_tap(temporal, vec2(uv_12.x, uv_0.y)) * (weight_12.x * weight_0.y)
        + cloud_history_tap(temporal, vec2(uv_0.x, uv_12.y)) * (weight_0.x * weight_12.y)
        + cloud_history_tap(temporal, uv_12) * (weight_12.x * weight_12.y)
        + cloud_history_tap(temporal, vec2(uv_3.x, uv_12.y)) * (weight_3.x * weight_12.y)
        + cloud_history_tap(temporal, vec2(uv_12.x, uv_3.y)) * (weight_12.x * weight_3.y);
    float total = weight_12.x * weight_0.y + weight_0.x * weight_12.y + weight_12.x * weight_12.y
        + weight_3.x * weight_12.y + weight_12.x * weight_3.y;
    return sum / total;
}

// Where a pixel's cloud was in the previous frame, as a texture coordinate; z is 0 outside the previous view. A cloud
// comes from where the wind had it, a pixel without one from its direction at infinity.
vec3 cloud_history_uv(CloudsTemporalRoot temporal, vec3 origin, vec3 direction, float cloud_distance) {
    vec4 clip = cloud_distance > 0.0
        ? temporal.previous_view_proj * vec4(origin + direction * cloud_distance - temporal.wind_delta.xyz, 1.0)
        : temporal.previous_view_proj * vec4(direction, 0.0);
    if (clip.w <= 0.0) return vec3(0.0);

    vec2 ndc = clip.xy / clip.w;
    vec2 uv = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    bool inside = all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
    return vec3(uv, inside ? 1.0 : 0.0);
}

// A group marches its pixels and a border of one around them, so every pixel can clamp its reprojected history to the
// range of its 3 x 3 neighbours' current radiance before the blend. The history belongs to the pixel's centre, which
// the reprojection starts from, while the march takes the frame's offset ray.
void main() {
    CloudsTemporalRoot temporal = CloudsTemporalRoot(pc.root_gpu);
    CloudsRoot root = CloudsRoot(temporal.clouds);
    FrameRoot frame = FrameRoot(root.frame);
    ivec2 extent = ivec2(root.width, root.height);
    // An orthographic view has no camera position to reproject a distant direction from: no jitter, no history.
    bool perspective = frame.proj[3][3] == 0.0;
    bool reproject = temporal.history != 0u && perspective;
    float jitter = perspective ? temporal.jitter : 0.0;
    vec2 pixel_offset = perspective ? vec2(temporal.pixel_jitter_x, temporal.pixel_jitter_y) : vec2(0.0);

    ivec2 tile_origin = ivec2(gl_WorkGroupID.xy) * int(CLOUD_TEMPORAL_GROUP) - 1;
    for (uint cell = gl_LocalInvocationIndex; cell < CLOUD_TILE_CELLS; cell += CLOUD_GROUP_CELLS) {
        ivec2 offset = ivec2(cell % CLOUD_TILE, cell / CLOUD_TILE);
        bool border = any(equal(offset, ivec2(0))) || any(equal(offset, ivec2(int(CLOUD_TILE) - 1)));
        if (border && !reproject) continue;

        float cell_distance;
        ivec2 cell_pixel = clamp(tile_origin + offset, ivec2(0), extent - 1);
        tile_cloud[cell] = march_clouds(root, cell_pixel, jitter, pixel_offset, cell_distance);
        tile_distance[cell] = cell_distance;
    }
    barrier();

    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= extent.x || pixel.y >= extent.y) return;

    uint own = (gl_LocalInvocationID.y + 1u) * CLOUD_TILE + gl_LocalInvocationID.x + 1u;
    vec4 cloud = tile_cloud[own];
    float cloud_distance = tile_distance[own];
    if (reproject) {
        vec3 origin;
        vec3 direction;
        fog_pixel_ray(frame, (vec2(pixel) + 0.5) / vec2(extent), origin, direction);
        vec3 history_uv = cloud_history_uv(temporal, origin, direction, cloud_distance);
        if (history_uv.z > 0.0) {
            vec4 history = cloud_history_sample(temporal, history_uv.xy, vec2(extent));
            history.rgb *= temporal.pre_exposure_ratio;
            vec4 lowest = cloud;
            vec4 highest = cloud;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    vec4 neighbour = tile_cloud[int(own) + y * int(CLOUD_TILE) + x];
                    lowest = min(lowest, neighbour);
                    highest = max(highest, neighbour);
                }
            }
            cloud = mix(cloud, clamp(history, lowest, highest), CLOUD_HISTORY_WEIGHT);

            ivec2 history_texel = min(ivec2(history_uv.xy * vec2(extent)), extent - 1);
            float history_distance = fetch_texture_2d(temporal.history_distance, history_texel).r;
            if (history_distance > 0.0) {
                cloud_distance = cloud_distance > 0.0
                    ? mix(cloud_distance, history_distance, CLOUD_HISTORY_WEIGHT)
                    : history_distance;
            }
        }
    }
    store_clouds(root, pixel, cloud.rgb, cloud.a, cloud_distance);
}
#else
void main() {
    CloudsRoot root = CloudsRoot(pc.root_gpu);
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(root.width) || pixel.y >= int(root.height)) return;

    float cloud_distance;
    vec4 cloud = march_clouds(root, pixel, 0.0, vec2(0.0), cloud_distance);
    store_clouds(root, pixel, cloud.rgb, cloud.a, cloud_distance);
}
#endif
