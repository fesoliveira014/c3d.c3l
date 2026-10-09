module c3d::test::texture_containers;

import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::material;
import std::core::bitorder;
import std::io::path;

const char[*] DX10_RGBA8_SRGB @local = $embed("../fixtures/texture/dx10_rgba8_srgb_5x3.dds");
const char[*] DX10_BC7_SRGB @local = $embed("../fixtures/texture/dx10_bc7_srgb_5x3.dds");
const char[*] DX10_FORMAT16 @local = $embed("../fixtures/texture/dx10_format16.dds");
const char[*] LEGACY_DXT1 @local = $embed("../fixtures/texture/legacy_dxt1_6x6.dds");
const char[*] LEGACY_RGBA16F @local = $embed("../fixtures/texture/legacy_rgba16f_4x4.dds");
const char[*] LEGACY_RGBA8 @local = $embed("../fixtures/texture/legacy_rgba8_2x2.dds");
const char[*] KTX1_R16 @local = $embed("../fixtures/texture/ktx1_r16_5x3.ktx");
const char[*] KTX1_BC1_SRGB @local = $embed("../fixtures/texture/ktx1_bc1_srgb_8x8.ktx");
const char[*] KTX1_GENERATE @local = $embed("../fixtures/texture/ktx1_rgba8_generate_2x2.ktx");
const char[*] KTX1_FORMAT16 @local = $embed("../fixtures/texture/ktx1_format16.ktx");
const char[*] KTX2_RGBA8_SRGB @local = $embed("../fixtures/texture/ktx2_rgba8_srgb_5x3.ktx2");
const char[*] KTX2_BC7_SRGB @local = $embed("../fixtures/texture/ktx2_bc7_srgb_5x3.ktx2");
const char[*] KTX2_BC5 @local = $embed("../fixtures/texture/ktx2_bc5_8x4.ktx2");
const char[*] KTX2_BC1_RGB_CLEAN @local = $embed("../fixtures/texture/ktx2_bc1_rgb_clean_4x4.ktx2");
const char[*] KTX2_BC1_RGB_PUNCH @local = $embed("../fixtures/texture/ktx2_bc1_rgb_punch_4x4.ktx2");
const char[*] KTX2_FORMAT16 @local = $embed("../fixtures/texture/ktx2_format16.ktx2");
const char[*] ORIENTATION_DDS @local = $embed("../fixtures/texture/orientation_4x4.dds");
const char[*] ORIENTATION_KTX1 @local = $embed("../fixtures/texture/orientation_4x4.ktx");
const char[*] ORIENTATION_KTX2 @local = $embed("../fixtures/texture/orientation_4x4.ktx2");
const uint MAXIMUM_EXTENT @local = uint::max;
const usz KTX2_LEVEL_INDEX @local = 80;
const usz KTX2_LEVEL_ENTRY_BYTES @local = 24;
const usz KTX2_DFD_OFFSET_FIELD @local = 48;
const usz KTX1_KEY_VALUE_BYTES_FIELD @local = 60;
const usz KTX1_HEADER_END @local = 64;
const char[*] REAL_SUPERCOMPRESSED @local =
  $embed("../fixtures/texture/gltf_sample_assets/FlightHelmet_Materials_LensesMat_Normal.ktx2");
const uint R16_MIP_STEP @local = 1000; // the fixture writer's texel value: 1000 * mip + row-major index

enum Field @local {
    DDS_FLAGS,
    DDS_HEIGHT,
    DDS_WIDTH,
    DDS_PITCH,
    DDS_DEPTH,
    DDS_MIP_COUNT,
    DDS_HEADER_SIZE,
    DDS_PIXEL_FORMAT_SIZE,
    DDS_PIXEL_FORMAT_FLAGS,
    DDS_FOUR_CC,
    DDS_RED_MASK,
    DDS_BLUE_MASK,
    DDS_ALPHA_MASK,
    DDS_CAPS,
    DDS_CAPS2,
    DX10_FORMAT,
    DX10_DIMENSION,
    DX10_MISC_FLAG,
    DX10_ARRAY_SIZE,
    DX10_MISC_FLAGS2,
    KTX1_ENDIANNESS,
    KTX1_GL_TYPE,
    KTX1_GL_FORMAT,
    KTX1_INTERNAL_FORMAT,
    KTX1_WIDTH,
    KTX1_HEIGHT,
    KTX1_DEPTH,
    KTX1_ARRAY_ELEMENTS,
    KTX1_FACES,
    KTX1_MIP_COUNT,
    KTX1_KEY_VALUE_BYTES,
    KTX2_VK_FORMAT,
    KTX2_TYPE_SIZE,
    KTX2_WIDTH,
    KTX2_HEIGHT,
    KTX2_DEPTH,
    KTX2_LAYERS,
    KTX2_FACES,
    KTX2_LEVEL_COUNT,
    KTX2_SCHEME,
    KTX2_DFD_LENGTH,
    KTX2_SGD_LENGTH,
}

enum LevelField @local {
    BYTE_OFFSET,
    BYTE_LENGTH,
    UNCOMPRESSED_LENGTH,
}

enum DescriptorField @local {
    TRANSFER,
    FLAGS,
}

struct FormatRow @local {
    uint code;
    uint gl_type;
    uint gl_format;
    uint type_size;
    char transfer;
    uint width;
    uint height;
    PixelFormat format;
}

struct RealToolRow @local {
    char[] bytes;
    PixelFormat format;
    uint width;
    uint height;
    usz[2][] spans; // offset and length of each level, base first
}

fn usz field_offset(Field field) @local {
    switch (field) {
        case DDS_FLAGS: return 8;
        case DDS_HEIGHT: return 12;
        case DDS_WIDTH: return 16;
        case DDS_PITCH: return 20;
        case DDS_DEPTH: return 24;
        case DDS_MIP_COUNT: return 28;
        case DDS_HEADER_SIZE: return 4;
        case DDS_PIXEL_FORMAT_SIZE: return 76;
        case DDS_PIXEL_FORMAT_FLAGS: return 80;
        case DDS_FOUR_CC: return 84;
        case DDS_RED_MASK: return 92;
        case DDS_BLUE_MASK: return 100;
        case DDS_ALPHA_MASK: return 104;
        case DDS_CAPS: return 108;
        case DDS_CAPS2: return 112;
        case DX10_FORMAT: return 128;
        case DX10_DIMENSION: return 132;
        case DX10_MISC_FLAG: return 136;
        case DX10_ARRAY_SIZE: return 140;
        case DX10_MISC_FLAGS2: return 144;
        case KTX1_ENDIANNESS: return 12;
        case KTX1_GL_TYPE: return 16;
        case KTX1_GL_FORMAT: return 24;
        case KTX1_INTERNAL_FORMAT: return 28;
        case KTX1_WIDTH: return 36;
        case KTX1_HEIGHT: return 40;
        case KTX1_DEPTH: return 44;
        case KTX1_ARRAY_ELEMENTS: return 48;
        case KTX1_FACES: return 52;
        case KTX1_MIP_COUNT: return 56;
        case KTX1_KEY_VALUE_BYTES: return 60;
        case KTX2_VK_FORMAT: return 12;
        case KTX2_TYPE_SIZE: return 16;
        case KTX2_WIDTH: return 20;
        case KTX2_HEIGHT: return 24;
        case KTX2_DEPTH: return 28;
        case KTX2_LAYERS: return 32;
        case KTX2_FACES: return 36;
        case KTX2_LEVEL_COUNT: return 40;
        case KTX2_SCHEME: return 44;
        case KTX2_DFD_LENGTH: return 52;
        case KTX2_SGD_LENGTH: return 72;
    }
}

fn char[] copied(char[] fixture) @local {
    char[] copy = alloc::new_array(tmem, char, (sz)fixture.len);
    copy[..] = fixture[..];
    return copy;
}

fn char[] with_field(char[] fixture, Field field, uint value) @local {
    char[] patched = copied(fixture);
    bitorder::write(value, patched[field_offset(field):uint::size], UIntLE);
    return patched;
}

fn char[] with_four_cc(char[] fixture, String code) @local {
    char[] patched = copied(fixture);
    patched[field_offset(DDS_FOUR_CC):code.len] = code[..];
    return patched;
}

fn char[] with_level_field(
    char[] fixture,
    uint level,
    LevelField field,
    ulong value,
) @local {
    char[] patched = copied(fixture);
    usz offset = KTX2_LEVEL_INDEX + level * KTX2_LEVEL_ENTRY_BYTES + (usz)field.ordinal * ulong::size;
    bitorder::write(value, patched[offset:ulong::size], ULongLE);
    return patched;
}

