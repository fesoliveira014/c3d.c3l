#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"

struct Particle {
    vec4 position_life;
    vec4 velocity_seed;
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Particles {
    Particle values[];
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ParticleParams {
    uint64_t particles;
    uint count;
    float size;
    float lifetime;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    vec4 color_young;
    vec4 color_old;
};

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    ParticleParams params = ParticleParams(material.parameters);
    uint index = uint(gl_VertexIndex);

    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    Particle particle = Particles(params.particles).values[index / 4u];
    vec3 right = vec3(frame.view[0][0], frame.view[1][0], frame.view[2][0]);
    vec3 up = vec3(frame.view[0][1], frame.view[1][1], frame.view[2][1]);
    vec3 toward_camera = -vec3(frame.view[0][2], frame.view[1][2], frame.view[2][2]);
    vec2 corner = vertex.uv0 * 2.0 - 1.0;
    float age = clamp(1.0 - particle.position_life.w / params.lifetime, 0.0, 1.0);
    float size = particle.position_life.w > 0.0 ? params.size * (1.0 - 0.5 * age) : 0.0;
    vertex.position = particle.position_life.xyz + (right * corner.x + up * corner.y) * size;
    vertex.normal = toward_camera;
    write_mesh_outputs(vertex, draw, frame, geometry);
    v_color = mix(params.color_young, params.color_old, age);
}
