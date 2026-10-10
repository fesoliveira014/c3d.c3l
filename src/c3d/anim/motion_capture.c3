module c3d::anim;

import c3d;
import c3d::asset;

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
        diagnostic: null,
    )!;
}

fn void? prepare_action_motion_capture(
    Allocator allocator,
    AssetStore* assets,
    ModelId model,
    Action* action,
    uint root_node,
    MotionBasis motion_basis,
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
        diagnostic: null,
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
    captured.model = model;
    captured.instance_scale = motion_basis.instance_scale;

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
    if (!chain) return;

    if (desc.extraction.generalized && !same_live_motion_extraction(chain.extraction, desc.extraction)) {
        return c3d::INVALID_ARGUMENT~;
    }

    validate_generalized_motion(
        template: &assets.models.try_get(playback.model)!.data,
        clip: clip,
        root: playback.root_node,
        extraction: chain.extraction,
        motion_basis: basis,
        additive: desc.additive,
        additive_scale: desc.additive_scale,
        diagnostic: null,
    )!;
}

fn bool same_live_motion_extraction(RootExtractionDesc first, RootExtractionDesc second) @local {
    if (first.up != second.up || first.twist != second.twist) return false;

    foreach (index, axis : first.translation_axes) if (axis != second.translation_axes[index]) return false;

    return true;
}
