module c3d::asset::image;

import c3d;
import c3d::material;

const usz KTX1_HEADER_END @local = 64;
const usz KTX1_ENDIANNESS_OFFSET @local = 12;
const usz KTX1_GL_TYPE_OFFSET @local = 16;
const usz KTX1_GL_FORMAT_OFFSET @local = 24;
const usz KTX1_INTERNAL_FORMAT_OFFSET @local = 28;
const usz KTX1_WIDTH_OFFSET @local = 36;
const usz KTX1_HEIGHT_OFFSET @local = 40;
const usz KTX1_DEPTH_OFFSET @local = 44;
const usz KTX1_ARRAY_ELEMENTS_OFFSET @local = 48;
const usz KTX1_FACES_OFFSET @local = 52;
const usz KTX1_MIP_COUNT_OFFSET @local = 56;
const usz KTX1_KEY_VALUE_BYTES_OFFSET @local = 60;
const uint KTX1_ENDIAN_NATIVE @local = 0x04030201;
const uint KTX1_ENDIAN_SWAPPED @local = 0x01020304;
const usz KTX1_ROW_ALIGNMENT @local = 4; // GL_UNPACK_ALIGNMENT of uncompressed rows
const usz KTX1_MIP_ALIGNMENT @local = 4;
const usz KTX2_HEADER_END @local = 80;
const usz KTX2_VK_FORMAT_OFFSET @local = 12;
const usz KTX2_TYPE_SIZE_OFFSET @local = 16;
const usz KTX2_WIDTH_OFFSET @local = 20;
const usz KTX2_HEIGHT_OFFSET @local = 24;
const usz KTX2_DEPTH_OFFSET @local = 28;
const usz KTX2_LAYERS_OFFSET @local = 32;
const usz KTX2_FACES_OFFSET @local = 36;
const usz KTX2_LEVELS_OFFSET @local = 40;
const usz KTX2_SCHEME_OFFSET @local = 44;
const usz KTX2_DFD_OFFSET_OFFSET @local = 48;
const usz KTX2_DFD_LENGTH_OFFSET @local = 52;
const usz KTX2_KVD_OFFSET_OFFSET @local = 56;
const usz KTX2_KVD_LENGTH_OFFSET @local = 60;
const usz KTX2_SGD_LENGTH_OFFSET @local = 72;
const usz KTX2_LEVEL_ENTRY_BYTES @local = 24;
const usz KTX2_LEVEL_LENGTH_OFFSET @local = 8;
const usz KTX2_LEVEL_UNCOMPRESSED_OFFSET @local = 16;
const usz KTX2_LEVEL_ALIGNMENT @local = 4; // levels align to lcm(texel block bytes, 4)
const usz DFD_MINIMUM_BYTES @local = 28; // dfdTotalSize plus the basic block header
const usz DFD_TRANSFER_OFFSET @local = 14;
const usz DFD_FLAGS_OFFSET @local = 15;
const char KHR_DF_TRANSFER_SRGB @local = 2;
const char KHR_DF_FLAG_ALPHA_PREMULTIPLIED @local = 1;
const String KTX1_ORIENTATION @local = "S=r,T=d";
const String KTX2_ORIENTATION @local = "rd";
const String IDENTITY_SWIZZLE @local = "rgba";

