module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

<* Owned node weights and their model identity/layout snapshot. *>
struct WeightedJointMask {
    Allocator allocator;
    ModelId model;
    String[] model_names;
    int[] model_parents;
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

    WeightedJointMask mask = copy_weighted_mask_layout(allocator, model, &record.data)!;

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

    WeightedJointMask mask = copy_weighted_mask_layout(allocator, model, &record.data)!;

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
 Release every mask-owned array and clear its value.
 @param [&inout] mask : "Sole owner; left zeroed."
*>
fn void destroy_weighted_joint_mask(WeightedJointMask* mask) {
    foreach (name : mask.model_names) alloc::free(mask.allocator, name.ptr);

    alloc::free(mask.allocator, mask.model_names.ptr);
    alloc::free(mask.allocator, mask.model_parents.ptr);
    alloc::free(mask.allocator, mask.nodes.ptr);
    *mask = {};
}

fn void? validate_weighted_joint_mask(
    AssetStore* assets,
    ModelId model,
    WeightedJointMask* mask,
) @private {
    ModelAsset* record = assets.models.try_get(model)!;
    if (!c3d::same_id(model, mask.model) || mask.nodes.len != record.data.nodes.len
      || mask.model_names.len != record.data.nodes.len || mask.model_parents.len != record.data.nodes.len) {
        return c3d::INVALID_ARGUMENT~;
    }

    foreach (index, node : record.data.nodes) {
        if (mask.model_names[index] != node.name || mask.model_parents[index] != node.parent
          || !math::is_finite(mask.nodes[index]) || mask.nodes[index] < 0 || mask.nodes[index] > 1) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
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

fn WeightedJointMask? copy_weighted_mask_layout(
    Allocator allocator,
    ModelId model,
    ModelTemplate* template,
) @private {
    WeightedJointMask mask = { .allocator = allocator, .model = model };
    defer catch destroy_weighted_joint_mask(&mask);

    mask.nodes = alloc::new_array_try(allocator, float, template.nodes.len) ?? c3d::CAPACITY_EXCEEDED~!;
    mask.model_names = alloc::new_array_try(allocator, String, template.nodes.len) ?? c3d::CAPACITY_EXCEEDED~!;
    mask.model_parents = alloc::new_array_try(allocator, int, template.nodes.len) ?? c3d::CAPACITY_EXCEEDED~!;

    foreach (index, node : template.nodes) {
        char[] name = alloc::new_array_try(allocator, char, node.name.len) ?? c3d::CAPACITY_EXCEEDED~!;
        name[..] = node.name[..];
        mask.model_names[index] = (String)name;
        mask.model_parents[index] = node.parent;
    }

    return mask;
}
