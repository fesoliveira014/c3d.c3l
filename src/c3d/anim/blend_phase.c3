module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

struct BlendSpaceFade @private {
    float* weight;
    float* target;
    float* rate;
}

struct BlendPhaseStep @private {
    double start;
    double travel;
    double phase;
    double clock_rate;
}

fn bool? stop_blend_space_weight(BlendSpaceFade fade, float duration) @private {
    if (!math::is_finite(duration) || duration < 0) return c3d::INVALID_ARGUMENT~;
    if (duration == 0) return true;

    *fade.target = 0;
    *fade.rate = *fade.weight / duration;
    return false;
}

fn void? fade_blend_space_weight(BlendSpaceFade fade, float target, float duration) @private {
    if (!math::is_finite(target) || target < 0 || target > 1
      || !math::is_finite(duration) || duration <= 0) return c3d::INVALID_ARGUMENT~;

    *fade.target = target;
    *fade.rate = math::abs(target - *fade.weight) / duration;
}

fn bool advance_blend_space_weight(BlendSpaceFade fade, float dt) @private {
    float step = *fade.rate * dt;
    float remaining = *fade.target - *fade.weight;

    if (*fade.rate > 0) {
        if (math::abs(remaining) <= step) {
            *fade.weight = *fade.target;
            *fade.rate = 0;
        } else {
            *fade.weight += remaining < 0 ? -step : step;
        }
    }

    return *fade.weight == 0 && *fade.target == 0;
}

fn BlendPhaseStep advance_blend_phase(
    double phase,
    float dt,
    float speed,
    bool playing,
    double duration,
) @private {
    double travel = playing ? (double)dt * speed / duration : 0;
    double start = phase;
    if (start == 0 && travel < 0) start = 1;
    double end = start + travel;

    return {
        .start = start,
        .travel = travel,
        .phase = end - math::floor(end),
        .clock_rate = playing ? (double)speed / duration : 0,
    };
}

fn void write_blend_space_member(
    Action* action,
    BlendPhaseStep phase,
    float duration,
    float normalized,
    float weight,
) @private {
    action.previous_time = phase.start * duration;
    action.clock_delta = phase.travel * duration;
    action.clock_time = phase.phase * duration;
    action.clock_rate = phase.clock_rate * duration;
    action.time = (float)action.clock_time;
    action.published_time = action.time;

    action.weight = weight * normalized;
}

fn void remove_blend_space_members(PlaybackView* playback, AnimationActionId[] members) @private {
    foreach (id : members) remove_playback_action(playback, id);
}

<*
 Validate group members and prepare their owned actions for a free space slot.
 @param [&in] assets : "Clips remain live throughout playback."
 @param prepared : "Receives one action per clip; released again on faults."
 @return "Free space slot shared by both group kinds."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
 @require prepared.len == clips.len
*>
fn uint? prepare_group_members(
    PlaybackView* playback,
    AssetStore* assets,
    ClipId[] clips,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
    Action[] prepared,
) @private {
    foreach (clip : clips) {
        float duration = assets.clips.try_get(clip)!.data.duration;
        if (!math::is_finite(duration) || duration <= 0) return c3d::INVALID_ARGUMENT~;
    }

    bool unsupported;
    foreach (clip : clips) {
        if (catch excuse = validate_playback_addition(
            playback: playback,
            assets: assets,
            clip: &assets.clip(clip).data,
            desc: desc,
            destination: destination,
            basis: motion_basis,
        )) {
            if (excuse != c3d::UNSUPPORTED) return excuse~;
            unsupported = true;
        }
    }

    if (unsupported) return c3d::UNSUPPORTED~;

    uint slot;
    while (slot < MAX_BLEND_SPACES
      && (playback.blend_spaces[slot].count || playback.blend_spaces_2d[slot].count)) slot++;
    if (slot == MAX_BLEND_SPACES || playback.actions.free_count < clips.len) return c3d::CAPACITY_EXCEEDED~;

    uint prepared_count;
    defer catch {
        foreach (&action : prepared[:prepared_count]) release_prepared_action(playback.allocator, action);
    }

    PlayDesc member_desc = desc;
    member_desc.fade_in = 0;

    foreach (index, clip : clips) {
        prepared[index] = prepare_playback_action(
            allocator: playback.allocator,
            assets: assets,
            clip: clip,
            desc: member_desc,
            destination: destination,
            motion_basis: motion_basis,
            root_node: playback.root_node,
            precise_rotation: desc.extraction.generalized || generalized_playback_chain(playback) != null,
        )!;
        prepared_count++;
        prepare_action_motion_capture(
            allocator: playback.allocator,
            assets: assets,
            model: playback.model,
            action: &prepared[index],
            root_node: playback.root_node,
            motion_basis: motion_basis,
        )!;
    }

    return slot;
}

<*
 Install prepared group members; the first carries the group's weight.
 @param [&inout] playback : "Owns the members' action slots and mask rows."
 @param prepared : "Prepared for this playback by prepare_group_members."
 @param [out] members : "Installed action ids in member order."
 @require members.len == prepared.len, playback.actions.free_count >= prepared.len
*>
fn void install_group_members(
    PlaybackView* playback,
    Action[] prepared,
    uint slot,
    PlayDesc desc,
    float weight,
    AnimationActionId[] members,
) @private {
    foreach (uint index, action : prepared) {
        AnimationActionId id = install_playback_action(playback, action, desc.mask);
        members[index] = id;
        Action* installed = playback.actions.get(id);
        installed.blend_space = slot + 1;
        installed.playing = false;
        installed.weight = index == 0 ? weight : 0;
    }

    if (desc.fade_in == 0) invalidate_inertial_history(playback);
}
