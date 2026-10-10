module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

<* Clips sharing one blend-space phase. *>
const uint MAX_BLEND_SPACE_ACTIONS = 8; // eight IDs and positions per space; bounds the neighbor search

<* Blend-space slots owned by each playback owner. *>
const uint MAX_BLEND_SPACES = 2; // two groups allocated with animator storage; bounds concurrent spaces

<* Phase-synchronized clips controlled by one parameter. *>
struct BlendSpace1D {
    AnimationActionId[MAX_BLEND_SPACE_ACTIONS] actions;
    float[MAX_BLEND_SPACE_ACTIONS] positions;
    uint count;
    float parameter;
    float weight;
    float fade_target;
    float fade_rate;
    double phase;
    float speed;
    bool playing;
}

<*
 Start phase-synchronized clips and borrow their controlling space.
 @param [&in] assets : "Clips remain live throughout playback."
 @param positions : "Strictly ascending, finite, one per clip."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn BlendSpace1D*? Animator.add_blend_space(
    &self,
    AssetStore* assets,
    ClipId[] clips,
    float[] positions,
    PlayDesc desc = PLAY_DESC_DEFAULT,
) {
    PlaybackView playback = self.playback();
    refresh_destination(self);

    return playback.add_blend_space(
        assets: assets,
        clips: clips,
        positions: positions,
        desc: desc,
        destination: self.pose_storage.destination,
        motion_basis: animator_motion_basis(self),
    );
}

<*
 Fade a space out or remove its members immediately.
 @param [&inout] space : "Current borrow from this animator."
 @param fade_out : "Finite nonnegative seconds; zero removes immediately."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? Animator.stop_blend_space(&self, BlendSpace1D* space, float fade_out = 0) {
    PlaybackView playback = self.playback();
    playback.stop_blend_space(space, fade_out)!;
}

<*
 Fade a space toward a new weight.
 @param [&inout] space : "Current borrow from this animator."
 @param target_weight : "Finite weight in [0,1]."
 @param duration : "Finite positive seconds."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? Animator.fade_blend_space(
    &self,
    BlendSpace1D* space,
    float target_weight,
    float duration,
) {
    PlaybackView playback = self.playback();
    playback.fade_blend_space(space, target_weight, duration)!;
}

<*
 Start phase-synchronized clips and borrow their controlling space.
 @param [&in] assets : "Clips remain live throughout playback."
 @param positions : "Strictly ascending, finite, one per clip."
 @param desc : "Shared captured configuration and initial fade."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn BlendSpace1D*? PlaybackView.add_blend_space(
    &self,
    AssetStore* assets,
    ClipId[] clips,
    float[] positions,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
) {
    if (clips.len < 2 || clips.len > MAX_BLEND_SPACE_ACTIONS || clips.len != positions.len
        || !math::is_finite(desc.fade_in) || desc.fade_in < 0) return c3d::INVALID_ARGUMENT~;

    foreach (index, position : positions) {
        if (!math::is_finite(position) || (index && position <= positions[index - 1])) return c3d::INVALID_ARGUMENT~;
        float duration = assets.clips.try_get(clips[index])!.data.duration;
        if (!math::is_finite(duration) || duration <= 0) return c3d::INVALID_ARGUMENT~;
    }

    uint slot;
    while (slot < MAX_BLEND_SPACES && self.blend_spaces[slot].count) slot++;
    if (slot == MAX_BLEND_SPACES || self.actions.free_count < clips.len) return c3d::CAPACITY_EXCEEDED~;

    BlendSpace1D created = {
        .parameter = positions[0],
        .weight = desc.fade_in > 0 ? 0 : 1,
        .fade_target = 1,
        .fade_rate = desc.fade_in > 0 ? 1 / desc.fade_in : 0,
        .speed = 1,
        .playing = true,
    };
    defer catch {
        foreach (id : created.actions[:created.count]) self.stop(id)!!;
    }

    desc.fade_in = 0;
    foreach (index, clip : clips) {
        created.actions[index] = self.play(
            assets: assets,
            clip: clip,
            desc: desc,
            destination: destination,
            motion_basis: motion_basis,
        )!;
        created.positions[index] = positions[index];
        created.count++;
    }

    foreach (id : created.actions[:created.count]) {
        Action* action = self.actions.get(id);
        action.blend_space = slot + 1;
        action.playing = false;
        action.weight = 0;
    }

    self.blend_spaces[slot] = created;
    self.actions.get(created.actions[0]).weight = created.weight;
    return &self.blend_spaces[slot];
}

