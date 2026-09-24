module c3d::spatial::bvh;

import c3d;
import c3d::maths;
import std::math;

<*
 Most node levels a build produces; each traversal level stacks this many entries.
*>
const uint BVH_MAX_DEPTH = 32; // mirrored as BVH_STACK_DEPTH in c3d.abi; 128 bytes of stack per level per invocation

<*
 Twelve bins, leaves of up to four primitives.
*>
const BvhBuildDesc BVH_BUILD_DEFAULT = { .bins = 12, .leaf_size = 4 };

const Aabb EMPTY_BOX @local = {
    .min = { math::FLOAT_MAX, math::FLOAT_MAX, math::FLOAT_MAX },
    .max = { -math::FLOAT_MAX, -math::FLOAT_MAX, -math::FLOAT_MAX },
};

<*
 Split candidates per axis and the leaf size a split must beat.
*>
struct BvhBuildDesc {
    uint bins;
    uint leaf_size;
}

<*
 One node; count 0 marks an interior node whose children are left_or_first and left_or_first + 1.
*>
struct BvhNode {
    float[3] min;
    uint     left_or_first;
    float[3] max;
    uint     count;
}
$assert BvhNode::size == 32;
$assert $reflect(BvhNode.left_or_first).offset == 12;
$assert $reflect(BvhNode.max).offset == 16;
$assert $reflect(BvhNode.count).offset == 28;

<*
 Nodes in depth-first order and the primitive ids its leaves cover.
 A leaf covers primitives[left_or_first .. left_or_first + count).
*>
struct Bvh {
    BvhNode[] nodes;
    uint[]    primitives;
    Aabb      bounds;
}

<*
 Nearest primitive a ray met.
*>
struct BvhHit {
    uint  primitive;
    float distance;
    Vec3  barycentric;
}

struct TraceStack @local {
    uint[BVH_MAX_DEPTH]  nodes;
    float[BVH_MAX_DEPTH] entries;
    uint                 count;
}

struct BuildState @local {
    BvhNode[] nodes;
    uint[]    primitives;
    Aabb[]    boxes;
    Vec3[]    centroids;
    uint[]    bin_of;
    Aabb[]    bin_boxes;
    uint[]    bin_counts;
    float[]   right_costs;
    uint      node_count;
    uint      bins;
    uint      leaf_size;
}

<*
 Nearest two-sided triangle hit closer than distance_limit.
 @param [&in] self : "Built by build_triangle_bvh from the same arrays."
 @param [&out] hit : "Untouched when nothing is hit."
*>
fn bool Bvh.trace(
    &self,
    Vec3[] positions,
    uint[] indices,
    Ray ray,
    float distance_limit,
    BvhHit* hit,
) {
    return traverse(
        bvh:            self,
        positions:      positions,
        indices:        indices,
        ray:            ray,
        distance_limit: distance_limit,
        first_hit:      false,
        hit:            hit,
    );
}

<*
 Whether any two-sided triangle lies closer than distance_limit.
 @param [&in] self : "Built by build_triangle_bvh from the same arrays."
*>
fn bool Bvh.trace_any(
    &self,
    Vec3[] positions,
    uint[] indices,
    Ray ray,
    float distance_limit,
) {
    BvhHit ignored;
    return traverse(
        bvh:            self,
        positions:      positions,
        indices:        indices,
        ray:            ray,
        distance_limit: distance_limit,
        first_hit:      true,
        hit:            &ignored,
    );
}

<*
 Whether the arrays form a triangle list the builders accept.
 @param indices : "Empty for a triangle list of positions."
 @pure
*>
fn bool triangle_list_valid(Vec3[] positions, uint[] indices) {
    if (positions.len < 3 || indices.len % 3 != 0) return false;
    if (!indices.len && positions.len % 3 != 0) return false;
    foreach (index : indices) {
        if (index >= positions.len) return false;
    }
    return true;
}

<*
 Binned-SAH BVH over an indexed triangle mesh or a triangle list.
 Scratch lives in the temp allocator.
 @param allocator : "Owns the result; release with free_bvh."
 @param indices : "Empty for a triangle list of positions."
 @return? c3d::INVALID_ARGUMENT
 @require desc.bins >= 2 && desc.leaf_size >= 1
*>
fn Bvh? build_triangle_bvh(
    Allocator allocator,
    Vec3[] positions,
    uint[] indices,
    BvhBuildDesc desc = BVH_BUILD_DEFAULT,
) {
    if (!triangle_list_valid(positions, indices)) return c3d::INVALID_ARGUMENT~;

    usz triangle_count = indices.len ? indices.len / 3 : positions.len / 3;
    Aabb[] boxes = alloc::alloc_array(tmem, Aabb, (sz)triangle_count);
    foreach (usz triangle, &box : boxes) {
        Vec3[3] corners = triangle_corners(positions, indices, (uint)triangle);
        *box = {
            .min = math::min(math::min(corners[0], corners[1]), corners[2]),
            .max = math::max(math::max(corners[0], corners[1]), corners[2]),
        };
    }
    return build(allocator, boxes, desc);
}

