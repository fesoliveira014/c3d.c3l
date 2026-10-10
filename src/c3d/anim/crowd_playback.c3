module c3d::anim;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::pool;
import c3d::scene;
import std::math;

<* Default concurrent actions prepared for each crowd instance. *>
const uint DEFAULT_CROWD_ACTIONS = 4; // Four Action records and model-sized masks per instance; spaces share these slots.

<* Default event entries retained across one crowd update. *>
const uint DEFAULT_CROWD_EVENT_CAPACITY = 1024; // 1024 * CrowdEvent::size bytes; accommodates crossings from 512 walkers.

<* Event crossed by one generational crowd instance. *>
struct CrowdEvent {
    CrowdInstanceId instance;
    FiredEvent event;
}

<* Fixed playback arrays and outputs owned by one crowd slot. *>
struct CrowdPlaybackSlot {
    Pool{Action, AnimationActionId} actions;
    AnimationActionId[] order;
    bool[] masks;
    BlendSpace1D[] spaces;
    BlendSpace2D[] spaces_2d;
    uint action_count;
    uint generation;
    uint root_node;
    AnimationActionId base_action;
    RootMotionDelta root_motion;
}

<* Owns crowd playback storage, baselines and one event buffer. *>
struct CrowdPlaybackState {
    Allocator allocator;
    ModelId model;
    ulong identity;
    Transform[] placements;
    CrowdPlaybackSlot[] slots;
    Transform[] base_pose;
    int[] parents;
    uint[] mesh_nodes;
    float[][] base_morph_weights;
    Transform[] poses;
    float[] weight_values;
    float[][] logical_weights;
    PoseStorage* pose_storage;
    InertialStorage* inertial_storage;
    CrowdEvent[] events;
    uint event_count;
    uint events_dropped;
    uint count;
    uint default_root_node;
}

<* Borrowed controls for one generational crowd instance. *>
struct CrowdPlayer {
    CrowdPlaybackState* state;
    CrowdInstanceId instance;
}

ulong crowd_playback_identity_counter @private;

<*
 Evaluate live instances and retain their crowd-wide event prefix.
 @param [&in] assets : "Owns every retained action's clip."
 @param dt : "Finite nonnegative seconds."
 @require math::is_finite(dt) && dt >= 0
*>
fn void CrowdPlaybackState.update(&self, AssetStore* assets, float dt) {
    self.event_count = 0;
    self.events_dropped = 0;

    for (uint index = 0; index < self.count; index++) {
        CrowdPlaybackSlot* slot = &self.slots[index];
        PlaybackView playback = crowd_playback_view(self, slot);
        PoseDestination destination = crowd_destination(self, index);

        EventOutput output = { .stride = CrowdEvent::size, .capacity = self.events.len - self.event_count };
        if (output.capacity) output.first = &self.events[self.event_count].event;

        PoseReport report = evaluate_pose(
            playback: &playback,
            assets: assets,
            destination: destination,
            scratch: self.pose_storage.scratch,
            dt: dt,
            events: output,
        );

        Vec3 reference;
        if (report.motion.yaw != 0) {
            reference = destination.pose[slot.root_node].position;

            for (int parent = self.parents[slot.root_node]; parent >= 0; parent = self.parents[parent]) {
                reference = maths::transform_point(destination.pose[parent].to_mat4(), reference);
            }
        }

        slot.root_motion = root_motion_delta(report.motion, reference);

        foreach (&event : self.events[self.event_count:report.events.count]) {
            event.instance = { .index = index, .generation = slot.generation };
        }

        self.event_count += report.events.count;
        self.events_dropped += math::min(report.events.dropped, uint::max - self.events_dropped);
    }
}

<*
 Identify a live instance within this crowd owner.
 @return? c3d::INVALID_ID
*>
fn CrowdInstanceId? CrowdPlaybackState.instance_id(&self, uint index) {
    if (index >= self.count) return c3d::INVALID_ID~;

    return { .index = index, .generation = self.slots[index].generation };
}

<*
 Borrow controls for a live instance until replacement.
 @return? c3d::INVALID_ID
*>
fn CrowdPlayer? CrowdPlaybackState.player(&self, CrowdInstanceId instance) {
    crowd_slot(self, instance)!;

    return { .state = self, .instance = instance };
}

