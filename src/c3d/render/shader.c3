module c3d::render;

import c3d;
import c3d::asset;
import gpu;

<*
 Renderer-owned record of one store shader and the revision its pipelines hold.
*>
struct ShaderRes {
    ShaderId asset;
    uint     revision;
    uint     rejected_revision;
}

<*
 Rebuild the shader's pipelines now, or record the rebuild into the open frame.
 @param [&inout] self : "Completes closed-frame work without a window."
 @return? c3d::INVALID_ID, gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::SLOT_TABLE_FULL, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::DEVICE_BUSY, gpu::WAIT_TIMEOUT, gpu::INVALID_HANDLE
 @return? gpu::INVALID_RESOURCE_STATE, gpu::RESOURCE_IN_USE, gpu::COMMAND_RECORDING_ERROR
 @return? gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::BACKEND_ERROR
*>
fn void? Renderer.upload_shader(&self, ShaderId shader) {
    if (!self.assets.shaders.is_live(shader)) return c3d::INVALID_ID~;
    if (self.frame_open) {
        rebuild_shader_pipelines(self, shader)!;
        return;
    }
    open_closed_frame_slot(self)!;
    defer catch discard_uploads(self);
    rebuild_shader_pipelines(self, shader)!;
    return submit_pending(self);
}

fn void? rebuild_shader_pipelines(Renderer* renderer, ShaderId shader) @private {
    if (catch excuse = replace_shader_pipelines(renderer, shader)) {
        (void)pipeline_rejected(renderer, shader, excuse);
        return excuse~;
    }
    return;
}

fn ShaderRes*? resolve_shader(Renderer* renderer, ShaderId shader) @private {
    ShaderAsset* record = renderer.assets.shader(shader);
    ShaderRes* mirror = &renderer.shaders[shader.index];
    bool same_asset = mirror.asset.index == shader.index && mirror.asset.generation == shader.generation;
    if (same_asset && mirror.revision == record.header.revision) return mirror;
    if (same_asset && mirror.rejected_revision == record.header.revision) return mirror;

    if (catch excuse = replace_shader_pipelines(renderer, shader)) {
        if (!pipeline_rejected(renderer, shader, excuse)) return excuse~;
    }
    return mirror;
}

fn bool pipeline_rejected(Renderer* renderer, ShaderId shader, fault excuse) @private {
    if (excuse == PIPELINE_REJECTED) return true;
    if (excuse != gpu::SHADER_INVALID && excuse != gpu::PIPELINE_CREATE_FAILED) return false;
    ShaderRes* mirror = &renderer.shaders[shader.index];
    mirror.asset = shader;
    mirror.rejected_revision = renderer.assets.shader(shader).header.revision;
    renderer.stats.shader_rejections++;
    return true;
}

fn void? replace_shader_pipelines(Renderer* renderer, ShaderId shader) @private {
    ShaderAsset* record = renderer.assets.shader(shader);
    ShaderRes* mirror = &renderer.shaders[shader.index];
    bool same_asset = mirror.asset.index == shader.index && mirror.asset.generation == shader.generation;
    uint old_revision = same_asset ? mirror.revision : 0;

    RetireList* retire = renderer.frame_open
        ? &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT].retire
        : &renderer.pending_upload_retire;
    if (!same_asset && mirror.asset.generation) retire_shader_pipelines(renderer, mirror.asset, retire);
    @pool() {
        gpu::PipelineHandle[] superseded = renderer.pipelines.replace_shader(
            allocator:    tmem,
            device:       &renderer.device,
            shader:       shader,
            old_revision: old_revision,
            new_revision: record.header.revision,
            stages:       &record.desc,
        )!;
        foreach (handle : superseded) retire.push({ .kind = RetiredKind.PIPELINE, .pipeline = handle });
    };

    mirror.asset = shader;
    mirror.revision = record.header.revision;
    mirror.rejected_revision = 0;
    return;
}

fn void retire_shader_pipelines(Renderer* renderer, ShaderId shader, RetireList* retire) @private {
    @pool() {
        foreach (handle : renderer.pipelines.remove_shader(tmem, shader)) {
            retire.push({ .kind = RetiredKind.PIPELINE, .pipeline = handle });
        }
    };
}

fn void sweep_shaders(Renderer* renderer) @private {
    foreach (&mirror : renderer.shaders) {
        if (!mirror.asset.generation || renderer.assets.shaders.is_live(mirror.asset)) continue;
        retire_shader_pipelines(renderer, mirror.asset, &renderer.pending_upload_retire);
        *mirror = {};
    }
}

fn void free_shaders(Renderer* renderer) @private {
    alloc::free(renderer.allocator, renderer.shaders.ptr);
}
