module c3d::render;

import c3d;
import c3d::asset;
import c3d::instrumentation @public;
import c3d::material;
import gpu;

<*
 Renderer-owned image and full-chain view of one texture asset.
*>
struct TextureRes {
    TextureId asset;
    uint revision;
    uint binding_revision;
    gpu::TextureHandle texture;
    gpu::TextureView view;
    gpu::TextureState state;
    uint width;
    uint height;
    uint depth;
    uint mip_count;
    uint layers;
    bool is_cube;
    gpu::Format format;
    gpu::TextureView[] storage_views;
}

<*
 Upload texture pixels now or before this frame's sampling.
 @param [&inout] self : "Open-frame uploads precede sampling views."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::UNSUPPORTED_FEATURE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !self.overlay_open, !self.frame_open || self.has_output
*>
fn void? Renderer.upload_texture(&self, TextureId texture) {
    if (!self.assets.textures.is_live(texture)) return c3d::INVALID_ID~;

    instrumentation::@scope("renderer.upload_texture") {
        if (self.frame_open) {
            resolve_texture(self, texture)!;
            return;
        }

        open_closed_frame_slot(self)!;
        defer catch discard_uploads(self);
        resolve_texture(self, texture)!;
        submit_pending(self)!;
    };
}

fn TextureRes*? resolve_texture(Renderer* renderer, TextureId texture) @private {
    TextureAsset* record = renderer.assets.texture(texture);
    TextureRes* mirror = &renderer.textures[texture.index];
    bool same_asset = mirror.asset.index == texture.index && mirror.asset.generation == texture.generation;
    if (same_asset && mirror.revision == record.header.revision) return mirror;

    foreach (&pending : renderer.pending_texture_uploads) {
        if (pending.asset.index == texture.index && pending.asset.generation == texture.generation
            && pending.revision == record.header.revision) return mirror;
    }

    @pool() {
        bool empty = record.source_kind == TextureSourceKind.EMPTY;
        TextureMipChain chain;
        switch (record.source_kind) {
            case MIP_ZERO:
                chain = create_texture_mips(tmem, record.desc, record.pixels)!;
            case SUPPLIED_MIPS:
                chain = create_supplied_texture_mips(tmem, record.desc, record.supplied_mips)!;
            case EMPTY:
                break;
        }
        defer {
            if (!empty) destroy_texture_mips(&chain);
        }
        uint mip_count = empty ? record.desc.mip_levels : chain.mip_count;
        uint layer_count = empty ? record.desc.layers : chain.layer_count;
        gpu::Format format = texture_format(record.desc.format);
        gpu::TextureDesc description = {
            .width = record.desc.width,
            .height = record.desc.height,
            .depth = record.desc.depth,
            .mip_levels = mip_count,
            .array_layers = layer_count,
            .cube_compatible = record.desc.is_cube,
            .format = format,
            .usage = { .sampled, .transfer_dst, .storage = record.desc.storage },
            .access = { .graphics },
            .debug_name = record.desc.debug_name,
        };
        bool reuse = same_asset && mirror.texture.is_valid()
            && mirror.width == description.width && mirror.height == description.height
            && mirror.depth == description.depth
            && mirror.mip_count == mip_count && mirror.format == format
            && mirror.layers == layer_count && mirror.is_cube == record.desc.is_cube
            && (mirror.storage_views.len > 0) == record.desc.storage;
        if (!reuse) {
            gpu::TextureHandle image = gpu::create_texture(&renderer.device, &description)!;
            defer catch {
                if (image.is_valid()) (void)gpu::destroy_texture(&renderer.device, image);
            }
            gpu::TextureViewDesc view_desc = { .cube = record.desc.is_cube };
            gpu::TextureView view = gpu::create_texture_view(&renderer.device, image, &view_desc)!;
            gpu::TextureView[] storage_views;
            if (record.desc.storage) {
                gpu::TextureView[]? created = create_storage_views(renderer, image, mip_count, layer_count);
                if (catch excuse = created) {
                    (void)gpu::destroy_texture_view(&renderer.device, view);
                    return excuse~;
                }
                storage_views = created;
            }

            retire_texture(renderer, mirror);
            *mirror = {
                .asset = texture,
                .binding_revision = mirror.binding_revision + 1,
                .texture = image,
                .view = view,
                .width = description.width,
                .height = description.height,
                .depth = description.depth,
                .mip_count = mip_count,
                .layers = layer_count,
                .is_cube = record.desc.is_cube,
                .format = format,
                .storage_views = storage_views,
            };
            image = {};
        }

        PendingTextureUpload pending = {
            .asset = texture,
            .revision = record.header.revision,
            .texture = mirror.texture,
            .before = mirror.state,
        };
        if (!empty) {
            Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
            gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, chain.pixels.len, UPLOAD_RING_ALIGNMENT)!;
            mem::copy(staging.bytes.ptr, chain.pixels.ptr, chain.pixels.len);
            pending.mip_count = chain.mip_count;
            for (uint mip = 0; mip < chain.mip_count; mip++) {
                usz bytes = gpu::texture_mip_bytes(&description, mip)!;
                pending.copies[mip] = {
                    .src = staging.span.checked_subspan(chain.offsets[mip], bytes * chain.layer_count)!,
                    .texture = mirror.texture,
                    .mip = mip,
                    .layer_count = chain.layer_count,
                };
            }
            renderer.stats.upload_bytes += (uint)chain.pixels.len;
        }
        renderer.pending_texture_uploads.push(pending);
        renderer.stats.uploads++;
    };

    return mirror;
}