<*
 Start a compatible clip on this instance.
 @param [&in] assets : "Owns the clip throughout playback."
 @param desc : "Mask membership is copied during this call."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn AnimationActionId? CrowdPlayer.play(
    &self,
    AssetStore* assets,
    ClipId clip,
    PlayDesc desc = PLAY_DESC_DEFAULT,
) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);

    return playback.play(
        assets: assets,
        clip: clip,
        desc: desc,
        destination: crowd_destination(self.state, self.instance.index),
        motion_basis: crowd_motion_basis(self.state, self.instance.index, slot.root_node),
    );
}

<*
 Borrow a known-live action until structural playback changes.
 @require self.instance.index < self.state.count
 @require self.state.slots[self.instance.index].generation == self.instance.generation
 @require self.state.slots[self.instance.index].actions.is_live(action)
*>
fn Action* CrowdPlayer.action(&self, AnimationActionId action) {
    return self.state.slots[self.instance.index].actions.get(action);
}

<*
 Borrow an action from this live instance.
 @return? c3d::INVALID_ID
*>
fn Action*? CrowdPlayer.try_action(&self, AnimationActionId action) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;

    return slot.actions.try_get(action);
}

<*
 Fade out an action or remove it immediately.
 @param fade_out : "Finite nonnegative seconds; zero removes immediately."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? CrowdPlayer.stop(&self, AnimationActionId action, float fade_out = 0) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);

    playback.stop(action, fade_out)!;
}

<*
 Fade one action out while another reaches full weight.
 @param duration : "Finite positive seconds."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? CrowdPlayer.cross_fade(
    &self,
    AnimationActionId from,
    AnimationActionId to,
    float duration,
) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);

    playback.cross_fade(from, to, duration)!;
}

<*
 Start phase-synchronized clips on this instance.
 @param [&in] assets : "Clips remain live throughout playback."
 @param positions : "Strictly ascending, finite, one per clip."
 @param desc : "Shared captured configuration and initial fade."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn BlendSpace1D*? CrowdPlayer.add_blend_space(
    &self,
    AssetStore* assets,
    ClipId[] clips,
    float[] positions,
    PlayDesc desc = PLAY_DESC_DEFAULT,
) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);

    return playback.add_blend_space(
        assets: assets,
        clips: clips,
        positions: positions,
        desc: desc,
        destination: crowd_destination(self.state, self.instance.index),
        motion_basis: crowd_motion_basis(self.state, self.instance.index, slot.root_node),
    );
}

<*
 Fade a space out or remove its members immediately.
 @param [&inout] space : "Current borrow from this instance."
 @param fade_out : "Finite nonnegative seconds."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? CrowdPlayer.stop_blend_space(&self, BlendSpace1D* space, float fade_out = 0) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);

    playback.stop_blend_space(space, fade_out)!;
}

<*
 Fade a space toward a new weight.
 @param [&inout] space : "Current borrow from this instance."
 @param target_weight : "Finite weight in [0,1]."
 @param duration : "Finite positive seconds."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? CrowdPlayer.fade_blend_space(
    &self,
    BlendSpace1D* space,
    float target_weight,
    float duration,
) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);

    playback.fade_blend_space(space, target_weight, duration)!;
}

<*
 Choose the template node used for root-motion extraction.
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? CrowdPlayer.set_root_node(&self, uint node) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    if (node != NO_ROOT_NODE && node >= self.state.base_pose.len) return c3d::INVALID_ARGUMENT~;

    slot.root_node = node;
}

<*
 Borrow the seed action's mutable playback controls.
 @return? c3d::INVALID_ID
*>
fn Action*? CrowdPlayer.base_action(&self) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;

    return slot.actions.try_get(slot.base_action);
}

