module c3d::test::texture;

import c3d;
import c3d::material;
import c3d::asset;
import c3d::render @public;
import c3d::render::post;
import std::math;
import c3d::shader;
import c3d::test::loading_fixtures;
import gpu;

const usz BAND_ALLOWANCE_ONE_MIB @local = 1 << 20;
const usz BAND_ALLOWANCE_EIGHT_MIB @local = 8 << 20;

fn void test_mips_distinguish_srgb_from_linear_alpha() @test {
    char[16] pixels = { 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0, 255, 255, 255, 255 };
    TextureMipChain srgb = render::create_texture_mips(
        allocator: mem,
        desc: material::texture_2d_desc(2, 2, RGBA8_SRGB),
        pixels: pixels[..],
    )!!;
    defer render::destroy_texture_mips(&srgb);
    TextureMipChain linear = render::create_texture_mips(
        allocator: mem,
        desc: material::texture_2d_desc(2, 2, RGBA8_UNORM),
        pixels: pixels[..],
    )!!;
    defer render::destroy_texture_mips(&linear);

    assert(srgb.mip_count == 2 && srgb.offsets[1] == 16 && srgb.pixels.len == 20);
    char[4] expected_srgb = { 188, 188, 188, 128 };
    char[4] expected_linear = { 128, 128, 128, 128 };
    assert(srgb.pixels[16..] == expected_srgb[..]);
    assert(linear.pixels[16..] == expected_linear[..]);
    assert(srgb.pixels[:16] == pixels[..]);
}

fn void test_mips_include_odd_edge_and_single_axis() @test {
    char[12] pixels = { 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255 };
    TextureMipChain chain = render::create_texture_mips(
        allocator: mem,
        desc: material::texture_2d_desc(3, 1, RGBA8_UNORM),
        pixels: pixels[..],
    )!!;
    defer render::destroy_texture_mips(&chain);

    char[4] expected = { 85, 85, 85, 255 };
    assert(chain.mip_count == 2 && chain.pixels[12..] == expected[..]);
    assert(material::texture_mip_count(1, 7) == 3);
}

fn void test_float_mips_keep_values_above_one() @test {
    float[8] pixels = { -2, 4, 6, 1, -4, 8, 12, 1 };
    char[] bytes = ((char*)&pixels[0])[:pixels.len * float::size];
    TextureMipChain chain = render::create_texture_mips(
        allocator: mem,
        desc: material::texture_2d_desc(2, 1, RGBA32_FLOAT),
        pixels: bytes,
    )!!;
    defer render::destroy_texture_mips(&chain);

    float[] tail = ((float*)(chain.pixels.ptr + chain.offsets[1]))[:4];
    float[4] expected = { -3, 6, 9, 1 };
    assert(tail == expected[..]);
}

fn void test_half_float_mips_keep_native_storage() @test {
    ushort[8] pixels = { 0xC000, 0x4400, 0x4600, 0x3C00, 0xC400, 0x4800, 0x4A00, 0x3C00 };
    char[] bytes = ((char*)&pixels[0])[:pixels.len * ushort::size];
    TextureMipChain chain = render::create_texture_mips(
        allocator: mem,
        desc: material::texture_2d_desc(2, 1, RGBA16_FLOAT),
        pixels: bytes,
    )!!;
    defer render::destroy_texture_mips(&chain);

    ushort[] tail = ((ushort*)(chain.pixels.ptr + chain.offsets[1]))[:4];
    ushort[4] expected = { 0xC200, 0x4600, 0x4880, 0x3C00 };
    assert(tail == expected[..]);
}

