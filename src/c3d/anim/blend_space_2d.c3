module c3d::anim;

import c3d;
import c3d::asset;
import c3d::scene;
import std::math;

<*
 Phase-synchronized clips controlled by planar coordinates.
 Arrays remain read-only throughout the borrow; keep parameter finite.
*>
struct BlendSpace2D {
    AnimationActionId[] actions;
    Vec2[] points;
    BlendTriangleIndices[] triangles;
    BlendHullIndices[] hull;
    uint count;
    uint triangle_count;
    uint hull_count;
    uint reversed;
    double extent;
    Vec2 parameter;
    float weight;
    float fade_target;
    float fade_rate;
    double phase;
    float speed;
    bool playing;
}

<*
 Start clips controlled by an explicit planar triangulation.
 @param [&in] assets : "Clips remain live throughout playback."
 @param coordinates : "One distinct finite point per clip."
 @param triangles : "Connected triangulation of the samples' convex hull."
 @param desc : "Shared captured configuration and initial fade."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn BlendSpace2D*? Animator.add_blend_space_2d(
    &self,
    AssetStore* assets,
    ClipId[] clips,
    Vec2[] coordinates,
    BlendTriangle[] triangles,
    PlayDesc desc = PLAY_DESC_DEFAULT,
) {
    refresh_destination(self);
    PlaybackView playback = self.playback();

    return playback.add_blend_space_2d(
        assets: assets,
        clips: clips,
        coordinates: coordinates,
        triangles: triangles,
        desc: desc,
        destination: self.pose_storage.destination,
        motion_basis: animator_motion_basis(self),
    );
}

<*
 Fade a planar space out or remove its members immediately.
 @param [&inout] space : "Current borrow from this animator."
 @param fade_out : "Finite nonnegative seconds."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? Animator.stop_blend_space_2d(&self, BlendSpace2D* space, float fade_out = 0) {
    PlaybackView playback = self.playback();
    playback.stop_blend_space_2d(space, fade_out)!;
}

<*
 Fade a planar space toward a new weight.
 @param [&inout] space : "Current borrow from this animator."
 @param target_weight : "Finite weight in [0,1]."
 @param duration : "Finite positive seconds."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? Animator.fade_blend_space_2d(
    &self,
    BlendSpace2D* space,
    float target_weight,
    float duration,
) {
    PlaybackView playback = self.playback();
    playback.fade_blend_space_2d(space, target_weight, duration)!;
}

<*
 Start planar phase-synchronized clips on this instance.
 @param [&in] assets : "Clips remain live throughout playback."
 @param coordinates : "One distinct finite point per clip."
 @param triangles : "Connected triangulation of the samples' convex hull."
 @param desc : "Shared captured configuration and initial fade."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn BlendSpace2D*? CrowdPlayer.add_blend_space_2d(
    &self,
    AssetStore* assets,
    ClipId[] clips,
    Vec2[] coordinates,
    BlendTriangle[] triangles,
    PlayDesc desc = PLAY_DESC_DEFAULT,
) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);

    return playback.add_blend_space_2d(
        assets: assets,
        clips: clips,
        coordinates: coordinates,
        triangles: triangles,
        desc: desc,
        destination: crowd_destination(self.state, self.instance.index),
        motion_basis: crowd_motion_basis(self.state, self.instance.index, slot.root_node),
    );
}

<*
 Fade a planar space out or remove its members immediately.
 @param [&inout] space : "Current borrow from this instance."
 @param fade_out : "Finite nonnegative seconds."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? CrowdPlayer.stop_blend_space_2d(&self, BlendSpace2D* space, float fade_out = 0) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);
    playback.stop_blend_space_2d(space, fade_out)!;
}

<*
 Fade a planar space toward a new weight.
 @param [&inout] space : "Current borrow from this instance."
 @param target_weight : "Finite weight in [0,1]."
 @param duration : "Finite positive seconds."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? CrowdPlayer.fade_blend_space_2d(
    &self,
    BlendSpace2D* space,
    float target_weight,
    float duration,
) {
    CrowdPlaybackSlot* slot = crowd_slot(self.state, self.instance)!;
    PlaybackView playback = crowd_playback_view(self.state, slot);
    playback.fade_blend_space_2d(space, target_weight, duration)!;
}

