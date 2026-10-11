#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"

struct Surface {
    vec4 bounds;
    vec4 color;
    float depth;
    float coverage;
    uint kind;
    uint node;
    uint part;
    uint instance;
    uint primitive;
    uint reader;
    vec4 plane;
    uint range;
    uint padding0;
    uint padding1;
    uint padding2;
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Surfaces {
    Surface values[];
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Draw {
    uint64_t surfaces;
    uint first;
    uint entries_per_instance;
    uint previous;
    uint selected;
    uint scene;
    uint mode;
    uint has_previous;
    uint opaque_depth;
    uint64_t transport;
};
layout(push_constant) uniform Push { uint64_t vertex_root; uint64_t fragment_root; } pc;
layout(location = 0) flat out uint surface_index;
invariant gl_Position;

void main() {
    Draw root = Draw(pc.vertex_root);
    surface_index = root.first + uint(gl_InstanceIndex) * root.entries_per_instance + uint(gl_VertexIndex) / 6u;
    Surface surface = Surfaces(root.surfaces).values[surface_index];
    const vec2 corners[6] = vec2[6](vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 0), vec2(1, 1), vec2(0, 1));
    vec2 xy = mix(surface.bounds.xy, surface.bounds.zw, corners[gl_VertexIndex % 6]);
    float depth = surface.depth + surface.plane.x * xy.x + surface.plane.y * xy.y;
    gl_Position = vec4(xy, depth, 1.0);
}
