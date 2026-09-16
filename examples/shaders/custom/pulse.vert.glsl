#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer PulseParams {
    vec4 color;
    vec4 motion;
};

vec3 pulse_position(vec3 local_position, float time, vec4 motion) {
    float displacement = motion.x * sin(time * motion.y + motion.z);
    return local_position + vec3(0.0, displacement, 0.0);
}

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    uint index = uint(gl_VertexIndex);

    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    apply_mesh_deformation(vertex, draw, geometry, index);
    PulseParams params = PulseParams(material.parameters);
    vertex.position = pulse_position(vertex.position, frame.jitter_time.z, params.motion);
    write_mesh_outputs(vertex, draw, frame, geometry);
}