<*
 Start copied planar clips in prepared playback storage.
 @param [&in] assets : "Clips remain live throughout playback."
 @param coordinates : "One distinct finite point per clip."
 @param triangles : "Connected triangulation of the samples' convex hull."
 @param desc : "Shared captured configuration and initial fade."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn BlendSpace2D*? PlaybackView.add_blend_space_2d(
    &self,
    AssetStore* assets,
    ClipId[] clips,
    Vec2[] coordinates,
    BlendTriangle[] triangles,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
) {
    uint capacity = (uint)self.actions.items.len;
    if (clips.len != coordinates.len || clips.len < 3 || clips.len > capacity) {
        return c3d::INVALID_ARGUMENT~;
    }

    BlendTriangleIndices[2 * MAX_ACTIONS - 5] admitted_triangles;
    BlendHullIndices[MAX_ACTIONS] admitted_hull;
    BlendLayoutInfo layout = prepare_blend_layout(
        points: coordinates,
        triangles: triangles,
        capacity: capacity,
        prepared_triangles: admitted_triangles[..],
        prepared_hull: admitted_hull[..],
    )!;

    foreach (clip : clips) {
        AnimationClip* data = &assets.clips.try_get(clip)!.data;
        if (!math::is_finite(data.duration) || data.duration <= 0) return c3d::INVALID_ARGUMENT~;

        (void)validate_playback_action(data, desc, destination)!;
    }

    if (desc.weighted_mask) validate_weighted_joint_mask(assets, self.model, desc.weighted_mask)!;

    uint slot;
    while (slot < MAX_BLEND_SPACES
      && (self.blend_spaces[slot].count || self.blend_spaces_2d[slot].count)) slot++;
    if (slot == MAX_BLEND_SPACES || self.actions.free_count < clips.len) return c3d::CAPACITY_EXCEEDED~;

    Action[MAX_ACTIONS] prepared;
    uint prepared_count;
    defer catch {
        foreach (&action : prepared[:prepared_count]) release_prepared_action(self.allocator, action);
    }

    PlayDesc member_desc = desc;
    member_desc.fade_in = 0;

    foreach (clip : clips) {
        prepared[prepared_count] = prepare_playback_action(
            allocator: self.allocator,
            assets: assets,
            clip: clip,
            desc: member_desc,
            destination: destination,
            motion_basis: motion_basis,
            root_node: self.root_node,
        )!;
        prepared_count++;
    }

    BlendSpace2D* space = &self.blend_spaces_2d[slot];
    space.count = (uint)clips.len;
    space.triangle_count = layout.triangle_count;
    space.hull_count = layout.hull_count;
    space.reversed = layout.reversed;
    space.extent = layout.extent;
    space.points[:space.count] = coordinates[..];
    space.triangles[:space.triangle_count] = admitted_triangles[:space.triangle_count];
    space.hull[:space.hull_count] = admitted_hull[:space.hull_count];
    space.parameter = coordinates[0];
    space.weight = desc.fade_in > 0 ? 0 : 1;
    space.fade_target = 1;
    space.fade_rate = desc.fade_in > 0 ? 1 / desc.fade_in : 0;
    space.speed = 1;
    space.playing = true;

    foreach (uint index, action : prepared[:prepared_count]) {
        space.actions[index] = install_playback_action(self, action, desc.mask);
        Action* installed = self.actions.get(space.actions[index]);
        installed.blend_space = slot + 1;
        installed.playing = false;
        installed.weight = index == 0 ? space.weight : 0;
    }

    return space;
}

<*
 Fade a planar space out or remove its members immediately.
 @param [&inout] space : "Current borrow from this playback."
 @param fade_out : "Finite nonnegative seconds."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? PlaybackView.stop_blend_space_2d(&self, BlendSpace2D* space, float fade_out = 0) {
    if (!space.count) return c3d::INVALID_ARGUMENT~;

    BlendSpaceFade fade = { .weight = &space.weight, .target = &space.fade_target, .rate = &space.fade_rate };
    if (stop_blend_space_weight(fade, fade_out)!) remove_blend_space_2d(self, space);
}

<*
 Fade a planar space toward a new weight.
 @param [&inout] space : "Current borrow from this playback."
 @param target_weight : "Finite weight in [0,1]."
 @param duration : "Finite positive seconds."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? PlaybackView.fade_blend_space_2d(
    &self,
    BlendSpace2D* space,
    float target_weight,
    float duration,
) {
    if (!space.count) return c3d::INVALID_ARGUMENT~;

    BlendSpaceFade fade = { .weight = &space.weight, .target = &space.fade_target, .rate = &space.fade_rate };
    fade_blend_space_weight(fade, target_weight, duration)!;
}

fn void remove_blend_space_2d(PlaybackView* playback, BlendSpace2D* space) @private {
    remove_blend_space_members(playback, space.actions[:space.count]);

    reset_blend_space_2d(space);
}