<*
 Validate a seed against the model's logical playback layout.
 @param [&in] assets : "Owns the referenced clip."
 @param [&in] template : "Validated model structure and authored defaults."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? validate_crowd_seed(AssetStore* assets, ModelTemplate* template, CrowdPose seed) {
    validate_seed_scalars(seed)!;
    AnimationClip* clip = &assets.clips.try_get(seed.clip)!.data;

    @pool() {
        PoseDestination destination = {
            .base_pose = alloc::new_array(tmem, Transform, template.nodes.len),
            .present = alloc::new_array(tmem, bool, template.nodes.len),
            .mesh_present = alloc::new_array(tmem, bool, template.nodes.len),
            .mesh_indices = alloc::new_array(tmem, uint, template.nodes.len),
            .mesh_widths = alloc::new_array(tmem, uint, template.meshes.len),
        };
        destination.present[..] = true;
        destination.mesh_indices[..] = uint::max;

        foreach (usz index, mesh : template.meshes) {
            destination.mesh_present[mesh.node] = true;
            destination.mesh_indices[mesh.node] = (uint)index;
            destination.mesh_widths[index] = (uint)mesh.default_morph_weights.len;
        }

        (void)validate_playback_action(clip, PLAY_DESC_DEFAULT, destination)!;
    };
}

<*
 Prepare an owned seed action without changing the crowd slot.
 @param [&inout] state : "Retains fixed storage throughout staging."
 @param [&in] assets : "Owns the referenced clip."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require index < state.slots.len
*>
fn Action? prepare_crowd_seed(
    CrowdPlaybackState* state,
    uint index,
    AssetStore* assets,
    CrowdPose seed,
) {
    validate_seed_scalars(seed)!;
    Action action = prepare_playback_action(
        allocator: state.allocator,
        assets: assets,
        clip: seed.clip,
        desc: PLAY_DESC_DEFAULT,
        destination: crowd_destination(state, index),
        motion_basis: crowd_motion_basis(state, index, state.default_root_node),
        root_node: state.default_root_node,
    )!;

    action.time = seed.time;
    action.speed = seed.speed;
    action.loop = seed.loop;

    return action;
}

<*
 Reset a slot while retaining its fixed pools and advancing identities.
 @param [&inout] state : "Every previous slot and action handle becomes stale."
 @require index < state.slots.len
*>
fn void reset_crowd_playback_slot(CrowdPlaybackState* state, uint index) {
    CrowdPlaybackSlot* slot = &state.slots[index];
    PlaybackView playback = crowd_playback_view(state, slot);

    clear_playback(&playback);

    slot.spaces[..] = (BlendSpace1D){};
    foreach (&space : slot.spaces_2d) reset_blend_space_2d(space);
    slot.generation++;
    if (!slot.generation) slot.generation = 1;
    if (state.inertial_storage) reset_inertial_row(state.inertial_storage, index, slot.generation);

    slot.root_node = state.default_root_node;
    slot.base_action = {};
    slot.root_motion = { .rotation = quaternion::IDENTITY };

    state.event_count = 0;
    state.events_dropped = 0;

    state.poses[(usz)index * state.base_pose.len:state.base_pose.len] = state.base_pose[..];
    foreach (usz mesh, base : state.base_morph_weights) {
        state.logical_weights[(usz)index * state.mesh_nodes.len + mesh][..] = base[..];
    }
}

<*
 Install a prepared seed into an empty fixed slot.
 @param [&inout] state : "Takes the prepared cursor and reference arrays."
 @require index < state.slots.len, state.slots[index].action_count == 0
*>
fn void install_crowd_seed(CrowdPlaybackState* state, uint index, Action action) {
    CrowdPlaybackSlot* slot = &state.slots[index];
    PlaybackView playback = crowd_playback_view(state, slot);

    slot.base_action = install_playback_action(&playback, action, null);
}

<*
 Allocate fixed crowd playback storage with copied authored baselines.
 @param [&in] template : "Supplies nodes, meshes and authored morph defaults."
 @param placements : "Borrowed capacity-sized storage owned by the crowd."
 @return? c3d::CAPACITY_EXCEEDED
 @require placements.len > 0, actions_per_instance > 0 && actions_per_instance <= MAX_ACTIONS