const uint GL_RGBA @local = 0x1908;
const uint GL_RED_INTEGER @local = 0x8D94;
const uint GL_UNSIGNED_BYTE @local = 0x1401;
const uint GL_UNSIGNED_SHORT @local = 0x1403;
const uint GL_HALF_FLOAT @local = 0x140B;
const uint GL_FLOAT @local = 0x1406;
const uint GL_RGBA8 @local = 0x8058;
const uint GL_SRGB8_ALPHA8 @local = 0x8C43;
const uint GL_RGBA16F @local = 0x881A;
const uint GL_RGBA32F @local = 0x8814;
const uint GL_R16UI @local = 0x8234;
const uint GL_COMPRESSED_RGB_S3TC_DXT1 @local = 0x83F0;
const uint GL_COMPRESSED_SRGB_S3TC_DXT1 @local = 0x8C4C;
const uint GL_COMPRESSED_RGBA_S3TC_DXT1 @local = 0x83F1;
const uint GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT1 @local = 0x8C4D;
const uint GL_COMPRESSED_RGBA_S3TC_DXT5 @local = 0x83F3;
const uint GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT5 @local = 0x8C4F;
const uint GL_COMPRESSED_RED_RGTC1 @local = 0x8DBB;
const uint GL_COMPRESSED_RG_RGTC2 @local = 0x8DBD;
const uint GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT @local = 0x8E8F;
const uint GL_COMPRESSED_RGBA_BPTC_UNORM @local = 0x8E8C;
const uint GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM @local = 0x8E8D;
const uint VK_FORMAT_R8G8B8A8_UNORM @local = 37;
const uint VK_FORMAT_R8G8B8A8_SRGB @local = 43;
const uint VK_FORMAT_R16_UINT @local = 74;
const uint VK_FORMAT_R16G16B16A16_SFLOAT @local = 97;
const uint VK_FORMAT_R32G32B32A32_SFLOAT @local = 109;
const uint VK_FORMAT_BC1_RGB_UNORM_BLOCK @local = 131;
const uint VK_FORMAT_BC1_RGB_SRGB_BLOCK @local = 132;
const uint VK_FORMAT_BC1_RGBA_UNORM_BLOCK @local = 133;
const uint VK_FORMAT_BC1_RGBA_SRGB_BLOCK @local = 134;
const uint VK_FORMAT_BC3_UNORM_BLOCK @local = 137;
const uint VK_FORMAT_BC3_SRGB_BLOCK @local = 138;
const uint VK_FORMAT_BC4_UNORM_BLOCK @local = 139;
const uint VK_FORMAT_BC5_UNORM_BLOCK @local = 141;
const uint VK_FORMAT_BC6H_UFLOAT_BLOCK @local = 143;
const uint VK_FORMAT_BC7_UNORM_BLOCK @local = 145;
const uint VK_FORMAT_BC7_SRGB_BLOCK @local = 146;

struct GlFormat @local {
    uint internal_format;
    uint type;            // 0 for compressed formats
    uint format;          // 0 for compressed formats
    PixelFormat pixel_format;
    bool opaque_bc1;
}

struct VkFormat @local {
    uint vk_format;
    uint type_size;
    PixelFormat pixel_format;
    bool opaque_bc1;
}

const GlFormat[16] GL_FORMATS @local = {
    { .internal_format = GL_RGBA8, .type = GL_UNSIGNED_BYTE, .format = GL_RGBA, .pixel_format = RGBA8_UNORM },
    { .internal_format = GL_SRGB8_ALPHA8, .type = GL_UNSIGNED_BYTE, .format = GL_RGBA, .pixel_format = RGBA8_SRGB },
    { .internal_format = GL_RGBA16F, .type = GL_HALF_FLOAT, .format = GL_RGBA, .pixel_format = RGBA16_FLOAT },
    { .internal_format = GL_RGBA32F, .type = GL_FLOAT, .format = GL_RGBA, .pixel_format = RGBA32_FLOAT },
    { .internal_format = GL_R16UI, .type = GL_UNSIGNED_SHORT, .format = GL_RED_INTEGER, .pixel_format = R16_UINT },
    { .internal_format = GL_COMPRESSED_RGB_S3TC_DXT1, .pixel_format = BC1_RGBA_UNORM, .opaque_bc1 = true },
    { .internal_format = GL_COMPRESSED_SRGB_S3TC_DXT1, .pixel_format = BC1_RGBA_SRGB, .opaque_bc1 = true },
    { .internal_format = GL_COMPRESSED_RGBA_S3TC_DXT1, .pixel_format = BC1_RGBA_UNORM },
    { .internal_format = GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT1, .pixel_format = BC1_RGBA_SRGB },
    { .internal_format = GL_COMPRESSED_RGBA_S3TC_DXT5, .pixel_format = BC3_UNORM },
    { .internal_format = GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT5, .pixel_format = BC3_SRGB },
    { .internal_format = GL_COMPRESSED_RED_RGTC1, .pixel_format = BC4_UNORM },
    { .internal_format = GL_COMPRESSED_RG_RGTC2, .pixel_format = BC5_UNORM },
    { .internal_format = GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT, .pixel_format = BC6H_UFLOAT },
    { .internal_format = GL_COMPRESSED_RGBA_BPTC_UNORM, .pixel_format = BC7_UNORM },
    { .internal_format = GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM, .pixel_format = BC7_SRGB },
};