fn void reset_blend_space_2d(BlendSpace2D* space) @private {
    BlendSpace2D empty = {
        .actions = space.actions,
        .points = space.points,
        .triangles = space.triangles,
        .hull = space.hull,
    };
    *space = empty;
}

fn void advance_blend_spaces_2d(PlaybackView* playback, AssetStore* assets, float dt) @private {
    foreach (&space : playback.blend_spaces_2d) {
        if (!space.count) continue;

        BlendSpaceFade fade = { .weight = &space.weight, .target = &space.fade_target, .rate = &space.fade_rate };
        if (advance_blend_space_weight(fade, dt)) {
            remove_blend_space_2d(playback, space);
            continue;
        }

        BlendLayoutView layout = {
            .points = space.points[:space.count],
            .triangles = space.triangles[:space.triangle_count],
            .hull = space.hull[:space.hull_count],
            .reversed = space.reversed,
            .extent = space.extent,
        };
        BlendLayoutSelection selected = select_blend_layout(layout, space.parameter);
        double duration;

        foreach (uint index, member : selected.indices[:selected.count]) {
            double member_duration = assets.clip(playback.actions.get(space.actions[member]).clip).data.duration;
            duration += member_duration * selected.weights[index];
        }

        BlendPhaseStep phase = advance_blend_phase(
            phase: space.phase,
            dt: dt,
            speed: space.speed,
            playing: space.playing,
            duration: duration,
        );
        space.phase = phase.phase;

        foreach (uint index, id : space.actions[:space.count]) {
            Action* action = playback.actions.get(id);
            float clip_duration = assets.clip(action.clip).data.duration;

            float normalized;
            foreach (uint selected_index, member : selected.indices[:selected.count]) {
                if (member == index) normalized = selected.weights[selected_index];
            }

            write_blend_space_member(
                action: action,
                phase: phase,
                duration: clip_duration,
                normalized: normalized,
                weight: space.weight,
            );
        }
    }
}

fn usz blend_space_2d_storage_bytes(uint capacity) @private {
    usz offset = MAX_BLEND_SPACES * BlendSpace2D::size;
    uint triangles = capacity * 2 > 5 ? capacity * 2 - 5 : 0;

    for (uint slot = 0; slot < MAX_BLEND_SPACES; slot++) {
        offset = align_blend_space_storage(offset, BlendSpace2D::alignment);
        offset = align_blend_space_storage(offset, AnimationActionId::alignment);
        offset += capacity * AnimationActionId::size;
        offset = align_blend_space_storage(offset, Vec2::alignment);
        offset += capacity * Vec2::size;
        offset += triangles * BlendTriangleIndices::size;
        offset += capacity * BlendHullIndices::size;
    }

    return align_blend_space_storage(offset, BlendSpace2D::alignment);
}

fn BlendSpace2D[]? create_blend_spaces_2d(Allocator allocator, uint capacity) @private {
    usz bytes = blend_space_2d_storage_bytes(capacity);
    char* storage = (char*)(allocator.acquire((sz)bytes, AllocInitType.ZERO, BlendSpace2D::alignment)
      ?? c3d::CAPACITY_EXCEEDED~!);

    BlendSpace2D[] spaces = ((BlendSpace2D*)storage)[:MAX_BLEND_SPACES];
    usz offset = MAX_BLEND_SPACES * BlendSpace2D::size;
    uint triangles = capacity * 2 > 5 ? capacity * 2 - 5 : 0;

    foreach (&space : spaces) {
        offset = align_blend_space_storage(offset, BlendSpace2D::alignment);
        offset = align_blend_space_storage(offset, AnimationActionId::alignment);
        space.actions = ((AnimationActionId*)(storage + offset))[:capacity];
        offset += capacity * AnimationActionId::size;
        offset = align_blend_space_storage(offset, Vec2::alignment);
        space.points = ((Vec2*)(storage + offset))[:capacity];
        offset += capacity * Vec2::size;
        space.triangles = ((BlendTriangleIndices*)(storage + offset))[:triangles];
        offset += triangles * BlendTriangleIndices::size;
        space.hull = ((BlendHullIndices*)(storage + offset))[:capacity];
        offset += capacity * BlendHullIndices::size;
    }

    return spaces;
}

fn void destroy_blend_spaces_2d(Allocator allocator, BlendSpace2D[] spaces) @private {
    if (spaces.len) allocator.release(spaces.ptr, true);
}

fn usz align_blend_space_storage(usz offset, usz alignment) @private {
    return (offset + alignment - 1) / alignment * alignment;
}
