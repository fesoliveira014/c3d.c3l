module c3d::anim::retarget;

import c3d;
import c3d::anim;
import c3d::asset;
import std::math;

fn void? validate_profile_clip(
    AnimationClip* clip,
    ProfileData* data,
    ModelTemplate* target,
    ProfileChannels[] channels,
    bool allow_partial,
    RetargetDiagnostic* diagnostic,
) @private {
    if (!math::is_finite(clip.duration) || clip.duration < 0
        || clip.targets.len > uint::max || clip.tracks.len > uint::max) {
        return profile_failure(diagnostic, c3d::ASSET_FORMAT_ERROR, RetargetReason.INVALID_CLIP)~;
    }
    foreach (node : clip.targets) {
        if (node >= data.source_nodes.len) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::ASSET_FORMAT_ERROR,
                reason: RetargetReason.INVALID_CLIP,
                source_node: node,
            )~;
        }
    }
    foreach (&track : clip.tracks) {
        if (track.target >= clip.targets.len) {
            return profile_failure(diagnostic, c3d::ASSET_FORMAT_ERROR, RetargetReason.INVALID_CLIP)~;
        }
        uint node = clip.targets[track.target];
        validate_profile_track(
            track: track,
            duration: clip.duration,
            node: node,
            diagnostic: diagnostic,
        )!;
        ProfileChannels* channel = &channels[node];
        bool duplicate;
        switch (track.path) {
            case TRANSLATION:
                duplicate = channel.translation != null;
                channel.translation = track;
            case ROTATION:
                duplicate = channel.rotation != null;
                channel.rotation = track;
            case SCALE:
                duplicate = channel.scale != null;
                channel.scale = track;
            case MORPH_WEIGHTS:
                foreach (&previous : clip.tracks) {
                    if (previous == track) break;
                    if (previous.path == TargetPath.MORPH_WEIGHTS
                        && clip.targets[previous.target] == node) duplicate = true;
                }
        }
        if (duplicate) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::ASSET_FORMAT_ERROR,
                reason: RetargetReason.INVALID_CLIP,
                source_node: node,
            )~;
        }
        channel.tracked = true;
        uint destination = data.source_nodes[node].mapped;
        if (destination == RETARGET_NO_NODE) {
            bool consumed_transform = data.source_nodes[node].consumed && track.path != TargetPath.MORPH_WEIGHTS;
            if (!allow_partial && !consumed_transform) {
                return profile_failure(
                    diagnostic: diagnostic,
                    excuse: c3d::ASSET_FORMAT_ERROR,
                    reason: RetargetReason.UNMATCHED_SOURCE,
                    source_node: node,
                )~;
            }
        } else if (track.path == TargetPath.MORPH_WEIGHTS) {
            validate_profile_morph(
                target: target,
                track: track,
                source_node: node,
                destination: destination,
                diagnostic: diagnostic,
            )!;
        }
        if (track.path == TargetPath.SCALE && data.source_nodes[node].consumed) {
            usz slot_count = track.interpolation == Interpolation.CUBIC_SPLINE ? anim::CUBIC_SLOTS_PER_KEY : 1;
            foreach (usz key, time : track.times) {
                usz offset = (key * slot_count + (slot_count == 1 ? 0 : anim::CUBIC_SLOT_VALUE)) * 3;
                Vec3 scale = { track.values[offset], track.values[offset + 1], track.values[offset + 2] };
                if (!profile_uniform_scale(scale)) {
                    return profile_failure(
                        diagnostic: diagnostic,
                        excuse: c3d::UNSUPPORTED,
                        reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
                        source_node: node,
                    )~;
                }
            }
        }
    }
    foreach (index, event : clip.events) {
        if (!math::is_finite(event.time) || event.time < 0 || event.time > clip.duration
            || (index > 0 && event.time < clip.events[index - 1].time)) {
            return profile_failure(diagnostic, c3d::ASSET_FORMAT_ERROR, RetargetReason.INVALID_CLIP)~;
        }
    }
}

fn void? validate_profile_track(
    Track* track,
    float duration,
    uint node,
    RetargetDiagnostic* diagnostic,
) @private {
    bool valid = track.times.len > 0 && track.times.len <= uint::max;
    foreach (index, time : track.times) {
        if (!math::is_finite(time) || time < 0 || time > duration
            || (index > 0 && time <= track.times[index - 1])) valid = false;
    }
    usz slots = track.interpolation == Interpolation.CUBIC_SPLINE ? anim::CUBIC_SLOTS_PER_KEY : 1;
    usz stride;
    switch (track.path) {
        case TRANSLATION:
        case SCALE:
            stride = 3;
        case ROTATION:
            stride = 4;
        case MORPH_WEIGHTS:
            if (track.times.len && track.values.len % (track.times.len * slots) == 0) {
                stride = track.values.len / (track.times.len * slots);
            }
    }
    valid = valid && stride > 0 && track.values.len == track.times.len * slots * stride;
    foreach (value : track.values) if (!math::is_finite(value)) valid = false;
    if (valid && track.path == TargetPath.ROTATION) {
        foreach (usz key, time : track.times) {
            usz offset = (key * slots + (slots == 1 ? 0 : anim::CUBIC_SLOT_VALUE)) * stride;
            Quat rotation = { .v = {
                track.values[offset], track.values[offset + 1],
                track.values[offset + 2], track.values[offset + 3],
            } };
            if (!profile_unit_rotation(rotation)) valid = false;
        }
    }
    if (!valid) {
        return profile_failure(
            diagnostic: diagnostic,
            excuse: c3d::ASSET_FORMAT_ERROR,
            reason: RetargetReason.INVALID_CLIP,
            source_node: node,
        )~;
    }
}

fn void? validate_profile_morph(
    ModelTemplate* target,
    Track* track,
    uint source_node,
    uint destination,
    RetargetDiagnostic* diagnostic,
) @private {
    uint stride = track.stride();
    bool found;
    foreach (&mesh : target.meshes) {
        if (mesh.node != destination) continue;
        found = true;
        if (mesh.default_morph_weights.len == stride) continue;
        return profile_failure(
            diagnostic: diagnostic,
            excuse: c3d::ASSET_FORMAT_ERROR,
            reason: RetargetReason.INVALID_MORPH_STRIDE,
            source_node: source_node,
            target_node: destination,
        )~;
    }
    if (!found) {
        return profile_failure(
            diagnostic: diagnostic,
            excuse: c3d::ASSET_FORMAT_ERROR,
            reason: RetargetReason.INVALID_MORPH_STRIDE,
            source_node: source_node,
            target_node: destination,
        )~;
    }
}
