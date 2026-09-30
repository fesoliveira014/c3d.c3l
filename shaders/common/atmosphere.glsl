#ifndef C3D_ATMOSPHERE_GLSL
#define C3D_ATMOSPHERE_GLSL

#include "descriptor_heap.glsl"
#include "constants.glsl"

const uint SKY_TRANSMITTANCE_STEPS = 64u;        // mirrored as ATMOSPHERE_TRANSMITTANCE_STEPS in atmosphere.c3
const uint SKY_SCATTERING_STEPS = 32u;           // per sky-view and cube texel; the per-view table's cost lever
const uint SKY_MULTI_SCATTERING_DIRECTIONS = 64u; // 8 x 8 stratified; a lower count shows as noise in the table
const uint SKY_MULTI_SCATTERING_STEPS = 20u;
const uint AERIAL_PERSPECTIVE_STEPS_PER_SLICE = 2u; // the last slice marches 64 steps over 128 km
const float SKY_SUN_DISC_LIMIT = 60000.0;        // below RGBA16F's 65504; a brighter sun saturates its disc

struct AtmosphereMedium {
    vec3 rayleigh;
    float mie;
    vec3 extinction;
};

struct SkyScattering {
    vec3 luminance;
    vec3 transmittance;
    vec3 multi_scattering;
};

AtmosphereMedium atmosphere_medium(SkyFogGpu sky, float altitude) {
    float rayleigh_density = exp(-altitude / sky.rayleigh_scattering_height.w);
    float mie_density = exp(-altitude / sky.mie.z);
    float ozone_offset = abs(altitude - sky.ozone_absorption_center.w);
    float ozone_density = max(0.0, 1.0 - ozone_offset / sky.ground_albedo_ozone_width.w);
    AtmosphereMedium medium;
    medium.rayleigh = sky.rayleigh_scattering_height.rgb * rayleigh_density;
    medium.mie = sky.mie.x * mie_density;
    medium.extinction = medium.rayleigh + (sky.mie.x + sky.mie.y) * mie_density
        + sky.ozone_absorption_center.rgb * ozone_density;
    return medium;
}

float rayleigh_phase(float cos_angle) {
    return 3.0 / (16.0 * PI) * (1.0 + cos_angle * cos_angle);
}

// Cornette-Shanks.
float mie_phase(float anisotropy, float cos_angle) {
    float squared = anisotropy * anisotropy;
    float denominator = 1.0 + squared - 2.0 * anisotropy * cos_angle;
    return 3.0 / (8.0 * PI) * (1.0 - squared) * (1.0 + cos_angle * cos_angle)
        / ((2.0 + squared) * denominator * sqrt(denominator));
}

// Squares of radii near 6.4e6 m lose metres to float rounding; these forms keep altitude-sized terms apart.
float atmosphere_ground_discriminant(SkyFogGpu sky, float altitude, float cos_zenith) {
    float radius = sky.planet_radius + altitude;
    return radius * radius * cos_zenith * cos_zenith - altitude * (2.0 * sky.planet_radius + altitude);
}

bool atmosphere_ray_meets_ground(SkyFogGpu sky, float altitude, float cos_zenith) {
    return cos_zenith < 0.0 && atmosphere_ground_discriminant(sky, altitude, cos_zenith) >= 0.0;
}

float atmosphere_distance_to_ground(SkyFogGpu sky, float altitude, float cos_zenith) {
    float radius = sky.planet_radius + altitude;
    return -radius * cos_zenith - sqrt(max(atmosphere_ground_discriminant(sky, altitude, cos_zenith), 0.0));
}

float atmosphere_distance_to_top(SkyFogGpu sky, float altitude, float cos_zenith) {
    float radius = sky.planet_radius + altitude;
    float height = sky.top_radius - sky.planet_radius;
    float discriminant = radius * radius * cos_zenith * cos_zenith
        + (height - altitude) * (sky.top_radius + radius);
    return -radius * cos_zenith + sqrt(max(discriminant, 0.0));
}

