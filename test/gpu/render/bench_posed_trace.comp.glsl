#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "scene_trace.glsl"

layout(local_size_x = 8, local_size_y = 8) in; // mirrored as GROUP_SIZE in bench_posed_trace.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer BenchRoot {
    mat4 inv_view_proj;
    vec4 camera;
    uint64_t scene;
    uint64_t output_address;
    uint width;
    uint height;
    uint _pad0;
    uint _pad1;
};

GPU_DECLARE_WRITEONLY_ARRAY_REF(BenchOutput, float);

const float BENCH_TRACE_FAR = 1.0e30;

// One primary ray per pixel; the distance is written so the traversal cannot be dropped.
void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    BenchRoot root = BenchRoot(dispatch.parameters);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    vec2 uv = (vec2(pixel) + 0.5) / vec2(root.width, root.height);
    vec2 ndc = (uv * 2.0 - 1.0) * vec2(1.0, -1.0);
    vec4 far_point = root.inv_view_proj * vec4(ndc, 0.5, 1.0);
    vec3 direction = normalize(far_point.xyz / far_point.w - root.camera.xyz);
    SceneHit hit;
    SceneTraceRoot scene = SceneTraceRoot(root.scene);
    bool hit_found = trace_scene(scene, root.camera.xyz, direction, BENCH_TRACE_FAR, TRACE_MASK_ALL, hit);
    float distance = hit_found ? hit.t : -1.0;
    BenchOutput(root.output_address).values[pixel.y * root.width + pixel.x] = distance;
}
