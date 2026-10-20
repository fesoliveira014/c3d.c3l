module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import gpu;
import std::math;

struct TextureBox @private {
    uint first_x;
    uint end_x;
    uint first_y;
    uint end_y;
}

struct RetainedSources @private {
    TextureMipLayout layout;
    char[] level_zero; // staged ahead of the retained levels; empty above base 0
    char[] levels;     // retained levels from the first staged one
}

fn uint texture_scale_floor(uint value, uint numerator, uint denominator) @local {
    return (uint)((ulong)value * numerator / denominator);
}

fn uint texture_scale_ceil(uint value, uint numerator, uint denominator) @local {
    return (uint)(((ulong)value * numerator + denominator - 1) / denominator);
}

fn TextureBox filtered_texture_box(TextureBox box, material::TextureDesc* desc, uint mip) @local {
    uint source_width = material::texture_mip_extent(desc.width, mip - 1);
    uint source_height = material::texture_mip_extent(desc.height, mip - 1);
    uint width = material::texture_mip_extent(desc.width, mip);
    uint height = material::texture_mip_extent(desc.height, mip);

    return {
        .first_x = texture_scale_floor(box.first_x, width, source_width),
        .end_x   = texture_scale_ceil(box.end_x, width, source_width),
        .first_y = texture_scale_floor(box.first_y, height, source_height),
        .end_y   = texture_scale_ceil(box.end_y, height, source_height),
    };
}

fn bool texture_retains_chain(TextureAsset* record) @private {
    return record.source_kind == TextureSourceKind.MIP_ZERO
        && record.desc.generate_mips && record.desc.coverage != CoveragePolicy.THRESHOLD;
}

fn bool texture_chain_current(TextureRes* mirror) @local {
    return mirror.mip_chain.len > 0 && mirror.chain_revision != 0 && mirror.chain_revision == mirror.revision;
}

fn TextureMipChain? acquire_retained_levels(
    Renderer* renderer,
    TextureRes* mirror,
    material::TextureDesc* desc,
) @private {
    GeneratedTextureLayout layout = generated_texture_mip_layout(*desc)!;

    if (!mirror.mip_chain.len && layout.byte_count) {
        mirror.mip_chain = alloc::alloc_array(renderer.allocator, char, (sz)layout.byte_count);
        mirror.chain_revision = 0;
    }

    return {
        .first_mip   = 1,
        .mip_count   = layout.mip_count,
        .layer_count = layout.layer_count,
        .offsets     = layout.offsets,
        .pixels      = mirror.mip_chain,
    };
}

fn void release_retained_levels(Renderer* renderer, TextureRes* mirror) @private {
    alloc::free(renderer.allocator, mirror.mip_chain.ptr);
    mirror.mip_chain = {};
    mirror.chain_revision = 0;
}

fn RetainedSources? refill_retained_levels(
    Renderer* renderer,
    TextureAsset* record,
    TextureRes* mirror,
    uint base,
) @private {
    material::TextureDesc* desc = &record.desc;
    TextureMipChain levels = acquire_retained_levels(renderer, mirror, desc)!;

    check_texture_mip_zero(*desc, record.pixels)!;
    fill_generated_texture_mips(*desc, record.pixels, &levels)!;

    usz skipped = base ? levels.offsets[base - 1] : 0;
    usz level_zero_bytes = base ? 0 : record.pixels.len;
    RetainedSources sources = {
        .layout = {
            .total_bytes = level_zero_bytes + levels.pixels.len - skipped,
            .mip_count   = levels.mip_count + 1 - base,
            .layer_count = levels.layer_count,
        },
        .level_zero = record.pixels[:level_zero_bytes],
        .levels     = levels.pixels[skipped..],
    };

    for (uint index = 0; index < sources.layout.mip_count; index++) {
        uint mip = base + index;

        sources.layout.offsets[index] = mip ? level_zero_bytes + levels.offsets[mip - 1] - skipped : 0;
    }

    return sources;
}

fn bool texture_upload_staged(Renderer* renderer, TextureRes* mirror) @local {
    foreach (&pending : renderer.pending_texture_uploads) {
        if (!pending.recorded && pending.texture == mirror.texture) return true;
    }

    return false;
}

fn bool texture_source_valid(TextureAsset* record) @local {
    switch (record.source_kind) {
        case MIP_ZERO:
            if (catch check_texture_mip_zero(record.desc, record.pixels)) return false;

            return true;

        case SUPPLIED_MIPS:
            if (catch supplied_texture_mip_layout(record.desc, record.supplied_mips)) return false;

            return true;

        case EMPTY:
            return false;
    }
}

fn bool texture_regions_stageable(
    Renderer* renderer,
    TextureAsset* record,
    TextureRes* mirror,
    TextureRegion[] regions,
) @private {
    material::TextureDesc* desc = &record.desc;

    if (desc.storage || material::texture_is_compressed(desc.format)) return false;

    // The coverage scale of a level depends on every texel of the level.
    if (desc.generate_mips && desc.coverage == CoveragePolicy.THRESHOLD) return false;

    if (record.regions_since(mirror.revision, regions) != TextureChange.REGIONS) return false;

    // An image with an unrecorded upload has a stale tracked state, and a barrier from it may discard texels.
    if (texture_upload_staged(renderer, mirror)) return false;

    return texture_source_valid(record);
}