// Altitude after travelling a distance from a start altitude along a direction of the cosine.
float atmosphere_altitude_along(SkyFogGpu sky, float altitude, float cos_zenith, float distance) {
    float radius = sky.planet_radius + altitude;
    float lift = altitude * (2.0 * sky.planet_radius + altitude) + distance * distance
        + 2.0 * radius * cos_zenith * distance;
    float reached = sqrt(max(radius * radius + distance * distance + 2.0 * radius * cos_zenith * distance, 0.0));
    return lift / (reached + sky.planet_radius);
}

float sky_unit_to_uv(float unit, float size) {
    return 0.5 / size + unit * (1.0 - 1.0 / size);
}

float sky_uv_to_unit(float uv, float size) {
    return (uv - 0.5 / size) / (1.0 - 1.0 / size);
}

// Bruneton 2017: rays that stay above the ground, dense at the horizon.
vec2 transmittance_uv(SkyFogGpu sky, float altitude, float cos_zenith) {
    float horizon = sqrt((sky.top_radius - sky.planet_radius) * (sky.top_radius + sky.planet_radius));
    float rho = sqrt(max(altitude * (2.0 * sky.planet_radius + altitude), 0.0));
    float distance = atmosphere_distance_to_top(sky, altitude, cos_zenith);
    float distance_min = sky.top_radius - sky.planet_radius - altitude;
    float distance_max = rho + horizon;
    float unit_zenith = (distance - distance_min) / max(distance_max - distance_min, 1e-3);
    return vec2(
        sky_unit_to_uv(clamp(unit_zenith, 0.0, 1.0), float(SKY_TRANSMITTANCE_WIDTH)),
        sky_unit_to_uv(clamp(rho / horizon, 0.0, 1.0), float(SKY_TRANSMITTANCE_HEIGHT))
    );
}

void transmittance_parameters(SkyFogGpu sky, vec2 uv, out float altitude, out float cos_zenith) {
    float unit_zenith = sky_uv_to_unit(uv.x, float(SKY_TRANSMITTANCE_WIDTH));
    float unit_height = sky_uv_to_unit(uv.y, float(SKY_TRANSMITTANCE_HEIGHT));
    float horizon = sqrt((sky.top_radius - sky.planet_radius) * (sky.top_radius + sky.planet_radius));
    float rho = horizon * unit_height;
    float radius = sqrt(rho * rho + sky.planet_radius * sky.planet_radius);
    altitude = rho * rho / (radius + sky.planet_radius);
    float distance_min = sky.top_radius - radius;
    float distance_max = rho + horizon;
    float distance = distance_min + unit_zenith * (distance_max - distance_min);
    cos_zenith = distance == 0.0
        ? 1.0
        : (horizon * horizon - rho * rho - distance * distance) / (2.0 * radius * distance);
    cos_zenith = clamp(cos_zenith, -1.0, 1.0);
}

// Zero where the ray meets the ground; the table holds only rays that miss it.
vec3 sky_transmittance(SkyFogGpu sky, float altitude, float cos_zenith) {
    if (atmosphere_ray_meets_ground(sky, altitude, cos_zenith)) return vec3(0.0);
    vec2 uv = transmittance_uv(sky, altitude, cos_zenith);
    return sample_texture_2d(sky.transmittance_lut, sky.lut_sampler, uv).rgb;
}

vec3 sky_multi_scattering(SkyFogGpu sky, float altitude, float cos_sun) {
    vec2 unit = vec2(cos_sun * 0.5 + 0.5, altitude / (sky.top_radius - sky.planet_radius));
    vec2 uv = vec2(
        sky_unit_to_uv(clamp(unit.x, 0.0, 1.0), float(SKY_MULTI_SCATTERING_SIZE)),
        sky_unit_to_uv(clamp(unit.y, 0.0, 1.0), float(SKY_MULTI_SCATTERING_SIZE))
    );
    return sample_texture_2d(sky.multi_scattering_lut, sky.lut_sampler, uv).rgb;
}