<*
 Binned-SAH BVH over boxes; leaf primitives are box indices.
 Scratch lives in the temp allocator.
 @param allocator : "Owns the result; release with free_bvh."
 @return? c3d::INVALID_ARGUMENT
 @require desc.bins >= 2 && desc.leaf_size >= 1
*>
fn Bvh? build_box_bvh(Allocator allocator, Aabb[] boxes, BvhBuildDesc desc = BVH_BUILD_DEFAULT) {
    if (!boxes.len) return c3d::INVALID_ARGUMENT~;
    return build(allocator, boxes, desc);
}

<*
 Release a BVH with the allocator that built it.
 @param [&inout] bvh : "Left zeroed."
*>
fn void free_bvh(Allocator allocator, Bvh* bvh) {
    alloc::free(allocator, bvh.nodes.ptr);
    *bvh = {};
}

fn Bvh build(Allocator allocator, Aabb[] boxes, BvhBuildDesc desc) @local {
    usz primitive_count = boxes.len;
    usz node_capacity = 2 * primitive_count - 1;
    usz id_nodes = (primitive_count * uint::size + BvhNode::size - 1) / BvhNode::size;
    BvhNode[] block = alloc::alloc_array(allocator, BvhNode, (sz)(node_capacity + id_nodes));
    BuildState state = {
        .nodes       = block[:node_capacity],
        .primitives  = ((uint*)&block[node_capacity])[:primitive_count],
        .boxes       = boxes,
        .centroids   = alloc::alloc_array(tmem, Vec3, (sz)primitive_count),
        .bin_of      = alloc::alloc_array(tmem, uint, (sz)primitive_count),
        .bin_boxes   = alloc::alloc_array(tmem, Aabb, desc.bins),
        .bin_counts  = alloc::alloc_array(tmem, uint, desc.bins),
        .right_costs = alloc::alloc_array(tmem, float, desc.bins),
        .node_count  = 1,
        .bins        = desc.bins,
        .leaf_size   = desc.leaf_size,
    };
    foreach (usz index, &centroid : state.centroids) {
        *centroid = (boxes[index].min + boxes[index].max) * 0.5f;
        state.primitives[index] = (uint)index;
    }
    subdivide(
        state:      &state,
        node_index: 0,
        first:      0,
        count:      (uint)primitive_count,
        depth:      0,
    );
    return {
        .nodes      = state.nodes[:state.node_count],
        .primitives = state.primitives,
        .bounds     = node_bounds(&state.nodes[0]),
    };
}

fn void subdivide(
    BuildState* state,
    uint node_index,
    uint first,
    uint count,
    uint depth,
) @local {
    Aabb bounds = state.boxes[state.primitives[first]];
    Vec3 centroid_min = state.centroids[state.primitives[first]];
    Vec3 centroid_max = centroid_min;
    foreach (primitive : state.primitives[first:count]) {
        bounds = maths::aabb_merge(bounds, state.boxes[primitive]);
        centroid_min = math::min(centroid_min, state.centroids[primitive]);
        centroid_max = math::max(centroid_max, state.centroids[primitive]);
    }
    BvhNode* node = &state.nodes[node_index];
    *node = { .min = bounds.min, .max = bounds.max, .left_or_first = first, .count = count };

    if (count <= state.leaf_size || depth == BVH_MAX_DEPTH - 1) return;
    Vec3 extent = centroid_max - centroid_min;
    usz axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2);
    if (extent[axis] <= 0) return;

    uint split_bin;
    bool split = best_split(
        state:       state,
        first:       first,
        count:       count,
        axis:        axis,
        axis_min:    centroid_min[axis],
        axis_extent: extent[axis],
        node_area:   surface_area(bounds),
        split_bin:   &split_bin,
    );
    if (!split) return;
    uint left_count = partition(
        state:     state,
        first:     first,
        count:     count,
        split_bin: split_bin,
    );

    uint left = state.node_count;
    state.node_count += 2;
    *node = { .min = bounds.min, .max = bounds.max, .left_or_first = left, .count = 0 };
    subdivide(
        state:      state,
        node_index: left,
        first:      first,
        count:      left_count,
        depth:      depth + 1,
    );
    subdivide(
        state:      state,
        node_index: left + 1,
        first:      first + left_count,
        count:      count - left_count,
        depth:      depth + 1,
    );
}

