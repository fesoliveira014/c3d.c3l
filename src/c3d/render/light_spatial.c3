module c3d::render;

import c3d::instrumentation @public;
import c3d::light;
import c3d::maths;
import c3d::shader;
import c3d::spatial::bvh;
import gpu;
import std::math;

const uint LIGHT_BOUND_SIGN @local = 0x80000000;
const float LIGHT_BOUND_ROUNDING @local = 8 * math::FLOAT_EPSILON;
const uint LIGHT_CLUSTER_MIN_FINITE_LIGHTS @private = 4096; // avoids tree-build cost for smaller raster lists
const float LIGHT_CLUSTER_MAX_MEAN_BOUND_AREA_RATIO @private = 0.25f; // avoids traversal overhead when bounds cover much of the root
const BvhBuildDesc LIGHT_CLUSTER_BVH_BUILD @private = {
    .bins = bvh::BVH_BUILD_DEFAULT.bins,
    .leaf_size = shader::CLUSTER_GROUP_SIZE,
};

struct LightSpatialData @private {
    Bvh tree;
    uint[] globals;
}

fn float expanded_light_bound(float value, bool maximum) @private {
    if (value == 0) return bitcast(maximum ? 1u : LIGHT_BOUND_SIGN | 1u, float);
    uint bits = bitcast(value, uint);
    if ((value > 0) == maximum) {
        bits++;
    } else {
        bits--;
    }
    return bitcast(bits, float);
}

fn LightSpatialData build_light_spatial_data(
    LightGpu[] lights,
    BvhBuildDesc desc = bvh::BVH_BUILD_DEFAULT,
    bool raster_admission = false,
) @private {
    if (raster_admission && lights.len < LIGHT_CLUSTER_MIN_FINITE_LIGHTS) return {};
    uint finite_count;
    uint global_count;
    foreach (light : lights) {
        if (light.kind == (uint)LightKind.DIRECTIONAL.ordinal || light.position_range.w == 0) {
            global_count++;
        } else {
            finite_count++;
        }
    }
    if (!finite_count || (raster_admission && finite_count < LIGHT_CLUSTER_MIN_FINITE_LIGHTS)) return {};

    Aabb[] boxes = alloc::alloc_array(tmem, Aabb, finite_count);
    uint[] source_indices = alloc::alloc_array(tmem, uint, finite_count);
    uint[] globals = alloc::alloc_array(tmem, uint, global_count);
    Aabb bounds;
    float bound_area_sum;
    uint finite_index;
    uint global_index;
    foreach (index, light : lights) {
        if (light.kind == (uint)LightKind.DIRECTIONAL.ordinal || light.position_range.w == 0) {
            globals[global_index++] = (uint)index;
            continue;
        }
        float radius = light.position_range.w;
        float radius_squared = radius * radius;
        if (!(radius > 0) || !math::is_finite(radius_squared) || radius_squared < math::FLOAT_MIN) return {};
        Vec3 position = light.position_range.xyz;
        Aabb box = { .min = position - radius, .max = position + radius };
        for (uint axis = 0; axis < 3; axis++) {
            if (!math::is_finite(box.min[axis]) || !math::is_finite(box.max[axis])) return {};
            // Rounded distance tests can admit points beyond a cancelling center +/- radius sum.
            float rounding = LIGHT_BOUND_ROUNDING * (math::abs(position[axis]) + radius);
            box.min[axis] = expanded_light_bound(box.min[axis] - rounding, false);
            box.max[axis] = expanded_light_bound(box.max[axis] + rounding, true);
            if (!math::is_finite(box.min[axis]) || !math::is_finite(box.max[axis])
                || !math::is_finite(box.min[axis] + box.max[axis])) return {};
        }
        if (raster_admission) {
            Vec3 size = box.max - box.min;
            bound_area_sum += 2 * (size.x * size.y + size.y * size.z + size.z * size.x);
        }
        boxes[finite_index] = box;
        source_indices[finite_index] = (uint)index;
        bounds = finite_index ? maths::aabb_merge(bounds, box) : box;
        finite_index++;
    }
    Vec3 size = bounds.max - bounds.min;
    float cost = 2 * (size.x * size.y + size.y * size.z + size.z * size.x) * (float)finite_count;
    if (!math::is_finite(cost) || cost == 0) return {};
    if (raster_admission && bound_area_sum >= cost * LIGHT_CLUSTER_MAX_MEAN_BOUND_AREA_RATIO) return {};

    Bvh tree = {
        .nodes = alloc::alloc_array(tmem, BvhNode, (sz)(2 * (usz)finite_count - 1)),
        .primitives = alloc::alloc_array(tmem, uint, finite_count),
    };
    bvh::build_box_bvh_into(&tree, boxes, desc)!!;
    foreach (&primitive : tree.primitives) *primitive = source_indices[*primitive];
    return { .tree = tree, .globals = globals };
}

fn gpu::GpuAddress? upload_light_spatial(
    Renderer* renderer,
    LightGpu[] lights,
    BvhBuildDesc desc = bvh::BVH_BUILD_DEFAULT,
    bool raster_admission = false,
) @private {
    instrumentation::@scope("view.light_spatial") {
        LightSpatialData data;
        instrumentation::@scope("view.light_spatial.build") {
            data = build_light_spatial_data(lights, desc, raster_admission);
        };
        if (!data.tree.nodes.len) return (gpu::GpuAddress)0;

        instrumentation::@scope("view.light_spatial.upload") {
            usz nodes_offset = LightSpatialRoot::size;
            usz indices_offset = nodes_offset + data.tree.nodes.len * BvhNodeGpu::size;
            usz globals_offset = align_up(indices_offset + data.tree.primitives.len * uint::size, STREAM_ALIGNMENT);
            usz bytes = globals_offset + data.globals.len * uint::size;
            Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
            gpu::MappedGpuSpan block = slot.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
            mem::copy(&block.bytes[nodes_offset], data.tree.nodes.ptr, data.tree.nodes.len * BvhNodeGpu::size);
            mem::copy(&block.bytes[indices_offset], data.tree.primitives.ptr, data.tree.primitives.len * uint::size);
            if (data.globals.len) mem::copy(&block.bytes[globals_offset], data.globals.ptr, data.globals.len * uint::size);
            *(LightSpatialRoot*)block.bytes.ptr = {
                .nodes = block.address + (gpu::GpuAddress)nodes_offset,
                .indices = block.address + (gpu::GpuAddress)indices_offset,
                .globals = data.globals.len ? block.address + (gpu::GpuAddress)globals_offset : (gpu::GpuAddress)0,
                .global_count = (uint)data.globals.len,
                .node_count = (uint)data.tree.nodes.len,
            };
            return block.address;
        };
    };
}
