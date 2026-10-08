module c3d::asset::image;

import c3d;
import c3d::asset;
import c3d::material;
import std::core::bitorder;

const char[4] DDS_MAGIC @local = { 'D', 'D', 'S', ' ' };
const char[12] KTX1_IDENTIFIER @local = { 0xAB, 'K', 'T', 'X', ' ', '1', '1', 0xBB, 0x0D, 0x0A, 0x1A, 0x0A };
const char[12] KTX2_IDENTIFIER @local = { 0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, 0x0D, 0x0A, 0x1A, 0x0A };
const usz BC1_BLOCK_BYTES @local = 8;
const usz BC1_COLOR1_OFFSET @local = 2;
const usz BC1_INDICES_OFFSET @local = 4;
const uint BC1_INDEX_LOW_BITS @local = 0x55555555; // low bit of each of the sixteen 2-bit texel indices

<*
 Color interpretation requested for a container's texels.
*>
enum ColorSpace {
    FROM_FILE,
    SRGB,
    LINEAR,
}

<*
 2D texture description and level slices parsed from a container.
 Borrows the parsed bytes and scratch; invalid after either is freed.
*>
struct TextureContainerView {
    TextureDesc desc;
    uint level_count;
    TextureMipData[material::TEXTURE_MIP_CAPACITY] levels;
}

struct LevelSpan @private {
    usz offset;
    usz length;
}

struct ContainerLayout @private {
    TextureDesc desc;
    uint level_count;
    LevelSpan[material::TEXTURE_MIP_CAPACITY] spans; // filled by the reader unless contiguous
    bool contiguous;                                 // levels follow data_offset back to back, base first
    usz data_offset;
    usz row_alignment;                               // stored uncompressed rows round up to this; 1 is tight
    bool opaque_bc1;                                 // BC1 without alpha; BC1_RGBA only if no block reads alpha
    bool ends_at_last_level;                         // no byte may follow the last level
}

<*
 Parse a DDS, KTX1 or KTX2 container into a 2D supplied-mip view.
 Borrows bytes and scratch; the view is invalid after either is freed.
 @param scratch : "Holds de-padded KTX1 levels only."
 @param [in] bytes : "Whole container; never written."
 @param color_space : "An explicit choice overrides the file."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
*>
fn TextureContainerView? parse_texture_container(Allocator scratch, char[] bytes, ColorSpace color_space = FROM_FILE) {
    ContainerLayout layout = read_container_layout(bytes)!;
    return finish_container(
        scratch:     scratch,
        bytes:       bytes,
        layout:      &layout,
        color_space: color_space,
    );
}

<*
 Add a DDS, KTX1 or KTX2 texture from memory, copying its levels.
 @param [&inout] assets : "Owns one source allocation on success."
 @param [in] bytes : "Borrowed for the call."
 @param color_space : "An explicit choice overrides the file."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require assets.allocator != tmem
*>
fn TextureId? add_texture_container(
    AssetStore* assets,
    char[] bytes,
    ColorSpace color_space = FROM_FILE,
    String key = "",
) {
    TextureId texture;
    @pool() {
        TextureContainerView container = parse_texture_container(tmem, bytes, color_space)!;
        if (container.desc.generate_mips) {
            texture = assets.add_texture(container.desc, container.levels[0].bytes, key)!;
        } else {
            texture = assets.add_texture_mips(container.desc, container.levels[:container.level_count], key)!;
        }
    };
    return texture;
}

<*
 Read a DDS, KTX1 or KTX2 file into the store's texture pool.
 @param [&inout] assets : "Owns one source allocation on success."
 @param color_space : "An explicit choice overrides the file."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @return? c3d::CAPACITY_EXCEEDED
 @require path.len > 0, assets.allocator != tmem
