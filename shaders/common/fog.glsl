#ifndef C3D_FOG_GLSL
#define C3D_FOG_GLSL

#include "descriptor_heap.glsl"
#include "constants.glsl"
#include "gbuffer.glsl"
#include "irradiance.glsl"
#include "atmosphere.glsl"

const float FOG_SERIES_THRESHOLD = 1e-2; // mirrored as FOG_SERIES_THRESHOLD in height_fog.c3
const float FOG_TRANSMITTANCE_FLOOR = 1e-4; // divides a segment's aerial perspective; below it the segment reads opaque

// Radiance x seen through the fog is x * transmittance + inscatter.
struct FogTerms {
    vec3 transmittance;
    vec3 inscatter;
};

FogTerms fog_none() {
    FogTerms terms;
    terms.transmittance = vec3(1.0);
    terms.inscatter = vec3(0.0);
    return terms;
}

// Mirrored as fog_rise_factor in height_fog.c3.
float fog_rise_factor(float rise) {
    if (abs(rise) < FOG_SERIES_THRESHOLD) return 1.0 - rise * 0.5 + rise * rise / 6.0;
    return (1.0 - exp(-rise)) / rise;
}

float height_fog_density(SkyFogGpu sky, vec3 position) {
    return sky.fog_albedo_density.w * exp(-sky.fog_falloff * (position.y - sky.fog_base_height));
}

// Mirrored as height_fog_optical_depth in height_fog.c3.
float height_fog_optical_depth(SkyFogGpu sky, vec3 origin, vec3 direction, float distance) {
    return height_fog_density(sky, origin) * distance * fog_rise_factor(sky.fog_falloff * direction.y * distance);
}

// Mirrored as height_fog_limit_transmittance in height_fog.c3.
float height_fog_limit_transmittance(SkyFogGpu sky, vec3 origin, vec3 direction) {
    float density = height_fog_density(sky, origin);
    float rise = sky.fog_falloff * direction.y;
    if (rise > 0.0) return exp(-density / rise);
    return density > 0.0 ? 0.0 : 1.0;
}

// Light the fog scatters from the lighting environment, else the ambient; the volume adds its sun to it.
vec3 fog_ambient_color(FrameRoot frame, SkyFogGpu sky, vec3 direction) {
    vec3 albedo = sky.fog_albedo_density.rgb;
    if (frame.environment != 0ul) {
        EnvironmentGpu environment = EnvironmentGpu(frame.environment);
        vec3 rotated = vec3(
            dot(environment.rotation.row0.xyz, direction),
            dot(environment.rotation.row1.xyz, direction),
            dot(environment.rotation.row2.xyz, direction)
        );
        return albedo * environment_irradiance(environment.sh, rotated) * environment.intensity / PI;
    }
    return albedo * frame.ambient.rgb;
}

// Light the fog scatters toward the viewer: the sky at the view direction, else the environment, else ambient.
vec3 fog_inscatter_color(FrameRoot frame, SkyFogGpu sky, vec3 direction) {
    if ((sky.flags & SKY_FOG_ATMOSPHERE) != 0u) {
        return sky.fog_albedo_density.rgb * sky_view_radiance(sky, direction, true) * sky.sun_illuminance.rgb;
    }
    return fog_ambient_color(frame, sky, direction);
}

// The camera ray a world position lies on: its origin, unit direction and the distance along it.
void fog_view_ray(FrameRoot frame, vec3 position, out vec3 origin, out vec3 direction, out float distance) {
    if (frame.proj[3][3] != 0.0) {
        direction = -normalize(vec3(frame.view[0][2], frame.view[1][2], frame.view[2][2]));
        distance = dot(position - frame.camera_position.xyz, direction);
        origin = position - direction * distance;
        return;
    }
    vec3 offset = position - frame.camera_position.xyz;
    distance = length(offset);
    direction = distance > 0.0 ? offset / distance : vec3(0.0, 0.0, -1.0);
    origin = frame.camera_position.xyz;
}

// The camera ray through a pixel; uv has its origin at the top left.
void fog_pixel_ray(FrameRoot frame, vec2 uv, out vec3 origin, out vec3 direction) {
    if (frame.proj[3][3] != 0.0) {
        origin = reconstruct_world_position(frame, uv, 1.0);
        vec3 far_point = reconstruct_world_position(frame, uv, 0.25);
        direction = normalize(far_point - reconstruct_world_position(frame, uv, 0.75));
        return;
    }
    origin = frame.camera_position.xyz;
    direction = normalize(reconstruct_world_position(frame, uv, 0.5) - origin);
}

// Where a clipped view's ray enters the kept half-space: a mirror view fogs only the path behind its plane.
float fog_clip_start(FrameRoot frame, vec3 origin, vec3 direction) {
    if ((frame.flags & FRAME_CLIP_PLANE) == 0u) return 0.0;
    float side = dot(frame.clip_plane.xyz, origin) + frame.clip_plane.w;
    if (side >= 0.0) return 0.0;
    float rate = dot(frame.clip_plane.xyz, direction);
    return rate > 0.0 ? -side / rate : BACKGROUND_VIEW_DISTANCE;
}

