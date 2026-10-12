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
    PlaybackView playback = crowd_player_view(self)!;

    return playback.add_blend_space_2d(
        assets: assets,
        clips: clips,
        coordinates: coordinates,
        triangles: triangles,
        desc: desc,
        destination: crowd_destination(self.state, self.instance.index),
        motion_basis: crowd_motion_basis(self.state, self.instance.index, playback.root_node),
    );
}

<*
 Fade a planar space out or remove its members immediately.
 @param [&inout] space : "Current borrow from this instance."
 @param fade_out : "Finite nonnegative seconds."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? CrowdPlayer.stop_blend_space_2d(&self, BlendSpace2D* space, float fade_out = 0) {
    PlaybackView playback = crowd_player_view(self)!;
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
    PlaybackView playback = crowd_player_view(self)!;
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

    Action[MAX_ACTIONS] prepared;
    uint slot = prepare_group_members(
        playback: self,
        assets: assets,
        clips: clips,
        desc: desc,
        destination: destination,
        motion_basis: motion_basis,
        prepared: prepared[:clips.len],
    )!;

    BlendSpace2D* space = &self.blend_spaces_2d[slot];
    space.count = (uint)clips.len;
    space.triangle_count = layout.triangle_count;
    space.hull_count = layout.hull_count;
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

    install_group_members(
        playback: self,
        prepared: prepared[:space.count],
        slot: slot,
        desc: desc,
        weight: space.weight,
        members: space.actions[:space.count],
    );

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
    if (!stop_blend_space_weight(fade, fade_out)!) return;

    remove_blend_space_2d(self, space);
    invalidate_inertial_history(self);
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

fn BlendSpace2D[]? create_blend_spaces_2d(Allocator allocator, uint capacity, uint owners = 1) @private {
    $assert BlendSpace2D::alignment % AnimationActionId::alignment == 0
      && BlendSpace2D::alignment % Vec2::alignment == 0;

    uint triangles = capacity * 2 > 5 ? capacity * 2 - 5 : 0;
    usz count = (usz)owners * MAX_BLEND_SPACES;
    usz controls = count * BlendSpace2D::size;
    usz points_offset = align_blend_space_storage(capacity * AnimationActionId::size, Vec2::alignment);
    usz triangles_offset = points_offset + capacity * Vec2::size;
    usz hull_offset = triangles_offset + triangles * BlendTriangleIndices::size;
    usz slot_end = hull_offset + capacity * BlendHullIndices::size;
    usz slot_bytes = align_blend_space_storage(slot_end, BlendSpace2D::alignment);
    usz bytes = controls + count * slot_bytes;

    char* storage = (char*)(allocator.acquire((sz)bytes, AllocInitType.ZERO, BlendSpace2D::alignment)
      ?? c3d::CAPACITY_EXCEEDED~!);
    BlendSpace2D[] spaces = ((BlendSpace2D*)storage)[:count];

    foreach (usz slot, &space : spaces) {
        char* slot_storage = storage + controls + slot * slot_bytes;
        space.actions = ((AnimationActionId*)slot_storage)[:capacity];
        space.points = ((Vec2*)(slot_storage + points_offset))[:capacity];
        space.triangles = ((BlendTriangleIndices*)(slot_storage + triangles_offset))[:triangles];
        space.hull = ((BlendHullIndices*)(slot_storage + hull_offset))[:capacity];
    }

    return spaces;
}

fn void destroy_blend_spaces_2d(Allocator allocator, BlendSpace2D[] spaces) @private {
    if (spaces.len) allocator.release(spaces.ptr, true);
}

fn usz align_blend_space_storage(usz offset, usz alignment) @private {
    return (offset + alignment - 1) / alignment * alignment;
}
