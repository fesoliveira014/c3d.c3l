module c3d::anim::retarget;

import c3d;
import c3d::anim;
import c3d::asset;

fn void? bind_profile_clip(
    AnimationClip* clip,
    ProfileData* data,
    ModelTemplate* target,
    ProfileChannels[] channels,
    bool allow_partial,
) @private {
    foreach (&track : clip.tracks) {
        uint node = clip.targets[track.target];
        ProfileChannels* channel = &channels[node];

        switch (track.path) {
            case TRANSLATION: channel.translation = track;
            case ROTATION: channel.rotation = track;
            case SCALE: channel.scale = track;
            case MORPH_WEIGHTS: break;
        }

        uint destination = data.source_nodes[node].mapped;
        if (destination == RETARGET_NO_NODE) {
            bool consumed_transform = data.source_nodes[node].consumed && track.path != TargetPath.MORPH_WEIGHTS;
            if (!allow_partial && !consumed_transform) return c3d::ASSET_FORMAT_ERROR~;
        } else if (track.path == TargetPath.MORPH_WEIGHTS) {
            validate_profile_morph(target, track, destination)!;
        }
    }
}

fn void? validate_profile_morph(ModelTemplate* target, Track* track, uint destination) @private {
    uint stride = track.stride();
    bool found;

    foreach (&mesh : target.meshes) {
        if (mesh.node != destination) continue;
        found = true;
        if (mesh.default_morph_weights.len != stride) return c3d::ASSET_FORMAT_ERROR~;
    }

    if (!found) return c3d::ASSET_FORMAT_ERROR~;
}
