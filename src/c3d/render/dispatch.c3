module c3d::render;

import c3d;
import c3d::asset;
import gpu;

<*
 One compute dispatch: its shader, root bytes, workgroup counts and written buffers.
*>
struct DispatchDesc {
    ComputeShaderId shader;
    char[]          root;
    uint[<3>]       groups;
    BufferId[]      writes;
}

<*
 Renderer-owned record of one store compute shader and the revision its pipeline holds.
*>
struct ComputeShaderRes {
    ComputeShaderId asset;
    uint            revision;
    uint            rejected_revision;
}

<*
 Ring bytes a root of the length occupies; zero stays zero.
 @pure
*>
fn usz dispatch_root_size(usz root_len) {
    return (root_len + STREAM_ALIGNMENT - 1) / STREAM_ALIGNMENT * STREAM_ALIGNMENT;
}

<*
 Record a compute dispatch into the open frame, before its first view.
 A rejected stage is skipped and counted; the previous revision keeps dispatching.
 @param [&inout] self : "Records pending uploads first."
 @require self.frame_open, !self.overlay_open
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::SHADER_NOT_FOUND
 @return? gpu::UNSUPPORTED_FEATURE, gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE
*>
fn void? Renderer.dispatch(&self, DispatchDesc desc) {
    if (self.frame_recorded) return c3d::INVALID_ARGUMENT~;
    if (!self.assets.compute_shaders.is_live(desc.shader)) return c3d::INVALID_ID~;
    foreach (buffer : desc.writes) {
        if (!self.buffers.is_live(buffer)) return c3d::INVALID_ID~;
    }

    ComputeShaderRes* mirror = resolve_compute_shader(self, desc.shader)!;
    if (!mirror.revision) return;
    CustomStageSource source = { .compute = self.assets.compute_shader(desc.shader).desc.compute };
    gpu::PipelineHandle? pipeline = self.pipelines.get(
        &self.device,
        compute_pipeline_key(desc.shader, mirror.revision),
        &source,
    );
    if (catch excuse = pipeline) {
        if (compute_rejected(self, desc.shader, excuse)) return;
        return excuse~;
    }

    record_pending_copies(self, &self.commands)!;
    if (!self.compute_open) {
        write_pass_timestamp(
            renderer:    self,
            frame_index: self.frame_index,
            pass:        Pass.CUSTOM_COMPUTE,
            half:        TIMESTAMP_BEGIN,
        )!;
        self.compute_open = true;
    }

    gpu::GpuAddress root_address;
    if (desc.root.len) {
        Frame* slot = &self.frames[self.frame_index % FRAMES_IN_FLIGHT];
        gpu::MappedGpuSpan staging = slot.upload.take(
            &self.device,
            dispatch_root_size(desc.root.len),
            STREAM_ALIGNMENT,
        )!;
        staging.bytes[:desc.root.len] = desc.root[..];
        root_address = staging.address;
    }

    if (desc.writes.len) {
        gpu::Barrier readers_done = { .before = CONSUMER_STAGES, .after = { .compute } };
        gpu::cmd_barrier(&self.commands, &readers_done)!;
    }
    gpu::cmd_bind_pipeline(&self.commands, pipeline)!;
    gpu::cmd_dispatch(&self.commands, root_address, { desc.groups.x, desc.groups.y, desc.groups.z })!;
    if (desc.writes.len) {
        gpu::Barrier writes_visible = { .before = { .compute }, .after = CONSUMER_STAGES };
        gpu::cmd_barrier(&self.commands, &writes_visible)!;
    }
    self.stats.dispatches++;
}

<*
 Rebuild the compute shader's pipeline now, or record the rebuild into the open frame.
 @param [&inout] self : "Completes closed-frame work without a window."
 @return? c3d::INVALID_ID, gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::SLOT_TABLE_FULL, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::DEVICE_BUSY, gpu::WAIT_TIMEOUT, gpu::INVALID_HANDLE
 @return? gpu::INVALID_RESOURCE_STATE, gpu::RESOURCE_IN_USE, gpu::COMMAND_RECORDING_ERROR
 @return? gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::BACKEND_ERROR