fn void? stage_texture_regions(
    Renderer* renderer,
    TextureAsset* record,
    TextureRes* mirror,
    PendingTextureUpload* pending,
    TextureRegion[] regions,
    uint base,
) @private {
    material::TextureDesc* desc = &record.desc;
    bool generated = record.source_kind == TextureSourceKind.MIP_ZERO && desc.generate_mips;
    uint chain_mips = texture_chain_mips(record);
    TextureBox[material::TEXTURE_MIP_CAPACITY] boxes;
    TextureMipChain generated_levels;

    for (uint mip = 0; mip < record.region_mip_count(); mip++) {
        TextureRegion region = regions[mip];

        if (!region.width) continue;

        boxes[mip] = {
            .first_x = region.x,
            .end_x   = region.x + region.width,
            .first_y = region.y,
            .end_y   = region.y + region.height,
        };
    }

    if (generated) {
        bool incremental = texture_chain_current(mirror);

        generated_levels = acquire_retained_levels(renderer, mirror, desc)!;
        filter_texture_region_levels(
            record:           record,
            generated_levels: &generated_levels,
            region:           regions[0],
            boxes:            boxes[..],
            incremental:      incremental,
        )!;
        pending.chain_revision = record.header.revision;
    }

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    usz texel_bytes = material::texture_block_bytes(desc.format);
    bool volume = desc.depth > 0;
    usz staged_bytes;

    for (uint mip = base; mip < chain_mips; mip++) {
        TextureBox box = boxes[mip];

        if (box.end_x == box.first_x) continue;

        TextureRegion region = generated ? regions[0] : regions[mip];
        uint width = box.end_x - box.first_x;
        uint height = box.end_y - box.first_y;
        usz row_bytes = (usz)width * texel_bytes;
        usz box_bytes = row_bytes * height;
        usz level_width = material::texture_mip_extent(desc.width, mip);
        usz plane_bytes = level_width * material::texture_mip_extent(desc.height, mip) * texel_bytes;
        usz level_bytes = box_bytes * region.depth;

        gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, level_bytes, UPLOAD_RING_ALIGNMENT)!;

        for (uint plane = 0; plane < region.depth; plane++) {
            char[] source = texture_plane(
                record:           record,
                generated_levels: &generated_levels,
                mip:              mip,
                plane:            region.z + plane,
                plane_bytes:      plane_bytes,
            );

            for (uint row = 0; row < height; row++) {
                usz source_offset = ((usz)(box.first_y + row) * level_width + box.first_x) * texel_bytes;
                usz destination_offset = (usz)plane * box_bytes + row * row_bytes;

                mem::copy(staging.bytes.ptr + destination_offset, source.ptr + source_offset, (sz)row_bytes);
            }
        }

        pending.copies[pending.mip_count] = {
            .src         = staging.span.checked_subspan(0, level_bytes)!,
            .texture     = pending.texture,
            .mip         = mip - base,
            .base_layer  = volume ? 0 : region.z,
            .layer_count = volume ? 0 : region.depth,
            .x           = box.first_x,
            .y           = box.first_y,
            .z           = volume ? region.z : 0,
            .width       = width,
            .height      = height,
            .depth       = volume ? region.depth : 0,
        };
        pending.mip_count++;
        staged_bytes += level_bytes;
    }

    renderer.stats.upload_bytes += (uint)staged_bytes;
}

fn void? filter_texture_region_levels(
    TextureAsset* record,
    TextureMipChain* generated_levels,
    TextureRegion region,
    TextureBox[] boxes,
    bool incremental,
) @private {
    material::TextureDesc* desc = &record.desc;
    uint chain_mips = texture_chain_mips(record);

    for (uint mip = 1; mip < chain_mips; mip++) {
        boxes[mip] = filtered_texture_box(boxes[mip - 1], desc, mip);
    }

    if (!incremental) return fill_generated_texture_mips(*desc, record.pixels, generated_levels);

    for (uint mip = 1; mip < chain_mips; mip++) {
        TextureBox box = boxes[mip];

        for (uint plane = region.z; plane < region.z + region.depth; plane++) {
            write_texture_filter_band(
                desc:         *desc,
                mip:          mip,
                layer:        plane,
                first_row:    box.first_y,
                row_count:    box.end_y - box.first_y,
                mip_zero:     record.pixels,
                chain:        generated_levels,
                first_column: box.first_x,
                column_count: box.end_x - box.first_x,
            )!;
        }
    }
}

fn char[] texture_plane(
    TextureAsset* record,
    TextureMipChain* generated_levels,
    uint mip,
    uint plane,
    usz plane_bytes,
) @local {
    switch (record.source_kind) {
        case MIP_ZERO:
            if (!mip) return record.pixels[(usz)plane * plane_bytes:plane_bytes];

            return generated_levels.pixels[generated_levels.offsets[mip - 1] + (usz)plane * plane_bytes:plane_bytes];

        case SUPPLIED_MIPS:
            return record.supplied_mips[(usz)mip * record.desc.layers + plane].bytes;

        case EMPTY:
            unreachable();
    }
}