fn ulong level_field(char[] fixture, uint level, LevelField field) @local {
    usz offset = KTX2_LEVEL_INDEX + level * KTX2_LEVEL_ENTRY_BYTES + (usz)field.ordinal * ulong::size;
    return bitorder::read(fixture[offset:ulong::size], ULongLE);
}

fn char[] with_descriptor_byte(char[] fixture, DescriptorField field, char value) @local {
    const usz TRANSFER_BYTE = 14; // dfdTotalSize, two block header words, then model and primaries
    char[] patched = copied(fixture);
    usz descriptor = bitorder::read(fixture[KTX2_DFD_OFFSET_FIELD:uint::size], UIntLE);
    patched[descriptor + TRANSFER_BYTE + (usz)field.ordinal] = value;
    return patched;
}

fn char[] with_key_value(char[] fixture, String key, String value) @local {
    char[] patched = copied(fixture);
    sz key_start = ((String)fixture).index_of(key)!!;
    usz value_start = (usz)key_start + key.len + 1;
    patched[value_start:value.len] = value[..];
    return patched;
}

fn char[] with_first_image_size(char[] fixture, uint image_size) @local {
    char[] patched = copied(fixture);
    usz key_value_bytes = bitorder::read(fixture[KTX1_KEY_VALUE_BYTES_FIELD:uint::size], UIntLE);
    bitorder::write(image_size, patched[KTX1_HEADER_END + key_value_bytes:uint::size], UIntLE);
    return patched;
}

fn char[] with_bc1_block(
    char[] fixture,
    usz offset,
    ushort color0,
    ushort color1,
    uint indices,
) @local {
    const usz COLOR1_FIELD = 2;
    const usz INDICES_FIELD = 4;
    char[] patched = copied(fixture);
    bitorder::write(color0, patched[offset:ushort::size], UShortLE);
    bitorder::write(color1, patched[offset + COLOR1_FIELD:ushort::size], UShortLE);
    bitorder::write(indices, patched[offset + INDICES_FIELD:uint::size], UIntLE);
    return patched;
}

fn char[] with_trailing_zeros(char[] fixture, usz count) @local {
    char[] extended = alloc::new_array(tmem, char, (sz)(fixture.len + count));
    extended[:fixture.len] = fixture[..];
    return extended;
}

fn char[] truncated(char[] fixture, usz length) @local {
    return fixture[:length];
}

fn fault parse_fault(char[] bytes, ColorSpace color_space = FROM_FILE) @local {
    return @catch(image::parse_texture_container(tmem, bytes, color_space));
}

fn PixelFormat parsed_format(char[] bytes, ColorSpace color_space = FROM_FILE) @local {
    return image::parse_texture_container(tmem, bytes, color_space)!!.desc.format;
}

fn void check_borrowed_levels(TextureContainerView* view, char[] fixture, usz[2][] spans) @local {
    assert(view.level_count == spans.len && view.desc.mip_levels == spans.len);
    foreach (uint mip, span : spans) {
        TextureMipData level = view.levels[mip];
        assert(level.mip == mip && level.layer == 0, "mip %d", mip);
        assert(level.bytes.ptr == fixture.ptr + span[0] && level.bytes.len == span[1], "mip %d", mip);
    }
}

fn void check_plain_2d(
    TextureDesc desc,
    uint width,
    uint height,
    PixelFormat format,
) @local {
    assert(desc.width == width && desc.height == height && desc.format == format);
    assert(desc.depth == 0 && desc.layers == 1 && !desc.is_cube && !desc.storage);
}

fn AssetStore create_container_store(Allocator allocator, uint max_textures = 64) @local {
    return asset::create_asset_store(allocator, {
        .max_geometries = 1,
        .max_textures = max_textures,
        .max_materials = 1,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
    });
}

fn void test_container_normal_semantics_are_explicit_and_preserve_supplied_levels() @test {
    @pool() {
        TextureContainerView ordinary = image::parse_texture_container(tmem, KTX2_BC5[..])!!;
        TextureContainerView normal = image::parse_texture_container(
            scratch: tmem,
            bytes: KTX2_BC5[..],
            color_space: ColorSpace.FROM_FILE,
            semantic: TextureSemantic.NORMAL_RG,
        )!!;

        assert(ordinary.desc.semantic == TextureSemantic.COLOR);
        assert(normal.desc.semantic == TextureSemantic.NORMAL_RG && normal.desc.format == PixelFormat.BC5_UNORM);
        assert(normal.level_count == ordinary.level_count && !normal.desc.generate_mips);

        AssetStore assets = create_container_store(mem);
        defer asset::destroy_asset_store(&assets);

        TextureId texture = image::add_texture_container(
            assets: &assets,
            bytes: KTX2_BC5[..],
            color_space: ColorSpace.FROM_FILE,
            key: "normal/rg",
            semantic: TextureSemantic.NORMAL_RG,
        )!!;
        TextureAsset* record = assets.texture(texture);

        assert(record.source_kind == TextureSourceKind.SUPPLIED_MIPS);
        assert(record.desc.semantic == TextureSemantic.NORMAL_RG && record.desc.coverage == CoveragePolicy.NONE);

        foreach (index, level : record.supplied_mips) {
            assert(level.mip == normal.levels[index].mip && level.layer == normal.levels[index].layer);
            assert(level.bytes == ordinary.levels[index].bytes && level.bytes.ptr != ordinary.levels[index].bytes.ptr);
        }

        TextureId loaded = image::load_texture_container(
            assets: &assets,
            path: fixture_path("ktx2_bc5_8x4.ktx2"),
            color_space: ColorSpace.FROM_FILE,
            key: "normal/rg/file",
            semantic: TextureSemantic.NORMAL_RG,
        )!!;

        assert(assets.texture(loaded).desc.semantic == TextureSemantic.NORMAL_RG);

        foreach (index, level : assets.texture(loaded).supplied_mips) assert(level.bytes == normal.levels[index].bytes);
    };
}

fn void test_container_normal_semantic_faults_preserve_the_asset_store() @test {
    @pool() {
        AssetStore assets = create_container_store(mem);
        defer asset::destroy_asset_store(&assets);

        uint free_before = assets.textures.free_count;

        assert(@catch(image::add_texture_container(
            assets: &assets,
            bytes: DX10_RGBA8_SRGB[..],
            color_space: ColorSpace.FROM_FILE,
            key: "normal/srgb",
            semantic: TextureSemantic.NORMAL_RGB,
        )) == c3d::INVALID_ARGUMENT);
        assert(@catch(image::parse_texture_container(
            scratch: tmem,
            bytes: KTX1_R16[..],
            color_space: ColorSpace.FROM_FILE,
            semantic: TextureSemantic.NORMAL_RG,
        )) == c3d::UNSUPPORTED);
        assert(assets.textures.free_count == free_before);
        assert(@catch(assets.find_texture("normal/srgb")) == NOT_FOUND);
    };
}

fn String fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/texture", name)!!;
}

fn ushort[] r16_texels(
    Allocator allocator,
    uint mip,
    uint width,
    uint height,
) @local {
    ushort[] texels = alloc::new_array(allocator, ushort, (sz)width * height);
    foreach (usz index, &texel : texels) *texel = (ushort)((usz)R16_MIP_STEP * mip + index);
    return texels;
}

fn char[] as_bytes(ushort[] texels) @local {
    return ((char*)texels.ptr)[:texels.len * ushort::size];
}

fn void test_dx10_levels_borrow_the_file_largest_first() @test {
    TrackingAllocator scratch;
    scratch.init(mem);
    defer scratch.free();

    char[] rgba_file = DX10_RGBA8_SRGB[..];
    TextureContainerView rgba = image::parse_texture_container(&scratch, rgba_file)!!;
    check_plain_2d(rgba.desc, 5, 3, RGBA8_SRGB);
    assert(!rgba.desc.generate_mips);
    check_borrowed_levels(&rgba, rgba_file, { { 148, 60 }, { 208, 8 }, { 216, 4 } });

    char[] blocks_file = DX10_BC7_SRGB[..];
    TextureContainerView blocks = image::parse_texture_container(&scratch, blocks_file)!!;
    check_plain_2d(blocks.desc, 5, 3, BC7_SRGB);
    check_borrowed_levels(&blocks, blocks_file, { { 148, 32 }, { 180, 16 }, { 196, 16 } });
    assert(scratch.total_allocation_count() == 0);
}