vec2 fog_screen_uv(FrameRoot frame, vec3 position) {
    vec4 clip = frame.view_proj * vec4(position, 1.0);
    vec2 ndc = clip.xy / clip.w;
    return vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
}

// Height fog over [near, far] of a ray, in front of whatever lies beyond far.
FogTerms height_fog_segment(FrameRoot frame, SkyFogGpu sky, vec3 origin, vec3 direction, float near, float far) {
    FogTerms terms = fog_none();
    if ((sky.flags & SKY_FOG_HEIGHT_FOG) == 0u) return terms;
    float transmittance = exp(-height_fog_optical_depth(sky, origin + direction * near, direction, far - near));
    terms.transmittance = vec3(transmittance);
    terms.inscatter = fog_inscatter_color(frame, sky, direction) * (1.0 - transmittance);
    return terms;
}

// Height fog from a point to infinity: what a background pixel takes.
FogTerms height_fog_to_infinity(FrameRoot frame, SkyFogGpu sky, vec3 origin, vec3 direction) {
    FogTerms terms = fog_none();
    if ((sky.flags & SKY_FOG_HEIGHT_FOG) == 0u) return terms;
    float transmittance = height_fog_limit_transmittance(sky, origin, direction);
    terms.transmittance = vec3(transmittance);
    terms.inscatter = fog_inscatter_color(frame, sky, direction) * (1.0 - transmittance);
    return terms;
}

// Aerial perspective over a pixel's ray up to a distance, for the sun's illuminance.
FogTerms aerial_perspective_terms(SkyFogGpu sky, vec2 uv, float distance) {
    FogTerms terms = fog_none();
    if ((sky.flags & SKY_FOG_ATMOSPHERE) == 0u) return terms;
    vec4 table = sky_aerial_perspective(sky, uv, distance);
    terms.transmittance = vec3(table.a);
    terms.inscatter = table.rgb * sky.sun_illuminance.rgb;
    return terms;
}

// far in front of near: the far medium's result is seen through the near one.
FogTerms fog_compose(FogTerms near, FogTerms far) {
    FogTerms terms;
    terms.transmittance = far.transmittance * near.transmittance;
    terms.inscatter = far.inscatter * near.transmittance + near.inscatter;
    return terms;
}

// The medium between near and far, from its values from the camera to each.
FogTerms fog_between(FogTerms to_near, FogTerms to_far) {
    vec3 near_transmittance = max(to_near.transmittance, vec3(FOG_TRANSMITTANCE_FLOOR));
    FogTerms terms;
    terms.transmittance = to_far.transmittance / near_transmittance;
    terms.inscatter = (to_far.inscatter - to_near.inscatter) / near_transmittance;
    return terms;
}

// Aerial perspective over [near, far] of a pixel's ray: the camera's table divided by its value at near.
FogTerms aerial_perspective_segment(SkyFogGpu sky, vec2 uv, float near, float far) {
    FogTerms to_far = aerial_perspective_terms(sky, uv, far);
    if (near <= 0.0) return to_far;
    return fog_between(aerial_perspective_terms(sky, uv, near), to_far);
}

// Distance along a froxel ray to slice boundary k; slices are squared toward the camera.
float fog_slice_distance(SkyFogGpu sky, uint boundary) {
    float share = float(boundary) / float(FOG_VOLUME_SLICES);
    return share * share * sky.fog_max_distance;
}

// The volume from the camera to a distance along a pixel's ray; texel k holds the integral to boundary k + 1.
FogTerms fog_volume_terms(SkyFogGpu sky, vec2 uv, float distance) {
    float slice = sqrt(clamp(distance / sky.fog_max_distance, 0.0, 1.0)) * float(FOG_VOLUME_SLICES);
    float depth = (max(slice, 1.0) - 0.5) / float(FOG_VOLUME_SLICES);
    vec4 volume = sample_texture_3d(sky.fog_volume, sky.lut_sampler, vec3(uv, depth));
    float weight = min(slice, 1.0); // below the first boundary the volume grows linearly from the camera
    FogTerms terms;
    terms.transmittance = vec3(mix(1.0, volume.a, weight));
    terms.inscatter = volume.rgb * weight;
    return terms;
}

FogTerms fog_volume_segment(SkyFogGpu sky, vec2 uv, float near, float far) {
    FogTerms to_far = fog_volume_terms(sky, uv, far);
    if (near <= 0.0) return to_far;
    return fog_between(fog_volume_terms(sky, uv, near), to_far);
}

