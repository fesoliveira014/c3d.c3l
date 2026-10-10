module c3d::anim;

import c3d;
import c3d::asset;
import c3d::scene @public;
import std::math;

<* Owns evaluated pose and scratch arrays, borrowing immutable baselines. *>
struct PoseStorage {
    PoseDestination destination;
    PoseScratch scratch;
}

<*
 Borrow the animator's playback until its owner changes structure.
 @param [&inout] self : "Owns every referenced playback array."
*>
fn PlaybackView Animator.playback(&self) {
    return {
        .allocator = self.scene.allocator,
        .model = self.scene.get(self.instance_root, ModelInstance).source,
        .actions = self.actions,
        .order = self.order,
        .action_count = &self.action_count,
        .mask_storage = self.mask_storage,
        .blend_spaces = self.blend_spaces,
        .blend_spaces_2d = self.blend_spaces_2d,
        .root_node = self.root_node,
    };
}

<*
 Allocate fixed pose/scratch arrays; baselines remain borrowed until destruction.
 @param event_capacity : "Maximum retained events in one evaluation."
 @return? c3d::CAPACITY_EXCEEDED
 @require mesh_nodes.len == base_morph_weights.len
*>
fn PoseStorage*? create_pose_storage_try(
    Allocator allocator,
    Transform[] base_pose,
    uint[] mesh_nodes,
    float[][] base_morph_weights,
    usz event_capacity,
) {
    PoseStorage* storage = alloc::new_try(allocator, PoseStorage) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch destroy_pose_storage(allocator, storage);

    PoseDestination* destination = &storage.destination;
    destination.base_pose = base_pose;
    destination.base_morph_weights = base_morph_weights;

    destination.present = alloc::new_array_try(allocator, bool, base_pose.len) ?? c3d::CAPACITY_EXCEEDED~!;
    destination.present[..] = true;

    destination.mesh_present = alloc::new_array_try(allocator, bool, base_pose.len) ?? c3d::CAPACITY_EXCEEDED~!;
    destination.mesh_indices = alloc::new_array_try(allocator, uint, base_pose.len) ?? c3d::CAPACITY_EXCEEDED~!;
    destination.mesh_indices[..] = uint::max;
    destination.mesh_widths = alloc::new_array_try(allocator, uint, mesh_nodes.len) ?? c3d::CAPACITY_EXCEEDED~!;

    destination.pose = alloc::new_array_try(allocator, Transform, base_pose.len) ?? c3d::CAPACITY_EXCEEDED~!;
    destination.morph_weights = alloc::new_array_try(allocator, float[], base_morph_weights.len)
      ?? c3d::CAPACITY_EXCEEDED~!;

    PoseScratch* scratch = &storage.scratch;
    scratch.channels = alloc::new_array_try(allocator, ChannelSums, base_pose.len) ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.morph_sums = alloc::new_array_try(allocator, float[], base_morph_weights.len) ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.morph_weights = alloc::new_array_try(allocator, float, base_morph_weights.len) ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.event_bookmarks = alloc::new_array_try(allocator, EventBookmark, (sz)event_capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;

    usz sample_width = 4;

    foreach (usz index, base : base_morph_weights) {
        destination.morph_weights[index] = alloc::new_array_try(allocator, float, base.len) ?? c3d::CAPACITY_EXCEEDED~!;
        scratch.morph_sums[index] = alloc::new_array_try(allocator, float, base.len) ?? c3d::CAPACITY_EXCEEDED~!;
        destination.mesh_indices[mesh_nodes[index]] = (uint)index;
        destination.mesh_present[mesh_nodes[index]] = true;
        destination.mesh_widths[index] = (uint)base.len;
        sample_width = math::max(sample_width, (usz)base.len);
    }

    scratch.sample = alloc::new_array_try(allocator, float, (sz)sample_width) ?? c3d::CAPACITY_EXCEEDED~!;

    return storage;
}

<* Allocate fixed pose/scratch arrays using an infallible owner allocator. *>
fn PoseStorage* create_pose_storage(
    Allocator allocator,
    Transform[] base_pose,
    uint[] mesh_nodes,
    float[][] base_morph_weights,
    usz event_capacity,
) {
    return create_pose_storage_try(
        allocator: allocator,
        base_pose: base_pose,
        mesh_nodes: mesh_nodes,
        base_morph_weights: base_morph_weights,
        event_capacity: event_capacity,
    )!!;
}

<*
 Free owned pose and scratch arrays.
 @param [&inout] storage : "Released; borrowed baselines remain untouched."
*>
fn void destroy_pose_storage(Allocator allocator, PoseStorage* storage) {
    foreach (values : storage.destination.morph_weights) alloc::free(allocator, values.ptr);
    foreach (values : storage.scratch.morph_sums) alloc::free(allocator, values.ptr);

    alloc::free(allocator, storage.destination.present.ptr);
    alloc::free(allocator, storage.destination.mesh_present.ptr);
    alloc::free(allocator, storage.destination.mesh_indices.ptr);
    alloc::free(allocator, storage.destination.mesh_widths.ptr);
    alloc::free(allocator, storage.destination.pose.ptr);
    alloc::free(allocator, storage.destination.morph_weights.ptr);
    alloc::free(allocator, storage.scratch.channels.ptr);
    alloc::free(allocator, storage.scratch.morph_sums.ptr);
    alloc::free(allocator, storage.scratch.morph_weights.ptr);
    alloc::free(allocator, storage.scratch.sample.ptr);
    alloc::free(allocator, storage.scratch.event_bookmarks.ptr);
    alloc::free(allocator, storage);
}

fn void refresh_destination(Animator* animator) @private {
    ModelInstance* instance = animator.scene.get(animator.instance_root, ModelInstance);
    PoseDestination* destination = &animator.pose_storage.destination;

    foreach (usz index, &present : destination.present) *present = instance.present_node(index) != null;

    destination.mesh_present[..] = false;
    foreach (usz index, node_index : instance.mesh_nodes) {
        Node* node = instance.present_node(node_index);
        if (!node) continue;
        Mesh* mesh = animator.scene.get(node, Mesh);
        if (!mesh) continue;
        destination.mesh_present[node_index] = true;
        destination.mesh_widths[index] = (uint)mesh.morph_weights.len;
    }
}

fn MotionBasis animator_motion_basis(Animator* animator) @private {
    MotionBasis result = {
        .ancestors_parent_space = true,
        .basis = matrix::IDENTITY4,
        .instance_scale = animator.instance_root.local.scale,
    };
    ModelInstance* instance = animator.scene.get(animator.instance_root, ModelInstance);

    if (animator.root_node >= instance.nodes.len) return result;
    Node* root = instance.present_node(animator.root_node);
    if (!root) return result;

    result.root_present = true;
    result.parent_space = root.transform_space == TransformSpace.PARENT;

    for (Node* parent = root.parent; parent != animator.instance_root; parent = parent.parent) {
        if (!parent || parent.transform_space != TransformSpace.PARENT) {
            result.ancestors_parent_space = false;
            return result;
        }
        result.basis = parent.local.to_mat4().mul(result.basis);
    }

    return result;
}

fn void publish_animator_pose(Animator* animator, ModelInstance* instance) @private {
    PoseDestination* destination = &animator.pose_storage.destination;
    foreach (usz index, pose : destination.pose) {
        Node* node = instance.present_node(index);
        if (node) node.local = pose;
    }

    foreach (index, values : destination.morph_weights) {
        Node* node = instance.present_node(instance.mesh_nodes[index]);
        if (!node) continue;
        Mesh* mesh = animator.scene.get(node, Mesh);
        if (mesh) mesh.morph_weights[..] = values[..];
    }

    LodGroup* group = animator.scene.get(animator.instance_root, LodGroup);
    if (group && group.state.animated) scene::publish_animated_lod_source(group.state);
}
