module c3d::anim;

import c3d;
import c3d::asset;
import c3d::pool;
import std::math;

<* Borrowed playback storage; reacquire after its owner changes structure. *>
struct PlaybackView {
    Allocator allocator;
    Pool{Action, AnimationActionId}* actions;
    AnimationActionId[] order;
    uint* action_count;
    bool[] mask_storage;
    BlendSpace1D[] blend_spaces;
    uint root_node;
    RootMotionDelta* root_motion;
}

<* Destination baselines, presence and caller-owned evaluated output. *>
struct PoseDestination {
    Transform[] base_pose;
    bool[] present;
    bool[] mesh_present;
    uint[] mesh_indices;
    uint[] mesh_widths;
    float[][] base_morph_weights;
    Transform[] pose;
    float[][] morph_weights;
    Transform*[] motion_ancestors;
}

<* Root basis captured by the target adapter when an action starts. *>
struct MotionBasis {
    bool root_present;
    bool parent_space;
    bool ancestors_parent_space;
    Mat4 basis;
    Vec3 instance_scale;
}

<* Per-node channel accumulators reused between layers. *>
struct ChannelSums {
    Vec3 translation;
    float translation_weight;
    Vec4 rotation;
    float rotation_weight;
    Vec3 scale;
    float scale_weight;
}

<* A retained event stream's state after its first emitted crossing. *>
struct EventBookmark {
    usz index;
    double next;
    double remaining;
}

<* Reused scratch; samples fit the largest present logical channel width. *>
struct PoseScratch {
    ChannelSums[] channels;
    float[][] morph_sums;
    float[] morph_weights;
    float[] sample;
    EventBookmark[] event_bookmarks;
}

<* Counts from this evaluation; dropped crossings saturate at uint::max. *>
struct EventReport {
    uint count;
    uint dropped;
}

<* Borrowed retained-event fields, contiguous or embedded in larger entries. *>
struct EventOutput {
    FiredEvent* first;
    usz stride;
    usz capacity;
}

<*
 Start a clip in the destination playback.
 @param [&in] assets : "Clips remain live throughout playback."
 @param desc : "Mask membership and motion configuration are captured."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require destination.present.len == destination.base_pose.len
 @require destination.mesh_present.len == destination.base_pose.len
 @require destination.mesh_indices.len == destination.base_pose.len
*>
fn AnimationActionId? PlaybackView.play(
    &self,
    AssetStore* assets,
    ClipId clip,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
) {
    AnimationClip* data = &assets.clips.try_get(clip)!.data;
    usz reference_count = validate_playback_action(data, desc, destination)!;
    if (!self.actions.free_count) return c3d::CAPACITY_EXCEEDED~;

    Action state = prepare_validated_playback_action(
        allocator: self.allocator,
        clip: clip,
        data: data,
        desc: desc,
        destination: destination,
        motion_basis: motion_basis,
        root_node: self.root_node,
        reference_count: reference_count,
    )!;

    return install_playback_action(self, state, desc.mask);
}

<* Borrow until structural changes.
   @require self.actions.is_live(action) *>
fn Action* PlaybackView.action(&self, AnimationActionId action) => self.actions.get(action);

<* Borrow until structural changes; stale identities fail.
   @return? c3d::INVALID_ID *>
fn Action*? PlaybackView.try_action(&self, AnimationActionId action) => self.actions.try_get(action);

<*
 Fade an action out or remove it immediately.
 @param fade_out : "Finite nonnegative seconds; zero removes immediately."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? PlaybackView.stop(&self, AnimationActionId action, float fade_out = 0) {
    Action* state = self.actions.try_get(action)!;
    if (state.blend_space) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(fade_out) || fade_out < 0) return c3d::INVALID_ARGUMENT~;

    if (fade_out == 0) {
        uint index;
        while (!c3d::same_id(self.order[index], action)) index++;
        remove_action(self, index);
        return;
    }

    state.fade_target = 0;
    state.fade_rate = state.weight / fade_out;
}

<*
 Transfer weight between two independent actions.
 @param duration : "Finite positive seconds."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? PlaybackView.cross_fade(
    &self,
    AnimationActionId from,
    AnimationActionId to,
    float duration,
) {
    Action* source = self.actions.try_get(from)!;
    Action* target = self.actions.try_get(to)!;
    if (source.blend_space || target.blend_space) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(duration) || duration <= 0 || c3d::same_id(from, to)) return c3d::INVALID_ARGUMENT~;

    source.fade_target = 0;
    source.fade_rate = source.weight / duration;
    target.fade_target = 1;
    target.fade_rate = math::abs(1 - target.weight) / duration;
}

