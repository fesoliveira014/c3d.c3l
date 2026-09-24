#ifndef C3D_SCENE_TRACE_GLSL
#define C3D_SCENE_TRACE_GLSL

#if !defined(SCENE_TRACE_BVH)
#error "define SCENE_TRACE_BVH before including scene_trace.glsl"
#endif

#include "c3d_abi.glsl"
#include "buffer_reference.glsl"
#include "vertex_pull.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(BvhNodeArray, BvhNodeGpu);
GPU_DECLARE_READONLY_ARRAY_REF(TraceInstanceArray, TraceInstanceGpu);
GPU_DECLARE_READONLY_ARRAY_REF(PrimitiveArray, uint);

const float TRIANGLE_PARALLEL_EPSILON = 1e-8; // mirrored from maths/bounds.c3
const float TRACE_MIN_DIRECTION = 1e-30; // keeps a zero direction component finite in the slab test

struct SceneHit {
    uint instance;
    uint primitive;
    vec2 barycentrics;
    float t;
};

struct TraceRay {
    vec3 origin;
    vec3 direction;
    vec3 inverse_direction;
};

TraceRay make_trace_ray(vec3 origin, vec3 direction) {
    vec3 magnitude = max(abs(direction), vec3(TRACE_MIN_DIRECTION));
    vec3 inverse_direction = mix(-1.0 / magnitude, 1.0 / magnitude, greaterThanEqual(direction, vec3(0.0)));
    return TraceRay(origin, direction, inverse_direction);
}

bool trace_box(BvhNodeGpu node, TraceRay ray, float t_max) {
    vec3 low = (vec3(node.min_x, node.min_y, node.min_z) - ray.origin) * ray.inverse_direction;
    vec3 high = (vec3(node.max_x, node.max_y, node.max_z) - ray.origin) * ray.inverse_direction;
    vec3 near = min(low, high);
    vec3 far = max(low, high);
    float entry = max(max(near.x, near.y), max(near.z, 0.0));
    float exit = min(min(far.x, far.y), min(far.z, t_max));
    return entry <= exit;
}

float trace_box_entry(BvhNodeGpu node, TraceRay ray) {
    vec3 low = (vec3(node.min_x, node.min_y, node.min_z) - ray.origin) * ray.inverse_direction;
    vec3 high = (vec3(node.max_x, node.max_y, node.max_z) - ray.origin) * ray.inverse_direction;
    vec3 near = min(low, high);
    return max(max(near.x, near.y), max(near.z, 0.0));
}

bool trace_triangle(
    TraceRay ray,
    vec3 a,
    vec3 b,
    vec3 c,
    out float t,
    out vec2 weights
) {
    t = 0.0;
    weights = vec2(0.0);
    vec3 edge_ab = b - a;
    vec3 edge_ac = c - a;
    vec3 perpendicular = cross(ray.direction, edge_ac);
    float determinant = dot(edge_ab, perpendicular);
    if (abs(determinant) < TRIANGLE_PARALLEL_EPSILON) return false;

    float inverse_determinant = 1.0 / determinant;
    vec3 to_origin = ray.origin - a;
    float weight_b = dot(to_origin, perpendicular) * inverse_determinant;
    if (weight_b < 0.0 || weight_b > 1.0) return false;
    vec3 crossed = cross(to_origin, edge_ab);
    float weight_c = dot(ray.direction, crossed) * inverse_determinant;
    if (weight_c < 0.0 || weight_b + weight_c > 1.0) return false;
    t = dot(edge_ac, crossed) * inverse_determinant;
    weights = vec2(weight_b, weight_c);
    return t >= 0.0;
}

// Stacked nodes are re-tested when popped: t_max may have shrunk since they were pushed.
bool trace_next_node(
    BvhNodeArray nodes,
    TraceRay ray,
    float t_max,
    inout uint stack[BVH_STACK_DEPTH],
    inout uint stack_count,
    inout uint node_index
) {
    BvhNodeGpu node = nodes.values[node_index];
    if (node.count == 0u) {
        uint left = node.left_or_first;
        BvhNodeGpu left_node = nodes.values[left];
        BvhNodeGpu right_node = nodes.values[left + 1u];
        bool left_met = trace_box(left_node, ray, t_max);
        bool right_met = trace_box(right_node, ray, t_max);
        if (left_met && right_met) {
            bool left_nearer = trace_box_entry(left_node, ray) <= trace_box_entry(right_node, ray);
            stack[stack_count] = left_nearer ? left + 1u : left;
            stack_count++;
            node_index = left_nearer ? left : left + 1u;
            return true;
        }
        if (left_met || right_met) {
            node_index = left_met ? left : left + 1u;
            return true;
        }
    }
    while (stack_count > 0u) {
        stack_count--;
        uint candidate = stack[stack_count];
        if (trace_box(nodes.values[candidate], ray, t_max)) {
            node_index = candidate;
            return true;
        }
    }
    return false;
}

