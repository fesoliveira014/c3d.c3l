#version 460
#include "ray_tracing.glsl"
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "trace_surface.glsl"
#include "path_trace.glsl"

layout(location = 0) rayPayloadInEXT SceneHit path_hit;

void main() {
    path_hit.instance = PATH_TRACE_MISS;
}