<*
 Fade a space out or remove its members immediately.
 @param [&inout] space : "Current borrow from this playback."
 @param fade_out : "Finite nonnegative seconds."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? PlaybackView.stop_blend_space(&self, BlendSpace1D* space, float fade_out = 0) {
    if (!space.count || !math::is_finite(fade_out) || fade_out < 0) return c3d::INVALID_ARGUMENT~;
    if (fade_out == 0) {
        remove_blend_space(self, space);
        return;
    }

    space.fade_target = 0;
    space.fade_rate = space.weight / fade_out;
}

<*
 Fade a space toward a new weight.
 @param [&inout] space : "Current borrow from this playback."
 @param target_weight : "Finite weight in [0,1]."
 @param duration : "Finite positive seconds."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? PlaybackView.fade_blend_space(
    &self,
    BlendSpace1D* space,
    float target_weight,
    float duration,
) {
    if (!space.count || !math::is_finite(target_weight) || target_weight < 0 || target_weight > 1
        || !math::is_finite(duration) || duration <= 0) return c3d::INVALID_ARGUMENT~;

    space.fade_target = target_weight;
    space.fade_rate = math::abs(target_weight - space.weight) / duration;
}

fn void remove_blend_space(PlaybackView* playback, BlendSpace1D* space) @private {
    foreach (id : space.actions[:space.count]) {
        playback.actions.get(id).blend_space = 0;
        playback.stop(id)!!;
    }

    *space = {};
}

fn void advance_blend_spaces(PlaybackView* playback, AssetStore* assets, float dt) @private {
    foreach (&space : playback.blend_spaces) {
        if (!space.count) continue;

        float step = space.fade_rate * dt;
        float remaining = space.fade_target - space.weight;
        if (space.fade_rate > 0) {
            if (math::abs(remaining) <= step) {
                space.weight = space.fade_target;
                space.fade_rate = 0;
            } else {
                space.weight += remaining < 0 ? -step : step;
            }
        }

        if (space.weight == 0 && space.fade_target == 0) {
            remove_blend_space(playback, space);
            continue;
        }

        float parameter = math::clamp(space.parameter, space.positions[0], space.positions[space.count - 1]);
        uint lower;
        while (lower + 2 < space.count && parameter >= space.positions[lower + 1]) lower++;
        float fraction = (parameter - space.positions[lower]) / (space.positions[lower + 1] - space.positions[lower]);
        double blend = fraction;
        double lower_duration = assets.clip(playback.actions.get(space.actions[lower]).clip).data.duration;
        double upper_duration = assets.clip(playback.actions.get(space.actions[lower + 1]).clip).data.duration;
        double duration = lower_duration * (1 - blend) + upper_duration * blend;
        double travel = space.playing ? (double)dt * space.speed / duration : 0;
        double start = space.phase;
        if (start == 0 && travel < 0) start = 1;
        double end = start + travel;
        space.phase = end - math::floor(end);

        foreach (uint index, id : space.actions[:space.count]) {
            Action* action = playback.actions.get(id);
            float clip_duration = assets.clip(action.clip).data.duration;
            action.previous_time = start * clip_duration;
            action.clock_delta = travel * clip_duration;
            action.clock_time = space.phase * clip_duration;
            action.time = (float)action.clock_time;
            action.published_time = action.time;
            float normalized = index == lower ? 1 - fraction : index == lower + 1 ? fraction : 0;
            action.weight = space.weight * normalized;
        }
    }
}
