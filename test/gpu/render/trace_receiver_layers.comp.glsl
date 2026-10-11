#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#define RT_SHADOWS
#include "hit_shading.glsl"

layout(local_size_x = 1) in;
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;
layout(buffer_reference, std430, buffer_reference_align = 8) readonly buffer ReceiverLayerRoot {
    uint64_t scene;
    uint64_t frame;
    uint64_t output_address;
};
GPU_DECLARE_WRITEONLY_ARRAY_REF(ReceiverLayerOutput, vec4);

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    ReceiverLayerRoot root = ReceiverLayerRoot(dispatch.parameters);
    SceneTraceRoot scene = SceneTraceRoot(root.scene);
    SceneHit hit;
    vec3 direction = vec3(0.0, 0.0, -1.0);
    vec4 result = vec4(-1.0);
    if (trace_scene(scene, vec3(0.125, 0.25, 0.0), direction, 9.0, TRACE_MASK_ALL, hit)) {
        TraceSurface surface = surface_from_hit(scene, hit, direction, 0.0);
        result = vec4(shade_hit(FrameRoot(root.frame), surface, -direction), uintBitsToFloat(surface.receiver_layers));
    }
    ReceiverLayerOutput(root.output_address).values[0] = result;
}
