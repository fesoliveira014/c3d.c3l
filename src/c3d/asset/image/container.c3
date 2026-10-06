module c3d::asset::image;

import c3d;
import c3d::asset;
import c3d::material;
import std::core::bitorder;

const char[4] DDS_MAGIC @local = { 'D', 'D', 'S', ' ' };

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
}

<*
 Parse a DDS container into a 2D supplied-mip view.
 Borrows bytes; the view is invalid after they are freed.
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

fn uint read_u32(char[] bytes, usz offset) @private {
    return bitorder::read(bytes[offset:uint::size], UIntLE);
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
    usz next_offset = layout.data_offset;
    foreach (uint mip, &span : spans) {
        usz tight = material::texture_mip_bytes(desc, mip) ?? c3d::ASSET_FORMAT_ERROR~!;
        if (layout.contiguous) *span = { .offset = next_offset, .length = tight };
        if (span.length != tight) return c3d::ASSET_FORMAT_ERROR~;
        if (span.offset > bytes.len || tight > bytes.len - span.offset) return c3d::ASSET_FORMAT_ERROR~;
        next_offset = span.offset + tight;
    }
    desc.format = apply_color_space(desc.format, color_space)!;

    TextureContainerView view = { .desc = desc, .level_count = layout.level_count };
    foreach (uint mip, span : spans) {
        view.levels[mip] = { .mip = mip, .layer = 0, .bytes = bytes[span.offset:span.length] };
    }
    return view;
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