fn void test_legacy_dds_forms_map_to_pixel_formats() @test {
    @pool() {
        char[] dxt1_file = LEGACY_DXT1[..];
        TextureContainerView dxt1 = image::parse_texture_container(tmem, dxt1_file)!!;
        check_plain_2d(dxt1.desc, 6, 6, BC1_RGBA_UNORM);
        check_borrowed_levels(&dxt1, dxt1_file, { { 128, 32 }, { 160, 8 }, { 168, 8 } });
        assert(parsed_format(with_four_cc(LEGACY_DXT1[..], "ATI1")) == BC4_UNORM);
        assert(parsed_format(with_four_cc(LEGACY_DXT1[..], "BC4U")) == BC4_UNORM);

        char[] dxt5 = with_field(with_four_cc(LEGACY_DXT1[..], "DXT5"), DDS_MIP_COUNT, 1);
        dxt5 = with_field(with_field(dxt5, DDS_WIDTH, 8), DDS_HEIGHT, 4);
        TextureContainerView blocks = image::parse_texture_container(tmem, dxt5)!!;
        check_plain_2d(blocks.desc, 8, 4, BC3_UNORM);
        check_borrowed_levels(&blocks, dxt5, { { 128, 32 } });
        assert(parsed_format(with_four_cc(dxt5, "ATI2")) == BC5_UNORM);
        assert(parsed_format(with_four_cc(dxt5, "BC5U")) == BC5_UNORM);

        char[] half_file = LEGACY_RGBA16F[..];
        TextureContainerView half = image::parse_texture_container(tmem, half_file)!!;
        check_plain_2d(half.desc, 4, 4, RGBA16_FLOAT);
        check_borrowed_levels(&half, half_file, { { 128, 128 } });
        char[] single = with_field(with_field(LEGACY_RGBA16F[..], DDS_FOUR_CC, 116), DDS_WIDTH, 2);
        TextureContainerView full = image::parse_texture_container(tmem, single)!!;
        check_plain_2d(full.desc, 2, 4, RGBA32_FLOAT);
        check_borrowed_levels(&full, single, { { 128, 128 } });

        char[] bytes_file = LEGACY_RGBA8[..];
        TextureContainerView bytes = image::parse_texture_container(tmem, bytes_file)!!;
        check_plain_2d(bytes.desc, 2, 2, RGBA8_UNORM);
        check_borrowed_levels(&bytes, bytes_file, { { 128, 16 }, { 144, 4 } });
        const uint DDPF_RGB = 0x40;
        assert(parsed_format(with_field(LEGACY_RGBA8[..], DDS_PIXEL_FORMAT_FLAGS, DDPF_RGB)) == RGBA8_UNORM);
    };
}

fn void test_legacy_dds_variants_outside_the_subset_are_unsupported() @test {
    @pool() {
        String[6] codes = { "DXT2", "DXT3", "DXT4", "BC4S", "BC5S", "RGBG" };
        foreach (code : codes) {
            assert(parse_fault(with_four_cc(LEGACY_DXT1[..], code)) == c3d::UNSUPPORTED, "%s", code);
        }
        const uint D3DFMT_A16B16G16R16 = 36;
        assert(parse_fault(with_field(LEGACY_RGBA16F[..], DDS_FOUR_CC, D3DFMT_A16B16G16R16)) == c3d::UNSUPPORTED);

        char[] bgra = with_field(with_field(LEGACY_RGBA8[..], DDS_RED_MASK, 0x00FF0000), DDS_BLUE_MASK, 0x000000FF);
        assert(parse_fault(bgra) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(LEGACY_RGBA8[..], DDS_ALPHA_MASK, 0)) == c3d::UNSUPPORTED);
        const uint DDPF_LUMINANCE = 0x20000;
        assert(parse_fault(with_field(LEGACY_RGBA8[..], DDS_PIXEL_FORMAT_FLAGS, DDPF_LUMINANCE)) == c3d::UNSUPPORTED);
    };
}

fn void test_dx10_forms_outside_the_subset_are_unsupported() @test {
    const uint TEXTURE1D = 2;
    const uint TEXTURE3D = 4;
    const uint TEXTURECUBE = 0x4;
    const uint ALPHA_MODE_STRAIGHT = 1;
    const uint ALPHA_MODE_PREMULTIPLIED = 2;
    const uint ALPHA_MODE_OPAQUE = 3;
    @pool() {
        assert(parse_fault(with_field(DX10_BC7_SRGB[..], DX10_DIMENSION, TEXTURE1D)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(DX10_BC7_SRGB[..], DX10_DIMENSION, TEXTURE3D)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(DX10_BC7_SRGB[..], DX10_ARRAY_SIZE, 2)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(DX10_BC7_SRGB[..], DX10_MISC_FLAG, TEXTURECUBE)) == c3d::UNSUPPORTED);
        char[] premultiplied = with_field(DX10_BC7_SRGB[..], DX10_MISC_FLAGS2, ALPHA_MODE_PREMULTIPLIED);
        assert(parse_fault(premultiplied) == c3d::UNSUPPORTED);
        assert(parsed_format(with_field(DX10_BC7_SRGB[..], DX10_MISC_FLAGS2, ALPHA_MODE_STRAIGHT)) == BC7_SRGB);
        assert(parsed_format(with_field(DX10_BC7_SRGB[..], DX10_MISC_FLAGS2, ALPHA_MODE_OPAQUE)) == BC7_SRGB);

        uint[11] outside = { 27, 70, 73, 74, 75, 81, 84, 87, 91, 96, 97 }; // typeless, BC2, SNORM, BGRA8, BC6H signed
        foreach (code : outside) {
            assert(parse_fault(with_field(DX10_BC7_SRGB[..], DX10_FORMAT, code)) == c3d::UNSUPPORTED, "%d", code);
        }
    };
}

fn void test_dx10_formats_map_to_pixel_formats() @test {
    FormatRow[14] rows = {
        { .code = 28, .width = 2, .height = 2, .format = RGBA8_UNORM },
        { .code = 29, .width = 2, .height = 2, .format = RGBA8_SRGB },
        { .code = 10, .width = 2, .height = 1, .format = RGBA16_FLOAT },
        { .code = 2, .width = 1, .height = 1, .format = RGBA32_FLOAT },
        { .code = 57, .width = 8, .height = 1, .format = R16_UINT },
        { .code = 71, .width = 8, .height = 4, .format = BC1_RGBA_UNORM },
        { .code = 72, .width = 8, .height = 4, .format = BC1_RGBA_SRGB },
        { .code = 77, .width = 4, .height = 4, .format = BC3_UNORM },
        { .code = 78, .width = 4, .height = 4, .format = BC3_SRGB },
        { .code = 80, .width = 8, .height = 4, .format = BC4_UNORM },
        { .code = 83, .width = 4, .height = 4, .format = BC5_UNORM },
        { .code = 95, .width = 4, .height = 4, .format = BC6H_UFLOAT },
        { .code = 98, .width = 4, .height = 4, .format = BC7_UNORM },
        { .code = 99, .width = 4, .height = 4, .format = BC7_SRGB },
    };
    @pool() {
        foreach (row : rows) {
            char[] patched = with_field(DX10_FORMAT16[..], DX10_FORMAT, row.code);
            patched = with_field(with_field(patched, DDS_WIDTH, row.width), DDS_HEIGHT, row.height);
            TextureContainerView view = image::parse_texture_container(tmem, patched)!!;
            assert(view.desc.format == row.format, "DXGI %d", row.code);
            check_borrowed_levels(&view, patched, { { 148, 16 } });
        }
    };
}

fn void test_dds_cubes_and_volumes_are_unsupported() @test {
    const uint DDSCAPS2_CUBEMAP = 0x200;
    const uint DDSCAPS2_VOLUME = 0x200000;
    @pool() {
        assert(parse_fault(with_field(LEGACY_DXT1[..], DDS_CAPS2, DDSCAPS2_CUBEMAP)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(LEGACY_DXT1[..], DDS_CAPS2, DDSCAPS2_VOLUME)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(LEGACY_DXT1[..], DDS_DEPTH, 2)) == c3d::UNSUPPORTED);
        assert(parsed_format(with_field(LEGACY_DXT1[..], DDS_DEPTH, 1)) == BC1_RGBA_UNORM);
    };
}

fn void test_dds_ignores_advisory_fields_and_trailing_bytes() @test {
    @pool() {
        char[] advisory = with_field(LEGACY_DXT1[..], DDS_FLAGS, 0);
        advisory = with_field(with_field(advisory, DDS_PITCH, 0), DDS_CAPS, 0);
        TextureContainerView view = image::parse_texture_container(tmem, advisory)!!;
        check_borrowed_levels(&view, advisory, { { 128, 32 }, { 160, 8 }, { 168, 8 } });

        char[] single = with_field(LEGACY_DXT1[..], DDS_MIP_COUNT, 0);
        TextureContainerView base = image::parse_texture_container(tmem, single)!!;
        check_borrowed_levels(&base, single, { { 128, 32 } });

        char[] extended = with_trailing_zeros(LEGACY_DXT1[..], 1);
        TextureContainerView trailing = image::parse_texture_container(tmem, extended)!!;
        check_borrowed_levels(&trailing, extended, { { 128, 32 }, { 160, 8 }, { 168, 8 } });
    };
}

