#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "trace_pose.glsl"
#include "landscape/terrain_normal.glsl"

// The trace grid's vertices lie on the unit square; each one reads the height of the texel it stands on.
void main() {
    TraceCustomPoseRoot root = TraceCustomPoseRoot(pc.root_gpu);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.vertex_count) return;

    CustomMaterialGpu material = CustomMaterialGpu(root.material);
    TerrainParams params = TerrainParams(material.parameters);
    uint height_texture = material.slots[TERRAIN_HEIGHT_SLOT].texture_index;
    uint border_texture = material.slots[TERRAIN_BORDER_SLOT].texture_index;
    TracePoseVertex vertex = trace_pose_vertex(index);
    ivec2 texel = ivec2(round(vertex.position.xz * float(params.texels - 1u)));
    vec3 position = vec3(
        float(texel.x) * params.cell_size,
        terrain_height(height_texture, params, texel),
        float(texel.y) * params.cell_size
    );
    vec3 normal = terrain_local_normal(height_texture, border_texture, params, vec2(texel));
    trace_pose_write(index, position, normal, vertex.tangent);
}
