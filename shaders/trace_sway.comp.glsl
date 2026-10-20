#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "instance_effects.glsl"
#include "trace_pose_streams.glsl"

layout(local_size_x = TRACE_POSE_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

GPU_DECLARE_READONLY_ARRAY_REF(TraceSwayRows, TraceSwayRowGpu);

// The sway branch of apply_instance_effects in mesh_vertex.glsl. The fade depends on the view, so none applies.
vec3 apply_trace_sway(TraceSwayBatchRoot root, TraceSwayRowGpu row, vec3 world_position, float bend_weight) {
    vec3 anchor = (row.instance.model * vec4(root.anchor.xyz, 1.0)).xyz;
    return world_position + sway_offset(root.sway, anchor, row.instance.normal_0.w, bend_weight);
}

// Raster moves the world position; the posed streams are in the geometry's space, so the offset is carried back.
// The z of the dispatch is the row, one posed slot of the batch.
void main() {
    TraceSwayBatchRoot root = TraceSwayBatchRoot(pc.root_gpu);
    uint index = trace_pose_linear_index();
    if (index >= root.vertex_count) return;

    TraceSwayRowGpu row = TraceSwayRows(root.rows).values[gl_WorkGroupID.z];
    GeometryRoot source = GeometryRoot(root.source);
    TracePoseVertex vertex = pull_trace_pose_vertex(source, index);
    mat4 model = row.instance.model * row.part_local;
    vec3 effect_position = (row.part_local * vec4(vertex.position, 1.0)).xyz;
    float bend_weight = (root.flags & DRAW_SWAY_VERTEX_ALPHA) != 0u
        ? clamp(vertex.color.a, 0.0, 1.0)
        : sway_height_weight(root.anchor, effect_position.y);

    vec3 world = (model * vec4(vertex.position, 1.0)).xyz;
    vec3 swayed = apply_trace_sway(root, row, world, bend_weight);
    mat3 inverse_model = mat3(row.inverse_model_0.xyz, row.inverse_model_1.xyz, row.inverse_model_2.xyz);
    vec3 position = vertex.position + inverse_model * (swayed - world);
    write_trace_pose(source, GeometryRoot(row.posed), index, position, vertex.normal, vertex.tangent);
}
