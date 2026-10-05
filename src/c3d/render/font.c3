module c3d::render;

import c3d;
import c3d::asset;
import c3d::shader;
import gpu;
import std::collections::list;

const usz FONT_CURVE_TEXEL_BYTES @local = 8; // RGBA16_FLOAT
const usz FONT_BAND_TEXEL_BYTES @local = 4;  // R32_UINT holding two u16 values

$assert(asset::FONT_TEXTURE_WIDTH == shader::FONT_TEXTURE_WIDTH);
$assert(1u << shader::FONT_TEXTURE_WIDTH_SHIFT == shader::FONT_TEXTURE_WIDTH);

struct FontRes @private {
    FontId             asset;
    uint               revision;
    gpu::TextureHandle curves;
    gpu::TextureView   curve_view;
    gpu::TextureState  curve_state;
    gpu::TextureHandle bands;
    gpu::TextureView   band_view;
    gpu::TextureState  band_state;
    uint               curve_texels; // uploaded and submitted
    uint               band_texels;  // uploaded and submitted
}

struct PendingFontUpload @private {
    FontId                     asset;
    uint                       revision;
    uint                       curve_texels;
    uint                       band_texels;
    gpu::TextureState          curve_before;
    gpu::TextureState          band_before;
    gpu::BufferTextureCopyDesc curve_copy; // zero height when no curve row changed
    gpu::BufferTextureCopyDesc band_copy;  // zero height when no band row changed
    bool                       recorded;
}

fn bool font_current(Renderer* renderer, FontId font) @local {
    FontAsset* record = renderer.assets.font(font);
    FontRes* mirror = &renderer.fonts[font.index];
    if (!c3d::same_id(mirror.asset, font)) return false;
    if (mirror.revision == record.header.revision) return true;
    foreach (&pending : renderer.pending_font_uploads) {
        if (c3d::same_id(pending.asset, font) && pending.revision == record.header.revision) return true;
    }
    return false;
}

fn FontRes*? resolve_font(Renderer* renderer, FontId font) @private {
    FontRes* mirror = &renderer.fonts[font.index];
    if (font_current(renderer, font)) return mirror;
    FontAsset* record = renderer.assets.font(font);
    if (!c3d::same_id(mirror.asset, font)) create_font_textures(renderer, mirror, font)!;

    uint curve_base = mirror.curve_texels;
    uint band_base = mirror.band_texels;
    foreach (&pending : renderer.pending_font_uploads) {
        if (!c3d::same_id(pending.asset, font)) continue;
        curve_base = pending.curve_texels;
        band_base = pending.band_texels;
    }

    PendingFontUpload pending = {
        .asset        = font,
        .revision     = record.header.revision,
        .curve_texels = record.curve_texels,
        .band_texels  = record.band_texels,
        .curve_before = mirror.curve_state,
        .band_before  = mirror.band_state,
    };
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    uint width = asset::FONT_TEXTURE_WIDTH;

    uint curve_row = curve_base / width;
    uint curve_rows = (record.curve_texels + width - 1) / width - curve_row;
    if (curve_rows) {
        usz texel_count = (usz)curve_rows * width;
        usz bytes = texel_count * FONT_CURVE_TEXEL_BYTES;
        gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, bytes, UPLOAD_RING_ALIGNMENT)!;
        ushort[] halves = ((ushort*)staging.bytes.ptr)[:texel_count * 4];
        foreach (index, texel : record.curves[curve_row * width : texel_count]) {
            halves[index * 4] = float_to_half(texel.x);
            halves[index * 4 + 1] = float_to_half(texel.y);
            halves[index * 4 + 2] = float_to_half(texel.z);
            halves[index * 4 + 3] = float_to_half(texel.w);
        }
        pending.curve_copy = {
            .src               = staging.span,
            .row_length_texels = width,
            .texture           = mirror.curves,
            .y                 = curve_row,
            .width             = width,
            .height            = curve_rows,
        };
        renderer.stats.upload_bytes += (uint)bytes;
    }

    uint band_row = band_base / width;
    uint band_rows = (record.band_texels + width - 1) / width - band_row;
    if (band_rows) {
        usz texel_count = (usz)band_rows * width;
        usz bytes = texel_count * FONT_BAND_TEXEL_BYTES;
        gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, bytes, UPLOAD_RING_ALIGNMENT)!;
        mem::copy(staging.bytes.ptr, &record.bands[band_row * width], (sz)bytes);
        pending.band_copy = {
            .src               = staging.span,
            .row_length_texels = width,
            .texture           = mirror.bands,
            .y                 = band_row,
            .width             = width,
            .height            = band_rows,
        };
        renderer.stats.upload_bytes += (uint)bytes;
    }

    renderer.pending_font_uploads.push(pending);
    renderer.stats.uploads++;
    return mirror;
}