bool trace_instance(
    TraceInstanceGpu instance,
    uint row,
    vec3 origin,
    vec3 direction,
    bool first_hit,
    inout float t_max,
    inout SceneHit hit
) {
    vec3 local_origin = vec3(
        dot(instance.world_to_local_0, vec4(origin, 1.0)),
        dot(instance.world_to_local_1, vec4(origin, 1.0)),
        dot(instance.world_to_local_2, vec4(origin, 1.0))
    );
    vec3 local_direction = vec3(
        dot(instance.world_to_local_0.xyz, direction),
        dot(instance.world_to_local_1.xyz, direction),
        dot(instance.world_to_local_2.xyz, direction)
    );
    TraceRay ray = make_trace_ray(local_origin, local_direction);
    BvhNodeArray nodes = BvhNodeArray(instance.nodes);
    if (!trace_box(nodes.values[0], ray, t_max)) return false;

    GeometryRoot geometry = GeometryRoot(instance.geometry);
    PrimitiveArray primitives = PrimitiveArray(instance.primitives);
    uint stack[BVH_STACK_DEPTH];
    uint stack_count = 0u;
    uint node_index = 0u;
    bool found = false;
    do {
        BvhNodeGpu node = nodes.values[node_index];
        for (uint slot = 0u; slot < node.count; slot++) {
            uint primitive = primitives.values[node.left_or_first + slot];
            uvec3 corners = pull_triangle(geometry, primitive);
            float t;
            vec2 weights;
            bool met = trace_triangle(
                ray,
                pull_vec3(geometry.positions, corners.x),
                pull_vec3(geometry.positions, corners.y),
                pull_vec3(geometry.positions, corners.z),
                t,
                weights
            );
            if (!met || t >= t_max) continue;
            t_max = t;
            hit = SceneHit(
                row,
                primitive,
                weights,
                t
            );
            found = true;
            if (first_hit) return true;
        }
    } while (trace_next_node(
        nodes,
        ray,
        t_max,
        stack,
        stack_count,
        node_index
    ));
    return found;
}

bool trace_scene_walk(
    SceneTraceRoot scene,
    vec3 origin,
    vec3 direction,
    float t_max,
    bool first_hit,
    out SceneHit hit
) {
    hit = SceneHit(
        0u,
        0u,
        vec2(0.0),
        t_max
    );
    if (scene.instance_count == 0u) return false;
    TraceRay ray = make_trace_ray(origin, direction);
    BvhNodeArray nodes = BvhNodeArray(scene.top_nodes);
    if (!trace_box(nodes.values[0], ray, t_max)) return false;

    TraceInstanceArray instances = TraceInstanceArray(scene.instances);
    uint stack[BVH_STACK_DEPTH];
    uint stack_count = 0u;
    uint node_index = 0u;
    bool found = false;
    do {
        BvhNodeGpu node = nodes.values[node_index];
        for (uint slot = 0u; slot < node.count; slot++) {
            uint row = node.left_or_first + slot;
            bool met = trace_instance(
                instances.values[row],
                row,
                origin,
                direction,
                first_hit,
                t_max,
                hit
            );
            if (met) {
                found = true;
                if (first_hit) return true;
            }
        }
    } while (trace_next_node(
        nodes,
        ray,
        t_max,
        stack,
        stack_count,
        node_index
    ));
    return found;
}

bool trace_scene(
    SceneTraceRoot scene,
    vec3 origin,
    vec3 direction,
    float t_max,
    out SceneHit hit
) {
    return trace_scene_walk(
        scene,
        origin,
        direction,
        t_max,
        false,
        hit
    );
}

bool trace_scene_any(
    SceneTraceRoot scene,
    vec3 origin,
    vec3 direction,
    float t_max
) {
    SceneHit ignored;
    return trace_scene_walk(
        scene,
        origin,
        direction,
        t_max,
        true,
        ignored
    );
}

#endif
