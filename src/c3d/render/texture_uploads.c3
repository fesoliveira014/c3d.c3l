module c3d::render;

import c3d;
import gpu;
import std::collections::list;

<*
 Staged mip copies retained until their submission is published.
*>
struct PendingTextureUpload {
    TextureId asset;
    uint revision;
    gpu::TextureHandle texture;
    gpu::TextureState before;
    uint mip_count;
    gpu::BufferTextureCopyDesc[TEXTURE_MIP_CAPACITY] copies;
    bool recorded;
}

<*
 Tracked state of one store texture before the current recording touched it.
*>
struct TextureStateUndo {
    TextureId asset;
    gpu::TextureHandle texture;
    gpu::TextureState state;
}

<*
 Record the mirror's tracked state once for the current recording.
 @param [&inout] undo : "Entries already holding this asset and image are kept."
 @param [&in] mirror : "Live mirror; its asset and image identify the entry."
*>
fn void remember_texture_state(List{TextureStateUndo}* undo, TextureRes* mirror) {
    foreach (&entry : *undo) {
        if (entry.asset.index == mirror.asset.index && entry.asset.generation == mirror.asset.generation
            && entry.texture == mirror.texture) return;
    }
    undo.push({ .asset = mirror.asset, .texture = mirror.texture, .state = mirror.state });
}

<*
 Put every remembered mirror back and empty the list.
 An entry whose asset or image no longer matches its mirror is skipped.
 @param [&inout] undo : "Emptied on return."
*>
fn void restore_texture_states(List{TextureStateUndo}* undo, TextureRes[] textures) {
    foreach (&entry : *undo) {
        TextureRes* mirror = &textures[entry.asset.index];
        if (mirror.asset.index != entry.asset.index || mirror.asset.generation != entry.asset.generation
            || mirror.texture != entry.texture) continue;
        mirror.state = entry.state;
    }
    undo.clear();
}

fn void? record_texture_uploads(Renderer* renderer, gpu::CommandList* commands) @private {
    foreach (&pending : renderer.pending_texture_uploads) {
        if (pending.recorded) continue;

        gpu::TextureBarrier to_upload = gpu::texture_transition(
            texture: pending.texture,
            before: pending.before,
            after: {
                .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                .stages = { .transfer },
                .access = { .write },
            },
        )!;
        gpu::cmd_texture_barrier(commands, &to_upload)!;
        for (uint mip = 0; mip < pending.mip_count; mip++) {
            gpu::cmd_copy_buffer_to_texture(commands, &pending.copies[mip])!;
        }

        gpu::TextureBarrier to_sampled = gpu::texture_transition(
            texture: pending.texture,
            before: to_upload.after,
            after: gpu::sampled_at({ .fragment_shader, .compute }),
        )!;
        gpu::cmd_texture_barrier(commands, &to_sampled)!;
        pending.recorded = true;
        TextureRes* mirror = &renderer.textures[pending.asset.index];
        if (mirror.texture == pending.texture) mirror.state = to_sampled.after;
    }
}

fn void commit_uploads(Renderer* renderer, Frame* slot) @private {
    commit_environment_preparations(renderer, slot);
    foreach (&pending : renderer.pending_texture_uploads) {
        renderer.textures[pending.asset.index].revision = pending.revision;
    }
    renderer.pending_texture_uploads.clear();
    renderer.texture_state_undo.clear();
    renderer.pending_geometry_uploads.clear();
    renderer.scene_trace.pending_builds.clear();
    renderer.rt.pending_blas.clear();
    renderer.rt.recorded_blas = 0;
    renderer.uploads_recorded = false;

    foreach (retired : renderer.pending_upload_retire) slot.retire.push(retired);
    renderer.pending_upload_retire.clear();
}

fn void discard_uploads(Renderer* renderer) @private {
    discard_environment_preparations(renderer);
    restore_texture_states(&renderer.texture_state_undo, renderer.textures);
    if (!renderer.uploads_recorded && !renderer.pending_copies.len()
        && !renderer.pending_texture_uploads.len() && !renderer.pending_geometry_uploads.len()) return;

    renderer.uploads_recorded = false;
    renderer.pending_texture_uploads.clear();
    renderer.pending_copies.clear();
    renderer.pending_overwrite = false;

    foreach (geometry : renderer.pending_geometry_uploads) {
        renderer.geometries[geometry.index].revision = 0;
    }
    renderer.pending_geometry_uploads.clear();
    foreach (&material : renderer.materials) material.revision = 0;
    discard_scene_trace(renderer);
}

fn void free_pending_uploads(Renderer* renderer) @private {
    drain_retired(&renderer.device, &renderer.pending_upload_retire);
    renderer.pending_upload_retire.free();
    renderer.pending_texture_uploads.free();
    renderer.texture_state_undo.free();
    renderer.pending_geometry_uploads.free();
}
