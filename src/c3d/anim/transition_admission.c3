module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

struct TransitionMotionIdentity @private {
    RootExtractionDesc extraction;
    uint root_node;
    bool consumes_chain;
    bool unsupported;
}

fn TransitionMotionIdentity? validate_transition_motion_identity(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationTransitionDesc desc,
    PoseDestination destination,
    MotionBasis motion_basis,
    bool defer_unsupported = false,
) @private {
    validate_transition_source_pose(destination)!;
    ModelTemplate* template = &assets.models.try_get(playback.model)!.data;
    TransitionMotionIdentity identity = { .root_node = playback.root_node };

    foreach (id : playback.order[:*playback.action_count]) {
        Action* source = playback.actions.get(id);
        if (source.motion_chain) {
            validate_transition_capture_layout(
                captured: source.motion_chain,
                model: playback.model,
                template: template,
                root_node: playback.root_node,
                motion_basis: motion_basis,
            )!;
        }

        if (!source.extraction.generalized || source.root_motion != RootMotion.EXTRACT) continue;
        if (identity.consumes_chain) {
            if (!transition_extraction_equal(identity.extraction, source.extraction)) return c3d::INVALID_ARGUMENT~;
        } else {
            identity.extraction = source.extraction;
            identity.consumes_chain = true;
        }
    }

    foreach (target : desc.actions) {
        if (!target.play.extraction.generalized || target.play.root_motion != RootMotion.EXTRACT) continue;
        if (identity.consumes_chain) {
            if (!transition_extraction_equal(identity.extraction, target.play.extraction)) {
                return c3d::INVALID_ARGUMENT~;
            }
        } else {
            identity.extraction = target.play.extraction;
            identity.consumes_chain = true;
        }
    }

    if (!identity.consumes_chain) return identity;
    if (playback.root_node >= template.nodes.len || playback.root_node >= destination.pose.len
      || !destination.present[playback.root_node] || !motion_basis.root_present || !motion_basis.parent_space
      || !motion_basis.ancestors_parent_space) return c3d::INVALID_ARGUMENT~;

    for (int node = (int)playback.root_node; node >= 0; node = template.nodes[node].parent) {
        if (!destination.present[node]) return c3d::INVALID_ARGUMENT~;
        foreach (component : destination.pose[node].scale) {
            if (component <= 0) return c3d::INVALID_ARGUMENT~;
        }
    }

    foreach (target : desc.actions) {
        AnimationClip* clip = &assets.clips.try_get(target.clip)!.data;
        foreach (&track : clip.tracks) {
            if (track.path != TargetPath.SCALE) continue;
            if (track.target >= clip.targets.len || clip.targets[track.target] >= template.nodes.len) {
                return c3d::INVALID_ARGUMENT~;
            }
            if (!transition_node_consumed(template, playback.root_node, clip.targets[track.target])) continue;

            ConsumedScaleDomain? result = classify_consumed_scale_track(track, target.play.additive);
            if (catch excuse = result) {
                if (excuse != c3d::UNSUPPORTED) return excuse~;
                identity.unsupported = true;
            } else if (result == ConsumedScaleDomain.SAMPLING_UNPROVEN) {
                identity.unsupported = true;
            }
        }
    }

    if (identity.unsupported && !defer_unsupported) return c3d::UNSUPPORTED~;

    return identity;
}

fn void? validate_transition_source_pose(PoseDestination destination) @local {
    foreach (index, pose : destination.pose) {
        if (!destination.present[index]) continue;
        foreach (component : pose.position) if (!math::is_finite(component)) return c3d::INVALID_ARGUMENT~;
        foreach (component : pose.scale) if (!math::is_finite(component)) return c3d::INVALID_ARGUMENT~;

        bool nonzero;
        foreach (component : pose.rotation.v) {
            if (!math::is_finite(component)) return c3d::INVALID_ARGUMENT~;
            nonzero |= component != 0;
        }
        if (!nonzero) return c3d::INVALID_ARGUMENT~;
    }

    foreach (values : destination.morph_weights) {
        foreach (value : values) if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? validate_transition_capture_layout(
    CapturedMotionChain* captured,
    ModelId model,
    ModelTemplate* template,
    uint root_node,
    MotionBasis motion_basis,
) @local {
    if (!c3d::same_id(captured.model, model) || captured.root_node != root_node
      || captured.model_names.len != template.nodes.len || captured.model_parents.len != template.nodes.len
      || captured.instance_scale != motion_basis.instance_scale) return c3d::INVALID_ARGUMENT~;

    foreach (index, node : template.nodes) {
        if (captured.model_names[index] != node.name || captured.model_parents[index] != node.parent) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn bool transition_extraction_equal(RootExtractionDesc first, RootExtractionDesc second) @local {
    if (first.generalized != second.generalized || first.up != second.up || first.twist != second.twist) return false;

    foreach (index, axis : first.translation_axes) if (axis != second.translation_axes[index]) return false;

    return true;
}

fn bool transition_node_consumed(ModelTemplate* template, uint root_node, uint candidate) @local {
    for (int node = (int)root_node; node >= 0; node = template.nodes[node].parent) {
        if ((uint)node == candidate) return true;
    }

    return false;
}
