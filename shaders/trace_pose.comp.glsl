#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "deform.glsl"

layout(local_size_x = TRACE_POSE_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

GPU_DECLARE_WRITEONLY_ARRAY_REF(PosedStream, float);

void store_vec3(uint64_t stream, uint index, vec3 value) {
    PosedStream values = PosedStream(stream);
    values.values[3u * index] = value.x;
    values.values[3u * index + 1u] = value.y;
    values.values[3u * index + 2u] = value.z;
}

void store_vec4(uint64_t stream, uint index, vec4 value) {
    PosedStream values = PosedStream(stream);
    values.values[4u * index] = value.x;
    values.values[4u * index + 1u] = value.y;
    values.values[4u * index + 2u] = value.z;
    values.values[4u * index + 3u] = value.w;
}

// The order and functions of apply_mesh_deformation in mesh_vertex.glsl: morph, then skin; tangent w is kept.
void main() {
    TracePoseRoot root = TracePoseRoot(pc.root_gpu);
    GeometryRoot source = GeometryRoot(root.source);
    uint index = gl_GlobalInvocationID.x;
    if (index >= source.vertex_count) return;

    GeometryRoot posed = GeometryRoot(root.posed);
    bool normals = (source.flags & GEOMETRY_HAS_NORMALS) != 0u;
    bool tangents = (source.flags & GEOMETRY_HAS_TANGENTS) != 0u;
    vec3 position = pull_vec3(source.positions, index);
    vec3 normal = normals ? pull_vec3(source.normals, index) : vec3(0.0, 0.0, 1.0);
    vec4 tangent = tangents ? pull_vec4(source.tangents, index) : vec4(0.0);
    if (root.morph != 0ul) {
        MorphWeightsGpu morph = MorphWeightsGpu(root.morph);
        position += morph_delta(source, morph, index, MORPH_STREAM_POSITION);
        normal += morph_delta(source, morph, index, MORPH_STREAM_NORMAL);
    }
    if (root.palette != 0ul) {
        mat4 skin = skin_matrix(source, root.palette, index);
        position = (skin * vec4(position, 1.0)).xyz;
        normal = mat3(skin) * normal;
        tangent.xyz = mat3(skin) * tangent.xyz;
    }

    store_vec3(posed.positions, index, position);
    if (normals) store_vec3(posed.normals, index, normal);
    if (tangents) store_vec4(posed.tangents, index, tangent);
}
