#version 460
#include "ray_tracing.glsl"
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "trace_surface.glsl"

layout(location = 0) rayPayloadInEXT SceneHit path_hit;
hitAttributeEXT vec2 attributes;

void main() {
    path_hit = SceneHit(gl_InstanceCustomIndexEXT, gl_PrimitiveID, attributes, gl_HitTEXT);
}
