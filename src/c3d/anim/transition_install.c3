module c3d::anim;

import c3d;
import c3d::asset;

struct InstalledTransition @private {
    AnimationActionId[MAX_ACTIONS] actions;
    uint count;
}

<* @require prepared.action_count <= playback.actions.items.len *>
fn InstalledTransition install_animation_transition(
    PlaybackView* playback,
    AssetStore* assets,
    PreparedTransition* prepared,
) @private {
    clear_playback(playback);
    playback.blend_spaces[..] = (BlendSpace1D){};
    foreach (&space : playback.blend_spaces_2d) reset_blend_space_2d(space);

    InstalledTransition installed = { .count = prepared.action_count };
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
                space.reversed = source.layout.reversed;
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
