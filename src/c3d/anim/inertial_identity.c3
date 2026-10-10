module c3d::anim;

import c3d;
import c3d::asset;
import std::hash::fnv64a;

const char INERTIAL_METADATA_HASH_DOMAIN @local = 0x49;
const char INERTIAL_LAYOUT_HASH_DOMAIN @local = 0x4c;
const uint INERTIAL_IDENTITY_WORD_BYTES @local = 4;
const uint INERTIAL_IDENTITY_BYTE_BITS @local = 8;

struct InertialIdentityState @private {
    ulong fingerprint;
    ulong layout;
    bool valid;
    bool pending_seek;
}

fn InertialIdentityState compute_inertial_identity(
    PlaybackView* playback,
    AssetStore* assets,
    bool[] target_present = {},
) @private {
    InertialIdentityState identity;
    if (!assets.models.is_live(playback.model)) return identity;

    ModelAsset* model = assets.models.get(playback.model);
    Fnv64a metadata;
    metadata.init();
    metadata.update_byte(INERTIAL_METADATA_HASH_DOMAIN);
    inertial_identity_word(&metadata, playback.model.index);
    inertial_identity_word(&metadata, playback.model.generation);
    inertial_identity_word(&metadata, model.header.revision);
    inertial_identity_word(&metadata, playback.inertial ? playback.inertial.control.generation : 0);
    inertial_identity_word(&metadata, *playback.action_count);

    Fnv64a layout;
    layout.init();
    layout.update_byte(INERTIAL_LAYOUT_HASH_DOMAIN);
    inertial_identity_word(&layout, playback.root_node);
    inertial_identity_word(&layout, (uint)model.data.nodes.len);
    inertial_identity_word(&layout, (uint)target_present.len);

    foreach (present : target_present) layout.update_byte(present ? 1 : 0);

    foreach (id : playback.order[:*playback.action_count]) {
        if (!playback.actions.is_live(id)) return identity;
        Action* action = playback.actions.get(id);
        if (!assets.clips.is_live(action.clip)) return identity;
        ClipAsset* clip = assets.clips.get(action.clip);
        inertial_identity_word(&metadata, id.index);
        inertial_identity_word(&metadata, id.generation);
        inertial_identity_word(&metadata, action.clip.index);
        inertial_identity_word(&metadata, action.clip.generation);
        inertial_identity_word(&metadata, clip.header.revision);
        identity.pending_seek |= action.time != action.published_time;

        inertial_identity_word(&layout, action.layer);
        inertial_identity_word(&layout, (uint)action.root_motion);
        inertial_identity_word(&layout, (uint)action.additive_scale);
        layout.update_byte(action.additive ? 1 : 0);
        layout.update_byte(action.root_yaw ? 1 : 0);
        inertial_identity_extraction(&layout, action.extraction);
        if (action.motion_chain) {
            inertial_identity_word(&layout, action.motion_chain.root_node);
            inertial_identity_word(&layout, (uint)action.motion_chain.model_names.len);
            inertial_identity_word(&layout, (uint)action.motion_chain.model_parents.len);
            inertial_identity_extraction(&layout, action.motion_chain.extraction);
        } else {
            inertial_identity_word(&layout, NO_ROOT_NODE);
        }
    }

    identity.fingerprint = (ulong)metadata;
    identity.layout = (ulong)layout;
    identity.valid = true;

    return identity;
}

fn bool inertial_history_is_current(InertialRow* row, InertialIdentityState identity) @private {
    InertialIdentityState cached = row.control.identity;

    return row.control.history_valid && identity.valid && !identity.pending_seek
      && cached.valid && cached.fingerprint == identity.fingerprint && cached.layout == identity.layout;
}

fn void refresh_inertial_identity(InertialRow* row, InertialIdentityState identity) @private {
    InertialIdentityState cached = row.control.identity;
    bool changed = cached.valid
      && (cached.fingerprint != identity.fingerprint || cached.layout != identity.layout);

    if (!identity.valid || identity.pending_seek || changed) {
        row.control.history_valid = false;
        row.control.active = false;
        row.control.duration = 0;
        row.control.elapsed = 0;
        row.root.target_rate_pending = false;
    }

    // A successful request can stamp new targets before its first update without cancelling its residual.
    row.control.identity = identity;
}

fn void inertial_identity_word(Fnv64a* hash, uint value) @local {
    for (uint byte = 0; byte < INERTIAL_IDENTITY_WORD_BYTES; byte++) {
        hash.update_byte((char)(value >> (byte * INERTIAL_IDENTITY_BYTE_BITS)));
    }
}

fn void inertial_identity_extraction(Fnv64a* hash, RootExtractionDesc extraction) @local {
    hash.update_byte(extraction.generalized ? 1 : 0);
    foreach (axis : extraction.translation_axes) hash.update_byte(axis ? 1 : 0);
    hash.update_byte(extraction.twist ? 1 : 0);
    inertial_identity_word(hash, bitcast(extraction.up.x, uint));
    inertial_identity_word(hash, bitcast(extraction.up.y, uint));
    inertial_identity_word(hash, bitcast(extraction.up.z, uint));
}
