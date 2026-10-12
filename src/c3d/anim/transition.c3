module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

<* Full-weight looping destination action at its first sample. *>
const AnimationTargetDesc ANIMATION_TARGET_DEFAULT = {
    .speed = 1,
    .weight = 1,
    .loop = true,
    .playing = true,
};

<* Captured translation axes and twist in the instance-root frame. *>
struct RootExtractionDesc {
    bool generalized;
    bool[3] translation_axes;
    Vec3 up;
    bool twist;
}

<* Fixed animation storage selected when an owner is prepared. *>
struct AnimatorDesc {
    bool inertia_enabled;
}

<* One copied destination action of an inertial request. *>
struct AnimationTargetDesc {
    ClipId clip;
    PlayDesc play;
    float start_time;
    float speed;
    float weight;
    bool loop;
    bool playing;
}

<* Request-only group authoring with an initial normalized clock and positive group weight. *>
struct AnimationTransitionSpaceDesc {
    CrowdSpaceAuthoring space;
    float phase;
}

<* Borrowed installed group, valid until playback changes structure. *>
struct AnimationTransitionGroup {
    AnimationSpaceKind kind;
    union {
        BlendSpace1D* one_dimensional;
        BlendSpace2D* two_dimensional;
    }
}

<* Installed action IDs follow target ordinals; group borrows follow descriptions. *>
struct AnimationTransitionResult {
    AnimationActionId[MAX_ACTIONS] actions;
    uint count;
    AnimationTransitionGroup[MAX_BLEND_SPACES] spaces;
    uint space_count;
}

<* Replacement actions and groups corrected over update seconds. *>
struct AnimationTransitionDesc {
    float duration;
    AnimationTargetDesc[] actions;
    AnimationTransitionSpaceDesc[] spaces;
}

struct PreparedTransitionSpace @private {
    AnimationSpaceKind kind;
    uint[MAX_ACTIONS] members;
    uint count;
    float[MAX_BLEND_SPACE_ACTIONS] positions;
    Vec2[MAX_ACTIONS] points;
    BlendTriangleIndices[2 * MAX_ACTIONS - 5] triangles;
    BlendHullIndices[MAX_ACTIONS] hull;
    BlendLayoutInfo layout;
    float parameter;
    Vec2 parameter_2d;
    float speed;
    float weight;
    bool playing;
    double phase;
}

struct PreparedTransition @private {
    Allocator allocator;
    Action[MAX_ACTIONS] actions;
    bool[][MAX_ACTIONS] boolean_masks;
    bool[MAX_ACTIONS] has_boolean_mask;
    PreparedTransitionSpace[MAX_BLEND_SPACES] spaces;
    uint action_count;
    uint space_count;
    float duration;
}

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

<*
 @require playback.actions.items.len > 0 && playback.actions.items.len <= MAX_ACTIONS
 @require destination.present.len == destination.base_pose.len
 @require destination.mesh_present.len == destination.base_pose.len
 @require destination.mesh_indices.len == destination.base_pose.len
*>
fn PreparedTransition? validate_animation_transition(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationTransitionDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
) @private {
    if (!math::is_finite(desc.duration) || desc.duration < 0) return c3d::INVALID_ARGUMENT~;
    if (desc.actions.len > playback.actions.items.len || desc.spaces.len > MAX_BLEND_SPACES) {
        return c3d::CAPACITY_EXCEEDED~;
    }

    PreparedTransition prepared = {
        .allocator = playback.allocator,
        .duration = desc.duration,
    };

    foreach (index, source : desc.spaces) {
        prepare_transition_space(
            source: source.space,
            phase: source.phase,
            destination: &prepared.spaces[index],
            action_count: (uint)desc.actions.len,
            capacity: (uint)playback.actions.items.len,
        )!;
    }
    prepared.space_count = (uint)desc.spaces.len;

    bool[MAX_ACTIONS] grouped;
    foreach (space : prepared.spaces[:prepared.space_count]) {
        foreach (ordinal : space.members[:space.count]) {
            if (grouped[ordinal]) return c3d::INVALID_ARGUMENT~;
            grouped[ordinal] = true;
        }
    }

    RootExtractionDesc* consumed_extraction;
    foreach (&target : desc.actions) {
        if (!target.play.extraction.generalized) continue;
        consumed_extraction = &target.play.extraction;
        break;
    }

    bool unsupported;
    foreach (index, target : desc.actions) {
        if (!math::is_finite(target.start_time) || !math::is_finite(target.speed)
          || !math::is_finite(target.weight) || target.weight < 0) return c3d::INVALID_ARGUMENT~;

        AnimationClip* clip = &assets.clips.try_get(target.clip)!.data;
        if (!math::is_finite(clip.duration) || clip.duration < 0 || (grouped[index] && clip.duration <= 0)) {
            return c3d::INVALID_ARGUMENT~;
        }

        unsupported |= validate_action_desc(
            playback: playback,
            assets: assets,
            clip: clip,
            desc: target.play,
            destination: destination,
            motion_basis: motion_basis,
            consumed_extraction: consumed_extraction,
        )!;

        // Targets share the source's extraction so the root residual stays in one frame.
        validate_live_extraction(playback, target.play)!;
        if (consumed_extraction && target.play.root_motion == RootMotion.EXTRACT
          && !same_extraction(*consumed_extraction, target.play.extraction)) return c3d::INVALID_ARGUMENT~;
    }

    if (consumed_extraction) {
        validate_consumed_scales(
            template: &assets.models.try_get(playback.model)!.data,
            root_node: playback.root_node,
            destination: destination,
        )!;
    }

    if (unsupported) return c3d::UNSUPPORTED~;

    return prepared;
}