*>
fn void? Renderer.upload_compute_shader(&self, ComputeShaderId shader) {
    if (!self.assets.compute_shaders.is_live(shader)) return c3d::INVALID_ID~;
    if (self.frame_open) {
        rebuild_compute_pipeline(self, shader)!;
        return;
    }
    open_closed_frame_slot(self)!;
    defer catch discard_uploads(self);
    rebuild_compute_pipeline(self, shader)!;
    return submit_pending(self);
}

fn void? close_custom_compute(Renderer* renderer) @private {
    if (!renderer.compute_open) return;
    renderer.compute_open = false;
    write_pass_timestamp(
        renderer:    renderer,
        frame_index: renderer.frame_index,
        pass:        Pass.CUSTOM_COMPUTE,
        half:        TIMESTAMP_END,
    )!;
    renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT].timed[Pass.CUSTOM_COMPUTE.ordinal] = true;
}

fn void? rebuild_compute_pipeline(Renderer* renderer, ComputeShaderId shader) @private {
    if (catch excuse = replace_compute_pipeline(renderer, shader)) {
        (void)compute_rejected(renderer, shader, excuse);
        return excuse~;
    }
    return;
}

fn ComputeShaderRes*? resolve_compute_shader(Renderer* renderer, ComputeShaderId shader) @private {
    ComputeShaderAsset* record = renderer.assets.compute_shader(shader);
    ComputeShaderRes* mirror = &renderer.compute_shaders[shader.index];
    bool same_asset = mirror.asset.index == shader.index && mirror.asset.generation == shader.generation;
    if (same_asset && mirror.revision == record.header.revision) return mirror;
    if (same_asset && mirror.rejected_revision == record.header.revision) return mirror;

    if (catch excuse = replace_compute_pipeline(renderer, shader)) {
        if (!compute_rejected(renderer, shader, excuse)) return excuse~;
    }
    return mirror;
}

fn bool compute_rejected(Renderer* renderer, ComputeShaderId shader, fault excuse) @private {
    if (excuse == PIPELINE_REJECTED) return true;
    if (excuse != gpu::SHADER_INVALID && excuse != gpu::PIPELINE_CREATE_FAILED) return false;
    ComputeShaderRes* mirror = &renderer.compute_shaders[shader.index];
    mirror.asset = shader;
    mirror.rejected_revision = renderer.assets.compute_shader(shader).header.revision;
    renderer.stats.shader_rejections++;
    return true;
}

fn void? replace_compute_pipeline(Renderer* renderer, ComputeShaderId shader) @private {
    ComputeShaderAsset* record = renderer.assets.compute_shader(shader);
    ComputeShaderRes* mirror = &renderer.compute_shaders[shader.index];
    bool same_asset = mirror.asset.index == shader.index && mirror.asset.generation == shader.generation;
    uint old_revision = same_asset ? mirror.revision : 0;

    RetireList* retire = renderer.frame_open
        ? &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT].retire
        : &renderer.pending_upload_retire;
    if (!same_asset && mirror.asset.generation) retire_compute_pipelines(renderer, mirror.asset, retire);
    @pool() {
        gpu::PipelineHandle[] superseded = renderer.pipelines.replace_compute_shader(
            allocator:    tmem,
            device:       &renderer.device,
            shader:       shader,
            old_revision: old_revision,
            new_revision: record.header.revision,
            spirv:        record.desc.compute,
        )!;
        foreach (handle : superseded) retire.push({ .kind = RetiredKind.PIPELINE, .pipeline = handle });
    };

    mirror.asset = shader;
    mirror.revision = record.header.revision;
    mirror.rejected_revision = 0;
    return;
}

fn void retire_compute_pipelines(Renderer* renderer, ComputeShaderId shader, RetireList* retire) @private {
    @pool() {
        foreach (handle : renderer.pipelines.remove_compute_shader(tmem, shader)) {
            retire.push({ .kind = RetiredKind.PIPELINE, .pipeline = handle });
        }
    };
}

fn void sweep_compute_shaders(Renderer* renderer) @private {
    foreach (&mirror : renderer.compute_shaders) {
        if (!mirror.asset.generation || renderer.assets.compute_shaders.is_live(mirror.asset)) continue;
        retire_compute_pipelines(renderer, mirror.asset, &renderer.pending_upload_retire);
        *mirror = {};
    }
}

fn void free_compute_shaders(Renderer* renderer) @private {
    alloc::free(renderer.allocator, renderer.compute_shaders.ptr);
}