fn void test_malformed_dds_is_a_format_error() @test {
    @pool() {
        assert(parse_fault(truncated(LEGACY_DXT1[..], 127)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(truncated(DX10_BC7_SRGB[..], 147)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(truncated(LEGACY_DXT1[..], LEGACY_DXT1.len - 1)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(LEGACY_DXT1[..], DDS_HEADER_SIZE, 100)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(LEGACY_DXT1[..], DDS_PIXEL_FORMAT_SIZE, 0)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(LEGACY_DXT1[..], DDS_WIDTH, 0)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(LEGACY_DXT1[..], DDS_HEIGHT, 0)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(LEGACY_DXT1[..], DDS_MIP_COUNT, 4)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(LEGACY_DXT1[..], DDS_WIDTH, 12)) == c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_level_count_beyond_capacity_is_a_format_error() @test {
    uint capacity = material::TEXTURE_MIP_CAPACITY;
    @pool() {
        char[] maximal = with_field(with_field(LEGACY_DXT1[..], DDS_WIDTH, MAXIMUM_EXTENT), DDS_HEIGHT, MAXIMUM_EXTENT);
        assert(parse_fault(with_field(maximal, DDS_MIP_COUNT, capacity + 1)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(maximal, DDS_MIP_COUNT, capacity)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(maximal, DDS_FOUR_CC, 116)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(LEGACY_DXT1[..], DDS_MIP_COUNT, 40)) == c3d::ASSET_FORMAT_ERROR);

        assert(parse_fault($embed("../fixtures/texture/ktx1_level_capacity.ktx")) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault($embed("../fixtures/texture/ktx2_level_capacity.ktx2")) == c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_container_detection_reads_magic_bytes_only() @test {
    char[13] ktx2_prefix = { 0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, 0x0D, 0x0A, 0x1A, 0x0A, 0 };
    @pool() {
        assert(parse_fault({}) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(truncated(LEGACY_DXT1[..], 3)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(truncated(LEGACY_DXT1[..], 4)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(ktx2_prefix[:11]) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(ktx2_prefix[..]) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault($embed("../fixtures/rgba.png")) == c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_color_space_selects_srgb_twins() @test {
    @pool() {
        char[] bc1_srgb = with_field(DX10_FORMAT16[..], DX10_FORMAT, 72);
        bc1_srgb = with_field(with_field(bc1_srgb, DDS_WIDTH, 8), DDS_HEIGHT, 4);
        char[] bc3 = with_field(with_field(DX10_FORMAT16[..], DX10_FORMAT, 77), DDS_WIDTH, 4);
        bc3 = with_field(bc3, DDS_HEIGHT, 4);
        char[] bc3_srgb = with_field(bc3, DX10_FORMAT, 78);
        char[] bc7 = with_field(DX10_BC7_SRGB[..], DX10_FORMAT, 98);

        assert(parsed_format(LEGACY_RGBA8[..]) == RGBA8_UNORM);
        assert(parsed_format(LEGACY_RGBA8[..], SRGB) == RGBA8_SRGB);
        assert(parsed_format(DX10_RGBA8_SRGB[..], LINEAR) == RGBA8_UNORM);
        assert(parsed_format(DX10_RGBA8_SRGB[..], SRGB) == RGBA8_SRGB);
        assert(parsed_format(LEGACY_DXT1[..], SRGB) == BC1_RGBA_SRGB);
        assert(parsed_format(bc1_srgb, LINEAR) == BC1_RGBA_UNORM);
        assert(parsed_format(bc3, SRGB) == BC3_SRGB);
        assert(parsed_format(bc3_srgb, LINEAR) == BC3_UNORM);
        assert(parsed_format(bc7, SRGB) == BC7_SRGB);
        assert(parsed_format(DX10_BC7_SRGB[..], LINEAR) == BC7_UNORM);
        assert(parsed_format(bc7, LINEAR) == BC7_UNORM);
    };
}

fn void test_srgb_request_without_an_srgb_twin_is_invalid() @test {
    FormatRow[6] rows = {
        { .code = 10, .width = 2, .height = 1, .format = RGBA16_FLOAT },
        { .code = 2, .width = 1, .height = 1, .format = RGBA32_FLOAT },
        { .code = 57, .width = 8, .height = 1, .format = R16_UINT },
        { .code = 80, .width = 8, .height = 4, .format = BC4_UNORM },
        { .code = 83, .width = 4, .height = 4, .format = BC5_UNORM },
        { .code = 95, .width = 4, .height = 4, .format = BC6H_UFLOAT },
    };
    @pool() {
        foreach (row : rows) {
            char[] patched = with_field(DX10_FORMAT16[..], DX10_FORMAT, row.code);
            patched = with_field(with_field(patched, DDS_WIDTH, row.width), DDS_HEIGHT, row.height);
            assert(parse_fault(patched, SRGB) == c3d::INVALID_ARGUMENT, "DXGI %d", row.code);
            assert(parsed_format(patched, LINEAR) == row.format, "DXGI %d", row.code);
        }
    };
}

fn void test_failed_parse_allocates_nothing() @test {
    TrackingAllocator scratch;
    scratch.init(mem);
    defer scratch.free();

    @pool() {
        char[] short_dds = truncated(LEGACY_DXT1[..], 150);
        char[] short_ktx1 = truncated(KTX1_R16[..], KTX1_R16.len - 1);
        char[] deep_ktx1 = with_field(KTX1_R16[..], KTX1_MIP_COUNT, 4);
        assert(@catch(image::parse_texture_container(&scratch, short_dds)) == c3d::ASSET_FORMAT_ERROR);
        assert(@catch(image::parse_texture_container(&scratch, KTX1_R16[..], SRGB)) == c3d::INVALID_ARGUMENT);
        assert(@catch(image::parse_texture_container(&scratch, short_ktx1)) == c3d::ASSET_FORMAT_ERROR);
        assert(@catch(image::parse_texture_container(&scratch, deep_ktx1)) == c3d::ASSET_FORMAT_ERROR);
    };
    assert(scratch.total_allocation_count() == 0);
}

fn void test_ktx2_levels_follow_the_level_index() @test {
    TrackingAllocator scratch;
    scratch.init(mem);
    defer scratch.free();

    char[] rgba_file = KTX2_RGBA8_SRGB[..];
    TextureContainerView rgba = image::parse_texture_container(&scratch, rgba_file)!!;
    check_plain_2d(rgba.desc, 5, 3, RGBA8_SRGB);
    check_borrowed_levels(&rgba, rgba_file, { { 256, 60 }, { 248, 8 }, { 244, 4 } });

    char[] blocks_file = KTX2_BC7_SRGB[..];
    TextureContainerView blocks = image::parse_texture_container(&scratch, blocks_file)!!;
    check_plain_2d(blocks.desc, 5, 3, BC7_SRGB);
    check_borrowed_levels(&blocks, blocks_file, { { 272, 32 }, { 256, 16 }, { 240, 16 } });

    char[] two_channel_file = KTX2_BC5[..];
    TextureContainerView two_channel = image::parse_texture_container(&scratch, two_channel_file)!!;
    check_plain_2d(two_channel.desc, 8, 4, BC5_UNORM);
    check_borrowed_levels(&two_channel, two_channel_file, { { 208, 32 }, { 192, 16 } });
    assert(scratch.total_allocation_count() == 0);
}

fn void test_ktx1_levels_follow_image_sizes() @test {
    TrackingAllocator scratch;
    scratch.init(mem);
    defer scratch.free();

    char[] fixture = KTX1_BC1_SRGB[..];
    TextureContainerView view = image::parse_texture_container(&scratch, fixture)!!;
    check_plain_2d(view.desc, 8, 8, BC1_RGBA_SRGB);
    check_borrowed_levels(&view, fixture, { { 116, 32 }, { 152, 8 }, { 164, 8 }, { 176, 8 } });
    @pool() {
        char[] extended = with_trailing_zeros(KTX1_BC1_SRGB[..], 1);
        TextureContainerView trailing = image::parse_texture_container(&scratch, extended)!!;
        check_borrowed_levels(&trailing, extended, { { 116, 32 }, { 152, 8 }, { 164, 8 }, { 176, 8 } });
    };
    assert(scratch.total_allocation_count() == 0);
}

fn void test_padded_ktx1_rows_are_copied_into_scratch_only() @test {
    @pool() {
        TrackingAllocator scratch;
        scratch.init(tmem);
        defer scratch.free();

        char[] fixture = KTX1_R16[..];
        TextureContainerView view = image::parse_texture_container(&scratch, fixture)!!;
        check_plain_2d(view.desc, 5, 3, R16_UINT);
        assert(view.level_count == 3 && scratch.total_allocation_count() == 1);
        assert(view.levels[1].bytes.ptr == fixture.ptr + 108 && view.levels[1].bytes.len == 4);
        foreach (mip : (uint[2]){ 0, 2 }) {
            char* start = view.levels[mip].bytes.ptr;
            assert(start < fixture.ptr || start >= fixture.ptr + fixture.len, "mip %d", mip);
        }
        uint[3] widths = { 5, 2, 1 };
        uint[3] heights = { 3, 1, 1 };
        foreach (uint mip, width : widths) {
            assert(view.levels[mip].bytes == as_bytes(r16_texels(tmem, mip, width, heights[mip])), "mip %d", mip);
        }
    };
}

fn void test_padded_ktx1_matches_texels_supplied_by_hand() @test {
    AssetStore assets = create_container_store(mem);
    defer asset::destroy_asset_store(&assets);

    @pool() {
        TextureContainerView view = image::parse_texture_container(tmem, KTX1_R16[..])!!;
        TextureId loaded = assets.add_texture_mips(view.desc, view.levels[:view.level_count])!!;

        TextureMipData[3] levels = {
            { .mip = 0, .bytes = as_bytes(r16_texels(tmem, 0, 5, 3)) },
            { .mip = 1, .bytes = as_bytes(r16_texels(tmem, 1, 2, 1)) },
            { .mip = 2, .bytes = as_bytes(r16_texels(tmem, 2, 1, 1)) },
        };
        TextureDesc desc = material::texture_2d_desc(5, 3, R16_UINT);
        desc.generate_mips = false;
        desc.mip_levels = 3;
        TextureId supplied = assets.add_texture_mips(desc, levels[..])!!;

        TextureAsset* container = assets.texture(loaded);
        TextureAsset* hand = assets.texture(supplied);
        assert(container.desc.mip_levels == hand.desc.mip_levels && container.desc.format == hand.desc.format);
        foreach (usz mip, level : hand.supplied_mips) assert(container.supplied_mips[mip].bytes == level.bytes);
    };
}

fn void test_ktx1_internal_formats_map_to_pixel_formats() @test {
    const uint GL_RGBA = 0x1908;
    const uint GL_RED_INTEGER = 0x8D94;
    FormatRow[16] rows = {
        { .code = 0x8058, .gl_type = 0x1401, .gl_format = GL_RGBA, .width = 2, .height = 2, .format = RGBA8_UNORM },
        { .code = 0x8C43, .gl_type = 0x1401, .gl_format = GL_RGBA, .width = 2, .height = 2, .format = RGBA8_SRGB },
        { .code = 0x881A, .gl_type = 0x140B, .gl_format = GL_RGBA, .width = 2, .height = 1, .format = RGBA16_FLOAT },
        { .code = 0x8814, .gl_type = 0x1406, .gl_format = GL_RGBA, .width = 1, .height = 1, .format = RGBA32_FLOAT },
        { .code = 0x8234, .gl_type = 0x1403, .gl_format = GL_RED_INTEGER, .width = 8, .height = 1, .format = R16_UINT },
        { .code = 0x83F0, .width = 8, .height = 4, .format = BC1_RGBA_UNORM },
        { .code = 0x8C4C, .width = 8, .height = 4, .format = BC1_RGBA_SRGB },
        { .code = 0x83F1, .width = 8, .height = 4, .format = BC1_RGBA_UNORM },
        { .code = 0x8C4D, .width = 8, .height = 4, .format = BC1_RGBA_SRGB },
        { .code = 0x83F3, .width = 4, .height = 4, .format = BC3_UNORM },
        { .code = 0x8C4F, .width = 4, .height = 4, .format = BC3_SRGB },
        { .code = 0x8DBB, .width = 8, .height = 4, .format = BC4_UNORM },
        { .code = 0x8DBD, .width = 4, .height = 4, .format = BC5_UNORM },
        { .code = 0x8E8F, .width = 4, .height = 4, .format = BC6H_UFLOAT },
        { .code = 0x8E8C, .width = 4, .height = 4, .format = BC7_UNORM },
        { .code = 0x8E8D, .width = 4, .height = 4, .format = BC7_SRGB },
    };
    @pool() {
        foreach (row : rows) {
            char[] patched = with_field(KTX1_FORMAT16[..], KTX1_INTERNAL_FORMAT, row.code);
            patched = with_field(with_field(patched, KTX1_GL_TYPE, row.gl_type), KTX1_GL_FORMAT, row.gl_format);
            patched = with_field(with_field(patched, KTX1_WIDTH, row.width), KTX1_HEIGHT, row.height);
            TextureContainerView view = image::parse_texture_container(tmem, patched)!!;
            assert(view.desc.format == row.format, "internal format %x", row.code);
            check_borrowed_levels(&view, patched, { { 68, 16 } });
        }
    };
}

fn void test_ktx2_vk_formats_map_to_pixel_formats() @test {
    const char LINEAR_TRANSFER = 1;
    const char SRGB_TRANSFER = 2;
    FormatRow[16] rows = {
        { .code = 37, .type_size = 1, .transfer = LINEAR_TRANSFER, .width = 2, .height = 2, .format = RGBA8_UNORM },
        { .code = 43, .type_size = 1, .transfer = SRGB_TRANSFER, .width = 2, .height = 2, .format = RGBA8_SRGB },
        { .code = 97, .type_size = 2, .transfer = LINEAR_TRANSFER, .width = 2, .height = 1, .format = RGBA16_FLOAT },
        { .code = 109, .type_size = 4, .transfer = LINEAR_TRANSFER, .width = 1, .height = 1, .format = RGBA32_FLOAT },
        { .code = 74, .type_size = 2, .transfer = LINEAR_TRANSFER, .width = 8, .height = 1, .format = R16_UINT },
        { .code = 131, .type_size = 1, .transfer = LINEAR_TRANSFER, .width = 8, .height = 4, .format = BC1_RGBA_UNORM },
        { .code = 132, .type_size = 1, .transfer = SRGB_TRANSFER, .width = 8, .height = 4, .format = BC1_RGBA_SRGB },
        { .code = 133, .type_size = 1, .transfer = LINEAR_TRANSFER, .width = 8, .height = 4, .format = BC1_RGBA_UNORM },
        { .code = 134, .type_size = 1, .transfer = SRGB_TRANSFER, .width = 8, .height = 4, .format = BC1_RGBA_SRGB },
        { .code = 137, .type_size = 1, .transfer = LINEAR_TRANSFER, .width = 4, .height = 4, .format = BC3_UNORM },
        { .code = 138, .type_size = 1, .transfer = SRGB_TRANSFER, .width = 4, .height = 4, .format = BC3_SRGB },
        { .code = 139, .type_size = 1, .transfer = LINEAR_TRANSFER, .width = 8, .height = 4, .format = BC4_UNORM },
        { .code = 141, .type_size = 1, .transfer = LINEAR_TRANSFER, .width = 4, .height = 4, .format = BC5_UNORM },
        { .code = 143, .type_size = 1, .transfer = LINEAR_TRANSFER, .width = 4, .height = 4, .format = BC6H_UFLOAT },
        { .code = 145, .type_size = 1, .transfer = LINEAR_TRANSFER, .width = 4, .height = 4, .format = BC7_UNORM },
        { .code = 146, .type_size = 1, .transfer = SRGB_TRANSFER, .width = 4, .height = 4, .format = BC7_SRGB },
    };
    @pool() {
        foreach (row : rows) {
            char[] patched = with_field(KTX2_FORMAT16[..], KTX2_VK_FORMAT, row.code);
            patched = with_field(with_field(patched, KTX2_TYPE_SIZE, row.type_size), KTX2_WIDTH, row.width);
            patched = with_descriptor_byte(with_field(patched, KTX2_HEIGHT, row.height), TRANSFER, row.transfer);
            TextureContainerView view = image::parse_texture_container(tmem, patched)!!;
            assert(view.desc.format == row.format, "vkFormat %d", row.code);
            check_borrowed_levels(&view, patched, { { 208, 16 } });
        }
    };
}

fn void test_ktx_variants_outside_the_subset_are_unsupported() @test {
    const uint BIG_ENDIAN = 0x01020304;
    const uint CUBE_FACES = 6;
    const char PREMULTIPLIED = 1;
    @pool() {
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_ENDIANNESS, BIG_ENDIAN)) == c3d::UNSUPPORTED);
        // unsized RGBA, RGB8, DXT3, signed RGTC1, signed BC6H
        uint[5] gl_outside = { 0x1908, 0x8051, 0x83F2, 0x8DBC, 0x8E8E };
        foreach (code : gl_outside) {
            char[] patched = with_field(KTX1_BC1_SRGB[..], KTX1_INTERNAL_FORMAT, code);
            assert(parse_fault(patched) == c3d::UNSUPPORTED, "%x", code);
        }
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_HEIGHT, 0)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_DEPTH, 1)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_ARRAY_ELEMENTS, 2)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_FACES, CUBE_FACES)) == c3d::UNSUPPORTED);

        foreach (scheme : (uint[3]){ 1, 2, 3 }) {
            assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_SCHEME, scheme)) == c3d::UNSUPPORTED, "%d", scheme);
        }
        uint[6] vk_outside = { 0, 135, 136, 140, 142, 144 }; // undefined, BC2, SNORM BC4 and BC5, signed BC6H
        foreach (code : vk_outside) {
            assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_VK_FORMAT, code)) == c3d::UNSUPPORTED, "%d", code);
        }
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_HEIGHT, 0)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_DEPTH, 1)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_LAYERS, 2)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_FACES, CUBE_FACES)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_descriptor_byte(KTX2_BC7_SRGB[..], FLAGS, PREMULTIPLIED)) == c3d::UNSUPPORTED);
    };
}

