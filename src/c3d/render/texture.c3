module c3d::render;

import c3d;
import c3d::asset;
import c3d::instrumentation @public;
import c3d::material;
import gpu;
import std::math;

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
    bool copy_source;
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

fn bool texture_current(Renderer* renderer, TextureId texture) @private {
    TextureAsset* record = renderer.assets.texture(texture);
    TextureRes* mirror = &renderer.textures[texture.index];
    if (c3d::same_id(mirror.asset, texture) && mirror.revision == record.header.revision) return true;
    foreach (&pending : renderer.pending_texture_uploads) {
        if (c3d::same_id(pending.asset, texture) && pending.revision == record.header.revision) return true;
    }
    return false;
}

fn TextureRes*? resolve_texture(Renderer* renderer, TextureId texture, bool full_reader = false) @private {
    TextureAsset* record = renderer.assets.texture(texture);
    TextureRes* mirror = &renderer.textures[texture.index];
    TextureResidency* residency = &renderer.residencies[texture.index];
    residency.last_used_frame = renderer.frame_index;
    if (texture_current(renderer, texture)) {
        if (full_reader) mark_full_reader(residency);
        return mirror;
    }
    bool same_asset = c3d::same_id(mirror.asset, texture);

    @pool() {
        material::TextureDesc desc = record.desc;
        uint chain_mips = texture_chain_mips(record);
        bool eligible = texture_eligible(desc, record.source_kind, chain_mips);
        bool pinned = full_reader || (same_asset && residency.full_reader);
        bool streamed = eligible && !pinned;
        uint tail_base = streamed ? texture_tail_base(math::max(desc.width, desc.height), chain_mips) : 0;
        bool same_chain = same_asset && mirror.texture.is_valid()
            && residency.chain_mips == chain_mips && residency.chain_width == desc.width
            && residency.chain_height == desc.height && residency.format == desc.format;
        uint base = same_chain ? residency.resident_base : (streamed && renderer.texture_budget_bytes ? tail_base : 0);

        gpu::Format format = texture_format(desc.format);
        gpu::TextureDesc description = texture_gpu_description(desc, format, chain_mips, base, eligible);
        bool reuse = texture_mirror_fits(mirror, &description, same_asset, desc, eligible);
        if (!reuse && !streamed && base > 0) {
            base = 0;
            description = texture_gpu_description(desc, format, chain_mips, base, eligible);
        }

        TextureMipChain chain;
        TextureMipLayout layout;
        switch (record.source_kind) {
            case MIP_ZERO:
                chain = create_texture_mips(tmem, desc, record.pixels, first_mip: base)!;
                layout = {
                    .total_bytes = chain.pixels.len,
                    .mip_count = chain.mip_count,
                    .layer_count = chain.layer_count,
                    .offsets = chain.offsets,
                };
            case SUPPLIED_MIPS:
                layout = supplied_texture_mip_layout(desc, record.supplied_mips, first_mip: base)!;
            case EMPTY:
                layout = { .mip_count = desc.mip_levels, .layer_count = desc.layers };
        }
        defer {
            if (record.source_kind == TextureSourceKind.MIP_ZERO) destroy_texture_mips(&chain);
        }
        uint mip_count = description.mip_levels;
        uint layer_count = description.array_layers;
        TextureLevelBytes level_bytes = chain_mips ? texture_level_bytes(desc, chain_mips)! : {};
        if (!reuse) {
            gpu::TextureHandle image = gpu::create_texture(&renderer.device, &description)!;
            defer catch {
                if (image.is_valid()) (void)gpu::destroy_texture(&renderer.device, image);
            }
            gpu::TextureViewDesc view_desc = { .cube = desc.is_cube };
            gpu::TextureView view = gpu::create_texture_view(&renderer.device, image, &view_desc)!;
            gpu::TextureView[] storage_views;
            if (desc.storage) {
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
                .is_cube = desc.is_cube,
                .copy_source = eligible,
                .format = format,
                .storage_views = storage_views,
            };
            image = {};
        }

        remember_texture_state(&renderer.texture_state_undo, mirror);
        PendingTextureUpload pending = {
            .asset = texture,
            .revision = record.header.revision,
            .texture = mirror.texture,
            .before = mirror.state,
        };
        if (layout.total_bytes) {
            Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
            gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, layout.total_bytes, UPLOAD_RING_ALIGNMENT)!;
            switch (record.source_kind) {
                case MIP_ZERO: mem::copy(staging.bytes.ptr, chain.pixels.ptr, chain.pixels.len);
                case SUPPLIED_MIPS: copy_supplied_texture_mips(staging.bytes, record.supplied_mips, base);
                case EMPTY: unreachable();
            }
            pending.mip_count = layout.mip_count;
            for (uint mip = 0; mip < layout.mip_count; mip++) {
                usz bytes = gpu::texture_mip_bytes(&description, mip)!;
                pending.copies[mip] = {
                    .src = staging.span.checked_subspan(layout.offsets[mip], bytes * layout.layer_count)!,
                    .texture = mirror.texture,
                    .mip = mip,
                    .layer_count = layout.layer_count,
                };
            }
            renderer.stats.upload_bytes += (uint)layout.total_bytes;
        }
        renderer.pending_texture_uploads.push(pending);
        renderer.stats.uploads++;

        *residency = {
            .chain_mips = chain_mips,
            .chain_width = desc.width,
            .chain_height = desc.height,
            .format = desc.format,
            .level_bytes = level_bytes,
            .tail_base = tail_base,
            .resident_base = base,
            .required_base = chain_mips,
            .last_used_frame = residency.last_used_frame,
            .eligible = eligible,
            .full_reader = pinned,
            .streamed = streamed,
            .raisable = texture_source_present(record),
        };
    };

    return mirror;
}

