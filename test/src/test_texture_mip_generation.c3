module c3d::render;

import c3d::material;
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

struct HalvingShape @local {
    uint width;
    uint height;
}

fn uint next_random(uint* state) @local {
    *state = *state * LCG_MULTIPLIER + LCG_INCREMENT;
    return *state >> 8;
}

fn char[] random_texels(usz bytes, uint seed) @local {
    char[] pixels = alloc::new_array(mem, char, (sz)bytes);
    uint state = seed;
    foreach (&byte : pixels) *byte = (char)(next_random(&state) >> 16);
    return pixels;
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