fn void test_malformed_ktx_is_a_format_error() @test {
    const uint GL_FLOAT = 0x1406;
    const uint GL_UNSIGNED_BYTE = 0x1401;
    @pool() {
        assert(parse_fault(truncated(KTX1_BC1_SRGB[..], 63)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_ENDIANNESS, 0)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX1_FORMAT16[..], KTX1_GL_TYPE, GL_FLOAT)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_GL_TYPE, GL_UNSIGNED_BYTE)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_FACES, 0)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_KEY_VALUE_BYTES, 1000)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_MIP_COUNT, 5)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_first_image_size(KTX1_BC1_SRGB[..], 24)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_first_image_size(KTX1_R16[..], 30)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(truncated(KTX1_BC1_SRGB[..], KTX1_BC1_SRGB.len - 1)) == c3d::ASSET_FORMAT_ERROR);

        assert(parse_fault(truncated(KTX2_BC7_SRGB[..], 79)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(truncated(KTX2_BC7_SRGB[..], 100)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_FACES, 0)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_LEVEL_COUNT, 4)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_LEVEL_COUNT, 40)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_level_field(KTX2_BC7_SRGB[..], 0, BYTE_OFFSET, 1 << 20)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_level_field(KTX2_BC7_SRGB[..], 0, BYTE_LENGTH, 16)) == c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_ktx2_strictness_rejects_index_inconsistencies() @test {
    @pool() {
        ulong smallest = level_field(KTX2_BC7_SRGB[..], 2, BYTE_OFFSET);
        ulong base = level_field(KTX2_BC7_SRGB[..], 0, BYTE_OFFSET);
        char[] misaligned = with_level_field(KTX2_BC7_SRGB[..], 2, BYTE_OFFSET, smallest - 4);
        assert(parse_fault(misaligned) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_level_field(KTX2_BC7_SRGB[..], 1, BYTE_OFFSET, base)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_level_field(KTX2_BC7_SRGB[..], 0, UNCOMPRESSED_LENGTH, 48)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_DFD_LENGTH, 0)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_TYPE_SIZE, 4)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_SGD_LENGTH, 8)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_trailing_zeros(KTX2_BC7_SRGB[..], 1)) == c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_ktx2_transfer_function_must_match_the_format() @test {
    const char UNSPECIFIED_TRANSFER = 0;
    const char LINEAR_TRANSFER = 1;
    const char SRGB_TRANSFER = 2;
    @pool() {
        char[] linear_srgb_format = with_descriptor_byte(KTX2_RGBA8_SRGB[..], TRANSFER, LINEAR_TRANSFER);
        char[] srgb_unorm_format = with_descriptor_byte(KTX2_FORMAT16[..], TRANSFER, SRGB_TRANSFER);
        assert(parse_fault(linear_srgb_format) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(srgb_unorm_format) == c3d::ASSET_FORMAT_ERROR);
        assert(parsed_format(with_descriptor_byte(KTX2_FORMAT16[..], TRANSFER, UNSPECIFIED_TRANSFER)) == RGBA8_UNORM);
    };
}

