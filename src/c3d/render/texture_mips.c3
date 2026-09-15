module c3d::render;

import c3d;
import c3d::material;
import std::math;

<*
 Maximum mip count for an unsigned 32-bit image extent.
*>
const uint TEXTURE_MIP_CAPACITY = 32;

const uint RGBA_CHANNELS @local = 4;
const uint RGB_CHANNELS @local = 3;
const double UNORM_MAX @local = char::max;
const double SRGB_ENCODED_THRESHOLD @local = 0.04045;
const double SRGB_LINEAR_THRESHOLD @local = 0.0031308;
const double SRGB_LINEAR_SCALE @local = 12.92;
const double SRGB_OFFSET @local = 0.055;
const double SRGB_SCALE @local = 1.055;
const double SRGB_EXPONENT @local = 2.4;
const ushort HALF_SIGN_MASK @local = 0x8000;
const uint HALF_MANTISSA_BITS @local = 10;
const ushort HALF_MANTISSA_MASK @local = 0x3ff;
const uint HALF_EXPONENT_MASK @local = 0x1f;
const ushort HALF_INFINITY @local = 0x7c00;
const ushort HALF_QUIET_NAN @local = 0x7e00;
const float HALF_SUBNORMAL_UNIT @local = 1.0f / 16777216.0f; // 2^-24, the lowest half mantissa bit
const uint HALF_TO_FLOAT_BIAS @local = 112; // float bias 127 minus half bias 15
const uint FLOAT_SIGN_MASK @local = 0x80000000;
const uint FLOAT_EXPONENT_MASK @local = 0x7f800000;
const uint FLOAT_MANTISSA_MASK @local = 0x007fffff;
const uint FLOAT_HIDDEN_BIT @local = 0x00800000;
const uint FLOAT_HALF_OVERFLOW @local = 0x477ff000; // 65520, the first float that rounds to half infinity
const uint FLOAT_HALF_MIN_NORMAL @local = 0x38800000; // 2^-14, the smallest normal half
const uint FLOAT_HALF_UNDERFLOW @local = 0x33000000; // 2^-25, half of the smallest subnormal half
const uint HALF_SUBNORMAL_SHIFT_BASE @local = 113; // biased float exponent of 2^-14
const uint HALF_ROUND_BIAS @local = 0xfff; // round-to-nearest bias for the 13 dropped mantissa bits
const uint FLOAT_HALF_EXPONENT_OFFSET @local = 0x38000000; // (127 - 15) << 23

<*
 One owned mip-major chain of tightly packed texture layers.
*>
struct TextureMipChain {
    Allocator allocator;
    uint mip_count;
    uint layer_count;
    usz[TEXTURE_MIP_CAPACITY] offsets;
    char[] pixels;
}

<*
 Count mip levels down to one texel.
 @require width > 0, height > 0
 @pure
*>
fn uint texture_mip_count(uint width, uint height) {
    uint count = 1;
    for (uint extent = math::max(width, height); extent > 1; extent >>= 1) count++;

    return count;
}

<*
 Prepare uncompressed 2D or cube mips from complete base layers.
 @param pixels : "Borrowed mip-zero RGBA texels in layer order."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
