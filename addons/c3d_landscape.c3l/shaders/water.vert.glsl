#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"
#include "landscape/water_waves.glsl"

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    WaterParams params = WaterParams(CustomMaterialGpu(draw.material).parameters);

    MeshVertexInput vertex = pull_mesh_vertex(geometry, uint(gl_VertexIndex));
    vec2 rest = vertex.position.xz;
    WaterSurfacePoint point = water_surface_point(params, rest, frame.jitter_time.z);
    vertex.position = point.position;
    vertex.normal = point.normal;
    vertex.tangent = vec4(point.tangent, 1.0);
    vertex.uv0 = rest;
    vertex.uv1 = rest;
    vertex.color = vec4(1.0, 1.0, 1.0, point.crest);
#ifdef VELOCITY
    vec3 previous = water_surface_point(params, rest, frame.previous_time).position;
    write_mesh_outputs(vertex, previous, draw, frame, geometry);
#else
    write_mesh_outputs(vertex, draw, frame, geometry);
#endif
}
