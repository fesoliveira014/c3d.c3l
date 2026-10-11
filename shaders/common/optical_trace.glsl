#ifndef C3D_OPTICAL_TRACE_GLSL
#define C3D_OPTICAL_TRACE_GLSL

#include "scene_trace.glsl"
#include "optical_surface.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(OpticalTraceKeyArray, OpticalTraceKeyGpu);
GPU_DECLARE_READONLY_ARRAY_REF(OpticalTintArray, vec4);

struct OpticalHit {
    SceneHit hit;
    OpticalTraceKeyGpu key;
    vec3 throughput;
    bool found;
};

bool optical_key_before(OpticalTraceKeyGpu first, uint first_primitive, OpticalTraceKeyGpu second, uint second_primitive) {
    if (first.node_index != second.node_index) return first.node_index < second.node_index;
    if (first.node_generation != second.node_generation) return first.node_generation < second.node_generation;
    if (first.part_index != second.part_index) return first.part_index < second.part_index;
    if (first.range_index != second.range_index) return first.range_index < second.range_index;
    if (first.instance_index != second.instance_index) return first.instance_index < second.instance_index;
    return first_primitive < second_primitive;
}

vec3 optical_hit_normal(
    TraceInstanceGpu instance,
    GeometryRoot geometry,
    StandardMaterialGpu material,
    uvec3 corners,
    vec3 weights,
    vec2 uv0,
    vec2 uv1,
    bool back_face
) {
    vec3 first = pull_vec3(geometry.positions, corners.x);
    vec3 second = pull_vec3(geometry.positions, corners.y);
    vec3 third = pull_vec3(geometry.positions, corners.z);
    vec3 normal = transform_normal(instance, cross(second - first, third - first));
    if ((geometry.flags & GEOMETRY_HAS_NORMALS) != 0u) {
        normal = normalize(transform_normal(instance, pull_vec3(geometry.normals, corners.x)) * weights.x
            + transform_normal(instance, pull_vec3(geometry.normals, corners.y)) * weights.y
            + transform_normal(instance, pull_vec3(geometry.normals, corners.z)) * weights.z);
    }

    if ((material.map_flags & MATERIAL_MAP_NORMAL) != 0u && material.normal_scale != 0.0) {
        vec3 mapped = decode_normal(
            optical_map(material.normal_map, material.map_flags, MATERIAL_MAP_NORMAL, uv0, uv1).rgb,
            material.normal_scale,
            (material.map_flags & MATERIAL_MAP_NORMAL_RG) != 0u
        );
        if ((geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u) {
            normal = tangent_normal(normal, hit_tangent(instance, geometry, corners, weights), mapped);
        } else {
            vec2 first_uv = corner_map_uv(material.normal_map, material.map_flags, geometry, corners, vec3(1.0, 0.0, 0.0));
            vec2 second_uv = corner_map_uv(material.normal_map, material.map_flags, geometry, corners, vec3(0.0, 1.0, 0.0));
            vec2 third_uv = corner_map_uv(material.normal_map, material.map_flags, geometry, corners, vec3(0.0, 0.0, 1.0));
            normal = derivative_normal(
                normal,
                mapped,
                transform_point(instance, second) - transform_point(instance, first),
                transform_point(instance, third) - transform_point(instance, first),
                second_uv - first_uv,
                third_uv - first_uv
            );
        }
    }

    return back_face ? -normal : normal;
}

void optical_consider_hit(
    SceneTraceRoot scene,
    uint64_t key_address,
    SceneHit hit,
    vec3 to_light,
    uint layers,
    OpticalHit cursor,
    inout OpticalHit best,
    inout bool blocked
) {
    OpticalTraceKeyGpu key = OpticalTraceKeyArray(key_address).values[hit.instance];
    if ((key.layers & layers) == 0u) return;

    TraceInstanceGpu instance = trace_instance(scene, hit.instance);
    GeometryRoot geometry = GeometryRoot(instance.geometry);
    uvec3 corners = pull_triangle(geometry, hit.primitive);
    vec3 first = pull_vec3(geometry.positions, corners.x);
    vec3 edge_first = pull_vec3(geometry.positions, corners.y) - first;
    vec3 edge_second = pull_vec3(geometry.positions, corners.z) - first;
    vec3 local_light = vec3(
        dot(instance.world_to_local_0.xyz, to_light),
        dot(instance.world_to_local_1.xyz, to_light),
        dot(instance.world_to_local_2.xyz, to_light)
    );
    bool back_face = dot(cross(edge_first, edge_second), local_light) <= 0.0;
    if (back_face && (instance.flags & TRACE_INSTANCE_DOUBLE_SIDED) == 0u) return;

    if (instance.material_kind != MATERIAL_KIND_PHYSICAL) {
        if ((instance.flags & TRACE_INSTANCE_ALPHA_MASK) == 0u || trace_surface_passes(instance, hit)) blocked = true;
        return;
    }
    PhysicalMaterialGpu material = PhysicalMaterialGpu(instance.material);
    vec3 weights = vec3(1.0 - hit.barycentrics.x - hit.barycentrics.y, hit.barycentrics);
    vec2 uv0 = hit_uv(geometry.uv0, corners, weights);
    vec2 uv1 = hit_uv(geometry.uv1, corners, weights);
    vec4 base = material.standard.base_color;
    float metallic = material.standard.metallic;
    if ((material.standard.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
        base *= optical_map(material.standard.base_color_map, material.standard.map_flags, MATERIAL_MAP_BASE_COLOR, uv0, uv1);
    }
    if ((geometry.flags & GEOMETRY_HAS_COLORS) != 0u) {
        base *= pull_vec4(geometry.colors, corners.x) * weights.x
            + pull_vec4(geometry.colors, corners.y) * weights.y
            + pull_vec4(geometry.colors, corners.z) * weights.z;
    }
    if (key.instance_color != 0ul) base *= OpticalTintArray(key.instance_color).values[0];
    if ((material.standard.flags & MATERIAL_ALPHA_MASK) != 0u && base.a < material.standard.alpha_cutoff) return;

    float transmission = material.transmission;
    if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_TRANSMISSION) != 0u) {
        transmission = clamp(transmission * optical_map(
            material.transmission_map, material.extension_map_flags, PHYSICAL_EXTENSION_MAP_TRANSMISSION, uv0, uv1
        ).r, 0.0, 1.0);
    }
    if (transmission == 0.0) {
        if ((material.standard.flags & MATERIAL_ALPHA_BLEND) == 0u) blocked = true;
        return;
    }

    // The cursor orders from the light toward the receiver, with exact distance keys and canonical ties.
    if (cursor.found && (hit.t > cursor.hit.t || (hit.t == cursor.hit.t
        && !optical_key_before(cursor.key, cursor.hit.primitive, key, hit.primitive)))) return;
    if (best.found && (hit.t < best.hit.t || (hit.t == best.hit.t
        && !optical_key_before(key, hit.primitive, best.key, best.hit.primitive)))) return;

    if ((material.standard.map_flags & MATERIAL_MAP_METALLIC_ROUGHNESS) != 0u) {
        metallic = clamp(metallic * optical_map(
            material.standard.metallic_roughness_map,
            material.standard.map_flags,
            MATERIAL_MAP_METALLIC_ROUGHNESS,
            uv0,
            uv1
        ).b, 0.0, 1.0);
    }
    vec3 normal = optical_hit_normal(instance, geometry, material.standard, corners, weights, uv0, uv1, back_face);
    OpticalSurface surface = optical_surface(material, base, metallic, normal, uv0, uv1);
    vec3 model_scale = vec3(
        length(vec3(instance.local_to_world_0.x, instance.local_to_world_1.x, instance.local_to_world_2.x)),
        length(vec3(instance.local_to_world_0.y, instance.local_to_world_1.y, instance.local_to_world_2.y)),
        length(vec3(instance.local_to_world_0.z, instance.local_to_world_1.z, instance.local_to_world_2.z))
    );
    best.hit = hit;
    best.key = key;
    best.throughput = optical_surface_throughput(surface, to_light, model_scale);
    best.found = true;
}