*>
fn TextureMipChain? create_texture_mips(Allocator allocator, material::TextureDesc desc, char[] pixels) {
    if (!desc.width || !desc.height || desc.mip_levels != 1) return c3d::INVALID_ARGUMENT~;
    if (desc.depth) return create_volume_texture_mips(allocator, desc, pixels);
    if (desc.is_cube) {
        if (desc.layers != material::CUBE_FACE_COUNT || desc.width != desc.height) return c3d::INVALID_ARGUMENT~;
    } else if (desc.layers != 1) {
        return c3d::UNSUPPORTED~;
    }

    switch (desc.format) {
        case RGBA8_UNORM:
            return create_typed_texture_mips(
                $Scalar: char,
                $srgb: false,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        case RGBA8_SRGB:
            return create_typed_texture_mips(
                $Scalar: char,
                $srgb: true,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        case RGBA16_FLOAT:
            return create_typed_texture_mips(
                $Scalar: float16,
                $srgb: false,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        case RGBA32_FLOAT:
            return create_typed_texture_mips(
                $Scalar: float,
                $srgb: false,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        case BC1_RGBA_UNORM:
        case BC1_RGBA_SRGB:
        case BC3_UNORM:
        case BC3_SRGB:
        case BC4_UNORM:
        case BC5_UNORM:
        case BC6H_UFLOAT:
        case BC7_UNORM:
        case BC7_SRGB:
            return c3d::UNSUPPORTED~;
    }
}

fn TextureMipChain? create_volume_texture_mips(
    Allocator allocator,
    material::TextureDesc desc,
    char[] pixels,
) @local {
    if (desc.generate_mips || desc.layers != 1 || desc.is_cube) return c3d::UNSUPPORTED~;
    switch (desc.format) {
        case RGBA8_UNORM:
        case RGBA8_SRGB:
            break;
        case RGBA16_FLOAT:
        case RGBA32_FLOAT:
        case BC1_RGBA_UNORM:
        case BC1_RGBA_SRGB:
        case BC3_UNORM:
        case BC3_SRGB:
        case BC4_UNORM:
        case BC5_UNORM:
        case BC6H_UFLOAT:
        case BC7_UNORM:
        case BC7_SRGB:
            return c3d::UNSUPPORTED~;
    }
    ulong texels = (ulong)desc.width * desc.height * desc.depth;
    if (texels > (ulong)sz::max / RGBA_CHANNELS) return c3d::INVALID_ARGUMENT~;
    if (!pixels.len) return c3d::ASSET_DATA_UNAVAILABLE~;
    if (pixels.len != (usz)texels * RGBA_CHANNELS) return c3d::INVALID_ARGUMENT~;

    char[] copy = alloc::new_array(allocator, char, (sz)pixels.len);
    mem::copy(copy.ptr, pixels.ptr, pixels.len);
    return { .allocator = allocator, .mip_count = 1, .layer_count = 1, .pixels = copy };
}

<*
 Release mip pixels and clear their owner.
 @param [&inout] chain : "Live chain; cleared after release."
*>
fn void destroy_texture_mips(TextureMipChain* chain) {
    alloc::free(chain.allocator, chain.pixels.ptr);
    *chain = {};
}

macro TextureMipChain? create_typed_texture_mips(
    $Scalar,
    $srgb,
    Allocator allocator,
    material::TextureDesc desc,
    char[] pixels,
) @local {
    const usz TEXEL_BYTES = RGBA_CHANNELS * $Scalar::size;
    ulong texels = (ulong)desc.width * desc.height;
    if (texels > (ulong)sz::max / TEXEL_BYTES / desc.layers) return c3d::INVALID_ARGUMENT~;
    if (!pixels.len) return c3d::ASSET_DATA_UNAVAILABLE~;
    if (pixels.len != (usz)texels * TEXEL_BYTES * desc.layers) return c3d::INVALID_ARGUMENT~;

    TextureMipChain chain = {
        .allocator = allocator,
        .mip_count = desc.generate_mips ? texture_mip_count(desc.width, desc.height) : 1,
        .layer_count = desc.layers,
    };
    usz total_bytes;
    for (uint mip = 0; mip < chain.mip_count; mip++) {
        usz width = math::max(1u, desc.width >> mip);
        usz height = math::max(1u, desc.height >> mip);
        usz level_bytes = width * height * TEXEL_BYTES * desc.layers;
        if (level_bytes > (usz)sz::max - total_bytes) return c3d::INVALID_ARGUMENT~;
        chain.offsets[mip] = total_bytes;
        total_bytes += level_bytes;
    }

    chain.pixels = alloc::new_array(allocator, char, (sz)total_bytes);
    mem::copy(chain.pixels.ptr, pixels.ptr, pixels.len);
    for (uint mip = 1; mip < chain.mip_count; mip++) {
        uint width = math::max(1u, desc.width >> (mip - 1));
        uint height = math::max(1u, desc.height >> (mip - 1));
        uint next_width = math::max(1u, width >> 1);
        uint next_height = math::max(1u, height >> 1);

        for (uint layer = 0; layer < desc.layers; layer++) {
            usz source_offset = chain.offsets[mip - 1] + (usz)layer * width * height * TEXEL_BYTES;
            usz destination_offset = chain.offsets[mip] + (usz)layer * next_width * next_height * TEXEL_BYTES;
            $Scalar* source = ($Scalar*)(chain.pixels.ptr + source_offset);
            $Scalar* destination = ($Scalar*)(chain.pixels.ptr + destination_offset);

            for (uint destination_y = 0; destination_y < next_height; destination_y++) {
                double top = (double)destination_y * height / next_height;
                double bottom = (double)(destination_y + 1) * height / next_height;
                for (uint destination_x = 0; destination_x < next_width; destination_x++) {
                    double left = (double)destination_x * width / next_width;
                    double right = (double)(destination_x + 1) * width / next_width;
                    double area = (right - left) * (bottom - top);
                    double[RGBA_CHANNELS] sum;
                    for (uint source_y = (uint)top; source_y < (uint)math::ceil(bottom); source_y++) {
                        double vertical = math::min(bottom, (double)source_y + 1) - math::max(top, (double)source_y);
                        for (uint source_x = (uint)left; source_x < (uint)math::ceil(right); source_x++) {
                            double horizontal = math::min(right, (double)source_x + 1)
                              - math::max(left, (double)source_x);
                            usz source_base = ((usz)source_y * width + source_x) * RGBA_CHANNELS;
                            for (uint channel = 0; channel < RGBA_CHANNELS; channel++) {
                                $if $Scalar == float16:
                                    double value = (double)half_to_float(bitcast(source[source_base + channel], ushort));
                                $else
                                    double value = (double)source[source_base + channel];
                                $endif
                                $if $srgb:
                                    if (channel < RGB_CHANNELS) value = decode_srgb(value / UNORM_MAX) * UNORM_MAX;
                                $endif
                                sum[channel] += value * horizontal * vertical;
                            }
                        }
                    }

                    usz destination_base = ((usz)destination_y * next_width + destination_x) * RGBA_CHANNELS;
                    for (uint channel = 0; channel < RGBA_CHANNELS; channel++) {
                        double value = sum[channel] / area;
                        $if $srgb:
                            if (channel < RGB_CHANNELS) value = encode_srgb(value / UNORM_MAX) * UNORM_MAX;
                        $endif
                        $if $Scalar == char:
                            value = math::clamp(math::round(value), 0.0, UNORM_MAX);
                        $endif
                        $if $Scalar == float16:
                            destination[destination_base + channel] = bitcast(float_to_half((float)value), float16);
                        $else
                            destination[destination_base + channel] = ($Scalar)value;
                        $endif
                    }
                }
            }
        }
    }

    return chain;
}

fn double decode_srgb(double encoded) @local {
    return encoded <= SRGB_ENCODED_THRESHOLD
      ? encoded / SRGB_LINEAR_SCALE
      : math::pow((encoded + SRGB_OFFSET) / SRGB_SCALE, SRGB_EXPONENT);
}

fn double encode_srgb(double linear) @local {
    return linear <= SRGB_LINEAR_THRESHOLD
      ? linear * SRGB_LINEAR_SCALE
      : SRGB_SCALE * math::pow(linear, 1.0 / SRGB_EXPONENT) - SRGB_OFFSET;
}

// c3c 0.8.3 ships no half-precision compiler-rt builtins on windows-x64, so no float16 cast may reach the linker.
fn float half_to_float(ushort bits) @local {
    uint sign = (uint)(bits & HALF_SIGN_MASK) << 16;
    uint exponent = (bits >> HALF_MANTISSA_BITS) & HALF_EXPONENT_MASK;
    uint mantissa = bits & HALF_MANTISSA_MASK;
    if (exponent == 0) {
        float magnitude = (float)mantissa * HALF_SUBNORMAL_UNIT;
        return bitcast(sign | bitcast(magnitude, uint), float);
    }
    if (exponent == HALF_EXPONENT_MASK) return bitcast(sign | FLOAT_EXPONENT_MASK | (mantissa << 13), float);
    return bitcast(sign | ((exponent + HALF_TO_FLOAT_BIAS) << 23) | (mantissa << 13), float);
}

fn ushort float_to_half(float value) @local {
    uint bits = bitcast(value, uint);
    uint sign = (bits >> 16) & HALF_SIGN_MASK;
    uint magnitude = bits & ~FLOAT_SIGN_MASK;
    if (magnitude > FLOAT_EXPONENT_MASK) return (ushort)(sign | HALF_QUIET_NAN);
    if (magnitude >= FLOAT_HALF_OVERFLOW) return (ushort)(sign | HALF_INFINITY);
    if (magnitude < FLOAT_HALF_UNDERFLOW) return (ushort)sign;
    if (magnitude < FLOAT_HALF_MIN_NORMAL) {
        uint shift = HALF_SUBNORMAL_SHIFT_BASE - (magnitude >> 23);
        uint mantissa = (magnitude & FLOAT_MANTISSA_MASK) | FLOAT_HIDDEN_BIT;
        uint half_mantissa = mantissa >> (shift + 13);
        uint remainder = mantissa & ((1u << (shift + 13)) - 1);
        uint halfway = 1u << (shift + 12);
        if (remainder > halfway || (remainder == halfway && (half_mantissa & 1))) half_mantissa++;
        return (ushort)(sign | half_mantissa);
    }
    uint rounded = magnitude + HALF_ROUND_BIAS + ((magnitude >> 13) & 1);
    return (ushort)(sign | ((rounded - FLOAT_HALF_EXPONENT_OFFSET) >> 13));
}