*>
fn TextureId? load_texture_container(
    AssetStore* assets,
    String path,
    ColorSpace color_space = FROM_FILE,
    String key = "",
) {
    char[] bytes = assets.read_file(mem, path)!;
    defer free(bytes.ptr);

    return add_texture_container(
        assets:      assets,
        bytes:       bytes,
        color_space: color_space,
        key:         key,
    );
}

fn uint read_u32(char[] bytes, usz offset) @private {
    return bitorder::read(bytes[offset:uint::size], UIntLE);
}

fn usz read_u64(char[] bytes, usz offset) @private {
    return (usz)bitorder::read(bytes[offset:ulong::size], ULongLE);
}

fn usz align_up(usz value, usz alignment) @private {
    return (value + alignment - 1) / alignment * alignment;
}

fn TextureDesc container_desc(
    uint width,
    uint height,
    PixelFormat format,
    uint level_count,
) @private {
    TextureDesc desc = material::texture_2d_desc(
        width:      width,
        height:     height,
        format:     format,
        debug_name: "texture_container",
    );
    desc.generate_mips = false;
    desc.mip_levels = level_count;
    return desc;
}

fn PixelFormat linear_twin(PixelFormat format) @private {
    switch (format) {
        case RGBA8_SRGB: return RGBA8_UNORM;
        case BC1_RGBA_SRGB: return BC1_RGBA_UNORM;
        case BC3_SRGB: return BC3_UNORM;
        case BC7_SRGB: return BC7_UNORM;
        case RGBA8_UNORM:
        case RGBA16_FLOAT:
        case RGBA32_FLOAT:
        case R16_UINT:
        case BC1_RGBA_UNORM:
        case BC3_UNORM:
        case BC4_UNORM:
        case BC5_UNORM:
        case BC6H_UFLOAT:
        case BC7_UNORM: return format;
    }
}

fn ContainerLayout? read_container_layout(char[] bytes) @local {
    if (starts_with(bytes, DDS_MAGIC[..])) return parse_dds_layout(bytes);
    if (starts_with(bytes, KTX1_IDENTIFIER[..])) return parse_ktx1_layout(bytes);
    if (starts_with(bytes, KTX2_IDENTIFIER[..])) return parse_ktx2_layout(bytes);
    return c3d::ASSET_FORMAT_ERROR~;
}

fn bool starts_with(char[] bytes, char[] prefix) @local {
    return bytes.len >= prefix.len && bytes[:prefix.len] == prefix;
}

fn TextureContainerView? finish_container(
    Allocator scratch,
    char[] bytes,
    ContainerLayout* layout,
    ColorSpace color_space,
) @local {
    TextureDesc desc = layout.desc;
    if (!desc.width || !desc.height) return c3d::ASSET_FORMAT_ERROR~;
    if (layout.level_count > material::texture_mip_count(desc.width, desc.height)) return c3d::ASSET_FORMAT_ERROR~;

    LevelSpan[] spans = layout.spans[:layout.level_count];
    usz[material::TEXTURE_MIP_CAPACITY] tight_bytes;
    usz next_offset = layout.data_offset;
    usz end;
    usz repacked_bytes;
    foreach (uint mip, &span : spans) {
        usz tight = material::texture_mip_bytes(desc, mip) ?? c3d::ASSET_FORMAT_ERROR~!;
        usz stored = stored_level_bytes(
            desc:          desc,
            mip:           mip,
            tight:         tight,
            row_alignment: layout.row_alignment,
        );
        if (layout.contiguous) *span = { .offset = next_offset, .length = stored };
        if (span.length != stored) return c3d::ASSET_FORMAT_ERROR~;
        if (span.offset > bytes.len || stored > bytes.len - span.offset) return c3d::ASSET_FORMAT_ERROR~;
        next_offset = span.offset + stored;
        if (next_offset > end) end = next_offset;
        if (stored != tight) repacked_bytes += tight;
        tight_bytes[mip] = tight;
    }
    if (spans_overlap(spans)) return c3d::ASSET_FORMAT_ERROR~;
    if (layout.ends_at_last_level && end != bytes.len) return c3d::ASSET_FORMAT_ERROR~;
    if (layout.opaque_bc1 && reads_bc1_alpha(bytes, spans)) return c3d::UNSUPPORTED~;
    desc.format = apply_color_space(desc.format, color_space)!;

    TextureContainerView view = { .desc = desc, .level_count = layout.level_count };
    char[] repacked = repacked_bytes > 0 ? alloc::new_array(scratch, char, (sz)repacked_bytes) : {};
    usz repacked_offset;
    foreach (uint mip, span : spans) {
        char[] level = bytes[span.offset:span.length];
        if (level.len != tight_bytes[mip]) {
            char[] packed = repacked[repacked_offset:tight_bytes[mip]];
            remove_row_padding(packed, level, material::texture_mip_extent(desc.height, mip));
            repacked_offset += packed.len;
            level = packed;
        }
        view.levels[mip] = { .mip = mip, .layer = 0, .bytes = level };
    }
    return view;
}

