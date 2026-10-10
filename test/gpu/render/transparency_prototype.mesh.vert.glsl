#version 460
#define main source_vertex_main
#include "transparency_mesh_body.glsl"
#undef main

layout(location = 8) flat out uint surface_index;
invariant gl_Position;

void main() {
    source_vertex_main();
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
#ifdef INSTANCED
    surface_index = draw.object_id + instance_source(draw);
#else
    surface_index = draw.object_id;
#endif
}