fn void test_half_float_mips_round_to_nearest_even() @test {
    ushort[8] pixels = { 0x3C00, 0x3C01, 0x0001, 0xC000, 0x3C01, 0x3C02, 0x0003, 0x4000 };
    char[] bytes = ((char*)&pixels[0])[:pixels.len * ushort::size];
    TextureMipChain chain = render::create_texture_mips(
        allocator: mem,
        desc: material::texture_2d_desc(2, 1, RGBA16_FLOAT),
        pixels: bytes,
    )!!;
    defer render::destroy_texture_mips(&chain);

    ushort[] tail = ((ushort*)(chain.pixels.ptr + chain.offsets[1]))[:4];
    ushort[4] expected = { 0x3C00, 0x3C02, 0x0002, 0x0000 };
    assert(tail == expected[..]);
}

fn void test_texture_input_faults_are_distinct() @test {
    material::TextureDesc desc = material::texture_2d_desc(2, 2, RGBA8_UNORM);
    if (catch excuse = render::create_texture_mips(mem, desc, (char[]){})) {
        assert(excuse == c3d::ASSET_DATA_UNAVAILABLE);
    } else {
        assert(false, "Invalid input was accepted");
    }

    char[4] short_pixels = {};
    if (catch excuse = render::create_texture_mips(mem, desc, short_pixels[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Invalid input was accepted");
    }

    desc.format = BC7_UNORM;
    if (catch excuse = render::create_texture_mips(mem, desc, short_pixels[..])) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "Invalid input was accepted");
    }
}

fn void test_mips_weight_fractional_footprints_on_both_axes() @test {
    char[60] pixels;
    for (usz pixel = 0; pixel < 15; pixel++) {
        pixels[pixel * 4] = pixel % 5 == 4 ? 255 : 0;
        pixels[pixel * 4 + 2] = pixel / 5 == 2 ? 255 : 0;
        pixels[pixel * 4 + 3] = 255;
    }
    char[60] original = pixels;
    TextureMipChain chain = render::create_texture_mips(
        allocator: mem,
        desc: material::texture_2d_desc(5, 3, RGBA8_UNORM),
        pixels: pixels[..],
    )!!;
    defer render::destroy_texture_mips(&chain);

    char[12] expected = { 0, 0, 85, 255, 102, 0, 85, 255, 51, 0, 85, 255 };
    assert(chain.mip_count == 3 && chain.offsets[1] == 60 && chain.offsets[2] == 68);
    assert(chain.pixels[60..] == expected[..]);
    assert(pixels == original && chain.pixels[:60] == original[..]);
}

fn void test_disabled_mips_preserve_an_independent_copy() @test {
    char[8] pixels = { 20, 40, 60, 80, 100, 120, 140, 160 };
    material::TextureDesc desc = material::texture_2d_desc(1, 2, RGBA8_UNORM);
    desc.generate_mips = false;
    TextureMipChain chain = render::create_texture_mips(mem, desc, pixels[..])!!;
    defer render::destroy_texture_mips(&chain);

    assert(chain.mip_count == 1 && chain.offsets[0] == 0);
    assert(chain.pixels == pixels[..] && chain.pixels.ptr != pixels[..].ptr);
    chain.pixels[0] = 0;
    assert(pixels[0] == 20);
}

fn void test_texture_descriptor_faults_precede_missing_pixels() @test {
    material::TextureDesc[7] descriptors = {
        { .width = 0, .height = 1, .layers = 1, .mip_levels = 1 },
        { .width = 1, .height = 0, .layers = 1, .mip_levels = 1 },
        { .width = 1, .height = 1, .layers = 1, .mip_levels = 2 },
        { .width = uint::max, .height = uint::max, .layers = 1, .mip_levels = 1 },
        { .width = 1, .height = 1, .depth = 1, .layers = 1, .mip_levels = 1, .generate_mips = true },
        { .width = 1, .height = 1, .layers = 2, .mip_levels = 1 },
        { .width = 1, .height = 1, .layers = 1, .mip_levels = 1, .is_cube = true },
    };
    foreach (index, desc : descriptors) {
        if (catch excuse = render::create_texture_mips(mem, desc, (char[]){})) {
            assert(excuse == (index < 4 || index == 6 ? c3d::INVALID_ARGUMENT : c3d::UNSUPPORTED));
        } else {
            assert(false, "Unsupported descriptor was accepted");
        }
    }
}

