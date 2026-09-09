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

<*
 One owned tightly packed chain of uncompressed 2D mips.
*>
struct TextureMipChain {
    Allocator allocator;
    uint mip_count;
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
 Prepare owned uncompressed mip pixels from complete mip zero.
 @param pixels : "Borrowed tightly packed mip-zero RGBA texels."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
*>
fn TextureMipChain? create_texture_mips(Allocator allocator, material::TextureDesc desc, char[] pixels) {
    if (!desc.width || !desc.height || desc.mip_levels != 1) return c3d::INVALID_ARGUMENT~;
    if (desc.depth || desc.layers != 1 || desc.is_cube) return c3d::UNSUPPORTED~;

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
    if (texels > (ulong)sz::max / TEXEL_BYTES) return c3d::INVALID_ARGUMENT~;
    if (!pixels.len) return c3d::ASSET_DATA_UNAVAILABLE~;
    if (pixels.len != (usz)texels * TEXEL_BYTES) return c3d::INVALID_ARGUMENT~;

    TextureMipChain chain = {
        .allocator = allocator,
        .mip_count = desc.generate_mips ? texture_mip_count(desc.width, desc.height) : 1,
    };
    usz total_bytes;
    for (uint mip = 0; mip < chain.mip_count; mip++) {
        usz width = math::max(1u, desc.width >> mip);
        usz height = math::max(1u, desc.height >> mip);
        usz level_bytes = width * height * TEXEL_BYTES;
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
        $Scalar* source = ($Scalar*)(chain.pixels.ptr + chain.offsets[mip - 1]);
        $Scalar* destination = ($Scalar*)(chain.pixels.ptr + chain.offsets[mip]);

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
                        double horizontal = math::min(right, (double)source_x + 1) - math::max(left, (double)source_x);
                        usz source_base = ((usz)source_y * width + source_x) * RGBA_CHANNELS;
                        for (uint channel = 0; channel < RGBA_CHANNELS; channel++) {
                            double value = (double)source[source_base + channel];
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
                    destination[destination_base + channel] = ($Scalar)value;
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
