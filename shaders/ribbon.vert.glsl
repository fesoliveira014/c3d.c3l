#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(RibbonPointArray, RibbonPointGpu);

const uint TANGENT_SCAN_LIMIT = 4u; // segments a joint looks past while a neighbour has zero length
const float SEGMENT_LENGTH_EPSILON_SQUARED = 1e-12; // squared metres below which two points coincide
const float CUSP_EPSILON_SQUARED = 1e-6; // squared length of the summed directions below which a joint doubles back
const float SIDE_EPSILON_SQUARED = 1e-8; // squared sine of the angle to the line of sight below which it is edge-on
const float EYE_EPSILON_SQUARED = 1e-12; // squared view distance below which a point sits on the eye

// The array ends with a point that has RIBBON_POINT_BREAK, so no segment joins a record past the last live point.
bool segment_joined(RibbonPointArray points, uint index) {
    RibbonPointGpu end = points.values[index + 1u];
    return (end.flags & RIBBON_POINT_BREAK) == 0u;
}

// Zero when no joined segment of positive length lies within the steps.
vec3 scan_direction(RibbonPointArray points, uint first, bool forward, uint steps) {
    for (uint step = 0u; step < steps; step++) {
        uint segment = forward ? first + step : first - step;
        if (!segment_joined(points, segment)) return vec3(0.0);
        vec3 direction = points.values[segment + 1u].position_width.xyz - points.values[segment].position_width.xyz;
        if (dot(direction, direction) > SEGMENT_LENGTH_EPSILON_SQUARED) return normalize(direction);
    }
    return vec3(0.0);
}

// A strip end has one direction; a joint that doubles back keeps the incoming one. Zero when the point has neither.
vec3 joint_tangent(RibbonPointArray points, uint point) {
    vec3 incoming = point > 0u ? scan_direction(points, point - 1u, false, min(TANGENT_SCAN_LIMIT, point)) : vec3(0.0);
    vec3 outgoing = scan_direction(points, point, true, TANGENT_SCAN_LIMIT);
    vec3 sum = incoming + outgoing;
    return dot(sum, sum) < CUSP_EPSILON_SQUARED ? incoming : normalize(sum);
}

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    RibbonPointArray points = RibbonPointArray(draw.instance_data);
    MeshVertexInput vertex = pull_mesh_vertex(geometry, uint(gl_VertexIndex));

    uint segment = uint(gl_InstanceIndex);
    RibbonPointGpu start = points.values[segment];
    RibbonPointGpu end = points.values[segment + 1u];
    bool at_end = vertex.position.y > 0.0;
    RibbonPointGpu point = at_end ? end : start;
    vec3 span = end.position_width.xyz - start.position_width.xyz;
    bool drawn = segment_joined(points, segment) && dot(span, span) > SEGMENT_LENGTH_EPSILON_SQUARED;

    vec3 center = drawn ? point.position_width.xyz : start.position_width.xyz;
    mat3 view_rotation = mat3(frame.view);
    vec3 view_center = (frame.view * vec4(center, 1.0)).xyz;
    bool orthographic = frame.proj[3][3] != 0.0;
    vec3 to_camera = orthographic || dot(view_center, view_center) < EYE_EPSILON_SQUARED
        ? vec3(0.0, 0.0, 1.0)
        : normalize(-view_center);

    vec3 tangent = drawn ? joint_tangent(points, segment + (at_end ? 1u : 0u)) : vec3(0.0);
    // A joint that doubles back holds the reverse of this segment's travel; the side axis must not flip along it.
    if (dot(tangent, span) < 0.0) tangent = -tangent;
    vec3 view_tangent = view_rotation * tangent;
    vec3 view_side = cross(view_tangent, to_camera);
    float side_length_squared = dot(view_side, view_side);
    view_side = side_length_squared > SIDE_EPSILON_SQUARED ? view_side * inversesqrt(side_length_squared) : vec3(0.0);

    mat3 view_inverse = transpose(view_rotation);
    vec3 side = view_inverse * view_side;
    vec3 normal = view_inverse * to_camera;
    float offset = drawn ? vertex.position.x * point.position_width.w : 0.0;
    vec3 world = center + side * offset;
    float u = vertex.position.x + 0.5;

    v_world_pos = world;
    v_normal = normal;
    v_tangent = vec4(tangent, dot(cross(normal, tangent), side) < 0.0 ? -1.0 : 1.0);
    v_uv0 = vec2(u, point.v);
    v_uv1 = v_uv0;
    v_billboard = vec3(u, point.v, 0.0);
    v_color = point.color;
    v_clip_pos = frame.view_proj * vec4(world, 1.0);
    gl_Position = v_clip_pos;
    gl_ClipDistance[0] = view_clip_distance(frame, world);
}
