#ifndef C3D_MEDIUM_GLSL
#define C3D_MEDIUM_GLSL

const float MEDIUM_SUN_COSINE_FLOOR = 1e-4; // keeps a grazing sun's column finite, so a clear channel stays 1
const float MEDIUM_PARALLEL_EPSILON = 1e-9; // a ray this close to a box slab's plane never crosses it

// A world position in the box's frame, whose top face lies in the plane y = 0.
vec3 medium_local_position(MediumGpu medium, vec3 position) {
    return vec3(
        dot(medium.world_to_local_0.xyz, position) + medium.world_to_local_0.w,
        dot(medium.world_to_local_1.xyz, position) + medium.world_to_local_1.w,
        dot(medium.world_to_local_2.xyz, position) + medium.world_to_local_2.w
    );
}

// Where a ray enters and leaves a medium's box within [near, far]; the exit precedes the entry for a miss.
vec2 medium_span(MediumGpu medium, vec3 origin, vec3 direction, float near, float far) {
    vec3 box_origin = medium_local_position(medium, origin);
    vec3 box_direction = vec3(
        dot(medium.world_to_local_0.xyz, direction),
        dot(medium.world_to_local_1.xyz, direction),
        dot(medium.world_to_local_2.xyz, direction)
    );

    vec3 lower = -medium.extent_anisotropy.xyz;
    vec3 upper = vec3(medium.extent_anisotropy.x, 0.0, medium.extent_anisotropy.z);
    float enter = near;
    float leave = far;
    for (int axis = 0; axis < 3; axis++) {
        if (abs(box_direction[axis]) < MEDIUM_PARALLEL_EPSILON) {
            if (box_origin[axis] < lower[axis] || box_origin[axis] > upper[axis]) return vec2(far, near);
            continue;
        }
        float first = (lower[axis] - box_origin[axis]) / box_direction[axis];
        float second = (upper[axis] - box_origin[axis]) / box_direction[axis];
        enter = max(enter, min(first, second));
        leave = min(leave, max(first, second));
    }
    return vec2(enter, leave);
}

bool medium_contains(MediumGpu medium, vec3 position) {
    vec3 local = medium_local_position(medium, position);
    vec3 extent = medium.extent_anisotropy.xyz;
    return all(greaterThanEqual(local, -extent)) && all(lessThanEqual(local, vec3(extent.x, 0.0, extent.z)));
}

vec3 medium_up(MediumGpu medium) {
    return medium.world_to_local_1.xyz / length(medium.world_to_local_1.xyz);
}

// Metres from the box's top face down to a position, along the box's up.
float medium_below_top(MediumGpu medium, vec3 position) {
    vec4 height_row = medium.world_to_local_1;
    return -(dot(height_row.xyz, position) + height_row.w) / length(height_row.xyz);
}

// Extinction per metre of depth below the top face, stretched by the slant of the sun's path.
vec3 medium_sun_column(MediumGpu medium, float sun_cosine) {
    return (medium.absorption.xyz + medium.scattering.xyz) / max(sun_cosine, MEDIUM_SUN_COSINE_FLOOR);
}

// Share of the media's sun reaching a point per channel, through every kept box holding it.
vec3 medium_sun_transmittance(SkyFogGpu sky, vec3 position) {
    MediumSetGpu set = MediumSetGpu(sky.media);
    uint count = min(sky.media_count, MAX_VIEW_MEDIA);
    vec3 optical_depth = vec3(0.0);
    for (uint index = 0u; index < count; index++) {
        MediumGpu medium = set.media[index];
        if (!medium_contains(medium, position)) continue;

        float sun_cosine = dot(medium_up(medium), set.to_sun.xyz);
        optical_depth += medium_sun_column(medium, sun_cosine) * medium_below_top(medium, position);
    }
    return exp(-optical_depth);
}

#endif
