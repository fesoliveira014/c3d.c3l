module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::shader;
import gpu;

<*
 Textures one dispatch may declare.
*>
const uint MAX_DISPATCH_TEXTURES = 8; // mirrored as MAX_DISPATCH_TEXTURES in c3d.abi; one 64-byte block per dispatch
$assert MAX_DISPATCH_TEXTURES == shader::MAX_DISPATCH_TEXTURES;

<*
 Which image a dispatch texture declaration names.
*>
enum DispatchTextureKind {
    ASSET,
    RENDER_TARGET,
    VIEW_COLOR,
    VIEW_DEPTH,
}

<*
 How a dispatch uses a declared texture: sampled, stored, or loaded and stored.
*>
enum DispatchAccess {
    READ,
    WRITE,
    READ_WRITE,
}

<*
 One texture a dispatch reads or writes; the id matching kind is live, the others unused.
*>
struct DispatchTexture {
    DispatchTextureKind kind;
    DispatchAccess      access;
    TextureId           texture;
    RenderTargetId      target;
    ViewId              view;
    SamplerId           sampler;
    uint                mip;
    uint                layer;
}

<*
 One compute dispatch: its shader, root bytes, workgroup counts, written buffers and textures.
*>
struct DispatchDesc {
    ComputeShaderId   shader;
    char[]            root;
    uint[<3>]         groups;
    BufferId[]        writes;
    DispatchTexture[] textures;
}

<*
 Renderer-owned record of one store compute shader and the revision its pipeline holds.
*>
struct ComputeShaderRes {
    ComputeShaderId asset;
    uint            revision;
    uint            rejected_revision;
}

struct ResolvedDispatchTexture @private {
    Target*           target;
    TextureRes*       mirror;
    gpu::TextureState use;
}

<*
 Sampled read of a store texture; a zero sampler selects linear clamp.
 @pure
*>
fn DispatchTexture read_texture(TextureId texture, SamplerId sampler = {}) {
    return { .kind = DispatchTextureKind.ASSET, .access = DispatchAccess.READ, .texture = texture, .sampler = sampler };
}

<*
 Storage write of one mip of one layer of a storage-capable store texture.
 @pure
*>
fn DispatchTexture write_texture(
    TextureId texture,
    uint mip = 0,
    uint layer = 0,
    DispatchAccess access = DispatchAccess.WRITE,
) {
    return { .kind = DispatchTextureKind.ASSET, .access = access, .texture = texture, .mip = mip, .layer = layer };
}

<*
 Sampled read of a render target; a zero sampler selects linear clamp.
 @pure
*>
fn DispatchTexture read_target(RenderTargetId target, SamplerId sampler = {}) {
    return { .kind = DispatchTextureKind.RENDER_TARGET, .access = DispatchAccess.READ, .target = target, .sampler = sampler };
}

<*
 Storage write of a render target.
 @pure
*>
fn DispatchTexture write_target(RenderTargetId target, DispatchAccess access = DispatchAccess.WRITE) {
    return { .kind = DispatchTextureKind.RENDER_TARGET, .access = access, .target = target };
}

<*
 Sampled read of a view's current scene image; a zero sampler selects linear clamp.
 @pure
*>
fn DispatchTexture read_view_color(ViewId view, SamplerId sampler = {}) {
    return { .kind = DispatchTextureKind.VIEW_COLOR, .access = DispatchAccess.READ, .view = view, .sampler = sampler };
}

<*
 Storage write of a view's current scene image.
 @pure
*>
fn DispatchTexture write_view_color(ViewId view, DispatchAccess access = DispatchAccess.WRITE) {
    return { .kind = DispatchTextureKind.VIEW_COLOR, .access = access, .view = view };
}

<*
 Sampled read of a view's depth image; a zero sampler selects linear clamp.
 @pure
*>
fn DispatchTexture read_view_depth(ViewId view, SamplerId sampler = {}) {
    return { .kind = DispatchTextureKind.VIEW_DEPTH, .access = DispatchAccess.READ, .view = view, .sampler = sampler };
}

<*
 Index of the storage view of one mip of one layer.
 @pure
*>
fn usz storage_view_slot(uint mip_count, uint layer, uint mip) {
    return (usz)layer * mip_count + mip;
}

