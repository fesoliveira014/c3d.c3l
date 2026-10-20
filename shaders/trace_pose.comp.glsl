#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "deform.glsl"
#include "trace_pose_streams.glsl"

layout(local_size_x = TRACE_POSE_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// The order and functions of apply_mesh_deformation in mesh_vertex.glsl: morph, then skin; tangent w is kept.
// INSTANCED poses every source of a crowd part: the group grid is the vertex, z the source, and the source picks its
// palette and morph rows and its slot in the posed streams, as logical_source does in mesh_vertex.glsl.
void main() {
    TracePoseRoot root = TracePoseRoot(pc.root_gpu);
    GeometryRoot source = GeometryRoot(root.source);
    uint index = trace_pose_linear_index();
    if (index >= source.vertex_count) return;

    uint64_t palette_address = root.palette;
    uint64_t morph_address = root.morph;
    uint posed_index = index;
#ifdef INSTANCED
    uint logical = gl_GlobalInvocationID.z;
    palette_address += uint64_t(logical) * uint64_t(root.palette_joints) * PALETTE_MATRIX_BYTES;
    morph_address += uint64_t(logical) * MORPH_BLOCK_BYTES;
    posed_index += logical * source.vertex_count;
#endif

    GeometryRoot posed = GeometryRoot(root.posed);
    bool normals = (source.flags & GEOMETRY_HAS_NORMALS) != 0u;
    bool tangents = (source.flags & GEOMETRY_HAS_TANGENTS) != 0u;
    vec3 position = pull_vec3(source.positions, index);
    vec3 normal = normals ? pull_vec3(source.normals, index) : vec3(0.0, 0.0, 1.0);
    vec4 tangent = tangents ? pull_vec4(source.tangents, index) : vec4(0.0);
    if (root.morph != 0ul) {
        MorphWeightsGpu morph = MorphWeightsGpu(morph_address);
        position += morph_delta(source, morph, index, MORPH_STREAM_POSITION);
        normal += morph_delta(source, morph, index, MORPH_STREAM_NORMAL);
    }
    if (root.palette != 0ul) {
        mat4 skin = skin_matrix(source, palette_address, index);
        position = (skin * vec4(position, 1.0)).xyz;
        normal = mat3(skin) * normal;
        tangent.xyz = mat3(skin) * tangent.xyz;
    }

    write_trace_pose(source, posed, posed_index, position, normal, tangent);
}
