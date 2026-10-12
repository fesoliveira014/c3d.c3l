module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

<* Owned per-node weights in model-node order. *>
struct WeightedJointMask {
    Allocator allocator;
    float[] nodes;
}

<*
 Select exact model names with copied weights; duplicates combine by maximum.
 @param [&in] assets : "Source model store."
 @param weights : "Finite values in [0,1], one per name."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, NOT_FOUND, c3d::CAPACITY_EXCEEDED
*>
fn WeightedJointMask? create_weighted_joint_mask(
    Allocator allocator,
    AssetStore* assets,
    ModelId model,
    String[] names,
    float[] weights,
) {
    ModelAsset* record = assets.models.try_get(model)!;
    validate_weighted_mask_names(&record.data, names, weights)!;

    WeightedJointMask mask = create_weighted_mask_row(allocator, record.data.nodes.len)!;

    foreach (index, node : record.data.nodes) {
        foreach (requested, name : names) {
            if (node.name == name) mask.nodes[index] = math::max(mask.nodes[index], weights[requested]);
        }
    }

    return mask;
}

<*
 Feather named subtrees inward; overlapping seeds combine by maximum.
 @param [&in] assets : "Source model store."
 @param weights : "Finite seed weights in [0,1], one per name."
 @param depths : "Ramp edge counts; zero gives full subtree weight."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, NOT_FOUND, c3d::CAPACITY_EXCEEDED
*>
fn WeightedJointMask? create_feathered_joint_mask(
    Allocator allocator,
    AssetStore* assets,
    ModelId model,
    String[] names,
    float[] weights,
    uint[] depths,
) {
    ModelAsset* record = assets.models.try_get(model)!;
    if (depths.len != names.len) return c3d::INVALID_ARGUMENT~;
    validate_weighted_mask_names(&record.data, names, weights)!;

    WeightedJointMask mask = create_weighted_mask_row(allocator, record.data.nodes.len)!;

    for (sz index = 0; index < record.data.nodes.len; index++) {
        foreach (requested, name : names) {
            double distance;
            for (int ancestor = (int)index; ancestor >= 0; ancestor = record.data.nodes[ancestor].parent) {
                if (record.data.nodes[ancestor].name == name) {
                    double ramp = math::min(1.0, (distance + 1.0) / ((double)depths[requested] + 1.0));
                    float weight = (float)((double)weights[requested] * ramp);
                    mask.nodes[index] = math::max(mask.nodes[index], weight);
                }

                distance += 1.0;
            }
        }
    }

    return mask;
}

<*
 Release the weight row and clear the mask.
 @param [&inout] mask : "Sole owner; left zeroed."
*>
fn void destroy_weighted_joint_mask(WeightedJointMask* mask) {
    alloc::free(mask.allocator, mask.nodes.ptr);
    *mask = {};
}

fn void? validate_weighted_mask_names(ModelTemplate* template, String[] names, float[] weights) @private {
    if (names.len != weights.len) return c3d::INVALID_ARGUMENT~;

    foreach (weight : weights) {
        if (!math::is_finite(weight) || weight < 0 || weight > 1) return c3d::INVALID_ARGUMENT~;
    }

    foreach (name : names) {
        bool found;
        foreach (node : template.nodes) found |= node.name == name;
        if (!found) return NOT_FOUND~;
    }
}

fn WeightedJointMask? create_weighted_mask_row(Allocator allocator, sz node_count) @private {
    float[] nodes = alloc::new_array_try(allocator, float, node_count) ?? c3d::CAPACITY_EXCEEDED~!;

    return { .allocator = allocator, .nodes = nodes };
}