void optical_find_in_scene(
    SceneTraceRoot scene,
    uint64_t keys,
    vec3 origin,
    vec3 direction,
    float distance,
    uint mask,
    uint layers,
    OpticalHit cursor,
    inout OpticalHit best,
    inout bool blocked
) {
    if (scene.instance_count == 0u) return;

#ifdef SCENE_TRACE_RAY_QUERY
    rayQueryEXT query;
    GPU_RAY_QUERY_INITIALIZE(query, scene.tlas_index, gl_RayFlagsNoOpaqueEXT, mask, origin, 0.0, direction, distance);
    while (rayQueryProceedEXT(query)) {
        if (rayQueryGetIntersectionTypeEXT(query, false) != gl_RayQueryCandidateIntersectionTriangleEXT) continue;

        SceneHit hit = SceneHit(
            rayQueryGetIntersectionInstanceCustomIndexEXT(query, false),
            rayQueryGetIntersectionPrimitiveIndexEXT(query, false),
            rayQueryGetIntersectionBarycentricsEXT(query, false),
            rayQueryGetIntersectionTEXT(query, false)
        );
        optical_consider_hit(scene, keys, hit, direction, layers, cursor, best, blocked);
    }
#else
    for (uint row = 0u; row < scene.instance_count; row++) {
        TraceInstanceGpu instance = trace_instance(scene, row);
        if ((instance.mask & mask) == 0u) continue;

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
        if (!trace_box(nodes.values[0], ray, distance)) continue;

        GeometryRoot geometry = GeometryRoot(instance.geometry);
        PrimitiveArray primitives = PrimitiveArray(instance.primitives);
        uint stack[BVH_STACK_DEPTH];
        uint stack_count = 0u;
        uint node_index = 0u;
        do {
            BvhNodeGpu node = nodes.values[node_index];
            for (uint slot = 0u; slot < node.count; slot++) {
                uint primitive = primitives.values[node.left_or_first + slot];
                uvec3 corners = pull_triangle(geometry, primitive);
                float t;
                float determinant;
                vec2 weights;
                if (!trace_triangle(
                    ray,
                    pull_vec3(geometry.positions, corners.x),
                    pull_vec3(geometry.positions, corners.y),
                    pull_vec3(geometry.positions, corners.z),
                    t,
                    weights,
                    determinant
                ) || t >= distance) continue;

                optical_consider_hit(scene, keys, SceneHit(row, primitive, weights, t), direction, layers, cursor, best, blocked);
            }
        } while (trace_next_node(nodes, ray, distance, stack, stack_count, node_index));
    }
#endif
}

