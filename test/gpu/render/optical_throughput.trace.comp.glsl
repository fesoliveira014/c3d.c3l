#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "scene_trace.glsl"
#include "optical_throughput.surface.glsl"

layout(local_size_x = 8, local_size_y = 8) in;
layout(push_constant) uniform Push { uint64_t root; } pc;
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OpticalTraceRoot {
    uint64_t scene;
    uint64_t surfaces;
    uint64_t order;
    uint64_t output_address;
    uint capacity;
    uint width;
    uint height;
    uint sampler_index;
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OpticalOrder { uint values[]; };
layout(buffer_reference, std430, buffer_reference_align = 16) buffer OpticalTraceOutput { vec4 values[]; };
const uint OPTICAL_TRACE_SURFACES = 64u;
const float OPTICAL_TRACE_RECEIVER_DISTANCE = 8.5;

OpticalSurface optical_trace_map(OpticalTraceRoot root, OpticalSurface surface, vec2 uv) {
    if (surface.map != 0u) {
        vec4 mapped = sample_texture_2d(surface.map, root.sampler_index, uv);
        surface.factors.x *= mapped.r;
        surface.normal_thickness.w *= mapped.g;
        surface.base_coverage.a *= mapped.a;
    }
    return surface;
}

void main() {
    OpticalTraceRoot root = OpticalTraceRoot(pc.root);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    SceneTraceRoot scene = SceneTraceRoot(root.scene);
    vec2 position = (vec2(pixel) + 0.5) / vec2(root.width, root.height) * 2.0 - 1.0;
    position.y = -position.y;
    vec3 origin = vec3(position, 0.0);
    vec3 direction = vec3(0.0, 0.0, -1.0);
    float distances[OPTICAL_TRACE_SURFACES];
    vec2 coordinates[OPTICAL_TRACE_SURFACES];
    for (uint row = 0u; row < scene.instance_count; row++) distances[row] = 0.0;

#ifdef SCENE_TRACE_RAY_QUERY
    rayQueryEXT query;
    GPU_RAY_QUERY_INITIALIZE(query, scene.tlas_index, gl_RayFlagsNoneEXT, TRACE_MASK_ALL,
        origin, 0.0, direction, OPTICAL_TRACE_RECEIVER_DISTANCE);
    while (rayQueryProceedEXT(query)) {
        if (rayQueryGetIntersectionTypeEXT(query, false) != gl_RayQueryCandidateIntersectionTriangleEXT) continue;
        uint row = rayQueryGetIntersectionInstanceCustomIndexEXT(query, false);
        SceneHit hit = SceneHit(row, rayQueryGetIntersectionPrimitiveIndexEXT(query, false),
            rayQueryGetIntersectionBarycentricsEXT(query, false), rayQueryGetIntersectionTEXT(query, false));
        TraceInstanceGpu instance = TraceInstanceArray(scene.instances).values[row];
        if (!trace_surface_passes(instance, hit)) continue;
        if (distances[row] != 0.0 && hit.t >= distances[row]) continue;

        GeometryRoot geometry = GeometryRoot(instance.geometry);
        uvec3 corners = pull_triangle(geometry, hit.primitive);
        distances[row] = hit.t;
        coordinates[row] = hit_uv(geometry.uv0, corners, vec3(1.0 - hit.barycentrics.x - hit.barycentrics.y,
            hit.barycentrics));
    }
#else
    for (uint row = 0u; row < scene.instance_count; row++) {
        float limit = OPTICAL_TRACE_RECEIVER_DISTANCE;
        SceneHit hit = SceneHit(row, 0u, vec2(0.0), limit);
        TraceInstanceGpu instance = TraceInstanceArray(scene.instances).values[row];
        if (!trace_instance(instance, row, TRACE_CULL_NONE, origin, direction, false, limit, hit)) continue;

        GeometryRoot geometry = GeometryRoot(instance.geometry);
        uvec3 corners = pull_triangle(geometry, hit.primitive);
        distances[row] = hit.t;
        coordinates[row] = hit_uv(geometry.uv0, corners, vec3(1.0 - hit.barycentrics.x - hit.barycentrics.y,
            hit.barycentrics));
    }
#endif

    vec3 visibility = vec3(1.0);
    float previous = 0.0;
    uint groups = 0u;
    bool blocker = false;
    bool scalar_blocker = false;
    for (uint item = 0u; item < scene.instance_count; item++) {
        uint row = OpticalOrder(root.order).values[item];
        if (distances[row] == 0.0) continue;
        OpticalSurface surface = optical_trace_map(root, OpticalSurfaces(root.surfaces).values[row], coordinates[row]);
        if (!optical_surface_survives(surface)) continue;
        blocker = blocker || optical_surface_blocks(surface);
        scalar_blocker = scalar_blocker || (surface.flags & OPTICAL_ALPHA_BLEND) == 0u;
        if (!optical_surface_participates(surface)) continue;

        if (groups == 0u || distances[row] != previous) {
            groups++;
            previous = distances[row];
        }
        visibility *= optical_surface_throughput(surface);
    }
    if (blocker || groups > root.capacity) visibility = vec3(0.0);
    OpticalTraceOutput(root.output_address).values[pixel.y * root.width + pixel.x]
        = vec4(visibility, scalar_blocker ? 0.0 : 1.0);
}