const VkFormat[16] VK_FORMATS @local = {
    { .vk_format = VK_FORMAT_R8G8B8A8_UNORM, .type_size = 1, .pixel_format = RGBA8_UNORM },
    { .vk_format = VK_FORMAT_R8G8B8A8_SRGB, .type_size = 1, .pixel_format = RGBA8_SRGB },
    { .vk_format = VK_FORMAT_R16G16B16A16_SFLOAT, .type_size = 2, .pixel_format = RGBA16_FLOAT },
    { .vk_format = VK_FORMAT_R32G32B32A32_SFLOAT, .type_size = 4, .pixel_format = RGBA32_FLOAT },
    { .vk_format = VK_FORMAT_R16_UINT, .type_size = 2, .pixel_format = R16_UINT },
    { .vk_format = VK_FORMAT_BC1_RGB_UNORM_BLOCK, .type_size = 1, .pixel_format = BC1_RGBA_UNORM, .opaque_bc1 = true },
    { .vk_format = VK_FORMAT_BC1_RGB_SRGB_BLOCK, .type_size = 1, .pixel_format = BC1_RGBA_SRGB, .opaque_bc1 = true },
    { .vk_format = VK_FORMAT_BC1_RGBA_UNORM_BLOCK, .type_size = 1, .pixel_format = BC1_RGBA_UNORM },
    { .vk_format = VK_FORMAT_BC1_RGBA_SRGB_BLOCK, .type_size = 1, .pixel_format = BC1_RGBA_SRGB },
    { .vk_format = VK_FORMAT_BC3_UNORM_BLOCK, .type_size = 1, .pixel_format = BC3_UNORM },
    { .vk_format = VK_FORMAT_BC3_SRGB_BLOCK, .type_size = 1, .pixel_format = BC3_SRGB },
    { .vk_format = VK_FORMAT_BC4_UNORM_BLOCK, .type_size = 1, .pixel_format = BC4_UNORM },
    { .vk_format = VK_FORMAT_BC5_UNORM_BLOCK, .type_size = 1, .pixel_format = BC5_UNORM },
    { .vk_format = VK_FORMAT_BC6H_UFLOAT_BLOCK, .type_size = 1, .pixel_format = BC6H_UFLOAT },
    { .vk_format = VK_FORMAT_BC7_UNORM_BLOCK, .type_size = 1, .pixel_format = BC7_UNORM },
    { .vk_format = VK_FORMAT_BC7_SRGB_BLOCK, .type_size = 1, .pixel_format = BC7_SRGB },
};