fn void test_ktx2_orientation_accepts_absent_and_rd_only() @test {
    @pool() {
        assert(parsed_format(KTX2_RGBA8_SRGB[..]) == RGBA8_SRGB);
        assert(parsed_format(KTX2_BC7_SRGB[..]) == BC7_SRGB);
        String[4] rejected = { "ru", "ld", "lu", "dr" };
        foreach (value : rejected) {
            char[] patched = with_key_value(KTX2_BC7_SRGB[..], "KTXorientation", value);
            assert(parse_fault(patched) == c3d::UNSUPPORTED, "%s", value);
        }
    };
}

fn void test_ktx1_orientation_accepts_absent_and_s_r_t_d_only() @test {
    @pool() {
        assert(parsed_format(KTX1_R16[..]) == R16_UINT);
        assert(parsed_format(KTX1_BC1_SRGB[..]) == BC1_RGBA_SRGB);
        String[4] rejected = { "S=r,T=u", "S=l,T=d", "T=d,S=r", "S=r;T=d" };
        foreach (value : rejected) {
            char[] patched = with_key_value(KTX1_BC1_SRGB[..], "KTXorientation", value);
            assert(parse_fault(patched) == c3d::UNSUPPORTED, "%s", value);
        }
    };
}

fn void test_swizzle_other_than_rgba_is_unsupported() @test {
    @pool() {
        assert(parse_fault(with_key_value(KTX2_BC7_SRGB[..], "KTXswizzle", "bgra")) == c3d::UNSUPPORTED);
        assert(parse_fault(with_key_value(KTX1_BC1_SRGB[..], "KTXswizzle", "rrr1")) == c3d::UNSUPPORTED);
    };
}

fn void test_generate_requests_map_to_generated_mips() @test {
    @pool() {
        char[] generate_file = KTX1_GENERATE[..];
        TextureContainerView ktx1 = image::parse_texture_container(tmem, generate_file)!!;
        check_plain_2d(ktx1.desc, 2, 2, RGBA8_UNORM);
        assert(ktx1.desc.generate_mips && ktx1.desc.mip_levels == 1 && ktx1.level_count == 1);
        assert(ktx1.levels[0].bytes.ptr == generate_file.ptr + 68 && ktx1.levels[0].bytes.len == 16);

        char[] base_only = with_field(KTX2_RGBA8_SRGB[..], KTX2_LEVEL_COUNT, 0);
        TextureContainerView ktx2 = image::parse_texture_container(tmem, base_only)!!;
        assert(ktx2.desc.generate_mips && ktx2.desc.mip_levels == 1 && ktx2.level_count == 1);
        assert(ktx2.levels[0].bytes.ptr == base_only.ptr + 256 && ktx2.levels[0].bytes.len == 60);
    };
}

fn void test_generate_requests_without_a_mip_filter_are_rejected() @test {
    @pool() {
        assert(parse_fault(with_field(KTX2_BC7_SRGB[..], KTX2_LEVEL_COUNT, 0)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(with_field(KTX1_BC1_SRGB[..], KTX1_MIP_COUNT, 0)) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(KTX1_R16[..], KTX1_MIP_COUNT, 0)) == c3d::UNSUPPORTED);
        char[] r16 = with_field(with_field(KTX2_FORMAT16[..], KTX2_VK_FORMAT, 74), KTX2_TYPE_SIZE, 2);
        r16 = with_field(with_field(r16, KTX2_WIDTH, 8), KTX2_HEIGHT, 1);
        assert(parsed_format(r16) == R16_UINT);
        assert(parse_fault(with_field(r16, KTX2_LEVEL_COUNT, 0)) == c3d::UNSUPPORTED);
    };
}

