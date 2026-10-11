#version 460
invariant gl_Position;
#define main source_vertex_main
#include "transparency_billboard_body.glsl"
#undef main

layout(location = 8) flat out uint surface_index;

void main() {
    source_vertex_main();
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    uint source = draw.instance_indices != 0ul
        ? BillboardVisibleArray(draw.instance_indices).values[gl_InstanceIndex]
        : uint(gl_InstanceIndex);
    surface_index = draw.object_id + source;
}
