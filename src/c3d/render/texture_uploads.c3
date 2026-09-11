module c3d::render;

import c3d;
import gpu;

<*
 Staged mip copies retained until their submission is published.
*>
struct PendingTextureUpload {
    TextureId asset;
    uint revision;
    gpu::TextureState before;
    uint mip_count;
    gpu::BufferTextureCopyDesc[TEXTURE_MIP_CAPACITY] copies;
    bool recorded;
}

fn void? record_texture_uploads(Renderer* renderer, gpu::CommandList* commands) @private {
    foreach (&pending : renderer.pending_texture_uploads) {
        if (pending.recorded) continue;

        gpu::TextureBarrier to_upload = gpu::texture_transition(
            texture: pending.copies[0].texture,
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
            texture: pending.copies[0].texture,
            before: to_upload.after,
            after: gpu::sampled_at({ .fragment_shader, .compute }),
        )!;
        gpu::cmd_texture_barrier(commands, &to_sampled)!;
        pending.recorded = true;
    }
}

fn void commit_uploads(Renderer* renderer, Frame* slot) @private {
    commit_environment_preparations(renderer, slot);
    foreach (&pending : renderer.pending_texture_uploads) {
        TextureRes* mirror = &renderer.textures[pending.asset.index];
        mirror.revision = pending.revision;
        mirror.state = gpu::sampled_at({ .fragment_shader, .compute });
    }
    renderer.pending_texture_uploads.clear();
    renderer.pending_geometry_uploads.clear();
    renderer.uploads_recorded = false;

    foreach (retired : renderer.pending_upload_retire) slot.retire.push(retired);
    renderer.pending_upload_retire.clear();
}

fn void discard_uploads(Renderer* renderer) @private {
    discard_environment_preparations(renderer);
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
}

fn void free_pending_uploads(Renderer* renderer) @private {
    drain_retired(&renderer.device, &renderer.pending_upload_retire);
    renderer.pending_upload_retire.free();
    renderer.pending_texture_uploads.free();
    renderer.pending_geometry_uploads.free();
}
