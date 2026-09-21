module c3d::geometry;

import c3d::maths;
import std::math;

<*
 Active morph targets one draw or one bound evaluation combines.
*>
const uint MAX_ACTIVE_MORPH_TARGETS = 8; // mirrored as MAX_ACTIVE_MORPH_TARGETS in c3d.abi; the vertex stage loops over exactly this many

<*
 The largest active morph targets by weight magnitude, with their original indices.
*>
struct MorphSelection {
    uint[MAX_ACTIVE_MORPH_TARGETS]  targets;
    float[MAX_ACTIVE_MORPH_TARGETS] weights;
    uint                            count;
}

<*
 Per-joint position and morph-delta bounds of a skinned geometry, retained after its streams are released.
*>
struct SkinBounds {
    Aabb[] joints;
    Aabb[] morph_deltas;
    bool[] used;
    uint   target_count;
    char[] storage;
}

<*
 Select the largest active targets by weight magnitude.
 @param channels : "Empty maps one weight to each target."
 @param weights : "One per channel, or per target when channels is empty."
 @pure
 @require channels.len == 0 || channels.len == weights.len
*>
fn MorphSelection select_morph_targets(MorphChannel[] channels, float[] weights) {
    MorphSelection selection;
    if (!channels.len) {
        foreach (uint index, weight : weights) insert_morph_target(&selection, index, weight);
        return selection;
    }
    foreach (usz index, &channel : channels) {
        ChannelBlend blend = channel.blend(weights[index]);
        insert_morph_target(&selection, blend.targets[0], blend.weights[0]);
        insert_morph_target(&selection, blend.targets[1], blend.weights[1]);
    }
    return selection;
}

<*
 @pure
*>
fn void insert_morph_target(MorphSelection* selection, uint index, float weight) @local {
    if (weight == 0) return;
    float magnitude = math::abs(weight);
    uint slot = selection.count;
    while (slot > 0 && math::abs(selection.weights[slot - 1]) < magnitude) slot--;
    if (slot >= MAX_ACTIVE_MORPH_TARGETS) return;
    uint last = math::min(selection.count, MAX_ACTIVE_MORPH_TARGETS - 1);
    for (uint move = last; move > slot; move--) {
        selection.targets[move] = selection.targets[move - 1];
        selection.weights[move] = selection.weights[move - 1];
    }
    selection.targets[slot] = index;
    selection.weights[slot] = weight;
    if (selection.count < MAX_ACTIVE_MORPH_TARGETS) selection.count++;
}

<*
 Build the per-joint bounds from the geometry's positions, influences and morph deltas.
 @param [&in] geometry : "Joint and weight streams of the position count; unskinned yields empty bounds."
 @return "One allocation owning every slice; free with free_skin_bounds."
*>
fn SkinBounds build_skin_bounds(Allocator allocator, Geometry* geometry) {
    uint joint_count;
    foreach (vertex, weight : geometry.weights) {
        for (usz slot = 0; slot < 4; slot++) {
            if (weight[slot] > 0) joint_count = math::max(joint_count, (uint)geometry.joints[vertex][slot] + 1);
        }
    }
    if (!joint_count) return {};

    usz target_count = geometry.targets.len;
    usz joint_bytes = (usz)joint_count * Aabb::size;
    usz delta_bytes = (usz)joint_count * target_count * Aabb::size;
    char[] storage = alloc::new_array(allocator, char, (sz)(joint_bytes + delta_bytes + joint_count));
    SkinBounds bounds = {
        .joints       = ((Aabb*)storage.ptr)[:joint_count],
        .morph_deltas = ((Aabb*)(storage.ptr + joint_bytes))[:joint_count * target_count],
        .used         = ((bool*)(storage.ptr + joint_bytes + delta_bytes))[:joint_count],
        .target_count = (uint)target_count,
        .storage      = storage,
    };
    foreach (vertex, weight : geometry.weights) {
        Vec3 position = geometry.positions[vertex];
        for (usz slot = 0; slot < 4; slot++) {
            if (weight[slot] <= 0) continue;
            uint joint = geometry.joints[vertex][slot];
            if (!bounds.used[joint]) {
                bounds.used[joint] = true;
                bounds.joints[joint] = { .min = position, .max = position };
                foreach (usz target, &deltas : geometry.targets) {
                    Vec3 delta = deltas.position_deltas[vertex];
                    bounds.morph_deltas[joint * target_count + target] = { .min = delta, .max = delta };
                }
                continue;
            }
            bounds.joints[joint] = extend(bounds.joints[joint], position);
            foreach (usz target, &deltas : geometry.targets) {
                usz index = joint * target_count + target;
                bounds.morph_deltas[index] = extend(bounds.morph_deltas[index], deltas.position_deltas[vertex]);
            }
        }
    }
    return bounds;
}

<*
 Free the retained bounds.
 @param [&inout] bounds : "Left empty."
*>
fn void free_skin_bounds(Allocator allocator, SkinBounds* bounds) {
    if (bounds.storage.len) alloc::free(allocator, bounds.storage.ptr);
    *bounds = {};
}

<*
 Mesh-local bound of one joint's vertices under the selected morph weights.
 @param [&in] bounds : "Retained bounds of the geometry."
 @param [&in] selection : "Targets below the geometry's target count."
 @require joint < bounds.joints.len, bounds.used[joint]
 @pure
*>
fn Aabb joint_morph_bounds(SkinBounds* bounds, uint joint, MorphSelection* selection) {
    Aabb local = bounds.joints[joint];
    for (uint active = 0; active < selection.count; active++) {
        Aabb delta = bounds.morph_deltas[(usz)joint * bounds.target_count + selection.targets[active]];
        float weight = selection.weights[active];
        if (weight >= 0) {
            local.min += delta.min * weight;
            local.max += delta.max * weight;
        } else {
            local.min += delta.max * weight;
            local.max += delta.min * weight;
        }
    }
    return local;
}

<*
 @pure
*>
fn Aabb extend(Aabb bounds, Vec3 point) @local {
    return { .min = math::min(bounds.min, point), .max = math::max(bounds.max, point) };
}
