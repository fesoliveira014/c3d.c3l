module c3d::render;

import c3d::material;
import c3d::test::loading_fixtures;
import std::math;

const usz TEXEL_BYTES @local = 4;
const double CODE_MAX @local = 255;
const ulong FNV_OFFSET @local = 0xcbf29ce484222325;
const ulong FNV_PRIME @local = 0x100000001b3;
const uint IMAGE_SEED @local = 0x2545f491;
const uint LCG_MULTIPLIER @local = 1664525;
const uint LCG_INCREMENT @local = 1013904223;
const uint SWEEP_STEPS @local = 1_000_000;
const ulong ODD_SRGB_DIGEST @local = 0x1061d393becd4e46;
const ulong EVEN_SRGB_DIGEST @local = 0x9a7fa2d2274fd02e;
const uint HALF_EXPONENT_LIMIT @local = 30; // keeps generated halves finite
const uint HALF_EXPONENT_SHIFT @local = 10;
const uint HALF_MANTISSA_LIMIT @local = 1024;
const ulong GENERATED_ALLOWANCE_ONE_MIB @local = 1 << 20;
const ulong GENERATED_ALLOWANCE_EIGHT_MIB @local = 8 << 20;
const uint GENERATED_BAND_ROWS @local = 16; // matches the preparation generator span

struct HalvingShape @local {
    uint width;
    uint height;
}

fn uint next_random(uint* state) @local {
    *state = *state * LCG_MULTIPLIER + LCG_INCREMENT;
    return *state >> 8;
}

fn char[] random_texels(usz bytes, uint seed) @local {
    return loading_fixtures::preparation_texture_bytes(mem, bytes, seed);
}

