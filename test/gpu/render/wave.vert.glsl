#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer WaveParams {
    vec4 color;
    vec4 motion;
};

// motion: amplitude, angular frequency, phase, phase step per instance.
vec3 wave_position(vec3 local_position, float time, vec4 motion, float instance_phase) {
    float displacement = motion.x * sin(time * motion.y + motion.z + instance_phase);
    return local_position + vec3(0.0, displacement, 0.0);
}

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    uint index = uint(gl_VertexIndex);
    WaveParams params = WaveParams(material.parameters);
#ifdef INSTANCED
    float instance_phase = params.motion.w * float(instance_source(draw));
#else
    float instance_phase = 0.0;
#endif

    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    apply_mesh_deformation(vertex, draw, geometry, index);
    vertex.position = wave_position(vertex.position, frame.jitter_time.z, params.motion, instance_phase);
#ifdef VELOCITY
    vec3 previous = previous_mesh_position(draw, geometry, index);
    previous = wave_position(previous, frame.previous_time, params.motion, instance_phase);
    write_mesh_outputs(vertex, previous, draw, frame, geometry);
#else
    write_mesh_outputs(vertex, draw, frame, geometry);
#endif
}