<*
 Ring bytes the application's root of the length occupies; zero stays zero.
 @pure
*>
fn usz dispatch_root_size(usz root_len) {
    return (root_len + STREAM_ALIGNMENT - 1) / STREAM_ALIGNMENT * STREAM_ALIGNMENT;
}

<*
 Record a compute dispatch into the open frame at its call position.
 A rejected stage is skipped and counted; the previous revision keeps dispatching.
 @param [&inout] self : "Records pending uploads first."
 @require self.frame_open, !self.overlay_open
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::SHADER_NOT_FOUND
 @return? c3d::ASSET_DATA_UNAVAILABLE, gpu::UNSUPPORTED_FEATURE, gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR, gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE
 @return? gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED
*>
fn void? Renderer.dispatch(&self, DispatchDesc desc) {
    if (desc.textures.len > MAX_DISPATCH_TEXTURES) return c3d::INVALID_ARGUMENT~;
    if (!self.assets.compute_shaders.is_live(desc.shader)) return c3d::INVALID_ID~;
    foreach (buffer : desc.writes) {
        if (!self.buffers.is_live(buffer)) return c3d::INVALID_ID~;
    }
    check_dispatch_textures(self, desc.textures)!;

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

    DispatchTexturesGpu bindings;
    ResolvedDispatchTexture[MAX_DISPATCH_TEXTURES] resolved;
    foreach (index, &declared : desc.textures) {
        resolved[index] = resolve_dispatch_texture(self, declared, &bindings.slots[index])!;
    }
    record_pending_copies(self, &self.commands)!;
    defer catch abort_frame(self);
    ProfileScopeToken dispatch_scope = begin_profile_dispatch(self, desc.shader, mirror.revision)!;
    foreach (&entry : resolved[:desc.textures.len]) transition_dispatch_texture(self, entry, entry.use)!;

    Frame* slot = &self.frames[self.frame_index % FRAMES_IN_FLIGHT];
    gpu::GpuAddress parameters;
    if (desc.root.len) {
        gpu::MappedGpuSpan staging = slot.upload.take(
            &self.device,
            dispatch_root_size(desc.root.len),
            STREAM_ALIGNMENT,
        )!;
        staging.bytes[:desc.root.len] = desc.root[..];
        parameters = staging.address;
    }
    gpu::GpuAddress textures;
    if (desc.textures.len) {
        gpu::MappedGpuSpan block = slot.upload.take(&self.device, DispatchTexturesGpu::size, STREAM_ALIGNMENT)!;
        *(DispatchTexturesGpu*)block.bytes.ptr = bindings;
        textures = block.address;
    }
    gpu::MappedGpuSpan root = slot.upload.take(&self.device, DispatchRoot::size, STREAM_ALIGNMENT)!;
    *(DispatchRoot*)root.bytes.ptr = { .textures = textures, .parameters = parameters };

    if (desc.writes.len) {
        gpu::Barrier readers_done = { .before = self.consumer_stages, .after = { .compute } };
        gpu::cmd_barrier(&self.commands, &readers_done)!;
    }
    gpu::cmd_bind_pipeline(&self.commands, pipeline)!;
    gpu::cmd_dispatch(&self.commands, root.address, { desc.groups.x, desc.groups.y, desc.groups.z })!;
    if (desc.writes.len) {
        gpu::Barrier writes_visible = { .before = { .compute }, .after = self.consumer_stages };
        gpu::cmd_barrier(&self.commands, &writes_visible)!;
    }
    foreach (&entry : resolved[:desc.textures.len]) {
        if (entry.mirror && entry.use.layout == gpu::TextureLayout.STORAGE) {
            transition_dispatch_texture(self, entry, self.sampled_state)!;
        }
    }
    end_profile_scope(self, dispatch_scope)!;
    self.stats.dispatches++;
    self.work_recorded = true;
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

fn void? check_dispatch_textures(Renderer* renderer, DispatchTexture[] textures) @private {
    foreach (&declared : textures) {
        switch (declared.kind) {
            case ASSET:
                if (!renderer.assets.textures.is_live(declared.texture)) return c3d::INVALID_ID~;
                TextureAsset* record = renderer.assets.texture(declared.texture);
                if (declared.access != DispatchAccess.READ && !record.desc.storage) return c3d::INVALID_ARGUMENT~;
            case RENDER_TARGET:
                TargetRecord* record = renderer.targets.try_get(declared.target)!;
                if (declared.access != DispatchAccess.READ && record.format == PixelFormat.RGBA8_SRGB) {
                    return c3d::UNSUPPORTED~;
                }
            case VIEW_COLOR:
                renderer.views.try_get(declared.view)!;
            case VIEW_DEPTH:
                renderer.views.try_get(declared.view)!;
                if (declared.access != DispatchAccess.READ) return c3d::INVALID_ARGUMENT~;
        }
        if (declared.access == DispatchAccess.READ && declared.sampler.generation
            && !renderer.assets.samplers.is_live(declared.sampler)) {
            return c3d::INVALID_ID~;
        }
    }
    return;
}

fn ResolvedDispatchTexture? resolve_dispatch_texture(
    Renderer* renderer,
    DispatchTexture* declared,
    DispatchTextureGpu* slot,
) @private {
    ResolvedDispatchTexture entry;
    switch (declared.kind) {
        case ASSET:
            entry.mirror = resolve_texture(renderer, declared.texture)!;
            if (declared.access != DispatchAccess.READ) {
                if (declared.mip >= entry.mirror.mip_count || declared.layer >= entry.mirror.layers) {
                    return c3d::INVALID_ARGUMENT~;
                }
                usz view_slot = storage_view_slot(entry.mirror.mip_count, declared.layer, declared.mip);
                slot.texture_index = entry.mirror.storage_views[view_slot].index;
            } else {
                slot.texture_index = entry.mirror.view.index;
            }
        case RENDER_TARGET:
            entry.target = &renderer.targets.get(declared.target).target;
            slot.texture_index = entry.target.view.index;
        case VIEW_COLOR:
            ViewRecord* record = renderer.views.get(declared.view);
            if (declared.access != DispatchAccess.READ) post::detach_scene_input(renderer, record)!;
            entry.target = record.scene_input;
            if (!entry.target.texture.is_valid()) return c3d::INVALID_ARGUMENT~;
            slot.texture_index = entry.target.view.index;
        case VIEW_DEPTH:
            entry.target = &renderer.views.get(declared.view).depth;
            if (!entry.target.texture.is_valid()) return c3d::INVALID_ARGUMENT~;
            slot.texture_index = entry.target.view.index;
    }
    switch (declared.access) {
        case READ:
            // A store texture already sits in the state materials sample from; only images with tracked state move.
            entry.use = entry.mirror
                ? renderer.sampled_state
                : gpu::sampled_at({ .compute });
            slot.sampler_index = declared.sampler.generation
                ? resolve_sampler(renderer, declared.sampler)!.index
                : renderer.linear_clamp_sampler;
        case WRITE:
            entry.use = gpu::storage_at({ .compute }, { .write });
        case READ_WRITE:
            entry.use = gpu::storage_at({ .compute }, { .read, .write });
    }
    return entry;
}

fn void? transition_dispatch_texture(
    Renderer* renderer,
    ResolvedDispatchTexture* entry,
    gpu::TextureState next,
) @private {
    if (entry.target) return entry.target.transition(&renderer.commands, next);

    remember_texture_state(&renderer.texture_state_undo, entry.mirror);
    gpu::TextureState before = entry.mirror.state;
    // An equal storage state still orders a write against the previous use; only reads may share a state.
    bool read_after_read = mem::equals(&before, &next, gpu::TextureState::size)
        && !before.access.write && !next.access.write;
    if (read_after_read) return;
    gpu::TextureBarrier barrier = gpu::texture_transition(entry.mirror.texture, before, next)!;
    gpu::cmd_texture_barrier(&renderer.commands, &barrier)!;
    entry.mirror.state = next;
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

fn void? dispatch_over(Renderer* renderer, gpu::GpuAddress root, Target* target) @private {
    return dispatch_extent(renderer, root, target.width, target.height);
}

fn void? dispatch_extent(
    Renderer* renderer,
    gpu::GpuAddress root,
    uint width,
    uint height,
) @private {
    uint groups_x = (width + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
    uint groups_y = (height + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
    return gpu::cmd_dispatch(&renderer.commands, root, { groups_x, groups_y, 1 });
}