fn ContainerLayout? parse_ktx1_layout(char[] bytes) @private {
    if (bytes.len < KTX1_HEADER_END) return c3d::ASSET_FORMAT_ERROR~;
    uint endianness = read_u32(bytes, KTX1_ENDIANNESS_OFFSET);
    if (endianness == KTX1_ENDIAN_SWAPPED) return c3d::UNSUPPORTED~;
    if (endianness != KTX1_ENDIAN_NATIVE) return c3d::ASSET_FORMAT_ERROR~;
    usz key_value_bytes = read_u32(bytes, KTX1_KEY_VALUE_BYTES_OFFSET);
    if (key_value_bytes > bytes.len - KTX1_HEADER_END) return c3d::ASSET_FORMAT_ERROR~;

    GlFormat format = gl_format(read_u32(bytes, KTX1_INTERNAL_FORMAT_OFFSET))!;
    if (read_u32(bytes, KTX1_GL_TYPE_OFFSET) != format.type) return c3d::ASSET_FORMAT_ERROR~;
    if (read_u32(bytes, KTX1_GL_FORMAT_OFFSET) != format.format) return c3d::ASSET_FORMAT_ERROR~;
    if (read_u32(bytes, KTX1_HEIGHT_OFFSET) == 0 || read_u32(bytes, KTX1_DEPTH_OFFSET) != 0) return c3d::UNSUPPORTED~;
    if (read_u32(bytes, KTX1_ARRAY_ELEMENTS_OFFSET) != 0) return c3d::UNSUPPORTED~;
    uint faces = read_u32(bytes, KTX1_FACES_OFFSET);
    if (faces == 0) return c3d::ASSET_FORMAT_ERROR~;
    if (faces > 1) return c3d::UNSUPPORTED~;

    uint mip_count = read_u32(bytes, KTX1_MIP_COUNT_OFFSET);
    bool generate = mip_count == 0;
    bool compressed = material::texture_is_compressed(format.pixel_format);
    if (generate && (compressed || format.pixel_format == R16_UINT)) return c3d::UNSUPPORTED~;
    uint level_count = generate ? 1 : mip_count;
    if (level_count > material::TEXTURE_MIP_CAPACITY) return c3d::ASSET_FORMAT_ERROR~;
    check_metadata(bytes[KTX1_HEADER_END:key_value_bytes], KTX1_ORIENTATION)!;

    ContainerLayout layout = {
        .desc = container_desc(
            width:       read_u32(bytes, KTX1_WIDTH_OFFSET),
            height:      read_u32(bytes, KTX1_HEIGHT_OFFSET),
            format:      format.pixel_format,
            level_count: level_count,
        ),
        .level_count = level_count,
        .row_alignment = compressed ? 1 : KTX1_ROW_ALIGNMENT,
        .opaque_bc1 = format.opaque_bc1,
    };
    layout.desc.generate_mips = generate;
    usz offset = KTX1_HEADER_END + key_value_bytes;
    for (uint mip = 0; mip < level_count; mip++) {
        if (offset > bytes.len || bytes.len - offset < uint::size) return c3d::ASSET_FORMAT_ERROR~;
        usz image_size = read_u32(bytes, offset);
        layout.spans[mip] = { .offset = offset + uint::size, .length = image_size };
        offset += uint::size + align_up(image_size, KTX1_MIP_ALIGNMENT);
    }
    return layout;
}

fn ContainerLayout? parse_ktx2_layout(char[] bytes) @private {
    if (bytes.len < KTX2_HEADER_END) return c3d::ASSET_FORMAT_ERROR~;
    if (read_u32(bytes, KTX2_SCHEME_OFFSET) != 0) return c3d::UNSUPPORTED~;
    VkFormat format = vk_format(read_u32(bytes, KTX2_VK_FORMAT_OFFSET))!;
    if (read_u32(bytes, KTX2_HEIGHT_OFFSET) == 0 || read_u32(bytes, KTX2_DEPTH_OFFSET) != 0) return c3d::UNSUPPORTED~;
    if (read_u32(bytes, KTX2_LAYERS_OFFSET) != 0) return c3d::UNSUPPORTED~;
    uint faces = read_u32(bytes, KTX2_FACES_OFFSET);
    if (faces == material::CUBE_FACE_COUNT) return c3d::UNSUPPORTED~;
    if (faces != 1) return c3d::ASSET_FORMAT_ERROR~;

    uint level_count = read_u32(bytes, KTX2_LEVELS_OFFSET);
    bool generate = level_count == 0;
    bool compressed = material::texture_is_compressed(format.pixel_format);
    if (generate && compressed) return c3d::ASSET_FORMAT_ERROR~;
    if (generate && format.pixel_format == R16_UINT) return c3d::UNSUPPORTED~;
    if (generate) level_count = 1;
    if (level_count > material::TEXTURE_MIP_CAPACITY) return c3d::ASSET_FORMAT_ERROR~;
    if (bytes.len - KTX2_HEADER_END < level_count * KTX2_LEVEL_ENTRY_BYTES) return c3d::ASSET_FORMAT_ERROR~;
    if (read_u32(bytes, KTX2_TYPE_SIZE_OFFSET) != format.type_size) return c3d::ASSET_FORMAT_ERROR~;
    if (read_u64(bytes, KTX2_SGD_LENGTH_OFFSET) != 0) return c3d::ASSET_FORMAT_ERROR~;
    check_descriptor(bytes, format.pixel_format)!;
    check_metadata(region(bytes, KTX2_KVD_OFFSET_OFFSET, KTX2_KVD_LENGTH_OFFSET)!, KTX2_ORIENTATION)!;

    ContainerLayout layout = {
        .desc = container_desc(
            width:       read_u32(bytes, KTX2_WIDTH_OFFSET),
            height:      read_u32(bytes, KTX2_HEIGHT_OFFSET),
            format:      format.pixel_format,
            level_count: level_count,
        ),
        .level_count = level_count,
        .row_alignment = 1,
        .opaque_bc1 = format.opaque_bc1,
        .ends_at_last_level = true,
    };
    layout.desc.generate_mips = generate;
    usz block_bytes = material::texture_block_bytes(format.pixel_format);
    usz alignment = block_bytes % KTX2_LEVEL_ALIGNMENT == 0 ? block_bytes : KTX2_LEVEL_ALIGNMENT;
    for (uint mip = 0; mip < level_count; mip++) {
        usz entry = KTX2_HEADER_END + mip * KTX2_LEVEL_ENTRY_BYTES;
        usz offset = read_u64(bytes, entry);
        usz length = read_u64(bytes, entry + KTX2_LEVEL_LENGTH_OFFSET);
        if (length != read_u64(bytes, entry + KTX2_LEVEL_UNCOMPRESSED_OFFSET)) return c3d::ASSET_FORMAT_ERROR~;
        if (offset % alignment != 0) return c3d::ASSET_FORMAT_ERROR~;
        layout.spans[mip] = { .offset = offset, .length = length };
    }
    return layout;
}