// Height fog over [near, far] of a pixel's ray: the volume up to its end, the analytic fog past it.
FogTerms height_fog_range(FrameRoot frame, SkyFogGpu sky, vec2 uv, vec3 origin, vec3 direction, float near, float far) {
    if (sky.fog_volume == 0u) return height_fog_segment(frame, sky, origin, direction, near, far);
    float end = sky.fog_max_distance;
    FogTerms volume = near < end ? fog_volume_segment(sky, uv, near, min(far, end)) : fog_none();
    FogTerms tail = far > end ? height_fog_segment(frame, sky, origin, direction, max(near, end), far) : fog_none();
    return fog_compose(volume, tail);
}

// Height fog from near along a pixel's ray to infinity: the volume up to its end, the analytic limit past it.
FogTerms height_fog_beyond(FrameRoot frame, SkyFogGpu sky, vec2 uv, vec3 origin, vec3 direction, float near) {
    if (sky.fog_volume == 0u) return height_fog_to_infinity(frame, sky, origin + direction * near, direction);
    float end = sky.fog_max_distance;
    FogTerms volume = near < end ? fog_volume_segment(sky, uv, near, end) : fog_none();
    return fog_compose(volume, height_fog_to_infinity(frame, sky, origin + direction * max(near, end), direction));
}

// Fog over [near, far] of a ray: aerial perspective behind the height fog.
FogTerms fog_segment(FrameRoot frame, SkyFogGpu sky, vec2 uv, vec3 origin, vec3 direction, float near, float far) {
    if (near >= far) return fog_none();
    return fog_compose(
        height_fog_range(frame, sky, uv, origin, direction, near, far),
        aerial_perspective_segment(sky, uv, near, far)
    );
}

// Fog between the camera, or a clipped view's plane, and a surface.
FogTerms fog_terms(FrameRoot frame, vec2 uv, vec3 position) {
    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    vec3 origin;
    vec3 direction;
    float distance;
    fog_view_ray(frame, position, origin, direction, distance);
    return fog_segment(frame, sky, uv, origin, direction, fog_clip_start(frame, origin, direction), distance);
}

// Fog in front of a background pixel: height fog to infinity, no aerial perspective.
FogTerms fog_background_terms(FrameRoot frame, vec2 uv) {
    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    vec3 origin;
    vec3 direction;
    fog_pixel_ray(frame, uv, origin, direction);
    float near = fog_clip_start(frame, origin, direction);
    if (near >= BACKGROUND_VIEW_DISTANCE) return fog_none();
    return height_fog_beyond(frame, sky, uv, origin, direction, near);
}

// Additive radiance adds no second in-scatter over the already-fogged background.
vec3 apply_material_fog(
    FrameRoot frame,
    vec3 world_position,
    vec3 color,
    uint material_flags
) {
    if (frame.sky_fog == 0ul) return color;
    FogTerms fog = fog_terms(frame, fog_screen_uv(frame, world_position), world_position);
    vec3 attenuated = color * fog.transmittance;
    return (material_flags & MATERIAL_BLEND_ADDITIVE) != 0u
        ? attenuated : attenuated + fog.inscatter;
}

// Fog a blended surface's radiance at its own position; the view's fog pass fogs everything else.
vec3 apply_fog(FrameRoot frame, vec3 world_position, vec3 color) {
    return apply_material_fog(frame, world_position, color, 0u);
}

// Fog between a surface and the scene behind it at a depth sample; depth 0 is the background.
vec3 fog_behind(FrameRoot frame, vec3 surface_position, vec3 behind, float behind_depth) {
    if (frame.sky_fog == 0ul) return behind;
    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    vec3 origin;
    vec3 direction;
    float near;
    fog_view_ray(frame, surface_position, origin, direction, near);
    if (behind_depth == 0.0) {
        vec2 uv = fog_screen_uv(frame, surface_position);
        FogTerms beyond = height_fog_beyond(frame, sky, uv, origin, direction, near);
        return behind * beyond.transmittance + beyond.inscatter;
    }
    vec3 forward = -normalize(vec3(frame.view[0][2], frame.view[1][2], frame.view[2][2]));
    float far = max(view_distance(frame, behind_depth) / max(dot(direction, forward), 1e-4), near);
    FogTerms segment = fog_segment(frame, sky, fog_screen_uv(frame, surface_position), origin, direction, near, far);
    return behind * segment.transmittance + segment.inscatter;
}

// A depth-writing refracting surface's output: transmittance * the refracted sample fogged to its own depth, plus the
// surface's own radiance. The view's fog pass then fogs the pixel from the camera to the surface, so the pixel reads
// t * fog(refracted, behind) + surface * T(surface) + (1 - t) * S(surface). A blended one wraps it in apply_fog.
vec3 apply_fog_refracted(
    FrameRoot frame,
    vec3 surface_position,
    vec3 transmittance,
    vec3 refracted,
    float refracted_depth,
    vec3 surface_radiance
) {
    return transmittance * fog_behind(frame, surface_position, refracted, refracted_depth) + surface_radiance;
}

#endif