fn void test_texture_uv_transform_order() @test {
    Vec4 row0;
    Vec4 row1;
    render::texture_uv_rows(
        transform: { .offset = { 3, 4 }, .scale = { 2, 3 }, .rotation = math::PI / 2 },
        row0: &row0,
        row1: &row1,
    );
    Vec3 input_uv = { 1, 2, 1 };
    float x = row0.x * input_uv.x + row0.y * input_uv.y + row0.z;
    float y = row1.x * input_uv.x + row1.y * input_uv.y + row1.z;
    assert(math::abs(x + 3) < 0.00001f && math::abs(y - 6) < 0.00001f);
    assert(row0.w == 0 && row1.w == 0);
}

fn void test_material_map_packs_uv_selection_and_identity() @test {
    char[] bytes = mem::new_array(char, render::MATERIAL_STRIDE);
    defer free(bytes.ptr);
    Material material = material::basic({
        .color = { 0.5f, 0.25f, 1, 0.75f },
        .map = material::texture_slot(uv_set: 1),
    });
    TextureBinding binding = {
        .texture_index = (gpu::TextureIndex)7,
        .sampler_index = (gpu::SamplerIndex)3,
        .present = true,
    };
    render::write_material_block(bytes, &material, { .base_color = binding });

    c3d::shader::BasicMaterialGpu* packed = (c3d::shader::BasicMaterialGpu*)bytes.ptr;
    assert(packed.map.texture_index == (gpu::TextureIndex)7 && packed.map.sampler_index == (gpu::SamplerIndex)3);
    assert(packed.map_flags == 0x21);
    assert(packed.map.uv_offset == (Vec2){ 0, 0 });
    assert(packed.map.uv_linear == (Vec4){ 1, 0, 0, 1 });
    assert(packed.color == material.basic.color);
}

fn void test_supplied_rgba_size_wrap_is_invalid_argument() @test {
    char[1] storage;
    TextureMipData[1] levels = {{ .bytes = storage[:0] }};
    material::TextureDesc desc = material::texture_2d_desc(1u << 31, 1u << 31, RGBA8_UNORM);
    desc.generate_mips = false;
    if (catch excuse = render::create_supplied_texture_mips(mem, desc, levels[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Wrapped RGBA footprint was accepted");
    }
}

fn void test_supplied_bc7_size_wrap_is_invalid_argument() @test {
    char[1] storage;
    TextureMipData[1] levels = {{ .bytes = storage[:0] }};
    material::TextureDesc desc = material::texture_2d_desc(uint::max, uint::max, BC7_UNORM);
    desc.generate_mips = false;
    if (catch excuse = render::create_supplied_texture_mips(mem, desc, levels[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Wrapped BC7 footprint was accepted");
    }
}

fn void test_texture_mips_accept_a_single_mip_rgba8_volume() @test {
    char[] pixels = post::identity_lut(mem, 4);
    defer free(pixels.ptr);
    TextureMipChain chain = render::create_texture_mips(mem, post::identity_lut_desc(4), pixels)!!;
    defer render::destroy_texture_mips(&chain);

    assert(chain.mip_count == 1 && chain.layer_count == 1);
    assert(chain.pixels.len == 256);
    assert(chain.pixels[((3 * 4 + 2) * 4 + 1) * 4] == 85);
}

fn void test_texture_mips_reject_volumes_with_mips_or_other_formats() @test {
    char[] pixels = post::identity_lut(mem, 2);
    defer free(pixels.ptr);

    material::TextureDesc mipped = post::identity_lut_desc(2);
    mipped.generate_mips = true;
    if (catch excuse = render::create_texture_mips(mem, mipped, pixels)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false);
    }

    material::TextureDesc half = material::texture_3d_desc(2, 2, 2, RGBA16_FLOAT);
    if (catch excuse = render::create_texture_mips(mem, half, pixels)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false);
    }

    TextureMipData[1] levels = {{ .mip = 0, .layer = 0, .bytes = pixels }};
    if (catch excuse = render::create_supplied_texture_mips(mem, post::identity_lut_desc(2), levels[..])) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false);
    }
}