fn usz stored_level_bytes(
    TextureDesc desc,
    uint mip,
    usz tight,
    usz row_alignment,
) @local {
    if (row_alignment == 1 || material::texture_is_compressed(desc.format)) return tight;
    usz row_bytes = (usz)material::texture_mip_extent(desc.width, mip) * material::texture_block_bytes(desc.format);
    return align_up(row_bytes, row_alignment) * material::texture_mip_extent(desc.height, mip);
}

fn void remove_row_padding(char[] packed, char[] stored, uint rows) @local {
    usz row_bytes = packed.len / rows;
    usz stride = stored.len / rows;
    for (usz row = 0; row < rows; row++) {
        mem::copy(packed.ptr + row * row_bytes, stored.ptr + row * stride, (sz)row_bytes);
    }
}

fn bool spans_overlap(LevelSpan[] spans) @local {
    foreach (usz index, first : spans) {
        foreach (second : spans[index + 1..]) {
            if (first.offset < second.offset + second.length && second.offset < first.offset + first.length) {
                return true;
            }
        }
    }
    return false;
}

fn bool reads_bc1_alpha(char[] bytes, LevelSpan[] spans) @local {
    foreach (span : spans) {
        for (usz block = span.offset; block < span.offset + span.length; block += BC1_BLOCK_BYTES) {
            ushort color0 = bitorder::read(bytes[block:ushort::size], UShortLE);
            ushort color1 = bitorder::read(bytes[block + BC1_COLOR1_OFFSET:ushort::size], UShortLE);
            uint indices = bitorder::read(bytes[block + BC1_INDICES_OFFSET:uint::size], UIntLE);
            // Index 3 of a three-color block is transparent in BC1_RGBA and opaque black in BC1_RGB.
            if (color0 <= color1 && (indices & (indices >> 1) & BC1_INDEX_LOW_BITS) != 0) return true;
        }
    }
    return false;
}

fn PixelFormat? apply_color_space(PixelFormat format, ColorSpace color_space) @local {
    switch (color_space) {
        case FROM_FILE: return format;
        case SRGB: return srgb_twin(format);
        case LINEAR: return linear_twin(format);
    }
}

fn PixelFormat? srgb_twin(PixelFormat format) @local {
    switch (format) {
        case RGBA8_UNORM:
        case RGBA8_SRGB: return RGBA8_SRGB;
        case BC1_RGBA_UNORM:
        case BC1_RGBA_SRGB: return BC1_RGBA_SRGB;
        case BC3_UNORM:
        case BC3_SRGB: return BC3_SRGB;
        case BC7_UNORM:
        case BC7_SRGB: return BC7_SRGB;
        case RGBA16_FLOAT:
        case RGBA32_FLOAT:
        case R16_UINT:
        case BC4_UNORM:
        case BC5_UNORM:
        case BC6H_UFLOAT: return c3d::INVALID_ARGUMENT~;
    }
}
