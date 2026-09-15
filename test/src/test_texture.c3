module c3d::test::texture;

import c3d;
import c3d::material;
import c3d::asset;
import c3d::render;
import c3d::render::post;
import std::math;
import c3d::shader;
import gpu;

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
    assert(render::texture_mip_count(1, 7) == 3);
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