<*
 Evaluate playback into caller-owned pose and event outputs.
 @param [&inout] playback : "Playback clocks and motion are advanced."
 @param [&in] assets : "Clips remain live throughout playback."
 @param dt : "Finite nonnegative seconds."
 @require math::is_finite(dt) && dt >= 0
 @require destination.pose.len == destination.base_pose.len
 @require destination.present.len == destination.base_pose.len
 @require destination.mesh_present.len == destination.base_pose.len
 @require destination.mesh_indices.len == destination.base_pose.len
 @require scratch.channels.len == destination.pose.len
 @require destination.morph_weights.len == destination.base_morph_weights.len
 @require scratch.morph_sums.len == destination.base_morph_weights.len
 @require scratch.morph_weights.len == destination.base_morph_weights.len
 @require scratch.event_bookmarks.len >= events.capacity
 @require events.capacity == 0 || events.first != null
 @require events.capacity == 0 || events.stride >= FiredEvent::size
*>
fn EventReport evaluate_pose(
    PlaybackView* playback,
    AssetStore* assets,
    PoseDestination destination,
    PoseScratch scratch,
    float dt,
    EventOutput events,
) {
    *playback.root_motion = { .rotation = quaternion::IDENTITY };

    advance(playback, assets, dt);
    advance_blend_spaces(playback, assets, dt);

    blend_pose(playback, assets, destination, scratch);

    publish_root_motion(playback, assets, destination);

    return publish_events(playback, assets, events, scratch.event_bookmarks);
}

<* Borrow a contiguous retained-event array. *>
fn EventOutput event_output(FiredEvent[] events) {
    return { .first = events.ptr, .stride = FiredEvent::size, .capacity = (usz)events.len };
}

<*
 Prepare owned action data without changing playback storage.
 @param [&in] assets : "Clips remain live throughout playback."
 @param desc : "Mask validation precedes its deferred installation copy."
 @param root_node : "Destination index used for motion."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require destination.present.len == destination.base_pose.len
 @require destination.mesh_present.len == destination.base_pose.len
 @require destination.mesh_indices.len == destination.base_pose.len
*>
fn Action? prepare_playback_action(
    Allocator allocator,
    AssetStore* assets,
    ClipId clip,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
    uint root_node,
) {
    AnimationClip* data = &assets.clips.try_get(clip)!.data;
    usz reference_count = validate_playback_action(data, desc, destination)!;

    return prepare_validated_playback_action(
        allocator: allocator,
        clip: clip,
        data: data,
        desc: desc,
        destination: destination,
        motion_basis: motion_basis,
        root_node: root_node,
        reference_count: reference_count,
    );
}

<*
 Install a prepared action, transferring its owned arrays.
 @param [&inout] playback : "Owns the destination action slot and mask row."
 @param owned_action : "Validated for this owner; arrays use playback.allocator."
 @param [in] mask : "Copied membership; null includes every node."
 @require playback.actions.free_count > 0
 @require playback_mask_fits(playback, mask)
*>
fn AnimationActionId install_playback_action(
    PlaybackView* playback,
    Action owned_action,
    JointMask* mask,
) {
    AnimationActionId id = playback.actions.add(owned_action)!!;
    Action* action = playback.actions.get(id);
    usz node_count = (usz)(playback.mask_storage.len / playback.actions.items.len);
    action.mask = playback.mask_storage[(usz)id.index * node_count:node_count];
    if (mask) {
        action.mask[..] = mask.nodes[..];
    } else {
        action.mask[..] = true;
    }

    playback.order[(*playback.action_count)++] = id;
    return id;
}

<*
 Release an uninstalled action's owned arrays.
 @param [&inout] action : "Cleared after its arrays are freed."
*>
fn void release_prepared_action(Allocator allocator, Action* action) {
    alloc::free(allocator, action.cursors.ptr);
    alloc::free(allocator, action.reference.ptr);
    *action = {};
}

<*
 Remove every action while retaining the owner's fixed pools.
 @param [&inout] playback : "Action generations advance; owned cursors and references are freed."
