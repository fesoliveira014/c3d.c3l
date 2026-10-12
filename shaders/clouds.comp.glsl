#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"
#include "ambient_occlusion.glsl"
#include "fog.glsl"
#include "noise.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float CLOUD_MAX_MARCH = 60000.0;       // metres of deck one ray marches from its entry; the air hides the rest
const float CLOUD_MIN_TRANSMITTANCE = 0.02;  // a ray this dark adds under 2 % of its radiance by marching on
const float CLOUD_PARALLEL_LIMIT = 1e-4;     // vertical cosine under which a ray runs parallel to a slab
const float CLOUD_DETAIL_FREQUENCY = 8.0;    // erosion repeats this many times per base repeat
const float CLOUD_EROSION_REACH = 0.5;       // share of a cloud's body the strongest erosion can carve away
const float CLOUD_BASE_RAMP = 0.1;           // share of the layer over which density rises from its bottom
const float CLOUD_TOP_ROUNDING = 0.4;        // share of a cloud's height over which it thins toward its top
const float CLOUD_BACK_LOBE_SHARE = 0.3;     // fixed blend of the back lobe into the phase function
const float CLOUD_POWDER = 0.5;              // darkening of the thinnest fringe, as a share of its radiance
const float CLOUD_POWDER_LENGTH = 400.0;     // metres of path over which a fringe still reads as thin
const float CLOUD_AMBIENT_FLOOR = 0.4;       // share of the sky light that reaches the bottom of the layer
const float CLOUD_SUN_FLOOR = 0.1;           // lowest sun cosine the light march divides by
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

// Extinction per metre at a point of the layer; the light march skips the detail octave.
float cloud_density(CloudsRoot root, vec2 horizontal, float altitude, bool detailed) {
    float fraction = (altitude - root.bottom) / (root.top - root.bottom);
    if (fraction <= 0.0 || fraction >= 1.0) return 0.0;

    vec2 weather = vec2(1.0);
    if (root.coverage != 0u) {
        weather = sample_texture_2d(
            root.coverage,
            root.coverage_sampler,
            (horizontal - root.wind_offset.xz) / root.coverage_extent
        ).rg;
    }
    float cover = weather.x;
    float profile = clamp(fraction / CLOUD_BASE_RAMP, 0.0, 1.0)
        * clamp((weather.y - fraction) / (CLOUD_TOP_ROUNDING * weather.y + 1e-4), 0.0, 1.0);
    if (cover <= 0.0 || profile <= 0.0) return 0.0;

    vec3 coordinate = vec3(
        horizontal.x - root.wind_offset.x,
        altitude - root.wind_offset.y,
        horizontal.y - root.wind_offset.z
    ) / root.noise_scale;
    vec4 shape = sample_texture_3d(root.noise, root.noise_sampler, coordinate);
    float low_frequency = dot(shape.gba, vec3(0.625, 0.25, 0.125));
    float base = clamp((shape.r - (low_frequency - 1.0)) / (2.0 - low_frequency), 0.0, 1.0);
    float body = clamp((base * profile - (1.0 - cover)) / cover, 0.0, 1.0) * cover;
    if (detailed && body > 0.0) {
        vec4 detail = sample_texture_3d(root.noise, root.noise_sampler, coordinate * CLOUD_DETAIL_FREQUENCY);
        float threshold = root.erosion * CLOUD_EROSION_REACH * dot(detail.gba, vec3(0.625, 0.25, 0.125));
        body = clamp((body - threshold) / (1.0 - threshold), 0.0, 1.0);
    }
    return root.density * body;
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
// scene depth the pixel samples.
void main() {
    CloudsRoot root = CloudsRoot(pc.root_gpu);
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(root.width) || pixel.y >= int(root.height)) return;

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 extent = ivec2(root.width, root.height);
    vec2 uv = (vec2(pixel) + 0.5) / vec2(extent);
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
    if (!cloud_interval(root, altitude, direction.y, start, end) || min(end, scene_distance) <= start) {
        store_clouds(root, pixel, vec3(0.0), 1.0, 0.0);
        return;
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
    store_clouds(root, pixel, scattered, transmittance, weight_sum > 0.0 ? weighted_distance / weight_sum : 0.0);
}