fn void retire_texture(Renderer* renderer, TextureRes* mirror) @private {
    if (!mirror.texture.is_valid()) return;

    foreach (view : mirror.storage_views) {
        renderer.pending_upload_retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = view });
    }
    alloc::free(renderer.allocator, mirror.storage_views.ptr);
    mirror.storage_views = {};
    renderer.pending_upload_retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = mirror.view });
    renderer.pending_upload_retire.push({ .kind = RetiredKind.TEXTURE, .texture = mirror.texture });
}

fn gpu::TextureView[]? create_storage_views(
    Renderer* renderer,
    gpu::TextureHandle image,
    uint mip_count,
    uint layer_count,
) @private {
    gpu::TextureView[] views = alloc::new_array(renderer.allocator, gpu::TextureView, (usz)mip_count * layer_count);
    usz created;
    defer catch {
        foreach (view : views[:created]) (void)gpu::destroy_texture_view(&renderer.device, view);
        alloc::free(renderer.allocator, views.ptr);
    }
    for (uint layer = 0; layer < layer_count; layer++) {
        for (uint mip = 0; mip < mip_count; mip++) {
            gpu::TextureViewDesc view_desc = {
                .base_mip    = mip,
                .mip_count   = 1,
                .base_layer  = layer,
                .layer_count = 1,
            };
            views[storage_view_slot(mip_count, layer, mip)] = gpu::create_texture_view(&renderer.device, image, &view_desc)!;
            created++;
        }
    }
    return views;
}

fn void sweep_textures(Renderer* renderer) @private {
    foreach (&mirror : renderer.textures) {
        if (!mirror.asset.generation || renderer.assets.textures.is_live(mirror.asset)) continue;

        retire_texture(renderer, mirror);
        uint binding_revision = mirror.binding_revision;
        *mirror = { .binding_revision = binding_revision };
    }
}

fn void free_textures(Renderer* renderer) @private {
    foreach (&mirror : renderer.textures) {
        if (!mirror.texture.is_valid()) continue;

        foreach (view : mirror.storage_views) (void)gpu::destroy_texture_view(&renderer.device, view);
        alloc::free(renderer.allocator, mirror.storage_views.ptr);
        (void)gpu::destroy_texture_view(&renderer.device, mirror.view);
        (void)gpu::destroy_texture(&renderer.device, mirror.texture);
    }
    alloc::free(renderer.allocator, renderer.textures.ptr);
    alloc::free(renderer.allocator, renderer.samplers.ptr);
}

fn void? prepare_builtin_textures(Renderer* renderer) @private {
    open_closed_frame_slot(renderer)!;
    defer catch discard_uploads(renderer);

    for (uint index = 0; index < asset::BUILTIN_SAMPLER_COUNT; index++) {
        resolve_sampler(renderer, { .index = index, .generation = 1 })!;
    }
    for (uint index = 0; index < asset::BUILTIN_TEXTURE_COUNT; index++) {
        resolve_texture(renderer, { .index = index, .generation = 1 })!;
    }
    submit_pending(renderer)!;
}