*>
fn CrowdPlaybackState*? create_crowd_playback(
    Allocator allocator,
    ModelTemplate* template,
    Transform[] placements,
    uint actions_per_instance,
    uint event_capacity,
    bool inertia_enabled = false,
) {
    CrowdPlaybackState* state = alloc::new_try(allocator, CrowdPlaybackState) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch destroy_crowd_playback(state);

    state.allocator = allocator;
    state.placements = placements;
    uint capacity = (uint)placements.len;

    state.slots = alloc::new_array_try(allocator, CrowdPlaybackSlot, capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;
    state.base_pose = alloc::new_array_try(allocator, Transform, template.nodes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    state.parents = alloc::new_array_try(allocator, int, template.nodes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    state.mesh_nodes = alloc::new_array_try(allocator, uint, template.meshes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    state.base_morph_weights = alloc::new_array_try(allocator, float[], template.meshes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;

    state.poses = alloc::new_array_try(allocator, Transform, (sz)capacity * template.nodes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    state.logical_weights = alloc::new_array_try(allocator, float[], (sz)capacity * template.meshes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    state.events = alloc::new_array_try(allocator, CrowdEvent, event_capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;

    foreach (usz index, node : template.nodes) {
        state.base_pose[index] = node.local;
        state.parents[index] = node.parent;
    }

    foreach (usz index, mesh : template.meshes) {
        state.mesh_nodes[index] = mesh.node;
        state.base_morph_weights[index] = alloc::new_array_try(
            allocator,
            float,
            mesh.default_morph_weights.len,
        ) ?? c3d::CAPACITY_EXCEEDED~!;
        state.base_morph_weights[index][..] = mesh.default_morph_weights[..];
    }

    usz weight_stride;
    foreach (values : state.base_morph_weights) weight_stride += values.len;
    state.weight_values = alloc::new_array_try(allocator, float, (sz)((usz)capacity * weight_stride))
      ?? c3d::CAPACITY_EXCEEDED~!;

    for (uint instance = 0; instance < capacity; instance++) {
        usz offset = (usz)instance * weight_stride;
        foreach (usz mesh, values : state.base_morph_weights) {
            state.logical_weights[(usz)instance * state.mesh_nodes.len + mesh] = state.weight_values[offset:values.len];
            state.weight_values[offset:values.len] = values[..];
            offset += values.len;
        }
    }

    state.pose_storage = create_pose_storage_try(
        allocator: allocator,
        base_pose: state.base_pose,
        mesh_nodes: state.mesh_nodes,
        base_morph_weights: state.base_morph_weights,
        event_capacity: event_capacity,
    )!;

    if (inertia_enabled) {
        state.inertial_storage = create_inertial_storage(
            allocator: allocator,
            nodes: (uint)state.base_pose.len,
            morphs: (uint)weight_stride,
            capacity: capacity,
        )!;
    }

    uint root_node = crowd_default_root(template);
    state.default_root_node = root_node;
    foreach (usz index, &slot : state.slots) {
        slot.actions.allocator = allocator;
        slot.actions.items = alloc::new_array_try(allocator, Action, actions_per_instance)
          ?? c3d::CAPACITY_EXCEEDED~!;
        slot.actions.generations = alloc::new_array_try(allocator, uint, actions_per_instance)
          ?? c3d::CAPACITY_EXCEEDED~!;
        slot.actions.free = alloc::new_array_try(allocator, uint, actions_per_instance)
          ?? c3d::CAPACITY_EXCEEDED~!;
        slot.order = alloc::new_array_try(allocator, AnimationActionId, actions_per_instance)
          ?? c3d::CAPACITY_EXCEEDED~!;
        slot.masks = alloc::new_array_try(allocator, bool, (sz)actions_per_instance * template.nodes.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        slot.spaces = alloc::new_array_try(allocator, BlendSpace1D, MAX_BLEND_SPACES)
          ?? c3d::CAPACITY_EXCEEDED~!;

        slot.spaces_2d = create_blend_spaces_2d(allocator, actions_per_instance)!;

        slot.actions.free_count = actions_per_instance;
        slot.actions.generations[..] = 1;
        for (uint action = 0; action < actions_per_instance; action++) {
            slot.actions.free[action] = actions_per_instance - 1 - action;
        }

        slot.generation = 1;
        if (state.inertial_storage) reset_inertial_row(state.inertial_storage, (uint)index, slot.generation);

        slot.root_node = root_node;
        slot.root_motion.rotation = quaternion::IDENTITY;
        state.poses[index * state.base_pose.len:state.base_pose.len] = state.base_pose[..];
    }

    state.identity = ++crowd_playback_identity_counter;

    return state;
}

<*
 Free crowd playback storage and every live action's owned arrays.
 @param [&inout] state : "Destroyed together with its crowd owner."
*>
fn void destroy_crowd_playback(CrowdPlaybackState* state) {
    Allocator allocator = state.allocator;
    foreach (&slot : state.slots) {
        foreach (id : slot.order[:slot.action_count]) {
            Action* action = slot.actions.get(id);
            alloc::free(allocator, action.cursors.ptr);
            alloc::free(allocator, action.reference.ptr);
            alloc::free(allocator, action.weighted_mask.ptr);
        }

        pool::destroy_pool{Action, AnimationActionId}(&slot.actions);
        alloc::free(allocator, slot.order.ptr);
        alloc::free(allocator, slot.masks.ptr);
        alloc::free(allocator, slot.spaces.ptr);
        destroy_blend_spaces_2d(allocator, slot.spaces_2d);
    }

    if (state.inertial_storage) destroy_inertial_storage(state.inertial_storage);
    if (state.pose_storage) destroy_pose_storage(allocator, state.pose_storage);

    foreach (values : state.base_morph_weights) alloc::free(allocator, values.ptr);

    alloc::free(allocator, state.slots.ptr);
    alloc::free(allocator, state.base_pose.ptr);
    alloc::free(allocator, state.parents.ptr);
    alloc::free(allocator, state.mesh_nodes.ptr);
    alloc::free(allocator, state.base_morph_weights.ptr);
    alloc::free(allocator, state.poses.ptr);
    alloc::free(allocator, state.weight_values.ptr);
    alloc::free(allocator, state.logical_weights.ptr);
    alloc::free(allocator, state.events.ptr);
    alloc::free(allocator, state);
}

fn CrowdPlaybackSlot*? crowd_slot(CrowdPlaybackState* state, CrowdInstanceId instance) @private {
    if (instance.index >= state.count || state.slots[instance.index].generation != instance.generation) {
        return c3d::INVALID_ID~;
    }

    return &state.slots[instance.index];
}

fn PlaybackView crowd_playback_view(CrowdPlaybackState* state, CrowdPlaybackSlot* slot) @private {
    return {
        .allocator = state.allocator,
        .model = state.model,
        .actions = &slot.actions,
        .order = slot.order,
        .action_count = &slot.action_count,
        .mask_storage = slot.masks,
        .blend_spaces = slot.spaces,
        .blend_spaces_2d = slot.spaces_2d,
        .root_node = slot.root_node,
        .inertial = state.inertial_storage
          ? &state.inertial_storage.rows[(usz)(slot - state.slots.ptr)] : null,
    };
}

fn PoseDestination crowd_destination(CrowdPlaybackState* state, uint index) @private {
    PoseDestination destination = state.pose_storage.destination;
    destination.pose = state.poses[(usz)index * state.base_pose.len:state.base_pose.len];
    destination.morph_weights = state.logical_weights[(usz)index * state.mesh_nodes.len:state.mesh_nodes.len];

    return destination;
}

fn MotionBasis crowd_motion_basis(CrowdPlaybackState* state, uint index, uint root_node) @private {
    MotionBasis basis = {
        .parent_space = true,
        .ancestors_parent_space = true,
        .basis = matrix::IDENTITY4,
        .instance_scale = state.placements[index].scale,
    };
    if (root_node >= state.base_pose.len) return basis;

    basis.root_present = true;
    Transform[] pose = state.poses[(usz)index * state.base_pose.len:state.base_pose.len];
    for (int parent = state.parents[root_node]; parent >= 0; parent = state.parents[parent]) {
        basis.basis = pose[parent].to_mat4().mul(basis.basis);
    }

    return basis;
}

fn void? validate_seed_scalars(CrowdPose seed) @private {
    if (!math::is_finite(seed.time) || !math::is_finite(seed.speed)) return c3d::INVALID_ARGUMENT~;
}

fn uint crowd_default_root(ModelTemplate* template) @private {
    if (!template.skins.len) return NO_ROOT_NODE;

    ModelSkin* skin = &template.skins[0];
    foreach (joint : skin.joint_nodes) {
        bool parent_is_joint;
        foreach (member : skin.joint_nodes) parent_is_joint |= template.nodes[joint].parent == (int)member;

        if (!parent_is_joint) return joint;
    }

    return NO_ROOT_NODE;
}
