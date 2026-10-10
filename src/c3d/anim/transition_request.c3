module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

<*
 Replace playback with copied targets and a decaying pose residual.
 @param [&in] assets : "Target clips remain live throughout playback."
 @param desc : "Target arrays are borrowed only during this call."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
 @require self.inertial_storage != null
*>
fn void? Animator.inertialize(&self, AssetStore* assets, AnimationTransitionDesc desc) {
    refresh_destination(self);
    PlaybackView playback = self.playback();
    (void)request_inertial_transition(
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
}

<* Discard the residual while keeping target playback.
   @require self.inertial_storage != null *>
fn void Animator.cancel_inertial_transition(&self) {
    cancel_inertial_row(&self.inertial_storage.rows[0]);
}

<*
 Replace this instance's playback with copied targets.
 @param [&in] assets : "Target clips remain live throughout playback."
 @param desc : "Target arrays are borrowed only during this call."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
 @require self.state.inertial_storage != null
*>
fn void? CrowdPlayer.inertialize(&self, AssetStore* assets, AnimationTransitionDesc desc) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);
    InstalledTransition installed = request_inertial_transition(
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

<* @require playback.inertial != null && scratch.derivative != null *>
fn InstalledTransition? request_inertial_transition(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationTransitionDesc desc,
    PoseDestination destination,
    PoseScratch scratch,
    MotionBasis motion_basis,
) @private {
    PreparedTransition validation = validate_animation_transition(
        playback: playback,
        assets: assets,
        desc: desc,
        destination: destination,
        motion_basis: motion_basis,
        defer_unsupported: true,
    )!;
    validate_transition_extraction_modes(playback, desc)!;
    TransitionMotionIdentity identity = validate_transition_motion_identity(
        playback: playback,
        assets: assets,
        desc: desc,
        destination: destination,
        motion_basis: motion_basis,
        defer_unsupported: true,
    )!;
    bool unsupported = validation.unsupported || identity.unsupported;
    if (catch excuse = validate_transition_scale_eligibility(
        playback: playback,
        assets: assets,
        desc: desc,
        prepared: &validation,
        destination: destination,
    )) {
        if (excuse != c3d::UNSUPPORTED) return excuse~;
        unsupported = true;
    }
    if (unsupported) return c3d::UNSUPPORTED~;

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

fn RootExtractionDesc transition_action_extraction(PlayDesc desc) @local {
    if (desc.extraction.generalized) return desc.extraction;

    return {
        .translation_axes = { true, false, true },
        .up = { 0, 1, 0 },
        .twist = desc.root_yaw,
    };
}

fn void? validate_transition_extraction_modes(PlaybackView* playback, AnimationTransitionDesc desc) @local {
    RootExtractionDesc source_config;
    bool has_config;
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (action.root_motion != RootMotion.EXTRACT) continue;
        RootExtractionDesc config = transition_action_extraction({
            .root_yaw = action.root_yaw,
            .extraction = action.extraction,
        });
        if (has_config && !same_transition_extraction(source_config, config)) return c3d::INVALID_ARGUMENT~;
        source_config = config;
        has_config = true;
    }

    foreach (target : desc.actions) {
        if (target.play.root_motion != RootMotion.EXTRACT) continue;
        RootExtractionDesc config = transition_action_extraction(target.play);
        if (has_config && !same_transition_extraction(source_config, config)) return c3d::INVALID_ARGUMENT~;
        source_config = config;
        has_config = true;
    }
}

fn bool same_transition_extraction(RootExtractionDesc first, RootExtractionDesc second) @local {
    if (first.generalized != second.generalized || first.up != second.up || first.twist != second.twist) return false;

    foreach (index, axis : first.translation_axes) if (axis != second.translation_axes[index]) return false;

    return true;
}