fn char[] random_half_texels(usz texels, uint seed) @local {
    char[] pixels = alloc::new_array(mem, char, (sz)texels * ushort::size);
    ushort* halves = (ushort*)pixels.ptr;
    uint state = seed;
    for (usz index = 0; index < texels; index++) {
        uint exponent = 1 + next_random(&state) % HALF_EXPONENT_LIMIT;
        uint mantissa = next_random(&state) % HALF_MANTISSA_LIMIT;
        halves[index] = (ushort)((exponent << HALF_EXPONENT_SHIFT) | mantissa);
    }
    return pixels;
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

fn void expect_halving_matches(material::PixelFormat format, HalvingShape shape) @local {
    char[] pixels = format == RGBA16_FLOAT
      ? random_half_texels((usz)shape.width * shape.height * TEXEL_BYTES, IMAGE_SEED)
      : random_texels((usz)shape.width * shape.height * TEXEL_BYTES, IMAGE_SEED);
    defer alloc::free(mem, pixels.ptr);
    material::TextureDesc desc = material::texture_2d_desc(shape.width, shape.height, format);
    TextureMipChain halved = create_texture_mips(mem, desc, pixels)!!;
    defer destroy_texture_mips(&halved);
    TextureMipChain filtered = create_area_filter_texture_mips(mem, desc, pixels)!!;
    defer destroy_texture_mips(&filtered);

    assert(halved.mip_count == filtered.mip_count);
    assert(halved.pixels == filtered.pixels);
}

fn void test_halving_path_matches_the_area_filter() @test {
    HalvingShape[3] shapes = {
        { .width = 64, .height = 64 },
        { .width = 64, .height = 1 },
        { .width = 1, .height = 64 },
    };
    material::PixelFormat[3] formats = { RGBA8_UNORM, RGBA8_SRGB, RGBA16_FLOAT };
    foreach (format : formats) {
        foreach (shape : shapes) expect_halving_matches(format, shape);
    }
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

fn void expect_generated_bands_equal(
    material::TextureDesc desc,
    char[] pixels,
    uint row_limit,
    ulong texel_allowance = 0,
) @local {
    TextureMipChain reference = create_texture_mips(mem, desc, pixels)!!;
    defer destroy_texture_mips(&reference);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        TextureMipChain stepped = create_generated_texture_mips(&tracker, desc)!!;
        defer destroy_texture_mips(&stepped);
        GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!!;
        assert(stepped.first_mip == 1 && stepped.mip_count + 1 == reference.mip_count);
        assert(stepped.pixels.len == layout.byte_count && tracker.allocs_total == 1);
        assert(stepped.pixels.len == reference.pixels.len - reference.offsets[1]);
        ulong completed;
        ulong charged;
        usz generated_bytes;
        for (uint mip = 1; mip < reference.mip_count; mip++) {
            uint width = material::texture_mip_extent(desc.width, mip);
            uint height = material::texture_mip_extent(desc.height, mip);
            for (uint layer = 0; layer < desc.layers; layer++) {
                for (uint row = 0; row < height;) {
                    uint rows = math::min(row_limit, height - row);
                    ulong previous = generated_mip_charge(layout.base_texels, completed, layout.output_texels);
                    if (texel_allowance) {
                        ulong minimum = generated_mip_charge(
                            base_texels: layout.base_texels,
                            output_done: completed + width,
                            output_total: layout.output_texels,
                        ) - previous;
                        assert(minimum <= texel_allowance);
                        uint first = 1;
                        uint last = rows;
                        while (first < last) {
                            uint candidate = first + (last - first + 1) / 2;
                            ulong next = generated_mip_charge(
                                base_texels: layout.base_texels,
                                output_done: completed + (ulong)width * candidate,
                                output_total: layout.output_texels,
                            );
                            if (next - previous <= texel_allowance) {
                                first = candidate;
                            } else {
                                last = candidate - 1;
                            }
                        }
                        rows = first;
                    }
                    write_texture_mip_band(
                        desc: desc,
                        mip: mip,
                        layer: layer,
                        first_row: row,
                        row_count: rows,
                        mip_zero: mip == 1 ? pixels : (char[]){},
                        chain: &stepped,
                    )!!;
                    completed += (ulong)width * rows;
                    ulong next = generated_mip_charge(layout.base_texels, completed, layout.output_texels);
                    assert(next == layout.base_texels * completed / layout.output_texels);
                    assert(next >= previous);
                    if (texel_allowance) assert(next - previous <= texel_allowance);
                    generated_bytes += (usz)width * rows * material::texture_block_bytes(desc.format);
                    charged += next - previous;
                    row += rows;
                }
            }
        }
        assert(completed == layout.output_texels && charged == layout.base_texels);
        assert(generated_bytes == layout.byte_count);
        assert(stepped.pixels == reference.pixels[reference.offsets[1]..]);
    }
    assert(tracker.allocated() == 0);
}

fn void test_generated_mip_bands_keep_srgb_npot_bytes() @test {
    char[] pixels = random_texels(37 * 19 * TEXEL_BYTES, IMAGE_SEED);
    defer alloc::free(mem, pixels.ptr);
    foreach (rows : (uint[3]){ 1, 3, 8 }) {
        expect_generated_bands_equal(material::texture_2d_desc(37, 19, RGBA8_SRGB), pixels, rows);
    }
    assert(srgb_chain_digest(37, 19) == ODD_SRGB_DIGEST);
}

fn void test_generated_mip_bands_keep_linear_halving_bytes() @test {
    char[] pixels = random_texels(64 * 64 * TEXEL_BYTES, IMAGE_SEED);
    defer alloc::free(mem, pixels.ptr);
    foreach (rows : (uint[3]){ 1, 5, 32 }) {
        expect_generated_bands_equal(material::texture_2d_desc(64, 64, RGBA8_UNORM), pixels, rows);
    }
}

fn void test_generated_mip_bands_keep_half_rounding() @test {
    ushort[8] ties = { 0x3C00, 0x3C01, 0x0001, 0xC000, 0x3C01, 0x3C02, 0x0003, 0x4000 };
    ushort[8 * 4 * 4] pixels;
    foreach (index, &value : pixels) *value = ties[index % ties.len];
    char[] bytes = ((char*)pixels[..].ptr)[:pixels.len * ushort::size];
    foreach (rows : (uint[2]){ 1, 3 }) {
        expect_generated_bands_equal(material::texture_2d_desc(8, 4, RGBA16_FLOAT), bytes, rows);
    }
}

fn void test_generated_mip_bands_keep_float_npot_values() @test {
    float[9 * 5 * 4] pixels;
    foreach (index, &value : pixels) *value = (float)((int)(index % 17) - 8) * 1.25f;
    char[] bytes = ((char*)pixels[..].ptr)[:pixels.len * float::size];
    foreach (rows : (uint[2]){ 1, 3 }) {
        expect_generated_bands_equal(material::texture_2d_desc(9, 5, RGBA32_FLOAT), bytes, rows);
    }
}

fn void test_generated_mip_bands_keep_single_axis_edges() @test {
    char[] pixels = random_texels(17 * TEXEL_BYTES, IMAGE_SEED);
    defer alloc::free(mem, pixels.ptr);
    foreach (shape : (HalvingShape[2]){ { .width = 1, .height = 17 }, { .width = 17, .height = 1 } }) {
        foreach (rows : (uint[2]){ 1, 3 }) {
            expect_generated_bands_equal(
                desc: material::texture_2d_desc(shape.width, shape.height, RGBA8_UNORM),
                pixels: pixels,
                row_limit: rows,
            );
        }
    }
}

fn void test_generated_mip_bands_keep_cube_faces() @test {
    char[6 * 4 * 4 * 4] pixels;
    foreach (index, &value : pixels) *value = (char)(1 + index % 251);
    foreach (rows : (uint[2]){ 1, 2 }) {
        expect_generated_bands_equal(material::texture_cube_desc(4, RGBA8_SRGB), pixels[..], rows);
    }
    GeneratedTextureLayout layout = generated_texture_mip_layout(material::texture_cube_desc(4, RGBA8_SRGB))!!;
    assert(layout.base_texels == 96 && layout.output_texels == 30 && layout.byte_count == 120);
}

fn void test_generated_mip_bands_reacquire_base_and_retain_owned_levels() @test {
    char[4 * 4 * 4] pixels;
    material::TextureDesc desc = material::texture_2d_desc(4, 4, RGBA8_UNORM);
    TextureMipChain chain = create_generated_texture_mips(mem, desc)!!;
    defer destroy_texture_mips(&chain);
    chain.pixels[..] = (char)0xA5;
    write_texture_mip_band(
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
    write_texture_mip_band(
        desc: desc,
        mip: 1,
        layer: 0,
        first_row: 1,
        row_count: 1,
        mip_zero: pixels[..],
        chain: &chain,
    )!!;
    write_texture_mip_band(
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

fn void test_generated_texel_charge_avoids_large_products() @test {
    assert(generated_mip_charge(1000, 100, 333) == 300);
    assert(generated_mip_charge(ulong::max, ulong::max - 1, ulong::max) == ulong::max - 1);
    assert(generated_mip_charge(ulong::max, ulong::max - 2, ulong::max - 1) == ulong::max - 2);
    assert(generated_mip_charge(ulong::max - 7, ulong::max - 12, ulong::max - 11) == ulong::max - 9);
    assert(generated_mip_charge(ulong::max / 2, ulong::max - 2, ulong::max - 1) == ulong::max / 2 - 1);
    assert(generated_mip_charge(ulong::max, 0, ulong::max - 1) == 0);
    assert(generated_mip_charge(ulong::max, ulong::max - 1, ulong::max - 1) == ulong::max);
}

fn void test_generated_layout_has_no_base_snapshot_or_empty_allocation() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    material::TextureDesc desc = material::texture_2d_desc(1, 1, RGBA8_SRGB);
    TextureMipChain chain = create_generated_texture_mips(&tracker, desc)!!;
    defer destroy_texture_mips(&chain);
    GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!!;
    assert(layout.base_texels == 1 && layout.output_texels == 0 && layout.byte_count == 0);
    assert(chain.first_mip == 1 && chain.mip_count == 0 && chain.pixels.len == 0);
    assert(tracker.allocs_total == 0 && tracker.allocated() == 0);
}

fn void expect_canonical_generated_allowances(material::TextureDesc desc, char[] pixels) @local {
    GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!!;
    uint width = material::texture_mip_extent(desc.width, 1);
    ulong minimum = layout.base_texels
      - generated_mip_charge(layout.base_texels, layout.output_texels - width, layout.output_texels);
    if (desc.width == 65537) {
        ulong first_span = generated_mip_charge(
            base_texels: layout.base_texels,
            output_done: (ulong)width * GENERATED_BAND_ROWS,
            output_total: layout.output_texels,
        );
        assert(first_span > GENERATED_ALLOWANCE_ONE_MIB);
    }
    foreach (allowance : (ulong[4]){ minimum, GENERATED_ALLOWANCE_ONE_MIB, GENERATED_ALLOWANCE_EIGHT_MIB, 0 }) {
        expect_generated_bands_equal(
            desc: desc,
            pixels: pixels,
            row_limit: GENERATED_BAND_ROWS,
            texel_allowance: allowance,
        );
    }
}

fn void test_generated_mip_bands_converge_with_canonical_texel_allowances() @test {
    foreach (desc : (material::TextureDesc[6]){
        material::texture_2d_desc(65537, 33, RGBA8_UNORM),
        material::texture_cube_desc(4, RGBA8_SRGB),
        material::texture_2d_desc(37, 19, RGBA8_SRGB),
        material::texture_2d_desc(64, 64, RGBA8_UNORM),
        material::texture_2d_desc(1, 17, RGBA8_UNORM),
        material::texture_2d_desc(17, 1, RGBA8_UNORM),
    }) {
        char[] pixels = random_texels((usz)desc.width * desc.height * desc.layers * TEXEL_BYTES, IMAGE_SEED);
        defer alloc::free(mem, pixels.ptr);
        expect_canonical_generated_allowances(desc, pixels);
    }

    ushort[8] ties = { 0x3C00, 0x3C01, 0x0001, 0xC000, 0x3C01, 0x3C02, 0x0003, 0x4000 };
    ushort[8 * 4 * 4] halves;
    foreach (index, &value : halves) *value = ties[index % ties.len];
    char[] half_bytes = ((char*)halves[..].ptr)[:halves.len * ushort::size];
    expect_canonical_generated_allowances(material::texture_2d_desc(8, 4, RGBA16_FLOAT), half_bytes);

    float[9 * 5 * 4] floats;
    foreach (index, &value : floats) *value = (float)((int)(index % 17) - 8) * 1.25f;
    char[] float_bytes = ((char*)floats[..].ptr)[:floats.len * float::size];
    expect_canonical_generated_allowances(material::texture_2d_desc(9, 5, RGBA32_FLOAT), float_bytes);
}
