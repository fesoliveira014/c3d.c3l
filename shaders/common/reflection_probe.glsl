#ifndef C3D_REFLECTION_PROBE_GLSL
#define C3D_REFLECTION_PROBE_GLSL

#include "descriptor_heap.glsl"

const uint ENVIRONMENT_GGX_CUBE = 0u;
const uint ENVIRONMENT_CHARLIE_CUBE = 1u;
const float REFLECTION_NO_EXIT = 3.40282347e+38; // float::max; mirrored as REFLECTION_NO_EXIT in reflection_probe.c3

// Up to two probes and the global environment lighting one point, with their shares of every lobe.
// Mirrored as ReflectionSelection in reflection_probe.c3.
struct ReflectionSelection {
    uint  count;
    uint  first;
    uint  second;
    float first_weight;
    float second_weight;
    float global_weight;
    vec3  first_position;  // the point in the first probe's box frame
    vec3  second_position;
};

vec3 reflection_probe_local(ReflectionProbeGpu probe, vec3 world) {
    return vec3(
        dot(probe.axis_x_extent.xyz, world),
        dot(probe.axis_y_extent.xyz, world),
        dot(probe.axis_z_extent.xyz, world)
    );
}

vec3 reflection_probe_world(ReflectionProbeGpu probe, vec3 local_direction) {
    return probe.axis_x_extent.xyz * local_direction.x
        + probe.axis_y_extent.xyz * local_direction.y
        + probe.axis_z_extent.xyz * local_direction.z;
}

vec3 reflection_probe_extent(ReflectionProbeGpu probe) {
    return vec3(probe.axis_x_extent.w, probe.axis_y_extent.w, probe.axis_z_extent.w);
}

// Mirrored as reflection_probe_weight in reflection_probe.c3.
float reflection_probe_weight(vec3 extent, float blend, vec3 local_position) {
    vec3 inside = extent - abs(local_position);
    float face_distance = min(inside.x, min(inside.y, inside.z));
    if (face_distance < 0.0) return 0.0;
    return blend > 0.0 ? min(face_distance / blend, 1.0) : 1.0;
}

// Mirrored as reflection_probe_select in reflection_probe.c3.
ReflectionSelection reflection_probe_select(FrameRoot frame, vec3 position) {
    ReflectionSelection selection = ReflectionSelection(0u, 0u, 0u, 0.0, 0.0, 1.0, vec3(0.0), vec3(0.0));
    if (frame.reflection_probes == 0ul) return selection;

    ReflectionProbeSetGpu set = ReflectionProbeSetGpu(frame.reflection_probes);
    float second_weight = 0.0;
    // The set is in priority, volume and entity order: the first weighted box lights the point, the second fades
    // in under it, and later boxes are not read.
    // Only the box fields load per probe: copying whole 96 B records cost 0.12 ms over one probe with 16 probes
    // and no hit at 2560 x 1440 on an RTX 4090.
    for (uint index = 0u; index < set.count; index++) {
        vec3 offset = position - set.probes[index].center_intensity.xyz;
        vec4 axis_x = set.probes[index].axis_x_extent;
        vec4 axis_y = set.probes[index].axis_y_extent;
        vec4 axis_z = set.probes[index].axis_z_extent;
        vec3 local_position = vec3(dot(axis_x.xyz, offset), dot(axis_y.xyz, offset), dot(axis_z.xyz, offset));
        float weight = reflection_probe_weight(
            vec3(axis_x.w, axis_y.w, axis_z.w),
            set.probes[index].capture_blend.w,
            local_position
        );
        if (weight == 0.0) continue;
        if (selection.count == 0u) {
            selection.count = 1u;
            selection.first = index;
            selection.first_weight = weight;
            selection.first_position = local_position;
            if (weight == 1.0) break;
        } else {
            selection.count = 2u;
            selection.second = index;
            selection.second_position = local_position;
            second_weight = weight;
            break;
        }
    }
    selection.second_weight = (1.0 - selection.first_weight) * second_weight;
    selection.global_weight = (1.0 - selection.first_weight) * (1.0 - second_weight);
    return selection;
}

// Mirrored as reflection_box_direction in reflection_probe.c3.
vec3 reflection_box_direction(ReflectionProbeGpu probe, vec3 local_position, vec3 direction) {
    if (probe.projection == REFLECTION_PROJECTION_INFINITE) return direction;
    vec3 local_direction = reflection_probe_local(probe, direction);
    vec3 extent = reflection_probe_extent(probe);
    // A weighted point and the capture point lie inside the box, so the ray leaves it at a distance >= 0, and the
    // exit point differs from the strictly interior capture point: no outside case and no zero direction.
    vec3 exits = vec3(REFLECTION_NO_EXIT);
    for (int axis = 0; axis < 3; axis++) {
        if (local_direction[axis] > 0.0) {
            exits[axis] = (extent[axis] - local_position[axis]) / local_direction[axis];
        } else if (local_direction[axis] < 0.0) {
            exits[axis] = (-extent[axis] - local_position[axis]) / local_direction[axis];
        }
    }
    float exit_distance = min(exits.x, min(exits.y, exits.z));
    vec3 exit_point = local_position + local_direction * exit_distance;
    return reflection_probe_world(probe, exit_point - probe.capture_blend.xyz);
}

vec3 reflection_probe_radiance(
    ReflectionProbeSetGpu set,
    uint index,
    vec3 local_position,
    vec3 direction,
    float lod,
    uint cube
) {
    ReflectionProbeGpu probe = set.probes[index];
    return sample_texture_cube_lod(
        cube == ENVIRONMENT_CHARLIE_CUBE ? probe.sheen_cube : probe.specular_cube,
        set.sampler_index,
        reflection_box_direction(probe, local_position, direction),
        lod
    ).rgb * probe.center_intensity.w;
}

#endif
