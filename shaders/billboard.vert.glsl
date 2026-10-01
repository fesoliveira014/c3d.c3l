#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(BillboardArray, BillboardGpu);
GPU_DECLARE_READONLY_ARRAY_REF(BillboardVisibleArray, uint);

const float DIRECTION_PROJECTION_EPSILON = 1e-8; // squared unit projection; avoids unstable facing near the view axis

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    uint source = draw.instance_indices != 0ul
        ? BillboardVisibleArray(draw.instance_indices).values[gl_InstanceIndex]
        : uint(gl_InstanceIndex);
    BillboardGpu billboard = BillboardArray(draw.instance_data).values[source];
    MeshVertexInput vertex = pull_mesh_vertex(geometry, uint(gl_VertexIndex));

    vec3 right = normalize(vec3(frame.view[0][0], frame.view[1][0], frame.view[2][0]));
    vec3 up = normalize(vec3(frame.view[0][1], frame.view[1][1], frame.view[2][1]));
    vec3 normal = normalize(vec3(frame.view[0][2], frame.view[1][2], frame.view[2][2]));
    if (billboard.facing == BILLBOARD_DIRECTIONAL) {
        vec2 projected = vec2(dot(billboard.direction_height.xyz, right), dot(billboard.direction_height.xyz, up));
        if (dot(projected, projected) > DIRECTION_PROJECTION_EPSILON) {
            projected = normalize(projected);
            vec3 along = right * projected.x + up * projected.y;
            right = right * projected.y - up * projected.x;
            up = along;
        }
    }
    float cosine = cos(billboard.rotation);
    float sine = sin(billboard.rotation);
    vec3 rotated_right = right * cosine + up * sine;
    vec3 rotated_up = up * cosine - right * sine;
    vec3 world = billboard.position_width.xyz
        + rotated_right * vertex.position.x * billboard.position_width.w
        + rotated_up * vertex.position.y * billboard.direction_height.w;

    v_world_pos = world;
    v_normal = normal;
    v_tangent = vec4(rotated_right, dot(cross(normal, rotated_right), rotated_up) < 0.0 ? -1.0 : 1.0);
    v_uv0 = vertex.uv0;
    v_uv1 = vertex.uv1;
    v_color = billboard.color;
    v_clip_pos = frame.view_proj * vec4(world, 1.0);
    gl_Position = v_clip_pos;
    gl_ClipDistance[0] = view_clip_distance(frame, world);
}
