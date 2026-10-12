module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

<*
 Replace playback with copied targets and a decaying pose residual.
 All source action IDs and borrows become stale.
 @param [&in] assets : "Target clips remain live throughout playback."
 @param desc : "Target arrays are borrowed only during this call."
 @return "Target-ordinal IDs and group borrows."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
 @require self.inertial_storage != null
 @ensure return.count == desc.actions.len && return.space_count == desc.spaces.len
 @ensure @transition_result_matches_order(return, self.order[:self.action_count])
*>
fn AnimationTransitionResult? Animator.inertialize(&self, AssetStore* assets, AnimationTransitionDesc desc) {
    refresh_destination(self);
    PlaybackView playback = self.playback();

    AnimationTransitionResult installed = request_inertial_transition(
        playback: &playback,
        assets: assets,
        desc: desc,
        destination: self.pose_storage.destination,
        scratch: self.pose_storage.scratch,
        motion_basis: animator_motion_basis(self),
    )!;

    ModelInstance* instance = self.scene.get(self.instance_root, ModelInstance);
    publish_animator_pose(self, instance);
    self.event_count = 0;
    self.events_dropped = 0;
    self.root_motion = { .rotation = quaternion::IDENTITY };

    return installed;
}

<* Discard the residual while keeping target playback.
   @require self.inertial_storage != null *>
fn void Animator.cancel_inertial_transition(&self) {
    cancel_inertial_row(&self.inertial_storage.rows[0]);
}

<*
 Replace this instance's playback with copied targets.
 All source action IDs and borrows become stale.
 @param [&in] assets : "Target clips remain live throughout playback."
 @param desc : "Target arrays are borrowed only during this call."
 @return "Target-ordinal IDs and group borrows."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
 @require self.state.inertial_storage != null
 @ensure return.count == desc.actions.len && return.space_count == desc.spaces.len
 @ensure @transition_result_matches_crowd(return, self)
*>
fn AnimationTransitionResult? CrowdPlayer.inertialize(&self, AssetStore* assets, AnimationTransitionDesc desc) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);

    AnimationTransitionResult installed = request_inertial_transition(
        playback: &playback,
        assets: assets,
        desc: desc,
        destination: crowd_destination(self.state, self.instance.index),
        scratch: self.state.pose_storage.scratch,
        motion_basis: crowd_motion_basis(self.state, self.instance.index, slot.root_node),
    )!;

    slot.base_action = {};
    foreach (id : installed.actions[:installed.count]) {
        if (slot.actions.get(id).blend_space) continue;
        slot.base_action = id;
        break;
    }

    slot.root_motion = { .rotation = quaternion::IDENTITY };

    uint kept;
    foreach (event : self.state.events[:self.state.event_count]) {
        if (c3d::same_id(event.instance, self.instance)) continue;
        self.state.events[kept++] = event;
    }
    self.state.event_count = kept;

    return installed;
}

<* Discard this instance's residual while keeping target playback.
   @return? c3d::INVALID_ID
   @require self.state.inertial_storage != null *>
fn void? CrowdPlayer.cancel_inertial_transition(&self) {
    (void)crowd_slot(self.state, self.instance)!;
    cancel_inertial_row(&self.state.inertial_storage.rows[self.instance.index]);
}

fn void cancel_inertial_row(InertialRow* row) @local {
    row.control.active = false;
    row.control.duration = 0;
    row.control.elapsed = 0;
    row.root.target_rate_pending = false;
}

<* @require playback.inertial != null && scratch.inertial != null *>
fn AnimationTransitionResult? request_inertial_transition(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationTransitionDesc desc,
    PoseDestination destination,
    PoseScratch scratch,
    MotionBasis motion_basis,
) @private {
    PreparedTransition prepared = prepare_animation_transition(
        playback: playback,
        assets: assets,
        desc: desc,
        destination: destination,
        motion_basis: motion_basis,
    )!;
    defer release_prepared_transition(&prepared);

    return begin_prepared_inertial_transition(
        playback: playback,
        assets: assets,
        prepared: &prepared,
        destination: destination,
        scratch: scratch,
    );
}

macro bool @transition_result_matches_order(AnimationTransitionResult result, AnimationActionId[] order) @private {
    if (result.count != order.len) return false;

    foreach (index, id : result.actions[:result.count]) {
        if (!c3d::same_id(id, order[index])) return false;
    }

    return true;
}

macro bool @transition_result_matches_crowd(AnimationTransitionResult result, CrowdPlayer* player) @private {
    CrowdPlaybackSlot* slot = &player.state.slots[player.instance.index];
    return @transition_result_matches_order(result, slot.order[:slot.action_count]);
}
