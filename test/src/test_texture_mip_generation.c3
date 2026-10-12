module c3d::render;

import c3d::material;
import c3d::test::loading_fixtures;
import std::math;

const usz TEXEL_BYTES @local = 4;
const double CODE_MAX @local = 255;
const ulong FNV_OFFSET @local = 0xcbf29ce484222325;
const ulong FNV_PRIME @local = 0x100000001b3;
const uint IMAGE_SEED @local = 0x2545f491;
const uint SWEEP_STEPS @local = 1_000_000;
const ulong ODD_SRGB_DIGEST @local = 0x1061d393becd4e46;
const ulong EVEN_SRGB_DIGEST @local = 0x9a7fa2d2274fd02e;

fn char[] random_texels(usz bytes, uint seed) @local {
    return loading_fixtures::preparation_texture_bytes(mem, bytes, seed);
}

fn ulong chain_digest(char[] bytes) @local {
    ulong hash = FNV_OFFSET;
    foreach (byte : bytes) hash = (hash ^ byte) * FNV_PRIME;
    return hash;
}

fn ulong srgb_chain_digest(uint width, uint height) @local {
    char[] pixels = random_texels((usz)width * height * TEXEL_BYTES, IMAGE_SEED);
    defer alloc::free(mem, pixels.ptr);
    TextureMipChain chain = create_texture_mips(mem, material::texture_2d_desc(width, height, RGBA8_SRGB), pixels)!!;
    defer destroy_texture_mips(&chain);
    return chain_digest(chain.pixels);
}

fn void test_srgb_tables_match_the_reference() @test {
    for (usz code = 0; code < SRGB_CODE_COUNT; code++) {
        assert(srgb_decode_table[code] == decode_srgb(code / CODE_MAX) * CODE_MAX);
    }
    for (uint step = 0; step <= SWEEP_STEPS; step++) {
        double value = (double)step * CODE_MAX / SWEEP_STEPS;
        assert(encode_srgb_code(value) == srgb_reference_code(value));
    }
    foreach (threshold : srgb_encode_thresholds) {
        ulong bits = bitcast(threshold, ulong);
        double below = bitcast(bits - 1, double);
        double above = bitcast(bits + 1, double);
        assert(encode_srgb_code(below) == srgb_reference_code(below));
        assert(encode_srgb_code(threshold) == srgb_reference_code(threshold));
        assert(encode_srgb_code(above) == srgb_reference_code(above));
    }
    assert(encode_srgb_code(-1.0) == 0 && encode_srgb_code(CODE_MAX * 2) == CODE_MAX);
}

fn void test_mip_chain_bytes_are_unchanged() @test {
    assert(srgb_chain_digest(37, 19) == ODD_SRGB_DIGEST);
    assert(srgb_chain_digest(64, 64) == EVEN_SRGB_DIGEST);
}

fn void expect_generated_bands_equal(material::TextureDesc desc, char[] pixels, uint row_limit) @local {
    TextureMipChain reference = create_texture_mips(mem, desc, pixels)!!;
    defer destroy_texture_mips(&reference);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        TextureMipChain stepped = create_generated_texture_mips(&tracker, desc)!!;
        defer destroy_texture_mips(&stepped);
        GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!!;
        assert(stepped.pixels.len == layout.byte_count && tracker.allocs_total == 1);
        ulong completed;
        for (uint mip = 1; mip < reference.mip_count; mip++) {
            uint width = material::texture_mip_extent(desc.width, mip);
            uint height = material::texture_mip_extent(desc.height, mip);
            for (uint layer = 0; layer < desc.layers; layer++) {
                for (uint row = 0; row < height;) {
                    uint rows = math::min(row_limit, height - row);
                    write_texture_filter_band(
                        desc: desc,
                        mip: mip,
                        layer: layer,
                        first_row: row,
                        row_count: rows,
                        mip_zero: mip == 1 ? pixels : (char[]){},
                        chain: &stepped,
                    )!!;
                    completed += (ulong)width * rows;
                    row += rows;
                }
            }
        }
        assert(completed == layout.output_texels);
        assert(stepped.pixels == reference.pixels[reference.offsets[1]..]);
    }
    assert(tracker.allocated() == 0);
}

fn void test_generated_mip_bands_match_synchronous_mips() @test {
    char[] srgb = random_texels(37 * 19 * TEXEL_BYTES, IMAGE_SEED);
    defer alloc::free(mem, srgb.ptr);
    char[] column = random_texels(17 * TEXEL_BYTES, IMAGE_SEED);
    defer alloc::free(mem, column.ptr);
    char[6 * 4 * 4 * 4] cube;
    foreach (index, &value : cube) *value = (char)(1 + index % 251);
    ushort[8] ties = { 0x3C00, 0x3C01, 0x0001, 0xC000, 0x3C01, 0x3C02, 0x0003, 0x4000 };
    ushort[8 * 4 * 4] halves;
    foreach (index, &value : halves) *value = ties[index % ties.len];
    char[] half_bytes = ((char*)halves[..].ptr)[:halves.len * ushort::size];

    foreach (rows : (uint[2]){ 1, uint::max }) {
        expect_generated_bands_equal(material::texture_2d_desc(37, 19, RGBA8_SRGB), srgb, rows);
        expect_generated_bands_equal(material::texture_2d_desc(8, 4, RGBA16_FLOAT), half_bytes, rows);
        expect_generated_bands_equal(material::texture_cube_desc(4, RGBA8_SRGB), cube[..], rows);
        expect_generated_bands_equal(material::texture_2d_desc(1, 17, RGBA8_UNORM), column, rows);
    }
}

fn void test_generated_mip_bands_reacquire_base_and_retain_owned_levels() @test {
    char[4 * 4 * 4] pixels;
    material::TextureDesc desc = material::texture_2d_desc(4, 4, RGBA8_UNORM);
    TextureMipChain chain = create_generated_texture_mips(mem, desc)!!;
    defer destroy_texture_mips(&chain);
    chain.pixels[..] = (char)0xA5;
    write_texture_filter_band(
        desc: desc,
        mip: 1,
        layer: 0,
        first_row: 0,
        row_count: 1,
        mip_zero: pixels[..],
        chain: &chain,
    )!!;
    assert(chain.pixels[:8] == (char[8]){}[..]);
    foreach (byte : chain.pixels[8..]) assert(byte == 0xA5);
    pixels[32..] = (char)255;
    write_texture_filter_band(
        desc: desc,
        mip: 1,
        layer: 0,
        first_row: 1,
        row_count: 1,
        mip_zero: pixels[..],
        chain: &chain,
    )!!;
    write_texture_filter_band(
        desc: desc,
        mip: 2,
        layer: 0,
        first_row: 0,
        row_count: 1,
        mip_zero: (char[]){},
        chain: &chain,
    )!!;
    TextureMipChain reference = create_texture_mips(mem, desc, pixels[..])!!;
    defer destroy_texture_mips(&reference);
    assert(chain.pixels == reference.pixels[reference.offsets[1]..]);
}

fn void test_generated_layout_has_no_base_snapshot_or_empty_allocation() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    material::TextureDesc desc = material::texture_2d_desc(1, 1, RGBA8_SRGB);
    TextureMipChain chain = create_generated_texture_mips(&tracker, desc)!!;
    defer destroy_texture_mips(&chain);
    GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!!;
    assert(layout.output_texels == 0 && layout.byte_count == 0);
    assert(chain.first_mip == 1 && chain.mip_count == 0 && chain.pixels.len == 0);
    assert(tracker.allocs_total == 0 && tracker.allocated() == 0);
}