fn void test_mip_bytes_match_the_backend_footprint() @test {
    const uint WIDTH = 13;
    const uint HEIGHT = 5;
    foreach (format : PixelFormat::values) {
        material::TextureDesc desc = material::texture_2d_desc(WIDTH, HEIGHT, format);
        desc.generate_mips = false;
        desc.mip_levels = material::texture_mip_count(WIDTH, HEIGHT);
        gpu::TextureDesc device = {
            .width = WIDTH,
            .height = HEIGHT,
            .mip_levels = desc.mip_levels,
            .array_layers = 1,
            .format = render::texture_format(format),
        };
        for (uint mip = 0; mip < desc.mip_levels; mip++) {
            usz bytes = material::texture_mip_bytes(desc, mip)!!;
            assert(bytes == gpu::texture_mip_bytes(&device, mip)!!, "%s mip %d", format, mip);
        }
    }
    material::TextureDesc huge = material::texture_2d_desc(uint::max, uint::max, RGBA32_FLOAT);
    assert(@catch(material::texture_mip_bytes(huge, 0)) == c3d::INVALID_ARGUMENT);
}

fn char[] assemble_texture_bands(
    material::TextureDesc desc,
    uint mip,
    char[] source,
    uint row_limit,
    usz byte_allowance = 0,
) @local {
    char[] copied = alloc::new_array(mem, char, (sz)source.len);
    uint depth = desc.depth ? material::texture_mip_extent(desc.depth, mip) : 1;
    uint height = material::texture_mip_extent(desc.height, mip);
    uint block_height = material::texture_is_compressed(desc.format) ? 4 : 1;
    uint block_rows = (height + block_height - 1) / block_height;
    usz copied_bytes;
    for (uint layer = 0; layer < desc.layers; layer++) {
        for (uint slice = 0; slice < depth; slice++) {
            for (uint row = 0; row < block_rows;) {
                uint rows = math::min(row_limit, block_rows - row);
                if (byte_allowance) {
                    TextureBand minimum = render::texture_band(
                        desc: desc,
                        mip: mip,
                        layer: layer,
                        slice: slice,
                        first_block_row: row,
                        block_rows: 1,
                    )!!;
                    assert(minimum.byte_count <= byte_allowance);
                    rows = (uint)math::min((usz)rows, byte_allowance / minimum.row_bytes);
                }
                TextureBand band = render::texture_band(
                    desc: desc,
                    mip: mip,
                    layer: layer,
                    slice: slice,
                    first_block_row: row,
                    block_rows: rows,
                )!!;
                assert(band.x == 0 && band.y == row * block_height && band.z == slice);
                assert(band.mip == mip && band.layer == layer && band.depth == 1);
                assert(band.height == math::min(rows * block_height, height - band.y));
                assert(band.byte_count == band.row_bytes * rows);
                if (byte_allowance) assert(band.byte_count <= byte_allowance);
                if (byte_allowance && rows < math::min(row_limit, block_rows - row)) {
                    assert(((usz)rows + 1) * band.row_bytes > byte_allowance);
                }
                copied_bytes += band.byte_count;
                assert(band.source_offset + band.byte_count <= source.len);
                mem::copy(
                    dst: copied.ptr + (sz)band.source_offset,
                    src: source.ptr + (sz)band.source_offset,
                    len: (sz)band.byte_count,
                );
                row += rows;
            }
        }
    }
    assert(copied_bytes == source.len);
    return copied;
}

