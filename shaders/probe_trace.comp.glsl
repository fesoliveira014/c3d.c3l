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
#include "ibl.glsl"

layout(local_size_x = 64) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

GPU_DECLARE_WRITEONLY_ARRAY_REF(RayResultArray, RayResultGpu);

// Diffuse direct light at a hit: a shadow ray only for a light that can reach the surface.
vec3 direct_lambert(FrameRoot frame, TraceSurface surface) {
    vec3 radiance = vec3(0.0);
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        LightSample light_sample = sample_light(light, surface.position);
        float cosine = dot(surface.normal, light_sample.direction);
        if (cosine <= 0.0 || light_sample.radiance == vec3(0.0)) continue;
        float visibility = light_casts_shadow(light)
            ? ray_shadow_visibility(frame, light, surface.position, surface.geometric_normal)
            : 1.0;
        radiance += light_sample.radiance * cosine * visibility;
    }
    return radiance * surface.albedo / PI;
}

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
    if (!trace_scene(scene, origin, direction, root.ray_far, TRACE_MASK_ALL, hit)) {
        result = vec4(trace_miss_radiance(frame, direction), root.ray_far);
    } else {
        TraceSurface surface = surface_from_hit(scene, hit, direction, hit.t * root.cone_spread);
        if (surface.back_face) {
            result = vec4(0.0, 0.0, 0.0, -hit.t);
        } else {
            vec3 bounce = surface.albedo / PI
                * indirect_diffuse_irradiance(frame, surface.position, surface.normal, -direction);
            result = vec4(direct_lambert(frame, surface) + surface.emissive + bounce, hit.t);
        }
    }
    RayResultArray(root.rays).values[thread] = RayResultGpu(result);
}