fn PreparedTransition? prepare_animation_transition(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationTransitionDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
) @private {
    PreparedTransition prepared = validate_animation_transition(
        playback: playback,
        assets: assets,
        desc: desc,
        destination: destination,
        motion_basis: motion_basis,
    )!;
    defer catch release_prepared_transition(&prepared);

    bool generalized;
    foreach (target : desc.actions) generalized |= target.play.extraction.generalized;

    foreach (index, target : desc.actions) {
        prepared.actions[index] = prepare_validated_playback_action(
            allocator: playback.allocator,
            clip: target.clip,
            data: &assets.clip(target.clip).data,
            desc: target.play,
            destination: destination,
            motion_basis: motion_basis,
            root_node: playback.root_node,
            precise_rotation: generalized,
        )!;
        prepared.action_count++;

        prepare_action_motion_capture(
            allocator: playback.allocator,
            assets: assets,
            model: playback.model,
            action: &prepared.actions[index],
            root_node: playback.root_node,
        )!;

        if (target.play.mask) {
            prepared.has_boolean_mask[index] = true;
            prepared.boolean_masks[index] = alloc::new_array_try(
                allocator: playback.allocator,
                $Type: bool,
                elements: target.play.mask.nodes.len,
            ) ?? c3d::CAPACITY_EXCEEDED~!;
            prepared.boolean_masks[index][..] = target.play.mask.nodes[..];
        }

        Action* action = &prepared.actions[index];
        action.time = target.start_time;
        action.previous_time = target.start_time;
        action.clock_time = target.start_time;
        action.published_time = target.start_time;
        action.clock_delta = 0;
        action.speed = target.speed;
        action.weight = target.weight;
        action.loop = target.loop;
        action.playing = target.playing;
    }

    return prepared;
}

fn void release_prepared_transition(PreparedTransition* prepared) @private {
    for (uint index = 0; index < prepared.action_count; index++) {
        release_prepared_action(prepared.allocator, &prepared.actions[index]);
        alloc::free(prepared.allocator, prepared.boolean_masks[index].ptr);
    }

    *prepared = {};
}

fn void? prepare_transition_space(
    CrowdSpaceAuthoring source,
    float phase,
    PreparedTransitionSpace* destination,
    uint action_count,
    uint capacity,
) @local {
    if (!math::is_finite(phase) || phase < 0 || phase >= 1) return c3d::INVALID_ARGUMENT~;

    if (!math::is_finite(source.speed) || !math::is_finite(source.weight) || source.weight <= 0) {
        return c3d::INVALID_ARGUMENT~;
    }

    switch (source.kind) {
        case ONE_DIMENSIONAL:
            if (!math::is_finite(source.parameter) || source.actions.len < 2
              || source.actions.len > MAX_BLEND_SPACE_ACTIONS || source.actions.len > capacity
              || source.positions.len != source.actions.len || source.points.len || source.triangles.len
              || source.parameter_2d != (Vec2){}) return c3d::INVALID_ARGUMENT~;

            foreach (index, position : source.positions) {
                if (!math::is_finite(position) || (index && position <= source.positions[index - 1])) {
                    return c3d::INVALID_ARGUMENT~;
                }
            }

            destination.positions[:source.positions.len] = source.positions[..];

        case TWO_DIMENSIONAL:
            if (!math::is_finite(source.parameter_2d.x) || !math::is_finite(source.parameter_2d.y)
              || source.points.len != source.actions.len || source.actions.len > capacity
              || source.positions.len || source.parameter != 0) return c3d::INVALID_ARGUMENT~;

            destination.layout = prepare_blend_layout(
                points: source.points,
                triangles: source.triangles,
                capacity: capacity,
                prepared_triangles: destination.triangles[..],
                prepared_hull: destination.hull[..],
            )!;
            destination.points[:source.points.len] = source.points[..];
    }

    bool[MAX_ACTIONS] seen;
    foreach (ordinal : source.actions) {
        if (ordinal >= action_count || seen[ordinal]) return c3d::INVALID_ARGUMENT~;
        seen[ordinal] = true;
    }

    destination.kind = source.kind;
    destination.count = (uint)source.actions.len;
    destination.members[:source.actions.len] = source.actions[..];
    destination.parameter = source.parameter;
    destination.parameter_2d = source.parameter_2d;
    destination.speed = source.speed;
    destination.weight = source.weight;
    destination.playing = source.playing;
    destination.phase = (double)phase;
}

