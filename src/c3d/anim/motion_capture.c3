module c3d::anim;

import c3d;
import c3d::asset;

fn usz? validate_playback_addition(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationClip* clip,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis basis,
) @private {
    foreach (track : clip.tracks) {
        if (track.target >= clip.targets.len) return c3d::INVALID_ARGUMENT~;
    }

    bool generalized = desc.extraction.generalized || generalized_playback_chain(playback) != null;
    PlayDesc structural = desc;
    if (generalized) structural.additive_scale = AdditiveScaleMode.DIFFERENCE;
    usz reference_count = validate_playback_action(clip, structural, destination)!;
    if (desc.weighted_mask) validate_weighted_joint_mask(assets, playback.model, desc.weighted_mask)!;

    Action motion;
    configure_motion(
        playback: playback,
        action: &motion,
        clip: clip,
        desc: desc,
        motion_basis: basis,
        node_count: destination.base_pose.len,
    )!;

    bool unsupported;
    if (catch excuse = validate_action_motion_capture(
        assets: assets,
        model: playback.model,
        clip: clip,
        desc: desc,
        root_node: playback.root_node,
        motion_basis: basis,
    )) {
        if (excuse != c3d::UNSUPPORTED) return excuse~;
        unsupported = true;
    }

    if (catch excuse = validate_live_motion_addition(
        playback: playback,
        assets: assets,
        clip: clip,
        desc: desc,
        basis: basis,
    )) {
        if (excuse != c3d::UNSUPPORTED) return excuse~;
        unsupported = true;
    }

    if (generalized && desc.additive && desc.additive_scale == AdditiveScaleMode.MULTIPLICATIVE) {
        foreach (index, track : clip.tracks) {
            if (track.path != TargetPath.SCALE) continue;

            AnimationClip channel = { .tracks = clip.tracks[index:1] };
            if (catch excuse = validate_multiplicative_scale(&channel)) {
                if (excuse != c3d::UNSUPPORTED) return excuse~;
                unsupported = true;
            }
        }
    }

    if (unsupported) return c3d::UNSUPPORTED~;
    return reference_count;
}

fn void? validate_action_motion_capture(
    AssetStore* assets,
    ModelId model,
    AnimationClip* clip,
    PlayDesc desc,
    uint root_node,
    MotionBasis motion_basis,
) @private {
    if (!desc.extraction.generalized) return;

    ModelTemplate* template = &assets.models.try_get(model)!.data;
    validate_generalized_motion(
        template: template,
        clip: clip,
        root: root_node,
        extraction: desc.extraction,
        motion_basis: motion_basis,
        additive: desc.additive,
        additive_scale: desc.additive_scale,
    )!;
}

fn void? prepare_action_motion_capture(
    Allocator allocator,
    AssetStore* assets,
    ModelId model,
    Action* action,
    uint root_node,
    MotionBasis motion_basis,
    bool derivatives_enabled = false,
) @private {
    if (!action.extraction.generalized) return;

    ModelTemplate* template = &assets.models.try_get(model)!.data;
    AnimationClip* clip = &assets.clips.try_get(action.clip)!.data;
    validate_generalized_motion(
        template: template,
        clip: clip,
        root: root_node,
        extraction: action.extraction,
        motion_basis: motion_basis,
        additive: action.additive,
        additive_scale: action.additive_scale,
    )!;

    CapturedMotionChain* captured = alloc::new_try(allocator, CapturedMotionChain)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, captured);

    *captured = create_captured_motion_chain(
        allocator: allocator,
        template: template,
        clip: clip,
        root: root_node,
        extraction: action.extraction,
    )!;
    defer catch destroy_captured_motion_chain(captured);

    if (!derivatives_enabled) {
        captured.pose_scale_sums = alloc::new_array_try(allocator, double[<3>], template.nodes.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
    }

    captured.model = model;

    action.motion_chain = captured;
    action.motion_reference = capture_generalized_motion_reference(captured, clip);
}

fn void? validate_inertial_rotation_domains(AnimationClip* clip) @private {
    bool unsupported;
    foreach (&track : clip.tracks) {
        if (track.path != TargetPath.ROTATION) continue;

        if (catch excuse = validate_motion_rotation_track(track)) {
            if (excuse != c3d::UNSUPPORTED) return excuse~;
            unsupported = true;
        }
    }

    if (unsupported) return c3d::UNSUPPORTED~;
}

fn void? validate_live_motion_addition(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationClip* clip,
    PlayDesc desc,
    MotionBasis basis,
) @private {
    CapturedMotionChain* chain = generalized_playback_chain(playback);
    RootExtractionDesc incoming = live_motion_extraction(desc);
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (desc.root_motion != RootMotion.EXTRACT || action.root_motion != RootMotion.EXTRACT) continue;

        RootExtractionDesc live = live_motion_extraction({
            .root_yaw = action.root_yaw,
            .extraction = action.extraction,
        });
        if (!same_live_motion_extraction(live, incoming)) return c3d::INVALID_ARGUMENT~;
    }

    if (!chain && !desc.extraction.generalized) return;

    RootExtractionDesc extraction = chain ? chain.extraction : desc.extraction;
    bool unsupported;
    if (catch excuse = validate_generalized_motion(
        template: &assets.models.try_get(playback.model)!.data,
        clip: clip,
        root: playback.root_node,
        extraction: extraction,
        motion_basis: basis,
        additive: desc.additive,
        additive_scale: desc.additive_scale,
    )) {
        if (excuse != c3d::UNSUPPORTED) return excuse~;
        unsupported = true;
    }

    if (!chain) {
        foreach (id : playback.order[:*playback.action_count]) {
            Action* action = playback.actions.get(id);
            if (catch excuse = validate_generalized_motion(
                template: &assets.models.try_get(playback.model)!.data,
                clip: &assets.clips.try_get(action.clip)!.data,
                root: playback.root_node,
                extraction: extraction,
                motion_basis: basis,
                additive: action.additive,
                additive_scale: action.additive_scale,
            )) {
                if (excuse != c3d::UNSUPPORTED) return excuse~;
                unsupported = true;
            }
        }
    }

    if (unsupported) return c3d::UNSUPPORTED~;
}

fn RootExtractionDesc live_motion_extraction(PlayDesc desc) @local {
    if (desc.extraction.generalized) return desc.extraction;

    return {
        .translation_axes = { true, false, true },
        .up = { 0, 1, 0 },
        .twist = desc.root_yaw,
    };
}

fn bool same_live_motion_extraction(RootExtractionDesc first, RootExtractionDesc second) @local {
    if (!first.generalized && !second.generalized) return true;

    if (first.generalized != second.generalized || first.up != second.up || first.twist != second.twist) return false;

    foreach (index, axis : first.translation_axes) if (axis != second.translation_axes[index]) return false;

    return true;
}
