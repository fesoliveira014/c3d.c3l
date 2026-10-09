module c3d::render;

import c3d;
import c3d::material;
import std::math;

const uint TEXEL_BLOCK_EXTENT @private = 4;
const uint CHARGE_BITS @local = ulong::size * 8;

<* Packed nonzero generated levels without a mip-zero snapshot. *>
struct GeneratedTextureLayout {
    usz byte_count;
    uint mip_count;
    uint layer_count;
    usz[material::TEXTURE_MIP_CAPACITY] offsets;
    ulong base_texels;
    ulong output_texels;
    uint passes;
}

<* One tightly packed mip band confined to a layer and slice. *>
struct TextureBand {
    uint mip;
    uint layer;
    uint x;
    uint y;
    uint z;
    uint width;
    uint height;
    uint depth;
    uint block_rows;
    usz row_bytes;
    usz byte_count;
    usz source_offset;
    usz layer_bytes;
    usz alignment;
}

<*
 Plan one band without borrowing its source.
 @param first_block_row : "Row index in format blocks."
 @param block_rows : "Number of format block rows."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
*>
fn TextureBand? texture_band(
    material::TextureDesc desc,
    uint mip,
    uint layer,
    uint slice,
    uint first_block_row,
    uint block_rows,
) {
    check_texture_band_description(desc)!;

    uint mip_count = desc.generate_mips ? material::texture_mip_count(desc.width, desc.height) : desc.mip_levels;

    if (mip >= mip_count || layer >= desc.layers || !block_rows) return c3d::INVALID_ARGUMENT~;

    uint width = material::texture_mip_extent(desc.width, mip);
    uint height = material::texture_mip_extent(desc.height, mip);
    uint depth = desc.depth ? material::texture_mip_extent(desc.depth, mip) : 1;

    if (slice >= depth) return c3d::INVALID_ARGUMENT~;

    uint block_extent = material::texture_is_compressed(desc.format) ? TEXEL_BLOCK_EXTENT : 1;
    usz block_bytes = material::texture_block_bytes(desc.format);
    usz row_blocks = ((usz)width + block_extent - 1) / block_extent;
    uint rows = (uint)(((usz)height + block_extent - 1) / block_extent);

    if (first_block_row >= rows || block_rows > rows - first_block_row) return c3d::INVALID_ARGUMENT~;

    if (row_blocks > (usz)sz::max / block_bytes / rows / depth / desc.layers) {
        return c3d::INVALID_ARGUMENT~;
    }

    usz row_bytes = row_blocks * block_bytes;
    usz layer_bytes = row_bytes * rows * depth;
    uint y = first_block_row * block_extent;

    return {
        .mip = mip, .layer = layer, .y = y, .z = slice,
        .width = width, .height = (uint)math::min((usz)(height - y), (usz)block_rows * block_extent), .depth = 1,
        .block_rows = block_rows, .row_bytes = row_bytes, .byte_count = row_bytes * block_rows,
        .source_offset = (usz)layer * layer_bytes + ((usz)slice * rows + first_block_row) * row_bytes,
        .layer_bytes = layer_bytes, .alignment = math::max((usz)uint::size, block_bytes),
    };
}

<*
 Plan generated storage without copying source texels.
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
*>
fn GeneratedTextureLayout? generated_texture_mip_layout(material::TextureDesc desc) {
    check_texture_band_description(desc)!;

    if (desc.depth || material::texture_is_compressed(desc.format)
      || (desc.format == R16_UINT && desc.generate_mips)) return c3d::UNSUPPORTED~;

    if (desc.mip_levels != 1) return c3d::INVALID_ARGUMENT~;

    usz texel_bytes = material::texture_block_bytes(desc.format);
    ulong layer_texels = (ulong)desc.width * desc.height;

    if (layer_texels > (ulong)sz::max / texel_bytes / desc.layers) return c3d::INVALID_ARGUMENT~;

    GeneratedTextureLayout layout = {
        .mip_count = desc.generate_mips ? material::texture_mip_count(desc.width, desc.height) - 1 : 0,
        .layer_count = desc.layers,
        .base_texels = layer_texels * desc.layers,
        .passes = texture_generation_passes(desc),
    };

    for (uint index = 0; index < layout.mip_count; index++) {
        uint mip = index + 1;
        ulong texels = (ulong)material::texture_mip_extent(desc.width, mip)
          * material::texture_mip_extent(desc.height, mip) * desc.layers;

        if (texels > ((ulong)sz::max - layout.byte_count) / texel_bytes) return c3d::INVALID_ARGUMENT~;

        layout.offsets[index] = layout.byte_count;
        layout.byte_count += (usz)texels * texel_bytes;
        layout.output_texels += texels;
    }

    if (layout.output_texels > ulong::max / layout.passes || layout.base_texels > ulong::max / layout.passes) {
        return c3d::INVALID_ARGUMENT~;
    }

    return layout;
}

<*
 Charge completed output in mip-zero-equivalent texels.
 @require output_total > 0, output_done <= output_total
 @pure
*>
fn ulong generated_mip_charge(ulong base_texels, ulong output_done, ulong output_total) {
    ulong quotient = base_texels / output_total;
    ulong remainder = base_texels % output_total;
    ulong whole = quotient * output_done;
    ulong fractional;
    ulong accumulated;

    for (uint bit = CHARGE_BITS; bit > 0; bit--) {
        fractional *= 2;

        if (accumulated >= output_total - accumulated) {
            accumulated -= output_total - accumulated;
            fractional++;
        } else {
            accumulated *= 2;
        }

        if (output_done & ((ulong)1 << (bit - 1))) {
            if (accumulated >= output_total - remainder) {
                accumulated -= output_total - remainder;
                fractional++;
            } else {
                accumulated += remainder;
            }
        }
    }

    return whole + fractional;
}

fn void? check_texture_band_description(material::TextureDesc desc) @local {
    asset::check_texture_semantics(desc)!;

    if (!desc.width || !desc.height || !desc.layers || !desc.mip_levels) return c3d::INVALID_ARGUMENT~;

    if (desc.depth) {
        if (desc.generate_mips || desc.layers != 1 || desc.is_cube || desc.mip_levels != 1) {
            return c3d::UNSUPPORTED~;
        }

        if (desc.format != RGBA8_UNORM && desc.format != RGBA8_SRGB) return c3d::UNSUPPORTED~;
    } else {
        if (desc.is_cube) {
            if (desc.layers != material::CUBE_FACE_COUNT || desc.width != desc.height) return c3d::INVALID_ARGUMENT~;
            if (material::texture_is_compressed(desc.format)) return c3d::UNSUPPORTED~;
        } else if (desc.layers != 1) {
            return c3d::UNSUPPORTED~;
        }

        if (desc.generate_mips) {
            if (desc.mip_levels != 1) return c3d::INVALID_ARGUMENT~;
            if (desc.format == R16_UINT || material::texture_is_compressed(desc.format)) return c3d::UNSUPPORTED~;
        } else if (desc.mip_levels > material::texture_mip_count(desc.width, desc.height)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}