fn void test_texture_bands_copy_each_cube_face_and_volume_slice() @test {
    material::TextureDesc cube = material::texture_cube_desc(4, RGBA8_UNORM);
    cube.generate_mips = false;
    char[6 * 4 * 4 * 4] cube_pixels;
    foreach (index, &value : cube_pixels) *value = (char)(index % 251 + 1);
    char[] cube_copy = assemble_texture_bands(
        desc: cube,
        mip: 0,
        source: cube_pixels[..],
        row_limit: 3,
    );
    defer alloc::free(mem, cube_copy.ptr);
    assert(cube_copy == cube_pixels[..]);
    TextureBand face = render::texture_band(
        desc: cube,
        mip: 0,
        layer: 4,
        slice: 0,
        first_block_row: 3,
        block_rows: 1,
    )!!;
    assert(face.source_offset == 4 * 64 + 3 * 16 && face.byte_count == 16 && face.layer_bytes == 64);

    foreach (format : (PixelFormat[2]){ RGBA8_UNORM, RGBA8_SRGB }) {
        material::TextureDesc volume = material::texture_3d_desc(
            width: 8,
            height: 4,
            depth: 3,
            format: format,
        );
        char[8 * 4 * 3 * 4] pixels;
        foreach (index, &value : pixels) *value = (char)(index % 251 + 1);
        char[] copy = assemble_texture_bands(
            desc: volume,
            mip: 0,
            source: pixels[..],
            row_limit: 3,
        );
        defer alloc::free(mem, copy.ptr);
        assert(copy == pixels[..]);
        TextureMipChain reference = render::create_texture_mips(mem, volume, pixels[..])!!;
        defer render::destroy_texture_mips(&reference);
        assert(copy == reference.pixels);
        TextureBand band = render::texture_band(
            desc: volume,
            mip: 0,
            layer: 0,
            slice: 2,
            first_block_row: 3,
            block_rows: 1,
        )!!;
        assert(band.source_offset == 2 * 128 + 3 * 32);
        assert(band.byte_count == 32 && band.y == 3 && band.z == 2 && band.depth == 1);
    }
}

fn void test_texture_bands_copy_uncompressed_storage_widths() @test {
    foreach (format : (PixelFormat[3]){ RGBA16_FLOAT, RGBA32_FLOAT, R16_UINT }) {
        material::TextureDesc desc = material::texture_2d_desc(9, 5, format);
        desc.generate_mips = false;
        usz bytes = material::texture_mip_bytes(desc, 0)!!;
        char[] pixels = alloc::new_array(mem, char, (sz)bytes);
        defer alloc::free(mem, pixels.ptr);
        foreach (index, &value : pixels) *value = (char)(index % 251 + 1);
        char[] copy = assemble_texture_bands(
            desc: desc,
            mip: 0,
            source: pixels,
            row_limit: 2,
        );
        defer alloc::free(mem, copy.ptr);
        assert(copy == pixels);
        TextureBand band = render::texture_band(
            desc: desc,
            mip: 0,
            layer: 0,
            slice: 0,
            first_block_row: 4,
            block_rows: 1,
        )!!;
        assert(band.row_bytes == 9 * material::texture_block_bytes(format));
        assert(band.source_offset == 4 * band.row_bytes && band.height == 1);
        assert(band.alignment >= material::texture_block_bytes(format));
    }
}

