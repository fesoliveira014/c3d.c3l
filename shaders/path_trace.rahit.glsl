#version 460
#include "ray_tracing.glsl"
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "trace_surface.glsl"

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

hitAttributeEXT vec2 attributes;

void main() {
    FrameRoot frame = FrameRoot(PathTraceRoot(pc.root_gpu).frame);
    TraceInstanceGpu row = trace_instance(SceneTraceRoot(frame.trace), gl_InstanceCustomIndexEXT);
    SceneHit hit = SceneHit(gl_InstanceCustomIndexEXT, gl_PrimitiveID, attributes, gl_HitTEXT);
    if (!trace_surface_passes(row, hit)) ignoreIntersectionEXT;
}