fn GlFormat? gl_format(uint internal_format) @local {
    foreach (format : GL_FORMATS) {
        if (format.internal_format == internal_format) return format;
    }
    return c3d::UNSUPPORTED~;
}

fn VkFormat? vk_format(uint value) @local {
    foreach (format : VK_FORMATS) {
        if (format.vk_format == value) return format;
    }
    return c3d::UNSUPPORTED~;
}

fn char[]? region(char[] bytes, usz offset_field, usz length_field) @local {
    usz offset = read_u32(bytes, offset_field);
    usz length = read_u32(bytes, length_field);
    if (offset > bytes.len || length > bytes.len - offset) return c3d::ASSET_FORMAT_ERROR~;
    return bytes[offset:length];
}

fn void? check_descriptor(char[] bytes, PixelFormat format) @local {
    char[] descriptor = region(bytes, KTX2_DFD_OFFSET_OFFSET, KTX2_DFD_LENGTH_OFFSET)!;
    if (descriptor.len < DFD_MINIMUM_BYTES || read_u32(descriptor, 0) != descriptor.len) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    bool srgb_format = linear_twin(format) != format;
    bool srgb_transfer = descriptor[DFD_TRANSFER_OFFSET] == KHR_DF_TRANSFER_SRGB;
    if (srgb_format != srgb_transfer) return c3d::ASSET_FORMAT_ERROR~;
    if (descriptor[DFD_FLAGS_OFFSET] & KHR_DF_FLAG_ALPHA_PREMULTIPLIED) return c3d::UNSUPPORTED~;
}

fn void? check_metadata(char[] key_values, String orientation) @local {
    usz offset;
    while (offset < key_values.len) {
        if (key_values.len - offset < uint::size) return c3d::ASSET_FORMAT_ERROR~;
        usz entry_length = read_u32(key_values, offset);
        offset += uint::size;
        if (entry_length > key_values.len - offset) return c3d::ASSET_FORMAT_ERROR~;
        String entry = (String)key_values[offset:entry_length];
        offset += align_up(entry_length, uint::size);

        sz terminator = entry.index_of_char('\0') ?? c3d::ASSET_FORMAT_ERROR~!;
        String key = entry[:terminator];
        String value = entry[terminator + 1..];
        if (value.len > 0 && value[^1] == '\0') value = value[:^1];
        if (key == "KTXorientation" && value != orientation) return c3d::UNSUPPORTED~;
        if (key == "KTXswizzle" && value != IDENTITY_SWIZZLE) return c3d::UNSUPPORTED~;
    }
}
