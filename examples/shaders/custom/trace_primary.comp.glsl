#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#define SCENE_TRACE_BVH
#include "scene_trace.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer TracePrimaryRoot {
    mat4 inverse_view_projection;
    vec4 camera_position;
    uint64_t scene;
    uint mode;
    uint width;
    uint height;
    uint split_x;
};

const uint MODE_DISTANCE = 0u; // mirrored as TraceMode.DISTANCE in software_rt.c3
const uint MODE_NORMAL = 1u; // mirrored as TraceMode.NORMAL in software_rt.c3
const float DISTANCE_FALLOFF = 20.0; // metres at which the distance shade reaches 63 percent
const float TRACE_FAR = 1.0e30;
const vec3 MISS_COLOR = vec3(0.02, 0.03, 0.08);

vec3 hashed_color(uint value) {
    uint hash = value * 747796405u + 2891336453u;
    hash = ((hash >> ((hash >> 28u) + 4u)) ^ hash) * 277803737u;
    hash = (hash >> 22u) ^ hash;
    return vec3(hash & 255u, (hash >> 8u) & 255u, (hash >> 16u) & 255u) / 255.0;
}

vec3 geometric_normal(SceneTraceRoot scene, SceneHit hit) {
    TraceInstanceGpu instance = TraceInstanceArray(scene.instances).values[hit.instance];
    GeometryRoot geometry = GeometryRoot(instance.geometry);
    uvec3 corners = pull_triangle(geometry, hit.primitive);
    vec3 a = pull_vec3(geometry.positions, corners.x);
    vec3 b = pull_vec3(geometry.positions, corners.y);
    vec3 c = pull_vec3(geometry.positions, corners.z);
    vec3 local = cross(b - a, c - a);
    mat3 world_to_local = mat3(
        instance.world_to_local_0.xyz,
        instance.world_to_local_1.xyz,
        instance.world_to_local_2.xyz
    );
    return normalize(world_to_local * local);
}

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    TracePrimaryRoot root = TracePrimaryRoot(dispatch.parameters);
    DispatchTextureGpu target = DispatchTexturesGpu(dispatch.textures).slots[0];
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x < root.split_x || pixel.x >= root.width || pixel.y >= root.height) return;

    vec2 uv = (vec2(pixel) + 0.5) / vec2(root.width, root.height);
    vec2 ndc = (uv * 2.0 - 1.0) * vec2(1.0, -1.0);
    vec4 near_point = root.inverse_view_projection * vec4(ndc, 1.0, 1.0);
    vec3 origin = root.camera_position.xyz;
    vec3 direction = normalize(near_point.xyz / near_point.w - origin);

    SceneTraceRoot scene = SceneTraceRoot(root.scene);
    SceneHit hit;
    vec3 color = MISS_COLOR;
    if (trace_scene(scene, origin, direction, TRACE_FAR, hit)) {
        if (root.mode == MODE_DISTANCE) {
            color = vec3(1.0 - exp(-hit.t / DISTANCE_FALLOFF));
        } else if (root.mode == MODE_NORMAL) {
            color = geometric_normal(scene, hit) * 0.5 + 0.5;
        } else {
            color = hashed_color(hit.instance);
        }
    }
    store_storage_texture(target.texture_index, ivec2(pixel), vec4(color, 1.0));
}
