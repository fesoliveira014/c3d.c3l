#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "optical_throughput.surface.glsl"
#include "optical_throughput.light.glsl"
layout(push_constant) uniform Push { uint64_t vertex_root; uint64_t fragment_root; } pc;
layout(location = 0) flat out uint surface_index;
layout(location = 1) out vec2 surface_uv;
layout(location = 2) out vec3 world_position;
invariant gl_Position;

void main() {
    OpticalLightDraw draw = OpticalLightDraw(pc.vertex_root);
    surface_index = draw.first;
    OpticalSurface surface = OpticalSurfaces(draw.surfaces).values[surface_index];
    const vec2 corners[6] = vec2[6](vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 0), vec2(1, 1), vec2(0, 1));
    if (draw.phase == OPTICAL_PHASE_STORE) {
        surface_uv = corners[gl_VertexIndex];
        world_position = vec3(0.0);
        gl_Position = vec4(corners[gl_VertexIndex] * 2.0 - 1.0, 0.5, 1.0);
        return;
    }

    uint vertex = (surface.flags & OPTICAL_REVERSED) != 0u ? 5u - uint(gl_VertexIndex) : uint(gl_VertexIndex);
    vec2 xy = mix(surface.bounds.xy, surface.bounds.zw, corners[vertex]);
    if ((surface.flags & OPTICAL_MIRRORED) != 0u) xy.x = -xy.x;
    surface_uv = vec2(corners[vertex].x, 1.0 - corners[vertex].y);
    float distance = 9.0 - 8.0 * surface.model_scale.w;
    world_position = vec3(xy, -distance);
    if (draw.kind == OPTICAL_LIGHT_DIRECTIONAL) {
        gl_Position = vec4(xy, surface.model_scale.w, 1.0);
    } else {
        float tangent = draw.kind == OPTICAL_LIGHT_SPOT ? OPTICAL_SPOT_TANGENT : 1.0;
        gl_Position = vec4(xy / tangent, surface.model_scale.w, distance);
    }
}
