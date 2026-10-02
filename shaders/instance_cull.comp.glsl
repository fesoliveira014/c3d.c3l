#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "buffer_reference.glsl"
#include "instance_effects.glsl"

layout(local_size_x = INSTANCE_CULL_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

GPU_DECLARE_READONLY_ARRAY_REF(CullInstances, InstanceGpu);
GPU_DECLARE_READONLY_ARRAY_REF(CullBillboards, BillboardGpu);
GPU_DECLARE_WRITEONLY_ARRAY_REF(VisibleOutput, uint);
GPU_DECLARE_READONLY_ARRAY_REF(LodMetadata, LodMetadataGpu);
layout(buffer_reference, std430, buffer_reference_align = 16) buffer LodHistory {
    LodHistoryGpu values[];
};

// instance_count sits at offset 4 in both indirect command layouts.
layout(buffer_reference, std430, buffer_reference_align = 4) buffer CullArgs {
    uint first_count;
    uint instance_count;
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

void select_lod(InstanceCullRoot root, uint source) {
    mat4 model = CullInstances(root.instances).values[source].model;
    vec3 center = (model * vec4((root.bounds_min.xyz + root.bounds_max.xyz) * 0.5, 1.0)).xyz;
    mat3 axes = mat3(model);
    mat3 reach = mat3(abs(axes[0]), abs(axes[1]), abs(axes[2]));
    float radius = length(reach * ((root.bounds_max.xyz - root.bounds_min.xyz) * 0.5) + root.lod_reach.xyz);
    float size = radius == 0.0 ? 0.0 : (root.lod_projection.z != 0.0
        ? 2.0 * radius / root.lod_projection.y
        : radius * root.lod_projection.x / distance(center, root.lod_camera_bias.xyz));
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
    LodHistory(root.lod_current).values[source] = LodHistoryGpu(model, level, generation, (!valid || previous != level) ? 1u : 0u, 0u);
    atomicAdd(CullCounter(root.counter).lod_selected[level], 1u);
}

void main() {
    InstanceCullRoot root = InstanceCullRoot(pc.root_gpu);
    uint slot = gl_GlobalInvocationID.x;
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
    if (root.lod_mode == LOD_SELECT) {
        select_lod(root, source);
        return;
    }
    if (root.lod_mode == LOD_CULL) {
        if (LodHistory(root.lod_current).values[source].level != root.lod_level
            || LodMetadata(root.lod_metadata).values[source].parity != root.lod_parity) return;
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
        mat4 model = CullInstances(root.instances).values[source].model;
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
        if (!box_visible(root, model, margin)) return;
        center = (model * vec4((root.bounds_min.xyz + root.bounds_max.xyz) * 0.5, 1.0)).xyz;
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