fn bool best_split(
    BuildState* state,
    uint first,
    uint count,
    usz axis,
    float axis_min,
    float axis_extent,
    float node_area,
    uint* split_bin,
) @local {
    uint bins = state.bins;
    float scale = (float)bins / axis_extent;
    foreach (&counted : state.bin_counts) *counted = 0;
    foreach (primitive : state.primitives[first:count]) {
        // The centroid at the range's upper end lands on bin `bins`.
        uint bin = math::min((uint)((state.centroids[primitive][axis] - axis_min) * scale), bins - 1);
        state.bin_of[primitive] = bin;
        if (state.bin_counts[bin]) {
            state.bin_boxes[bin] = maths::aabb_merge(state.bin_boxes[bin], state.boxes[primitive]);
        } else {
            state.bin_boxes[bin] = state.boxes[primitive];
        }
        state.bin_counts[bin]++;
    }

    Aabb accumulated = EMPTY_BOX;
    uint accumulated_count;
    for (uint bin = bins - 1; bin > 0; bin--) {
        if (state.bin_counts[bin]) accumulated = maths::aabb_merge(accumulated, state.bin_boxes[bin]);
        accumulated_count += state.bin_counts[bin];
        state.right_costs[bin] = accumulated_count ? surface_area(accumulated) * (float)accumulated_count : 0;
    }

    float best_cost = node_area * (float)count;
    bool found;
    accumulated = EMPTY_BOX;
    accumulated_count = 0;
    for (uint bin = 0; bin < bins - 1; bin++) {
        if (state.bin_counts[bin]) accumulated = maths::aabb_merge(accumulated, state.bin_boxes[bin]);
        accumulated_count += state.bin_counts[bin];
        if (!accumulated_count || accumulated_count == count) continue;
        float cost = surface_area(accumulated) * (float)accumulated_count + state.right_costs[bin + 1];
        if (cost >= best_cost) continue;
        best_cost = cost;
        *split_bin = bin + 1;
        found = true;
    }
    return found;
}

fn uint partition(
    BuildState* state,
    uint first,
    uint count,
    uint split_bin,
) @local {
    uint left = first;
    uint right = first + count;
    while (left < right) {
        if (state.bin_of[state.primitives[left]] < split_bin) {
            left++;
            continue;
        }
        right--;
        uint swapped = state.primitives[left];
        state.primitives[left] = state.primitives[right];
        state.primitives[right] = swapped;
    }
    return left - first;
}

fn float surface_area(Aabb box) @local {
    Vec3 size = box.max - box.min;
    return 2 * (size.x * size.y + size.y * size.z + size.z * size.x);
}

fn Aabb node_bounds(BvhNode* node) @local {
    return { .min = (Vec3)node.min, .max = (Vec3)node.max };
}

fn Vec3[3] triangle_corners(Vec3[] positions, uint[] indices, uint primitive) @local {
    usz first = 3 * (usz)primitive;
    if (!indices.len) return { positions[first], positions[first + 1], positions[first + 2] };
    return { positions[indices[first]], positions[indices[first + 1]], positions[indices[first + 2]] };
}

fn bool traverse(
    Bvh* bvh,
    Vec3[] positions,
    uint[] indices,
    Ray ray,
    float distance_limit,
    bool first_hit,
    BvhHit* hit,
) @local {
    float root_entry;
    if (!maths::ray_intersects_aabb(ray, node_bounds(&bvh.nodes[0]), &root_entry)) return false;
    TraceStack stack;
    push_node(&stack, 0, root_entry);
    float best = distance_limit;
    bool found;
    while (stack.count) {
        stack.count--;
        if (stack.entries[stack.count] >= best) continue;
        BvhNode* node = &bvh.nodes[stack.nodes[stack.count]];
        if (!node.count) {
            push_children(
                stack: &stack,
                bvh:   bvh,
                node:  node,
                ray:   ray,
                limit: best,
            );
            continue;
        }
        foreach (primitive : bvh.primitives[node.left_or_first:node.count]) {
            Vec3[3] corners = triangle_corners(positions, indices, primitive);
            float distance;
            Vec3 barycentric;
            bool met = maths::ray_intersects_triangle(
                ray:         ray,
                a:           corners[0],
                b:           corners[1],
                c:           corners[2],
                distance:    &distance,
                barycentric: &barycentric,
            );
            if (!met || distance >= best) continue;
            *hit = { .primitive = primitive, .distance = distance, .barycentric = barycentric };
            if (first_hit) return true;
            best = distance;
            found = true;
        }
    }
    return found;
}

fn void push_children(
    TraceStack* stack,
    Bvh* bvh,
    BvhNode* node,
    Ray ray,
    float limit,
) @local {
    uint left = node.left_or_first;
    float left_entry;
    float right_entry;
    bool left_met = maths::ray_intersects_aabb(ray, node_bounds(&bvh.nodes[left]), &left_entry)
        && left_entry < limit;
    bool right_met = maths::ray_intersects_aabb(ray, node_bounds(&bvh.nodes[left + 1]), &right_entry)
        && right_entry < limit;
    bool left_first = !right_met || (left_met && left_entry <= right_entry);
    if (left_first) {
        if (right_met) push_node(stack, left + 1, right_entry);
        if (left_met) push_node(stack, left, left_entry);
        return;
    }
    if (left_met) push_node(stack, left, left_entry);
    push_node(stack, left + 1, right_entry);
}

fn void push_node(TraceStack* stack, uint node, float entry) @local {
    stack.nodes[stack.count] = node;
    stack.entries[stack.count] = entry;
    stack.count++;
}