// Positive source and baseline scales keep every blended consumed scale positive for the log residual.
fn void? validate_consumed_scales(ModelTemplate* template, uint root_node, PoseDestination destination) @local {
    for (int node = (int)root_node; node >= 0; node = template.nodes[node].parent) {
        if (!destination.present[node]) return c3d::INVALID_ARGUMENT~;

        foreach (component : destination.pose[node].scale) {
            if (!(component > 0)) return c3d::INVALID_ARGUMENT~;
        }
        foreach (component : destination.base_pose[node].scale) {
            if (!(component > 0) || !math::is_finite(component)) return c3d::INVALID_ARGUMENT~;
        }
    }
}

<* @require prepared.action_count <= playback.actions.items.len *>
fn AnimationTransitionResult install_animation_transition(
    PlaybackView* playback,
    AssetStore* assets,
    PreparedTransition* prepared,
) @private {
    clear_playback(playback);
    playback.blend_spaces[..] = (BlendSpace1D){};
    foreach (&space : playback.blend_spaces_2d) reset_blend_space_2d(space);

    AnimationTransitionResult installed = {
        .count = prepared.action_count,
        .space_count = prepared.space_count,
    };
    foreach (uint index, &action : prepared.actions[:prepared.action_count]) {
        JointMask mask = { .nodes = prepared.boolean_masks[index] };
        installed.actions[index] = install_playback_action(
            playback: playback,
            owned_action: *action,
            mask: prepared.has_boolean_mask[index] ? &mask : null,
        );
        *action = {};
    }

    foreach (uint slot, source : prepared.spaces[:prepared.space_count]) {
        switch (source.kind) {
            case ONE_DIMENSIONAL:
                BlendSpace1D* space = &playback.blend_spaces[slot];
                *space = {
                    .count = source.count,
                    .parameter = source.parameter,
                    .weight = source.weight,
                    .fade_target = source.weight,
                    .phase = source.phase,
                    .speed = source.speed,
                    .playing = source.playing,
                };
                space.positions[:source.count] = source.positions[:source.count];
                installed.spaces[slot] = { .kind = ONE_DIMENSIONAL, .one_dimensional = space };

                foreach (uint index, ordinal : source.members[:source.count]) {
                    space.actions[index] = installed.actions[ordinal];
                    Action* action = playback.actions.get(space.actions[index]);
                    action.blend_space = slot + 1;
                    action.playing = false;
                    action.weight = index == 0 ? source.weight : 0;
                }

            case TWO_DIMENSIONAL:
                BlendSpace2D* space = &playback.blend_spaces_2d[slot];
                space.count = source.count;
                space.triangle_count = source.layout.triangle_count;
                space.hull_count = source.layout.hull_count;
                space.extent = source.layout.extent;
                space.points[:space.count] = source.points[:space.count];
                space.triangles[:space.triangle_count] = source.triangles[:space.triangle_count];
                space.hull[:space.hull_count] = source.hull[:space.hull_count];

                space.parameter = source.parameter_2d;
                space.weight = source.weight;
                space.fade_target = source.weight;
                space.phase = source.phase;
                space.speed = source.speed;
                space.playing = source.playing;
                installed.spaces[slot] = { .kind = TWO_DIMENSIONAL, .two_dimensional = space };

                foreach (uint index, ordinal : source.members[:source.count]) {
                    space.actions[index] = installed.actions[ordinal];
                    Action* action = playback.actions.get(space.actions[index]);
                    action.blend_space = slot + 1;
                    action.playing = false;
                    action.weight = index == 0 ? source.weight : 0;
                }
        }
    }

    advance_blend_spaces(playback, assets, 0);
    advance_blend_spaces_2d(playback, assets, 0);

    return installed;
}