fn void test_bc1_rgb_loads_only_without_three_color_alpha() @test {
    const uint GL_COMPRESSED_RGB_S3TC_DXT1 = 0x83F0;
    const uint GL_COMPRESSED_SRGB_S3TC_DXT1 = 0x8C4C;
    @pool() {
        char[] clean_file = KTX2_BC1_RGB_CLEAN[..];
        TextureContainerView clean = image::parse_texture_container(tmem, clean_file)!!;
        check_plain_2d(clean.desc, 4, 4, BC1_RGBA_UNORM);
        check_borrowed_levels(&clean, clean_file, { { 152, 8 } });
        assert(parse_fault(KTX2_BC1_RGB_PUNCH[..]) == c3d::UNSUPPORTED);
        char[] rgb = with_field(KTX1_BC1_SRGB[..], KTX1_INTERNAL_FORMAT, GL_COMPRESSED_RGB_S3TC_DXT1);
        char[] srgb = with_field(KTX1_BC1_SRGB[..], KTX1_INTERNAL_FORMAT, GL_COMPRESSED_SRGB_S3TC_DXT1);
        assert(parsed_format(rgb) == BC1_RGBA_UNORM);
        assert(parsed_format(srgb) == BC1_RGBA_SRGB);
    };
}

fn void test_bc1_rgb_scan_covers_the_last_level() @test {
    const uint GL_COMPRESSED_SRGB_S3TC_DXT1 = 0x8C4C;
    const usz BLOCK_BYTES = 8;
    const ushort THREE_COLOR_COLOR0 = 0x001F;
    const ushort THREE_COLOR_COLOR1 = 0xF800;
    const uint INDEX_THREE_AT_TEXEL_THREE = 0x000000C0;
    @pool() {
        char[] rgb = with_field(KTX1_BC1_SRGB[..], KTX1_INTERNAL_FORMAT, GL_COMPRESSED_SRGB_S3TC_DXT1);
        assert(parsed_format(rgb) == BC1_RGBA_SRGB);
        char[] punched = with_bc1_block(
            fixture: rgb,
            offset:  rgb.len - BLOCK_BYTES,
            color0:  THREE_COLOR_COLOR0,
            color1:  THREE_COLOR_COLOR1,
            indices: INDEX_THREE_AT_TEXEL_THREE,
        );
        assert(parse_fault(punched) == c3d::UNSUPPORTED);
    };
}

fn void test_orientation_fixture_matches_across_containers() @test {
    @pool() {
        TextureContainerView dds = image::parse_texture_container(tmem, ORIENTATION_DDS[..])!!;
        TextureContainerView ktx1 = image::parse_texture_container(tmem, ORIENTATION_KTX1[..])!!;
        TextureContainerView ktx2 = image::parse_texture_container(tmem, ORIENTATION_KTX2[..])!!;
        check_plain_2d(dds.desc, 4, 4, RGBA8_UNORM);
        check_plain_2d(ktx1.desc, 4, 4, RGBA8_UNORM);
        check_plain_2d(ktx2.desc, 4, 4, RGBA8_UNORM);
        char[4][3] markers = { { 255, 0, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 } };
        for (uint mip = 0; mip < 3; mip++) {
            assert(dds.levels[mip].bytes == ktx1.levels[mip].bytes && dds.levels[mip].bytes == ktx2.levels[mip].bytes);
            assert(dds.levels[mip].bytes[:4] == markers[mip][..], "mip %d", mip);
        }
    };
}

fn void check_real_tool(AssetStore* assets, RealToolRow* row) @local {
    TextureId loaded = image::add_texture_container(assets, row.bytes)!!;
    TextureMipData[material::TEXTURE_MIP_CAPACITY] levels;
    foreach (uint mip, span : row.spans) levels[mip] = { .mip = mip, .bytes = row.bytes[span[0]:span[1]] };
    TextureDesc desc = material::texture_2d_desc(row.width, row.height, row.format);
    desc.generate_mips = false;
    desc.mip_levels = (uint)row.spans.len;
    TextureId supplied = assets.add_texture_mips(desc, levels[:row.spans.len])!!;

    TextureAsset* container = assets.texture(loaded);
    TextureAsset* hand = assets.texture(supplied);
    check_plain_2d(container.desc, row.width, row.height, row.format);
    assert(container.desc.mip_levels == row.spans.len && !container.desc.generate_mips);
    foreach (usz mip, level : hand.supplied_mips) assert(container.supplied_mips[mip].bytes == level.bytes);
}

fn void test_store_helpers_insert_one_owned_copy() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_container_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        @pool() {
            char[] bytes = copied(KTX1_R16[..]);
            sz before = tracker.allocation_count();
            TextureId padded = image::add_texture_container(&assets, bytes)!!;
            assert(tracker.allocation_count() == before + 1);
            bytes[..] = 0;
            TextureAsset* record = assets.texture(padded);
            assert(record.source_kind == SUPPLIED_MIPS && record.supplied_mips.len == 3);
            assert(record.supplied_mips[0].bytes == as_bytes(r16_texels(tmem, 0, 5, 3)));

            TextureId generated = image::add_texture_container(
                assets: &assets,
                bytes:  KTX1_GENERATE[..],
                key:    "container/generated",
            )!!;
            TextureAsset* base = assets.texture(generated);
            assert(base.source_kind == MIP_ZERO && base.desc.generate_mips && base.pixels.len == 16);
            assert(base.pixels == KTX1_GENERATE[68:16]);
            TextureId found = assets.find_texture("container/generated")!!;
            assert(found.index == generated.index && found.generation == generated.generation);
        };
    }
    assert(!tracker.has_leaks());
}

fn void test_store_helper_faults_leave_the_store_unchanged() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore full = create_container_store(&tracker, asset::BUILTIN_TEXTURE_COUNT);
        defer asset::destroy_asset_store(&full);
        AssetStore assets = create_container_store(&tracker);
        defer asset::destroy_asset_store(&assets);
        image::add_texture_container(&assets, LEGACY_DXT1[..], key: "taken")!!;

        @pool() {
            sz allocated = tracker.allocated();
            uint full_slots = full.textures.free_count;
            uint free_slots = assets.textures.free_count;
            assert(@catch(image::add_texture_container(&full, KTX1_R16[..], key: "full")) == c3d::CAPACITY_EXCEEDED);
            assert(@catch(full.find_texture("full")) == NOT_FOUND);
            assert(@catch(image::add_texture_container(&assets, KTX2_BC5[..], key: "taken")) == c3d::INVALID_ARGUMENT);
            assert(@catch(image::add_texture_container(&assets, KTX2_BC5[..], SRGB)) == c3d::INVALID_ARGUMENT);
            char[] short_ktx2 = truncated(KTX2_BC5[..], 200);
            assert(@catch(image::add_texture_container(&assets, short_ktx2)) == c3d::ASSET_FORMAT_ERROR);
            assert(@catch(image::add_texture_container(&assets, KTX2_BC1_RGB_PUNCH[..])) == c3d::UNSUPPORTED);
            assert(tracker.allocated() == allocated);
            assert(full.textures.free_count == full_slots && assets.textures.free_count == free_slots);
        };
    }
    assert(!tracker.has_leaks());
}