fn void test_texture_bands_keep_supplied_compressed_edge_blocks() @test {
    foreach (format : (PixelFormat[2]){ BC1_RGBA_UNORM, BC7_UNORM }) {
        material::TextureDesc desc = material::texture_2d_desc(7, 5, format);
        desc.generate_mips = false;
        desc.mip_levels = 3;
        usz block_bytes = format == BC1_RGBA_UNORM ? 8 : 16;
        TextureMipData[3] levels;
        char[] storage = alloc::new_array(mem, char, (sz)(block_bytes * 6));
        defer alloc::free(mem, storage.ptr);
        usz offset;
        for (uint mip = 0; mip < desc.mip_levels; mip++) {
            usz bytes = mip ? block_bytes : block_bytes * 4;
            levels[mip] = { .mip = mip, .layer = 0, .bytes = storage[offset:bytes] };
            foreach (index, &value : levels[mip].bytes) *value = (char)(1 + (usz)mip * 40 + (usz)index);
            char[] copied = assemble_texture_bands(
                desc: desc,
                mip: mip,
                source: levels[mip].bytes,
                row_limit: 1,
            );
            defer alloc::free(mem, copied.ptr);
            assert(copied == levels[mip].bytes);
            offset += bytes;
        }
        assert(offset == storage.len);
        TextureMipChain reference = render::create_supplied_texture_mips(mem, desc, levels[..])!!;
        defer render::destroy_texture_mips(&reference);
        assert(reference.pixels == storage);
        TextureBand edge = render::texture_band(
            desc: desc,
            mip: 0,
            layer: 0,
            slice: 0,
            first_block_row: 1,
            block_rows: 1,
        )!!;
        assert(edge.width == 7 && edge.y == 4 && edge.height == 1);
        assert(edge.row_bytes == block_bytes * 2 && edge.byte_count == block_bytes * 2);
        assert(edge.source_offset == block_bytes * 2 && edge.alignment == block_bytes);
    }
}

fn void test_texture_bands_preserve_volume_and_generated_rejections() @test {
    material::TextureDesc volume = material::texture_3d_desc(
        width: 8,
        height: 4,
        depth: 3,
        format: RGBA8_UNORM,
    );
    foreach (format : (PixelFormat[4]){ RGBA16_FLOAT, RGBA32_FLOAT, R16_UINT, BC7_UNORM }) {
        volume.format = format;
        if (catch excuse = render::texture_band(
            desc: volume,
            mip: 0,
            layer: 0,
            slice: 0,
            first_block_row: 0,
            block_rows: 1,
        )) {
            assert(excuse == c3d::UNSUPPORTED);
        } else {
            assert(false, "Unsupported volume band was accepted");
        }
    }
    volume.format = RGBA8_UNORM;
    volume.generate_mips = true;
    if (catch excuse = render::texture_band(
        desc: volume,
        mip: 0,
        layer: 0,
        slice: 0,
        first_block_row: 0,
        block_rows: 1,
    )) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "Generated volume band was accepted");
    }
    material::TextureDesc compressed = material::texture_2d_desc(7, 5, BC1_RGBA_UNORM);
    if (catch excuse = render::texture_band(
        desc: compressed,
        mip: 0,
        layer: 0,
        slice: 0,
        first_block_row: 0,
        block_rows: 1,
    )) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "Generated compressed band was accepted");
    }
}

fn void test_texture_band_planning_rejects_invalid_ranges_without_allocating() @test {
    material::TextureDesc desc = material::texture_2d_desc(9, 5, RGBA8_UNORM);
    foreach (rows : (uint[3]){ 0, 2, uint::max }) {
        if (catch excuse = render::texture_band(
            desc: desc,
            mip: 0,
            layer: 0,
            slice: 0,
            first_block_row: 4,
            block_rows: rows,
        )) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "Out-of-range band was accepted");
        }
    }
    desc.width = uint::max;
    desc.height = uint::max;
    if (catch excuse = render::texture_band(
        desc: desc,
        mip: 0,
        layer: 0,
        slice: 0,
        first_block_row: 0,
        block_rows: 1,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Unrepresentable band layout was accepted");
    }
}

