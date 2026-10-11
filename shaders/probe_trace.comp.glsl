#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#ifndef SCENE_TRACE_BVH
#define SCENE_TRACE_RAY_QUERY
#endif
#define RT_SHADOWS
#include "constants.glsl"
#include "sampling.glsl"
#include "scene_trace.glsl"
#include "lights.glsl"
#include "shadows.glsl"
#include "hit_shading.glsl"
#include "trace_medium.glsl"

layout(local_size_x = 64) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

GPU_DECLARE_WRITEONLY_ARRAY_REF(RayResultArray, RayResultGpu);

void main() {
    ProbeTraceRoot root = ProbeTraceRoot(pc.root_gpu);
    uint thread = gl_GlobalInvocationID.x;
    if (thread >= root.probe_count * root.rays_per_probe) return;

    FrameRoot frame = FrameRoot(root.frame);
    ProbeVolumeGpu volume = ProbeVolumeSetGpu(frame.probe_volumes).volumes[root.volume];
    uint probe = root.first_probe + thread / root.rays_per_probe;
    uvec3 cell = uvec3(
        probe % volume.count_x,
        (probe / volume.count_x) % volume.count_y,
        probe / (volume.count_x * volume.count_y)
    );
    vec3 origin = volume.origin_energy.xyz + vec3(cell) * volume.spacing_max_distance.xyz;
    vec3 direction = quaternion_rotate(
        root.rotation,
        spherical_fibonacci(thread % root.rays_per_probe, root.rays_per_probe)
    );

    SceneTraceRoot scene = SceneTraceRoot(frame.trace);
    SceneHit hit;
    vec4 result;
    // A probe inside geometry must read dark, so its own ray keeps the back faces the effects cull.
    if (!trace_scene_with_back_faces(scene, origin, direction, root.ray_far, TRACE_MASK_ALL, hit)) {
        vec3 radiance = trace_background_radiance(frame, origin, direction, trace_miss_radiance(frame, direction));
        result = vec4(radiance, root.ray_far);
    } else {
        TraceSurface surface = surface_from_hit(scene, hit, direction, hit.t * root.cone_spread);
        if (surface.back_face) {
            result = vec4(0.0, 0.0, 0.0, -hit.t);
        } else {
            vec3 radiance = shade_hit(frame, surface, -direction);

            result = vec4(trace_segment_radiance(frame, origin, direction, hit.t, radiance), hit.t);
        }
    }

    RayResultArray(root.rays).values[thread] = RayResultGpu(result);
}
