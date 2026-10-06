module c3d::test::texture_containers;

import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::material;
import std::core::bitorder;
const char[*] DX10_RGBA8_SRGB @local = $embed("../fixtures/texture/dx10_rgba8_srgb_5x3.dds");
const char[*] DX10_BC7_SRGB @local = $embed("../fixtures/texture/dx10_bc7_srgb_5x3.dds");
const char[*] DX10_FORMAT16 @local = $embed("../fixtures/texture/dx10_format16.dds");
const char[*] LEGACY_DXT1 @local = $embed("../fixtures/texture/legacy_dxt1_6x6.dds");
const char[*] LEGACY_RGBA16F @local = $embed("../fixtures/texture/legacy_rgba16f_4x4.dds");
const char[*] LEGACY_RGBA8 @local = $embed("../fixtures/texture/legacy_rgba8_2x2.dds");
const uint MAXIMUM_EXTENT @local = uint::max;
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
        assert(@catch(image::parse_texture_container(&scratch, short_dds)) == c3d::ASSET_FORMAT_ERROR);
    };
    assert(scratch.total_allocation_count() == 0);
}
