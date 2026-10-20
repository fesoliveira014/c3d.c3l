#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "buffer_reference.glsl"
#include "dispatch_grid.glsl"
#include "instance_effects.glsl"
#include "quadtree_morph.glsl"

layout(local_size_x = INSTANCE_CULL_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

GPU_DECLARE_READONLY_ARRAY_REF(CullInstances, InstanceGpu);
GPU_DECLARE_READONLY_ARRAY_REF(CullBounds, mat4);
GPU_DECLARE_READONLY_ARRAY_REF(CullBillboards, BillboardGpu);
GPU_DECLARE_WRITEONLY_ARRAY_REF(VisibleOutput, uint);
GPU_DECLARE_READONLY_ARRAY_REF(LodMetadata, LodMetadataGpu);
GPU_DECLARE_READONLY_ARRAY_REF(QuadtreeNodes, QuadtreeNodeGpu);
GPU_DECLARE_READONLY_ARRAY_REF(QuadtreeDepths, uint);
layout(buffer_reference, std430, buffer_reference_align = 16) buffer LodHistory {
    LodHistoryGpu values[];
};

// One word per instance: QUADTREE_SPLIT is the node's split flag, QUADTREE_DRAW the view's draw flag.
layout(buffer_reference, std430, buffer_reference_align = 4) buffer QuadtreeHistory {
    uint values[];
};

// instance_count sits at offset 4 in both indirect command layouts.
layout(buffer_reference, std430, buffer_reference_align = 4) buffer CullArgs {
    uint first_count;
    uint instance_count;
};

// A DEVICE batch's live count, written by the dispatch that filled its records.
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer LiveCount {
    uint value;
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer CullCounter {
    uint visible;
    uint lod_visible[LOD_LEVEL_COUNT];
    uint lod_selected[LOD_LEVEL_COUNT];
};

// Keys follow the list at an 8-byte boundary, below the 16-byte default of the array macros.
layout(buffer_reference, std430, buffer_reference_align = 8) writeonly buffer SortKeys {
    uint64_t values[];
};

// The record's instance composed with the batch node's world.
mat4 instance_world(InstanceCullRoot root, mat4 record_model) {
    return root.node_world * record_model;
}

bool box_visible(InstanceCullRoot root, mat4 model, float margin) {
    vec3 corners[8];
    for (uint corner = 0u; corner < 8u; corner++) {
        vec3 local = vec3(
            (corner & 1u) != 0u ? root.bounds_max.x : root.bounds_min.x,
            (corner & 2u) != 0u ? root.bounds_max.y : root.bounds_min.y,
            (corner & 4u) != 0u ? root.bounds_max.z : root.bounds_min.z
        );
        corners[corner] = (model * vec4(local, 1.0)).xyz;
    }
    for (uint plane = 0u; plane < 6u; plane++) {
        vec4 coefficients = root.planes[plane];
        bool outside = true;
        for (uint corner = 0u; corner < 8u; corner++) {
            if (dot(coefficients.xyz, corners[corner]) + coefficients.w >= -margin) {
                outside = false;
                break;
            }
        }
        if (outside) return false;
    }
    return true;
}

// Mirrored as instance_sort_key in instance_sort.c3; descending order draws far to near, zero marks an empty slot.
uint64_t sort_key(float view_depth, uint source) {
    uint bits = floatBitsToUint(view_depth);
    bits ^= (bits & 0x80000000u) != 0u ? 0xFFFFFFFFu : 0x80000000u;
    return (uint64_t(bits) << 32) | uint64_t(~source);
}

// Height of a sphere as a share of the output height; infinite at the sphere's centre.
float sphere_size(InstanceCullRoot root, vec3 center, float radius) {
    return radius == 0.0 ? 0.0 : (root.lod_projection.z != 0.0
        ? 2.0 * radius / root.lod_projection.y
        : radius * root.lod_projection.x / distance(center, root.lod_camera_bias.xyz));
}

// Mirrors the radius of transformed_box_sphere in maths/bounds.c3: turning the instance leaves it unchanged, where its
// world bounding box grows by up to 1.41 times at 45 degrees. Shear under-bounds; LOD only.
float bounding_radius(mat4 model, vec3 half_extent, vec3 reach) {
    vec3 axis_scale = vec3(length(model[0].xyz), length(model[1].xyz), length(model[2].xyz));
    return length(axis_scale * half_extent + reach);
}

// Height of the instance's bound sphere, with the sway reach, as a share of the output height.
float projected_size(InstanceCullRoot root, mat4 model) {
    vec3 center = (model * vec4((root.bounds_min.xyz + root.bounds_max.xyz) * 0.5, 1.0)).xyz;
    vec3 half_extent = (root.bounds_max.xyz - root.bounds_min.xyz) * 0.5;
    return sphere_size(root, center, bounding_radius(model, half_extent, root.lod_reach.xyz));
}

float quadtree_size(InstanceCullRoot root, mat4 model) {
    vec3 center = (model * vec4((root.bounds_min.xyz + root.bounds_max.xyz) * 0.5, 1.0)).xyz;
    vec3 half_extent = (root.bounds_max.xyz - root.bounds_min.xyz) * 0.5;
    return sphere_size(root, center, bounding_radius(model, half_extent, vec3(0.0)));
}

void select_lod(InstanceCullRoot root, uint source) {
    mat4 model = instance_world(root, CullInstances(root.instances).values[source].model);
    float size = projected_size(root, model);
    if (size > 0.0 && !isinf(size)) size = exp2(log2(size) + root.lod_camera_bias.w);
    uint generation = LodMetadata(root.lod_metadata).values[source].generation;
    bool valid = root.lod_history_valid != 0u;
    uint previous = 0u;
    if (valid) {
        LodHistoryGpu history = LodHistory(root.lod_previous).values[source];
        valid = history.generation == generation;
        previous = history.level;
    }
    uint level = valid ? previous : 0u;
    if (isinf(size)) {
        level = 0u;
    } else {
        while (level + 1u < root.lod_level_count && size < root.lod_thresholds[level / 4u][level % 4u]) level++;
        while (valid && level > 0u && size > root.lod_thresholds[(level - 1u) / 4u][(level - 1u) % 4u] * (1.0 + root.lod_projection.w)) level--;
    }
    LodHistory(root.lod_current).values[source] = LodHistoryGpu(model, level, generation, (!valid || (previous != level && root.lod_animated == 0u)) ? 1u : 0u, 0u);
    atomicAdd(CullCounter(root.counter).lod_selected[level], 1u);
}

// Distance from a point to the nearest point of the instance's box. Shear under-bounds; LOD only.
float box_distance(InstanceCullRoot root, mat4 model, vec3 point) {
    vec3 axis_scale = vec3(length(model[0].xyz), length(model[1].xyz), length(model[2].xyz));
    vec3 center = (model * vec4((root.bounds_min.xyz + root.bounds_max.xyz) * 0.5, 1.0)).xyz;
    vec3 half_extent = (root.bounds_max.xyz - root.bounds_min.xyz) * 0.5 * axis_scale;

    vec3 offset = point - center;
    vec3 local = abs(vec3(
        dot(model[0].xyz, offset) / axis_scale.x,
        dot(model[1].xyz, offset) / axis_scale.y,
        dot(model[2].xyz, offset) / axis_scale.z
    ));
    return length(max(local - half_extent, vec3(0.0)));
}

bool quadtree_box_splits(InstanceCullRoot root, uint node, bool was_split) {
    QuadtreeGpu tree = QuadtreeGpu(root.quadtree_params);
    uint depth = QuadtreeDepths(root.quadtree_depths).values[node];
    if (root.lod_projection.z != 0.0) {
        float size = tree.levels[depth].extent * root.quadtree_world_scale * root.quadtree_pixel_scale;
        return was_split ? size >= tree.split_pixels / (1.0 + tree.hysteresis) : size > tree.split_pixels;
    }

    float range = quadtree_range(tree, depth, root.quadtree_pixel_scale, root.quadtree_world_scale);
    float nearest = box_distance(
        root,
        instance_world(root, CullInstances(root.instances).values[node].model),
        root.lod_camera_bias.xyz
    );
    return nearest < (was_split ? range * (1.0 + tree.hysteresis) : range);
}

bool quadtree_splits(InstanceCullRoot root, uint node) {
    if (QuadtreeNodes(root.quadtree_nodes).values[node].children == 0u) return false;

    bool was_split = root.quadtree_history_valid != 0u
        && (QuadtreeHistory(root.lod_previous).values[node] & QUADTREE_SPLIT) != 0u;
    if (root.quadtree_params != 0ul) return quadtree_box_splits(root, node, was_split);

    float size = quadtree_size(root, instance_world(root, CullInstances(root.instances).values[node].model))
        * root.quadtree_height_pixels;
    return was_split ? size >= root.quadtree_split_pixels / (1.0 + root.quadtree_hysteresis)
        : size > root.quadtree_split_pixels;
}

void select_quadtree(InstanceCullRoot root, uint node) {
    bool splits = quadtree_splits(root, node);
    bool draw = !splits;
    uint ancestor = QuadtreeNodes(root.quadtree_nodes).values[node].parent;
    for (uint depth = 0u; draw && depth < MAX_QUADTREE_DEPTH && ancestor != QUADTREE_ROOT; depth++) {
        draw = quadtree_splits(root, ancestor);
        ancestor = QuadtreeNodes(root.quadtree_nodes).values[ancestor].parent;
    }
    QuadtreeHistory(root.lod_current).values[node] = (splits ? QUADTREE_SPLIT : 0u) | (draw ? QUADTREE_DRAW : 0u);
}

void main() {
    InstanceCullRoot root = InstanceCullRoot(pc.root_gpu);
    uint slot = linear_group_index(INSTANCE_CULL_GROUP_SIZE);
    if (root.lod_mode == RIBBON_SEGMENTS) {
        if (slot != 0u) return;
        uint points = LiveCount(root.live_count).value;
        CullArgs(root.args).instance_count = points > 1u ? min(points - 1u, root.count) : 0u;
        return;
    }
    if (root.lod_mode == LOD_FINALIZE) {
        if (slot != 0u) return;
        if (root.args == 0ul) {
            atomicAdd(CullCounter(root.counter).lod_selected[0], root.count);
            if (root.lod_count_visible != 0u) {
                atomicAdd(CullCounter(root.counter).visible, root.count);
                atomicAdd(CullCounter(root.counter).lod_visible[0], root.count);
            }
        } else {
            CullArgs(root.args).instance_count = CullArgs(root.lod_source_args).instance_count;
        }
        return;
    }
    if (slot >= root.count) return;
    uint source = root.first + slot;
    if (root.live_count != 0ul && source >= LiveCount(root.live_count).value) return;
    if (root.lod_mode == LOD_SELECT) {
        select_lod(root, source);
        return;
    }
    if (root.lod_mode == QUADTREE_SELECT) {
        select_quadtree(root, source);
        return;
    }
    if (root.lod_mode == QUADTREE_CULL
        && (QuadtreeHistory(root.lod_current).values[source] & QUADTREE_DRAW) == 0u) return;
    if (root.lod_mode == LOD_CULL) {
        uint parity = LodMetadata(root.lod_metadata).values[source].parity;
        if (root.lod_animated != 0u) {
            parity = uint(CullInstances(root.bounds_instances).values[source].normal_1.w);
        }

        if (LodHistory(root.lod_current).values[source].level != root.lod_level
            || parity != root.lod_parity) return;
    }
    vec3 center;
    if (root.kind == INSTANCE_KIND_BILLBOARD) {
        BillboardGpu billboard = CullBillboards(root.instances).values[source];
        if (billboard.position_width.w == 0.0 || billboard.direction_height.w == 0.0) return;
        center = billboard.position_width.xyz;
        float radius = 0.5 * length(vec2(billboard.position_width.w, billboard.direction_height.w));
        for (uint plane = 0u; plane < 6u; plane++) {
            vec4 coefficients = root.planes[plane];
            if (dot(coefficients.xyz, center) + coefficients.w < -radius) return;
        }
    } else {
        mat4 model = instance_world(root, CullInstances(root.instances).values[source].model);
        float margin = 0.0;
        if (root.instance_effects != 0ul) {
            InstanceEffectsGpu effects = InstanceEffectsGpu(root.instance_effects);
            margin = effects.sway.direction_amplitude.w;
            // Only a complete collapse is dropped, the same scale the vertex stage draws with.
            if (effects.fade_end > 0.0) {
                float seed = CullInstances(root.instances).values[source].normal_0.w;
                if (instance_fade_scale(effects, instance_anchor(effects, model), seed) == 0.0) return;
            }
        }
        mat4 bounds_model = root.bounds_instances == 0ul || root.lod_animated != 0u ? model
            : instance_world(root, CullBounds(root.bounds_instances).values[source]);

        if (!box_visible(root, bounds_model, margin)) return;

        center = (bounds_model * vec4((root.bounds_min.xyz + root.bounds_max.xyz) * 0.5, 1.0)).xyz;
    }
    uint index = atomicAdd(CullArgs(root.args).instance_count, 1u);
    VisibleOutput(root.visible).values[index] = source;
    if (root.keys != 0ul) {
        float depth = dot(root.depth_axis.xyz, center) + root.depth_axis.w;
        SortKeys(root.keys).values[index] = sort_key(depth, source);
    }
    atomicAdd(CullCounter(root.counter).visible, 1u);
    if (root.lod_mode == LOD_CULL && root.lod_count_visible != 0u) {
        atomicAdd(CullCounter(root.counter).lod_visible[root.lod_level], 1u);
    }
}