fn void test_load_texture_container_reads_files() @test {
    AssetStore assets = create_container_store(mem);
    defer asset::destroy_asset_store(&assets);

    @pool() {
        TextureId texture = image::load_texture_container(&assets, fixture_path("ktx1_r16_5x3.ktx"), key: "heights")!!;
        assert(assets.texture(texture).desc.format == R16_UINT && assets.texture(texture).supplied_mips.len == 3);
        assert(@catch(image::load_texture_container(&assets, fixture_path("missing.ktx2"))) == c3d::ASSET_IO_ERROR);
        String malformed = fixture_path("../truncated.png");
        assert(@catch(image::load_texture_container(&assets, malformed)) == c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_real_tool_files_match_supplied_mips() @test {
    RealToolRow[24] rows = {
        {
            .bytes = $embed("../fixtures/texture/imagemagick/dxt1_8x8.dds"),
            .format = BC1_RGBA_UNORM, .width = 8, .height = 8,
            .spans = { { 128, 32 }, { 160, 8 }, { 168, 8 }, { 176, 8 } },
        },
        {
            .bytes = $embed("../fixtures/texture/imagemagick/dxt5_16x8.dds"),
            .format = BC3_UNORM, .width = 16, .height = 8,
            .spans = { { 128, 128 }, { 256, 32 }, { 288, 16 }, { 304, 16 }, { 320, 16 } },
        },
        {
            .bytes = $embed("../fixtures/texture/bcnencoder/test_decompress_bc1a.dds"),
            .format = BC1_RGBA_UNORM, .width = 48, .height = 48,
            .spans = { { 128, 1152 } },
        },
        {
            .bytes = $embed("../fixtures/texture/bcnencoder/decoding_dds_bc5.dds"),
            .format = BC5_UNORM, .width = 64, .height = 64,
            .spans = {
                { 148, 4096 }, { 4244, 1024 }, { 5268, 256 }, { 5524, 64 },
                { 5588, 16 }, { 5604, 16 }, { 5620, 16 },
            },
        },
        {
            .bytes = $embed("../fixtures/texture/openimageio/dds_dxgi_rgba8_srgb.dds"),
            .format = RGBA8_SRGB, .width = 16, .height = 8,
            .spans = { { 148, 512 } },
        },
        {
            .bytes = $embed("../fixtures/texture/openimageio/dds_dxgi_bc7_srgb.dds"),
            .format = BC7_SRGB, .width = 16, .height = 8,
            .spans = { { 148, 128 } },
        },
        {
            .bytes = $embed("../fixtures/texture/openimageio/dds_npot_bc3_mips.dds"),
            .format = BC3_UNORM, .width = 13, .height = 7,
            .spans = { { 128, 128 }, { 256, 32 }, { 288, 16 }, { 304, 16 } },
        },
        {
            .bytes = $embed("../fixtures/texture/bcnencoder/test_decompress_bc1a.ktx"),
            .format = BC1_RGBA_UNORM, .width = 48, .height = 48,
            .spans = { { 68, 1152 }, { 1224, 288 }, { 1516, 72 }, { 1592, 32 }, { 1628, 8 }, { 1640, 8 } },
        },
        {
            .bytes = $embed("../fixtures/texture/ktxtest/format_bc1_rgba_unorm.ktx"),
            .format = BC1_RGBA_UNORM, .width = 64, .height = 64,
            .spans = {
                { 68, 2048 }, { 2120, 512 }, { 2636, 128 }, { 2768, 32 },
                { 2804, 8 }, { 2816, 8 }, { 2828, 8 },
            },
        },
        {
            // BC1_RGB; no three-color block reads index 3
            .bytes = $embed("../fixtures/texture/ktxtest/format_bc1_rgb_unorm.ktx"),
            .format = BC1_RGBA_UNORM, .width = 64, .height = 64,
            .spans = {
                { 68, 2048 }, { 2120, 512 }, { 2636, 128 }, { 2768, 32 },
                { 2804, 8 }, { 2816, 8 }, { 2828, 8 },
            },
        },
        {
            .bytes = $embed("../fixtures/texture/ktxtest/format_bc3_unorm.ktx"),
            .format = BC3_UNORM, .width = 64, .height = 64,
            .spans = {
                { 68, 4096 }, { 4168, 1024 }, { 5196, 256 }, { 5456, 64 },
                { 5524, 16 }, { 5544, 16 }, { 5564, 16 },
            },
        },
        {
            .bytes = $embed("../fixtures/texture/ktxtest/format_bc4_unorm.ktx"),
            .format = BC4_UNORM, .width = 64, .height = 64,
            .spans = {
                { 68, 2048 }, { 2120, 512 }, { 2636, 128 }, { 2768, 32 },
                { 2804, 8 }, { 2816, 8 }, { 2828, 8 },
            },
        },
        {
            .bytes = $embed("../fixtures/texture/ktxtest/format_bc5_unorm.ktx"),
            .format = BC5_UNORM, .width = 64, .height = 64,
            .spans = {
                { 68, 4096 }, { 4168, 1024 }, { 5196, 256 }, { 5456, 64 },
                { 5524, 16 }, { 5544, 16 }, { 5564, 16 },
            },
        },
        {
            .bytes = $embed("../fixtures/texture/ktxtest/format_bc7_unorm.ktx"),
            .format = BC7_UNORM, .width = 64, .height = 64,
            .spans = {
                { 68, 4096 }, { 4168, 1024 }, { 5196, 256 }, { 5456, 64 },
                { 5524, 16 }, { 5544, 16 }, { 5564, 16 },
            },
        },
        {
            .bytes = $embed("../fixtures/texture/ktx2_samples/2d_rgba8.ktx2"),
            .format = RGBA8_SRGB, .width = 40, .height = 40,
            .spans = { { 2488, 6400 }, { 888, 1600 }, { 488, 400 }, { 388, 100 }, { 372, 16 }, { 368, 4 } },
        },
        {
            .bytes = $embed("../fixtures/texture/ktx2_samples/2d_rgba8_linear.ktx2"),
            .format = RGBA8_UNORM, .width = 40, .height = 40,
            .spans = { { 2488, 6400 }, { 888, 1600 }, { 488, 400 }, { 388, 100 }, { 372, 16 }, { 368, 4 } },
        },
        {
            .bytes = $embed("../fixtures/texture/ktx2_samples/2d_rgba16_linear.ktx2"),
            .format = RGBA16_FLOAT, .width = 40, .height = 40,
            .spans = { { 4608, 12800 }, { 1408, 3200 }, { 608, 800 }, { 408, 200 }, { 376, 32 }, { 368, 8 } },
        },
        {
            .bytes = $embed("../fixtures/texture/ktx2_samples/2d_rgba32_linear.ktx2"),
            .format = RGBA32_FLOAT, .width = 40, .height = 40,
            .spans = { { 8848, 25600 }, { 2448, 6400 }, { 848, 1600 }, { 448, 400 }, { 384, 64 }, { 368, 16 } },
        },
        {
            // BC1_RGB_SRGB; no three-color block reads index 3
            .bytes = $embed("../fixtures/texture/ktx2_samples/2d_bc1.ktx2"),
            .format = BC1_RGBA_SRGB, .width = 40, .height = 40,
            .spans = { { 648, 800 }, { 448, 200 }, { 376, 72 }, { 344, 32 }, { 336, 8 }, { 328, 8 } },
        },
        {
            .bytes = $embed("../fixtures/texture/ktx2_samples/2d_bc3.ktx2"),
            .format = BC3_SRGB, .width = 40, .height = 40,
            .spans = { { 992, 1600 }, { 592, 400 }, { 448, 144 }, { 384, 64 }, { 368, 16 }, { 352, 16 } },
        },
        {
            .bytes = $embed("../fixtures/texture/ktx2_samples/2d_bc4.ktx2"),
            .format = BC4_UNORM, .width = 40, .height = 40,
            .spans = { { 648, 800 }, { 448, 200 }, { 376, 72 }, { 344, 32 }, { 336, 8 }, { 328, 8 } },
        },
        {
            .bytes = $embed("../fixtures/texture/ktx2_samples/2d_bc5.ktx2"),
            .format = BC5_UNORM, .width = 40, .height = 40,
            .spans = { { 992, 1600 }, { 592, 400 }, { 448, 144 }, { 384, 64 }, { 368, 16 }, { 352, 16 } },
        },
        {
            .bytes = $embed("../fixtures/texture/ktx2_samples/2d_bc7.ktx2"),
            .format = BC7_SRGB, .width = 40, .height = 40,
            .spans = { { 976, 1600 }, { 576, 400 }, { 432, 144 }, { 368, 64 }, { 352, 16 }, { 336, 16 } },
        },
        {
            .bytes = $embed("../fixtures/texture/openimageio/rgba8_unorm_bc7.ktx2"),
            .format = BC7_UNORM, .width = 40, .height = 40,
            .spans = { { 224, 1600 } },
        },
    };
    AssetStore assets = create_container_store(mem);
    defer asset::destroy_asset_store(&assets);

    foreach (&row : rows) check_real_tool(&assets, row);
}

fn void test_real_tool_files_outside_the_subset_are_unsupported() @test {
    const uint GL_RGBA8 = 0x8058;
    const uint GL_RGBA = 0x1908;
    @pool() {
        assert(parse_fault($embed("../fixtures/texture/openimageio/dds_npot_rgba8_mips.dds")) == c3d::UNSUPPORTED);
        assert(parse_fault($embed("../fixtures/texture/ktxtest/endian_big_type_ubyte_r8g8.ktx")) == c3d::UNSUPPORTED);
        char[] array = $embed("../fixtures/texture/ktxtest/array_2_elements_2d.ktx");
        assert(parse_fault(array) == c3d::UNSUPPORTED);
        char[] array_rgba8 = with_field(with_field(array, KTX1_INTERNAL_FORMAT, GL_RGBA8), KTX1_GL_FORMAT, GL_RGBA);
        assert(parse_fault(array_rgba8) == c3d::UNSUPPORTED);
        assert(parse_fault(with_field(array_rgba8, KTX1_ARRAY_ELEMENTS, 0)) == c3d::ASSET_FORMAT_ERROR);
        assert(parse_fault(REAL_SUPERCOMPRESSED[..]) == c3d::UNSUPPORTED);
    };
}