vec3 optical_ray_visibility(FrameRoot frame, LightGpu light, vec3 world_position, vec3 normal) {
    OpticalShadowsGpu optical = OpticalShadowsGpu(frame.optical_shadows);
    if (optical.trace == 0ul) return vec3(1.0);

    OpticalTraceGpu trace = OpticalTraceGpu(optical.trace);
    if ((trace.flags & OPTICAL_TRACE_OVER_CAP) != 0u) return vec3(0.0);

    vec3 origin = world_position + normal * TRACE_SURFACE_OFFSET;
    vec3 direction = -light.direction_cos_outer.xyz;
    float distance = RT_SHADOW_FAR;
    if (light.kind != LIGHT_DIRECTIONAL) {
        vec3 offset = light.position_range.xyz - origin;
        distance = length(offset);
        if (distance == 0.0) return vec3(1.0);

        direction = offset / distance;
    }

    OpticalHit cursor;
    cursor.found = false;
    vec3 product = vec3(1.0);
    uint groups = 0u;
    for (;;) {
        OpticalHit next;
        next.found = false;
        bool blocked = false;
        optical_find_in_scene(
            SceneTraceRoot(frame.trace), trace.generic_keys, origin, direction, distance,
            TRACE_MASK_SHADOW_CASTER, light.layers, cursor, next, blocked
        );
        if (trace.scene != 0ul) {
            optical_find_in_scene(
                SceneTraceRoot(trace.scene), trace.blend_keys, origin, direction, distance,
                TRACE_MASK_OPTICAL, light.layers, cursor, next, blocked
            );
        }
        if (blocked) return vec3(0.0);
        if (!next.found) return product;

        if (!cursor.found || next.hit.t != cursor.hit.t) {
            groups++;
            if (groups > optical.capacity) return vec3(0.0);
        }
        product *= next.throughput;
        cursor = next;
    }
}

#endif