// Luminance for unit sun illuminance along a ray from an altitude, the local up being +y.
// multi_scattering_table: the second-order pass of the table, with isotropic phase and no table lookup.
SkyScattering integrate_sky_scattering(
    SkyFogGpu sky,
    float altitude,
    vec3 direction,
    vec3 sun_direction,
    float max_distance,
    uint steps,
    bool lit_ground,
    bool multi_scattering_table
) {
    SkyScattering result;
    result.luminance = vec3(0.0);
    result.transmittance = vec3(1.0);
    result.multi_scattering = vec3(0.0);

    float cos_zenith = direction.y;
    bool ground = atmosphere_ray_meets_ground(sky, altitude, cos_zenith);
    float ray_length = ground
        ? atmosphere_distance_to_ground(sky, altitude, cos_zenith)
        : atmosphere_distance_to_top(sky, altitude, cos_zenith);
    bool reaches_end = max_distance < 0.0 || max_distance >= ray_length;
    if (!reaches_end) ray_length = max_distance;
    ray_length = max(ray_length, 0.0);

    float cos_angle = dot(direction, sun_direction);
    float isotropic = 1.0 / (4.0 * PI);
    float rayleigh = multi_scattering_table ? isotropic : rayleigh_phase(cos_angle);
    float mie = multi_scattering_table ? isotropic : mie_phase(sky.mie.w, cos_angle);
    float step = ray_length / float(steps);
    vec3 start = vec3(0.0, sky.planet_radius + altitude, 0.0);
    for (uint index = 0u; index < steps; index++) {
        float along = (float(index) + 0.5) * step;
        vec3 position = start + direction * along;
        float sample_altitude = atmosphere_altitude_along(sky, altitude, cos_zenith, along);
        vec3 up = normalize(position);
        float cos_sun = dot(up, sun_direction);
        AtmosphereMedium medium = atmosphere_medium(sky, sample_altitude);
        vec3 scattering = medium.rayleigh + vec3(medium.mie);
        vec3 step_transmittance = exp(-medium.extinction * step);
        vec3 sunlight = sky_transmittance(sky, sample_altitude, cos_sun);
        vec3 source = sunlight * (medium.rayleigh * rayleigh + vec3(medium.mie * mie));
        if (!multi_scattering_table) source += sky_multi_scattering(sky, sample_altitude, cos_sun) * scattering;
        vec3 safe_extinction = max(medium.extinction, vec3(1e-12));
        vec3 kept = (vec3(1.0) - step_transmittance) / safe_extinction;
        result.luminance += result.transmittance * source * kept;
        result.multi_scattering += result.transmittance * scattering * kept;
        result.transmittance *= step_transmittance;
    }
    if (ground && reaches_end && lit_ground) {
        vec3 up = normalize(start + direction * ray_length);
        float cos_sun = dot(up, sun_direction);
        vec3 sunlight = sky_transmittance(sky, 0.0, cos_sun);
        result.luminance += result.transmittance * sunlight * max(cos_sun, 0.0)
            * sky.ground_albedo_ozone_width.rgb / PI;
    }
    return result;
}

// Hillaire 2020 sky-view mapping: azimuth from the sun, elevation dense at the horizon.
vec2 sky_view_uv(SkyFogGpu sky, float cos_zenith, float cos_azimuth, bool ground) {
    float altitude = sky.camera_altitude;
    float radius = sky.planet_radius + altitude;
    float rho = sqrt(max(altitude * (2.0 * sky.planet_radius + altitude), 0.0));
    float beta = acos(clamp(rho / radius, -1.0, 1.0));
    float horizon_angle = PI - beta;
    float zenith_angle = acos(clamp(cos_zenith, -1.0, 1.0));
    float v;
    if (!ground) {
        float coordinate = 1.0 - sqrt(max(1.0 - zenith_angle / horizon_angle, 0.0));
        v = coordinate * 0.5;
    } else {
        float coordinate = sqrt(max((zenith_angle - horizon_angle) / beta, 0.0));
        v = coordinate * 0.5 + 0.5;
    }
    float u = sqrt(clamp(-cos_azimuth * 0.5 + 0.5, 0.0, 1.0));
    return vec2(
        sky_unit_to_uv(clamp(u, 0.0, 1.0), float(SKY_VIEW_WIDTH)),
        sky_unit_to_uv(clamp(v, 0.0, 1.0), float(SKY_VIEW_HEIGHT))
    );
}

