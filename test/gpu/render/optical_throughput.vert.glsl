#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "optical_throughput.surface.glsl"
layout(push_constant) uniform Push { uint64_t vertex_root; uint64_t fragment_root; } pc;
layout(location = 0) flat out uint surface_index;
layout(location = 1) out vec2 surface_uv;
invariant gl_Position;
void main() {
    OpticalDraw root = OpticalDraw(pc.vertex_root);
    surface_index = root.first;
    OpticalSurface surface = OpticalSurfaces(root.surfaces).values[surface_index];
    const vec2 corners[6] = vec2[6](vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 0), vec2(1, 1), vec2(0, 1));
    uint vertex = (surface.flags & OPTICAL_REVERSED) != 0u ? 5u - uint(gl_VertexIndex) : uint(gl_VertexIndex);
    surface_uv = vec2(corners[vertex].x, 1.0 - corners[vertex].y);
    vec2 xy = mix(surface.bounds.xy, surface.bounds.zw, corners[vertex]);
    if ((surface.flags & OPTICAL_MIRRORED) != 0u) xy.x = -xy.x;
    gl_Position = vec4(xy, surface.model_scale.w + dot(surface.plane.xy, xy), 1.0);
}