fn void test_supplied_compressed_cube_keeps_existing_render_rejection() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    foreach (format : (PixelFormat[2]){ BC1_RGBA_UNORM, BC7_UNORM }) {
        material::TextureDesc desc = material::texture_cube_desc(8, format);
        desc.generate_mips = false;
        desc.mip_levels = 4;
        TextureMipData[4 * 6] levels;
        usz total_bytes;
        for (uint mip = 0; mip < desc.mip_levels; mip++) {
            total_bytes += material::texture_mip_bytes(desc, mip)!! * desc.layers;
        }
        char[] storage = alloc::new_array(mem, char, (sz)total_bytes);
        defer alloc::free(mem, storage.ptr);
        usz offset;
        for (uint mip = 0; mip < desc.mip_levels; mip++) {
            usz layer_bytes = material::texture_mip_bytes(desc, mip)!!;
            for (uint layer = 0; layer < desc.layers; layer++) {
                usz index = (usz)mip * desc.layers + layer;
                levels[index] = { .mip = mip, .layer = layer, .bytes = storage[offset:layer_bytes] };
                foreach (position, &byte : levels[index].bytes) {
                    *byte = (char)((usz)mip * 40 + (usz)layer * 10 + (usz)position + 1);
                }
                offset += layer_bytes;
            }
        }
        assert(offset == storage.len);
        TextureId texture = assets.add_texture_mips(desc, levels[..])!!;
        TextureAsset* stored = assets.texture(texture);
        assert(stored.source_kind == TextureSourceKind.SUPPLIED_MIPS);
        assert(stored.supplied_mips.len == levels.len);
        foreach (index, level : stored.supplied_mips) {
            assert(level.mip == levels[index].mip && level.layer == levels[index].layer);
            assert(level.bytes == levels[index].bytes && level.bytes.ptr != levels[index].bytes.ptr);
        }

        if (catch excuse = render::create_supplied_texture_mips(mem, desc, stored.supplied_mips)) {
            assert(excuse == c3d::UNSUPPORTED);
        } else {
            assert(false, "Supplied compressed cube unexpectedly became renderer-supported");
        }
        foreach (level : stored.supplied_mips) {
            if (catch excuse = render::texture_band(
                desc: desc,
                mip: level.mip,
                layer: level.layer,
                slice: 0,
                first_block_row: 0,
                block_rows: 1,
            )) {
                assert(excuse == c3d::UNSUPPORTED);
            } else {
                assert(false, "Compressed cube band changed the existing render rejection");
            }
        }
    }
}

fn void test_texture_bands_converge_with_canonical_byte_allowances() @test {
    foreach (desc : (material::TextureDesc[11]){
        material::texture_2d_desc(2049, 1025, RGBA8_UNORM),
        material::texture_cube_desc(4, RGBA8_UNORM),
        material::texture_3d_desc(
            width: 8,
            height: 4,
            depth: 3,
            format: RGBA8_UNORM,
        ),
        material::texture_3d_desc(
            width: 8,
            height: 4,
            depth: 3,
            format: RGBA8_SRGB,
        ),
        material::texture_2d_desc(7, 5, BC1_RGBA_UNORM),
        material::texture_2d_desc(7, 5, BC7_UNORM),
        material::texture_2d_desc(9, 5, RGBA16_FLOAT),
        material::texture_2d_desc(9, 5, RGBA32_FLOAT),
        material::texture_2d_desc(9, 5, R16_UINT),
        material::texture_2d_desc(1, 17, RGBA8_UNORM),
        material::texture_2d_desc(17, 1, RGBA8_UNORM),
    }) {
        desc.generate_mips = false;
        desc.mip_levels = desc.depth ? 1 : material::texture_mip_count(desc.width, desc.height);
        for (uint mip = 0; mip < desc.mip_levels; mip++) {
            usz bytes = material::texture_mip_bytes(desc, mip)!! * desc.layers;
            char[] pixels = loading_fixtures::preparation_texture_bytes(mem, bytes);
            defer alloc::free(mem, pixels.ptr);
            TextureBand minimum = render::texture_band(
                desc: desc,
                mip: mip,
                layer: 0,
                slice: 0,
                first_block_row: 0,
                block_rows: 1,
            )!!;
            if (desc.width == 2049 && mip == 0) assert(bytes > BAND_ALLOWANCE_EIGHT_MIB);
            foreach (allowance : (usz[4]){ minimum.byte_count, BAND_ALLOWANCE_ONE_MIB, BAND_ALLOWANCE_EIGHT_MIB, 0 }) {
                char[] copied = assemble_texture_bands(
                    desc: desc,
                    mip: mip,
                    source: pixels,
                    row_limit: uint::max,
                    byte_allowance: allowance,
                );
                defer alloc::free(mem, copied.ptr);
                assert(copied == pixels);
            }
        }
    }
}