<*
 Image description of a texture whose resident chain starts at base.
*>
fn gpu::TextureDesc texture_gpu_description(
    material::TextureDesc desc,
    gpu::Format format,
    uint chain_mips,
    uint base,
    bool copy_source,
) @private {
    return {
        .width = math::max(1u, desc.width >> base),
        .height = math::max(1u, desc.height >> base),
        .depth = desc.depth,
        .mip_levels = chain_mips - base,
        .array_layers = desc.layers,
        .cube_compatible = desc.is_cube,
        .format = format,
        .usage = { .sampled, .transfer_dst, .transfer_src = copy_source, .storage = desc.storage },
        .access = { .graphics },
        .debug_name = desc.debug_name,
    };
}

fn bool texture_mirror_fits(
    TextureRes* mirror,
    gpu::TextureDesc* description,
    bool same_asset,
    material::TextureDesc desc,
    bool copy_source,
) @local {
    return same_asset && mirror.texture.is_valid()
        && mirror.width == description.width && mirror.height == description.height
        && mirror.depth == description.depth
        && mirror.mip_count == description.mip_levels && mirror.format == description.format
        && mirror.layers == description.array_layers && mirror.is_cube == desc.is_cube
        && mirror.copy_source == copy_source
        && (mirror.storage_views.len > 0) == desc.storage;
}

fn uint texture_chain_mips(TextureAsset* record) @private {
    material::TextureDesc* desc = &record.desc;
    switch (record.source_kind) {
        case MIP_ZERO:
            if (desc.generate_mips && desc.width && desc.height) return material::texture_mip_count(desc.width, desc.height);
            return 1;
        case SUPPLIED_MIPS:
        case EMPTY:
            return desc.mip_levels;
    }
}

fn void mark_full_reader(TextureResidency* residency) @local {
    residency.full_reader = true;
    residency.streamed = false;
    residency.tail_base = 0;
}

fn bool texture_source_present(TextureAsset* record) @private {
    switch (record.source_kind) {
        case MIP_ZERO: return record.pixels.len > 0;
        case SUPPLIED_MIPS: return record.supplied_mips.len > 0;
        case EMPTY: return false;
    }
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
    foreach (index, &mirror : renderer.textures) {
        if (!mirror.asset.generation || renderer.assets.textures.is_live(mirror.asset)) continue;

        retire_texture(renderer, mirror);
        renderer.residencies[index] = {};
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
    alloc::free(renderer.allocator, renderer.residencies.ptr);
    alloc::free(renderer.allocator, renderer.residency_changes.ptr);
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