*>
fn void clear_playback(PlaybackView* playback) {
    while (*playback.action_count) remove_action(playback, *playback.action_count - 1);
}

fn bool playback_mask_fits(PlaybackView* playback, JointMask* mask) @private {
    if (!mask) return true;

    return mask.nodes.len == playback.mask_storage.len / playback.actions.items.len;
}

fn usz? validate_playback_action(
    AnimationClip* data,
    PlayDesc desc,
    PoseDestination destination,
) @private {
    if (!math::is_finite(desc.fade_in) || desc.fade_in < 0 || desc.layer >= MAX_ANIMATION_LAYERS) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (desc.mask && desc.mask.nodes.len != destination.base_pose.len) return c3d::INVALID_ARGUMENT~;

    usz reference_count;
    foreach (target : data.targets) {
        if (target >= destination.base_pose.len) return c3d::INVALID_ARGUMENT~;
    }

    foreach (&track : data.tracks) {
        reference_count += track.stride();
        if (track.path != TargetPath.MORPH_WEIGHTS) continue;
        uint target = data.targets[track.target];
        uint mesh = destination.mesh_indices[target];
        if (mesh == uint::max) return c3d::INVALID_ARGUMENT~;
        if (!destination.present[target] || !destination.mesh_present[target]) continue;
        if (destination.mesh_widths[mesh] != track.stride()) return c3d::INVALID_ARGUMENT~;
    }

    return reference_count;
}

fn Action? prepare_validated_playback_action(
    Allocator allocator,
    ClipId clip,
    AnimationClip* data,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
    uint root_node,
    usz reference_count,
) @private {
    PlaybackView playback = { .root_node = root_node };
    Action state;
    configure_motion(
        playback: &playback,
        action: &state,
        clip: data,
        desc: desc,
        motion_basis: motion_basis,
        node_count: (usz)destination.base_pose.len,
    )!;

    uint[] cursors = alloc::new_array_try(allocator, uint, data.tracks.len) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, cursors.ptr);

    float[] reference;
    if (desc.additive) {
        reference = alloc::new_array_try(allocator, float, (sz)reference_count)
          ?? c3d::CAPACITY_EXCEEDED~!;
    }
    defer catch alloc::free(allocator, reference.ptr);

    if (desc.additive) {
        usz offset;
        foreach (&track : data.tracks) {
            uint cursor;
            sample_track(
                track: track,
                time: 0,
                cursor: &cursor,
                out: reference[offset:track.stride()],
            );
            offset += track.stride();
        }
    }

    state.clip = clip;
    state.cursors = cursors;
    state.reference = reference;
    state.speed = 1;
    state.weight = desc.fade_in > 0 ? 0 : 1;
    state.fade_target = 1;
    state.fade_rate = desc.fade_in > 0 ? 1 / desc.fade_in : 0;
    state.layer = desc.layer;
    state.additive = desc.additive;
    state.loop = true;
    state.playing = true;

    return state;
}

fn void remove_action(PlaybackView* playback, uint index) @local {
    AnimationActionId id = playback.order[index];
    Action* action = playback.actions.get(id);
    alloc::free(playback.allocator, action.cursors.ptr);
    alloc::free(playback.allocator, action.reference.ptr);
    *action = {};

    playback.actions.remove(id);
    (*playback.action_count)--;
    for (uint next = index; next < *playback.action_count; next++) playback.order[next] = playback.order[next + 1];
}

fn void advance(PlaybackView* playback, AssetStore* assets, float dt) @local {
    for (uint index = *playback.action_count; index > 0; index--) {
        Action* action = playback.actions.get(playback.order[index - 1]);
        action.previous_time = action.time;
        action.clock_delta = 0;
        if (action.blend_space) continue;
        if (action.playing) advance_clock(action, assets.clip(action.clip).data.duration, (double)dt * action.speed);

        if (action.fade_rate > 0) {
            float step = action.fade_rate * dt;
            float remaining = action.fade_target - action.weight;
            if (math::abs(remaining) <= step) {
                action.weight = action.fade_target;
                action.fade_rate = 0;
            } else {
                action.weight += remaining < 0 ? -step : step;
            }
        }

        if (action.fade_target == 0 && action.weight == 0) remove_action(playback, index - 1);
    }
}