void sky_view_parameters(SkyFogGpu sky, vec2 uv, out float cos_zenith, out float cos_azimuth) {
    float u = sky_uv_to_unit(uv.x, float(SKY_VIEW_WIDTH));
    float v = sky_uv_to_unit(uv.y, float(SKY_VIEW_HEIGHT));
    float altitude = sky.camera_altitude;
    float radius = sky.planet_radius + altitude;
    float rho = sqrt(max(altitude * (2.0 * sky.planet_radius + altitude), 0.0));
    float beta = acos(clamp(rho / radius, -1.0, 1.0));
    float horizon_angle = PI - beta;
    if (v < 0.5) {
        float coordinate = 1.0 - 2.0 * v;
        coordinate = 1.0 - coordinate * coordinate;
        cos_zenith = cos(horizon_angle * coordinate);
    } else {
        float coordinate = 2.0 * v - 1.0;
        cos_zenith = cos(horizon_angle + beta * coordinate * coordinate);
    }
    cos_azimuth = -(u * u * 2.0 - 1.0);
}

// Cosine of the view's azimuth from the sun about the vertical; 1 where either is vertical.
float sky_cos_azimuth(vec3 direction, vec3 sun_direction) {
    vec2 view_flat = direction.xz;
    vec2 sun_flat = sun_direction.xz;
    float lengths = length(view_flat) * length(sun_flat);
    return lengths > 0.0 ? clamp(dot(view_flat, sun_flat) / lengths, -1.0, 1.0) : 1.0;
}

// Sky luminance for unit sun illuminance; horizon_clamped reads below-horizon views at the horizon.
vec3 sky_view_radiance(SkyFogGpu sky, vec3 direction, bool horizon_clamped) {
    float altitude = sky.camera_altitude;
    float cos_zenith = direction.y;
    float cos_horizon = -sqrt(max(altitude * (2.0 * sky.planet_radius + altitude), 0.0))
        / (sky.planet_radius + altitude);
    bool ground = atmosphere_ray_meets_ground(sky, altitude, cos_zenith);
    if (horizon_clamped && ground) {
        cos_zenith = cos_horizon;
        ground = false;
    }
    float cos_azimuth = sky_cos_azimuth(direction, sky.sun_direction_cos_radius.xyz);
    vec2 uv = sky_view_uv(sky, cos_zenith, cos_azimuth, ground);
    return sample_texture_2d(sky.sky_view_lut, sky.lut_sampler, uv).rgb;
}

// The sun disc above the horizon, through the atmosphere, for unit illuminance.
vec3 sky_sun_disc(SkyFogGpu sky, vec3 direction) {
    float cos_radius = sky.sun_direction_cos_radius.w;
    if (dot(direction, sky.sun_direction_cos_radius.xyz) < cos_radius) return vec3(0.0);
    float solid_angle = 2.0 * PI * (1.0 - cos_radius);
    return sky_transmittance(sky, sky.camera_altitude, direction.y) / solid_angle;
}

// Aerial perspective at a distance along a pixel's ray: in-scattering for unit illuminance and mean transmittance.
// Slices are squared toward the camera; nearer than the first slice's centre the value fades linearly to zero.
vec4 sky_aerial_perspective(SkyFogGpu sky, vec2 uv, float distance) {
    float first = 0.5 / float(AERIAL_PERSPECTIVE_SIZE);
    float w = sqrt(max(distance, 0.0) / sky.aerial_perspective_distance);
    float weight = 1.0;
    if (w < first) {
        weight = (w / first) * (w / first);
        w = first;
    }
    vec4 table = sample_texture_3d(sky.aerial_perspective_lut, sky.lut_sampler, vec3(uv, w)) * weight;
    return vec4(table.rgb, 1.0 - table.a);
}

#endif
