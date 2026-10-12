module c3d::anim;

import c3d;
import c3d::asset;

// Admission returns UNSUPPORTED as true, so a request reports every other fault of its actions first.
fn bool? validate_playback_addition(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationClip* clip,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis basis,
) @private {
    CapturedMotionChain* chain = generalized_playback_chain(playback);
    bool unsupported = validate_action_desc(
        playback: playback,
        assets: assets,
        clip: clip,
        desc: desc,
        destination: destination,
        motion_basis: basis,
        consumed_extraction: chain ? &chain.extraction : null,
    )!;

    validate_live_extraction(playback, desc)!;
    if (chain || !desc.extraction.generalized) return unsupported;

    ModelTemplate* template = &assets.models.try_get(playback.model)!.data;
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        unsupported |= validate_generalized_motion(
            template: template,
            clip: &assets.clips.try_get(action.clip)!.data,
            root: playback.root_node,
            extraction: desc.extraction,
            motion_basis: basis,
            additive: action.additive,
            additive_scale: action.additive_scale,
        )!;
    }

    return unsupported;
}

fn bool? validate_action_desc(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationClip* clip,
    PlayDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
    RootExtractionDesc* consumed_extraction,
) @private {
    validate_playback_action(clip, desc, destination)!;

    Action motion;
    configure_motion(
        playback: playback,
        action: &motion,
        clip: clip,
        desc: desc,
        motion_basis: motion_basis,
        node_count: destination.base_pose.len,
    )!;

    bool unsupported;
    if (desc.additive && desc.additive_scale == AdditiveScaleMode.MULTIPLICATIVE) {
        unsupported = validate_multiplicative_scale(clip)!;
    }

    RootExtractionDesc* extraction = desc.extraction.generalized ? &desc.extraction : consumed_extraction;
    if (!extraction) return unsupported;

    unsupported |= validate_generalized_motion(
        template: &assets.models.try_get(playback.model)!.data,
        clip: clip,
        root: playback.root_node,
        extraction: *extraction,
        motion_basis: motion_basis,
        additive: desc.additive,
        additive_scale: desc.additive_scale,
    )!;

    return unsupported;
}

fn void? validate_live_extraction(PlaybackView* playback, PlayDesc desc) @private {
    if (desc.root_motion != RootMotion.EXTRACT) return;

    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (action.root_motion == RootMotion.EXTRACT && !same_extraction(action.extraction, desc.extraction)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

// Planar extraction has one fixed frame; generalized frames must match exactly.
fn bool same_extraction(RootExtractionDesc first, RootExtractionDesc second) @private {
    if (!first.generalized && !second.generalized) return true;

    return first.generalized == second.generalized && first.up == second.up && first.twist == second.twist
      && first.translation_axes == second.translation_axes;
}

fn void? prepare_action_motion_capture(
    Allocator allocator,
    AssetStore* assets,
    ModelId model,
    Action* action,
    uint root_node,
) @private {
    if (!action.extraction.generalized) return;

    ModelTemplate* template = &assets.model(model).data;
    AnimationClip* clip = &assets.clip(action.clip).data;
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

    captured.pose_scale_sums = alloc::new_array_try(allocator, double[<3>], template.nodes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;

    action.motion_chain = captured;
    action.motion_reference = capture_generalized_motion_reference(captured, clip);
}