fn void? create_font_textures(Renderer* renderer, FontRes* mirror, FontId font) @local {
    FontAsset* record = renderer.assets.font(font);
    uint width = asset::FONT_TEXTURE_WIDTH;
    gpu::TextureDesc curve_desc = {
        .width      = width,
        .height     = (uint)record.curves.len / width,
        .format     = gpu::Format.RGBA16_FLOAT,
        .usage      = { .sampled, .transfer_dst },
        .access     = { .graphics },
        .debug_name = "font_curves",
    };
    gpu::TextureDesc band_desc = {
        .width      = width,
        .height     = (uint)record.bands.len / width,
        .format     = gpu::Format.R32_UINT,
        .usage      = { .sampled, .transfer_dst },
        .access     = { .graphics },
        .debug_name = "font_bands",
    };

    gpu::TextureHandle curves = gpu::create_texture(&renderer.device, &curve_desc)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, curves);
    gpu::TextureView curve_view = gpu::create_texture_view(&renderer.device, curves, null)!;
    defer catch (void)gpu::destroy_texture_view(&renderer.device, curve_view);
    gpu::TextureHandle bands = gpu::create_texture(&renderer.device, &band_desc)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, bands);
    gpu::TextureView band_view = gpu::create_texture_view(&renderer.device, bands, null)!;

    retire_font(renderer, mirror);
    *mirror = {
        .asset      = font,
        .curves     = curves,
        .curve_view = curve_view,
        .bands      = bands,
        .band_view  = band_view,
    };
}

fn void? record_font_uploads(Renderer* renderer, gpu::CommandList* commands) @private {
    foreach (&pending : renderer.pending_font_uploads) {
        if (pending.recorded) continue;

        FontRes* mirror = &renderer.fonts[pending.asset.index];
        if (pending.curve_copy.height) {
            record_font_copy(
                renderer: renderer,
                commands: commands,
                copy:     &pending.curve_copy,
                state:    &mirror.curve_state,
            )!;
        }
        if (pending.band_copy.height) {
            record_font_copy(
                renderer: renderer,
                commands: commands,
                copy:     &pending.band_copy,
                state:    &mirror.band_state,
            )!;
        }
        pending.recorded = true;
    }
}

fn void? record_font_copy(
    Renderer* renderer,
    gpu::CommandList* commands,
    gpu::BufferTextureCopyDesc* copy,
    gpu::TextureState* state,
) @local {
    gpu::TextureBarrier to_upload = gpu::texture_transition(
        texture: copy.texture,
        before:  *state,
        after:   {
            .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
            .stages = { .transfer },
            .access = { .write },
        },
    )!;
    gpu::cmd_texture_barrier(commands, &to_upload)!;
    gpu::cmd_copy_buffer_to_texture(commands, copy)!;

    gpu::TextureBarrier to_sampled = gpu::texture_transition(
        texture: copy.texture,
        before:  to_upload.after,
        after:   renderer.sampled_state,
    )!;
    gpu::cmd_texture_barrier(commands, &to_sampled)!;
    *state = to_sampled.after;
}

fn void commit_font_uploads(Renderer* renderer) @private {
    foreach (&pending : renderer.pending_font_uploads) {
        FontRes* mirror = &renderer.fonts[pending.asset.index];
        if (!c3d::same_id(mirror.asset, pending.asset)) continue;

        mirror.revision = pending.revision;
        mirror.curve_texels = pending.curve_texels;
        mirror.band_texels = pending.band_texels;
    }
    renderer.pending_font_uploads.clear();
}

// Reverse order leaves each mirror with the state its first upload of the frame found.
fn void discard_font_uploads(Renderer* renderer) @private {
    for (sz index = renderer.pending_font_uploads.len() - 1; index >= 0; index--) {
        PendingFontUpload* pending = &renderer.pending_font_uploads[index];
        FontRes* mirror = &renderer.fonts[pending.asset.index];
        if (!c3d::same_id(mirror.asset, pending.asset)) continue;

        mirror.curve_state = pending.curve_before;
        mirror.band_state = pending.band_before;
    }
    renderer.pending_font_uploads.clear();
}

fn void retire_font(Renderer* renderer, FontRes* mirror) @local {
    if (!mirror.curves.is_valid()) return;

    renderer.pending_upload_retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = mirror.curve_view });
    renderer.pending_upload_retire.push({ .kind = RetiredKind.TEXTURE, .texture = mirror.curves });
    renderer.pending_upload_retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = mirror.band_view });
    renderer.pending_upload_retire.push({ .kind = RetiredKind.TEXTURE, .texture = mirror.bands });
}

fn void sweep_fonts(Renderer* renderer) @private {
    foreach (&mirror : renderer.fonts) {
        if (!mirror.asset.generation || renderer.assets.fonts.is_live(mirror.asset)) continue;

        retire_font(renderer, mirror);
        *mirror = {};
    }
}

fn void free_fonts(Renderer* renderer) @private {
    foreach (&mirror : renderer.fonts) {
        if (!mirror.curves.is_valid()) continue;

        (void)gpu::destroy_texture_view(&renderer.device, mirror.curve_view);
        (void)gpu::destroy_texture(&renderer.device, mirror.curves);
        (void)gpu::destroy_texture_view(&renderer.device, mirror.band_view);
        (void)gpu::destroy_texture(&renderer.device, mirror.bands);
    }
    alloc::free(renderer.allocator, renderer.fonts.ptr);
}
