#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "scene_trace.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer TraceGridRoot {
    uint64_t scene;
    uint64_t output_address;
    vec4 origin;
    vec4 rectangle;
    float plane_z;
    uint grid_size;
    uint instance_mask;
    uint entry;
};

struct TraceGridResult {
    uint hit;
    uint primitive;
    float t;
    uint geometry_low;
    vec2 barycentrics;
    uint back_face;
    uint padding;
};

GPU_DECLARE_WRITEONLY_ARRAY_REF(TraceGridOutput, TraceGridResult);

const float TRACE_FAR = 1.0e30;
const uint TRACE_ENTRY_WITH_BACK_FACES = 1u; // mirrored as TRACE_ENTRY_WITH_BACK_FACES in test_scene_trace.c3

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    TraceGridRoot root = TraceGridRoot(dispatch.parameters);
    uvec2 cell = gl_GlobalInvocationID.xy;
    if (cell.x >= root.grid_size || cell.y >= root.grid_size) return;

    vec2 fraction = (vec2(cell) + 0.5) / float(root.grid_size);
    vec3 target = vec3(mix(root.rectangle.xy, root.rectangle.zw, fraction), root.plane_z);
    vec3 direction = normalize(target - root.origin.xyz);
    SceneTraceRoot scene = SceneTraceRoot(root.scene);
    SceneHit hit;
    TraceGridResult result = TraceGridResult(
        0u,
        0u,
        0.0,
        0u,
        vec2(0.0),
        0u,
        0u
    );
    bool met = root.entry == TRACE_ENTRY_WITH_BACK_FACES
        ? trace_scene_with_back_faces(scene, root.origin.xyz, direction, TRACE_FAR, root.instance_mask, hit)
        : trace_scene(scene, root.origin.xyz, direction, TRACE_FAR, root.instance_mask, hit);
    if (met) {
        TraceInstanceGpu instance = TraceInstanceArray(scene.instances).values[hit.instance];
        result = TraceGridResult(
            1u,
            hit.primitive,
            hit.t,
            uint(instance.geometry),
            hit.barycentrics,
            surface_from_hit(scene, hit, direction, 0.0).back_face ? 1u : 0u,
            0u
        );
    }
    TraceGridOutput(root.output_address).values[cell.y * root.grid_size + cell.x] = result;
}
