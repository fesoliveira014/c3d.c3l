module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

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
    float[MAX_ACTIONS] starts;
    PreparedTransitionSpace[MAX_BLEND_SPACES] spaces;
    uint action_count;
    uint target_count;
    uint space_count;
    float duration;
    bool unsupported;
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
    bool defer_unsupported = false,
) @private {
    if (!math::is_finite(desc.duration) || desc.duration < 0) return c3d::INVALID_ARGUMENT~;
    if (desc.actions.len > playback.actions.items.len || desc.spaces.len > MAX_BLEND_SPACES) {
        return c3d::CAPACITY_EXCEEDED~;
    }

    PreparedTransition prepared = {
        .allocator = playback.allocator,
        .target_count = (uint)desc.actions.len,
        .duration = desc.duration,
    };

    foreach (index, source : desc.spaces) {
        prepare_transition_space(
            source: source,
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

    bool unsupported;
    foreach (index, target : desc.actions) {
        if (!math::is_finite(target.start_time) || !math::is_finite(target.speed)
          || !math::is_finite(target.weight) || target.weight < 0) return c3d::INVALID_ARGUMENT~;

        AnimationClip* clip = &assets.clips.try_get(target.clip)!.data;
        if (!math::is_finite(clip.duration) || clip.duration < 0 || (grouped[index] && clip.duration <= 0)) {
            return c3d::INVALID_ARGUMENT~;
        }

        foreach (track : clip.tracks) {
            if (track.target >= clip.targets.len) return c3d::INVALID_ARGUMENT~;
        }

        PlayDesc structural = target.play;
        structural.additive_scale = AdditiveScaleMode.DIFFERENCE;
        (void)validate_playback_action(clip, structural, destination)!;
        if (target.play.weighted_mask) {
            validate_weighted_joint_mask(assets, playback.model, target.play.weighted_mask)!;
        }

        Action motion;
        configure_motion(
            playback: playback,
            action: &motion,
            clip: clip,
            desc: target.play,
            motion_basis: motion_basis,
            node_count: (usz)destination.base_pose.len,
        )!;

        if (target.play.additive && target.play.additive_scale == AdditiveScaleMode.MULTIPLICATIVE) {
            if (catch excuse = validate_multiplicative_scale(clip)) {
                if (excuse != c3d::UNSUPPORTED) return excuse~;
                unsupported = true;
            }
        }

        if (playback.inertial) {
            if (catch excuse = validate_inertial_rotation_domains(clip)) {
                if (excuse != c3d::UNSUPPORTED) return excuse~;
                unsupported = true;
            }
        }

        if (target.play.extraction.generalized) {
            ModelTemplate* template = &assets.models.try_get(playback.model)!.data;
            if (catch excuse = validate_generalized_motion(
                template: template,
                clip: clip,
                root: playback.root_node,
                extraction: target.play.extraction,
                motion_basis: motion_basis,
                additive: target.play.additive,
                additive_scale: target.play.additive_scale,
                diagnostic: null,
            )) {
                if (excuse != c3d::UNSUPPORTED) return excuse~;
                unsupported = true;
            }
        }
    }

    prepared.unsupported = unsupported;
    if (unsupported && !defer_unsupported) return c3d::UNSUPPORTED~;

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

    foreach (index, target : desc.actions) {
        prepared.actions[index] = prepare_playback_action(
            allocator: playback.allocator,
            assets: assets,
            clip: target.clip,
            desc: target.play,
            destination: destination,
            motion_basis: motion_basis,
            root_node: playback.root_node,
        )!;
        prepared.action_count++;

        prepare_action_motion_capture(
            allocator: playback.allocator,
            assets: assets,
            model: playback.model,
            action: &prepared.actions[index],
            root_node: playback.root_node,
            motion_basis: motion_basis,
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
        prepared.starts[index] = target.start_time;
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
    PreparedTransitionSpace* destination,
    uint action_count,
    uint capacity,
) @local {
    if (!math::is_finite(source.speed) || !math::is_finite(source.weight) || source.weight < 0) {
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
}