fn void expect_texture_source_fault(TextureAsset* source, fault expected) @local {
    assert(@catch(render::check_prepare_texture_source(source)) == expected);
    if (source.source_kind == TextureSourceKind.MIP_ZERO) {
        assert(@catch(render::create_texture_mips(mem, source.desc, source.pixels)) == expected);
    } else {
        assert(@catch(render::create_supplied_texture_mips(mem, source.desc, source.supplied_mips)) == expected);
    }
}

fn void test_prepared_texture_sources_keep_synchronous_faults_and_exact_lengths() @test {
    char[65] storage;
    TextureAsset source = {
        .desc = material::texture_2d_desc(4, 4, RGBA8_UNORM),
        .source_kind = TextureSourceKind.MIP_ZERO,
        .pixels = storage[..],
    };
    source.desc.generate_mips = false;
    expect_texture_source_fault(&source, c3d::INVALID_ARGUMENT);
    source.pixels = storage[:64];
    source.desc.mip_levels = 2;
    expect_texture_source_fault(&source, c3d::INVALID_ARGUMENT);
    source.desc.mip_levels = 1;
    source.pixels = {};
    expect_texture_source_fault(&source, c3d::ASSET_DATA_UNAVAILABLE);
    source.desc.layers = 0;
    expect_texture_source_fault(&source, c3d::UNSUPPORTED);
    source.desc = material::texture_cube_desc(4, RGBA8_UNORM);
    source.desc.height = 3;
    expect_texture_source_fault(&source, c3d::INVALID_ARGUMENT);
    source.desc = material::texture_2d_desc(4, 4, BC1_RGBA_UNORM);
    source.desc.generate_mips = false;
    expect_texture_source_fault(&source, c3d::UNSUPPORTED);
    source.desc = material::texture_3d_desc(
        width: 4,
        height: 4,
        depth: 1,
        format: RGBA16_FLOAT,
    );
    expect_texture_source_fault(&source, c3d::UNSUPPORTED);

    TextureMipData[1] level = {{ .mip = 0, .layer = 0, .bytes = storage[..] }};
    source = {
        .desc = material::texture_2d_desc(4, 4, RGBA8_UNORM),
        .source_kind = TextureSourceKind.SUPPLIED_MIPS,
        .supplied_mips = level[..],
    };
    source.desc.generate_mips = false;
    expect_texture_source_fault(&source, c3d::INVALID_ARGUMENT);
    level[0].bytes = storage[:64];
    source.desc.depth = 1;
    expect_texture_source_fault(&source, c3d::UNSUPPORTED);

    TextureMipData[material::TEXTURE_MIP_CAPACITY + 1] oversized;
    foreach (index, &entry : oversized) *entry = { .mip = (uint)index, .layer = 0, .bytes = storage[:1] };
    source.desc.depth = 0;
    source.desc.mip_levels = material::TEXTURE_MIP_CAPACITY + 1;
    source.supplied_mips = oversized[..];
    expect_texture_source_fault(&source, c3d::INVALID_ARGUMENT);
    assert(@catch(render::texture_band(
        desc: source.desc,
        mip: 0,
        layer: 0,
        slice: 0,
        first_block_row: 0,
        block_rows: 1,
    )) == c3d::INVALID_ARGUMENT);
}
