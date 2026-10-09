module c3d::render;

import c3d;
import c3d::material;
import std::math;

const uint RGBA_CHANNELS @local = 4;
const uint RGB_CHANNELS @local = 3;
const double UNORM_MAX @local = char::max;
const double SRGB_ENCODED_THRESHOLD @local = 0.04045;
const double SRGB_LINEAR_THRESHOLD @local = 0.0031308;
const double SRGB_LINEAR_SCALE @local = 12.92;
const double SRGB_OFFSET @local = 0.055;
const double SRGB_SCALE @local = 1.055;
const double SRGB_EXPONENT @local = 2.4;
const usz SRGB_CODE_COUNT @private = 256;
const usz SRGB_THRESHOLD_COUNT @private = SRGB_CODE_COUNT - 1;
const uint SRGB_BISECTION_LIMIT @local = 128; // far above the roughly 65 halvings that make two doubles adjacent
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

double[SRGB_CODE_COUNT] srgb_decode_table @private;
double[SRGB_THRESHOLD_COUNT] srgb_encode_thresholds @private; // smallest scaled linear value reaching each code

<*
 One owned mip-major chain of tightly packed texture layers.
*>
struct TextureMipChain {
    Allocator allocator;
    uint first_mip;   // chain level held at offsets[0]
    uint mip_count;   // levels held, from first_mip
    uint layer_count;
    usz[material::TEXTURE_MIP_CAPACITY] offsets;
    char[] pixels;
}

<*
 Prepare uncompressed 2D or cube mips from complete base layers.
 @param pixels : "Borrowed mip-zero texels of the format, in layer order."
 @param first_mip : "Levels above it are computed in the allocator and discarded."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @require first_mip == 0 || (desc.generate_mips && first_mip < material::texture_mip_count(desc.width, desc.height))
*>
fn TextureMipChain? create_texture_mips(
    Allocator allocator,
    material::TextureDesc desc,
    char[] pixels,
    uint first_mip = 0,
) {
    if (first_mip == 0) return create_full_texture_mips(allocator, desc, pixels);

    TextureMipChain full = create_full_texture_mips(allocator, desc, pixels)!;
    defer destroy_texture_mips(&full);

    usz kept_offset = full.offsets[first_mip];
    TextureMipChain chain = {
        .allocator = allocator,
        .first_mip = first_mip,
        .mip_count = full.mip_count - first_mip,
        .layer_count = full.layer_count,
        .pixels = alloc::new_array(allocator, char, (sz)(full.pixels.len - kept_offset)),
    };
    for (uint mip = 0; mip < chain.mip_count; mip++) {
        chain.offsets[mip] = full.offsets[first_mip + mip] - kept_offset;
    }
    mem::copy(chain.pixels.ptr, full.pixels.ptr + kept_offset, chain.pixels.len);
    return chain;
}

<*
 Allocate nonzero generated levels without copying the base.
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
*>
fn TextureMipChain? create_generated_texture_mips(Allocator allocator, material::TextureDesc desc) {
    GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!;
    TextureMipChain chain = {
        .allocator = allocator, .first_mip = 1, .mip_count = layout.mip_count,
        .layer_count = layout.layer_count, .offsets = layout.offsets,
    };
    if (layout.byte_count) chain.pixels = alloc::alloc_array(allocator, char, (sz)layout.byte_count);
    return chain;
}

<*
 Generate destination rows from freshly borrowed source or owned levels.
 @param mip_zero : "Read only for mip one; never retained."
 @param [&inout] chain : "Generated levels; earlier levels are complete."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @require chain.first_mip == 1, chain.layer_count == desc.layers
*>
fn void? write_texture_mip_band(
    material::TextureDesc desc,
    uint mip,
    uint layer,
    uint first_row,
    uint row_count,
    char[] mip_zero,
    TextureMipChain* chain,
) {
    TextureBand band = texture_band(
        desc: desc,
        mip: mip,
        layer: layer,
        slice: 0,
        first_block_row: first_row,
        block_rows: row_count,
    )!;
    if (!mip || mip > chain.mip_count) return c3d::INVALID_ARGUMENT~;
    usz texel_bytes = material::texture_block_bytes(desc.format);
    uint width = material::texture_mip_extent(desc.width, mip - 1);
    uint height = material::texture_mip_extent(desc.height, mip - 1);
    usz source_layer_bytes = (usz)width * height * texel_bytes;
    usz destination_layer_bytes = (usz)band.width * material::texture_mip_extent(desc.height, mip) * texel_bytes;
    char[] source_bytes;
    if (mip == 1) {
        if (!mip_zero.len) return c3d::ASSET_DATA_UNAVAILABLE~;
        if (mip_zero.len != source_layer_bytes * desc.layers) return c3d::INVALID_ARGUMENT~;
        source_bytes = mip_zero[(usz)layer * source_layer_bytes:source_layer_bytes];
    } else {
        usz source_offset = chain.offsets[mip - 2] + (usz)layer * source_layer_bytes;
        source_bytes = chain.pixels[source_offset:source_layer_bytes];
    }
    usz destination_offset = chain.offsets[mip - 1] + (usz)layer * destination_layer_bytes;
    char[] destination_bytes = chain.pixels[destination_offset:destination_layer_bytes];
    switch (desc.format) {
        case RGBA8_UNORM:
            write_typed_mip_band(
                $Scalar: char,
                $srgb: false,
                $halving: true,
                width: width,
                height: height,
                first_row: first_row,
                row_count: row_count,
                source_bytes: source_bytes,
                destination_bytes: destination_bytes,
            );
        case RGBA8_SRGB:
            write_typed_mip_band(
                $Scalar: char,
                $srgb: true,
                $halving: true,
                width: width,
                height: height,
                first_row: first_row,
                row_count: row_count,
                source_bytes: source_bytes,
                destination_bytes: destination_bytes,
            );
        case RGBA16_FLOAT:
            write_typed_mip_band(
                $Scalar: float16,
                $srgb: false,
                $halving: true,
                width: width,
                height: height,
                first_row: first_row,
                row_count: row_count,
                source_bytes: source_bytes,
                destination_bytes: destination_bytes,
            );
        case RGBA32_FLOAT:
            write_typed_mip_band(
                $Scalar: float,
                $srgb: false,
                $halving: true,
                width: width,
                height: height,
                first_row: first_row,
                row_count: row_count,
                source_bytes: source_bytes,
                destination_bytes: destination_bytes,
            );
        case R16_UINT:
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

fn TextureMipChain? create_full_texture_mips(Allocator allocator, material::TextureDesc desc, char[] pixels) @local {
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
                $halving: true,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        case RGBA8_SRGB:
            return create_typed_texture_mips(
                $Scalar: char,
                $srgb: true,
                $halving: true,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        case RGBA16_FLOAT:
            return create_typed_texture_mips(
                $Scalar: float16,
                $srgb: false,
                $halving: true,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        case RGBA32_FLOAT:
            return create_typed_texture_mips(
                $Scalar: float,
                $srgb: false,
                $halving: true,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        case R16_UINT:
            return create_single_texture_mip(
                allocator: allocator,
                desc: desc,
                pixels: pixels,
                texel_bytes: ushort::size,
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
        case R16_UINT:
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

fn TextureMipChain? create_single_texture_mip(
    Allocator allocator,
    material::TextureDesc desc,
    char[] pixels,
    usz texel_bytes,
) @local {
    if (desc.generate_mips) return c3d::UNSUPPORTED~;
    ulong texels = (ulong)desc.width * desc.height;
    if (texels > (ulong)sz::max / texel_bytes / desc.layers) return c3d::INVALID_ARGUMENT~;
    if (!pixels.len) return c3d::ASSET_DATA_UNAVAILABLE~;
    if (pixels.len != (usz)texels * texel_bytes * desc.layers) return c3d::INVALID_ARGUMENT~;

    char[] copy = alloc::new_array(allocator, char, (sz)pixels.len);
    mem::copy(copy.ptr, pixels.ptr, pixels.len);
    return { .allocator = allocator, .mip_count = 1, .layer_count = desc.layers, .pixels = copy };
}

<*
 Release mip pixels and clear their owner.
 @param [&inout] chain : "Live chain; cleared after release."
*>
fn void destroy_texture_mips(TextureMipChain* chain) {
    alloc::free(chain.allocator, chain.pixels.ptr);
    *chain = {};
}

fn TextureMipChain? create_area_filter_texture_mips(
    Allocator allocator,
    material::TextureDesc desc,
    char[] pixels,
) @private {
    switch (desc.format) {
        case RGBA8_UNORM:
            return create_typed_texture_mips(
                $Scalar: char,
                $srgb: false,
                $halving: false,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        case RGBA8_SRGB:
            return create_typed_texture_mips(
                $Scalar: char,
                $srgb: true,
                $halving: false,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        case RGBA16_FLOAT:
            return create_typed_texture_mips(
                $Scalar: float16,
                $srgb: false,
                $halving: false,
                allocator: allocator,
                desc: desc,
                pixels: pixels,
            );
        default:
            return c3d::UNSUPPORTED~;
    }
}

macro TextureMipChain? create_typed_texture_mips(
    $Scalar,
    $srgb,
    $halving,
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
        .mip_count = desc.generate_mips ? material::texture_mip_count(desc.width, desc.height) : 1,
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
            write_typed_mip_band(
                $Scalar: $Scalar,
                $srgb: $srgb,
                $halving: $halving,
                width: width,
                height: height,
                first_row: 0,
                row_count: next_height,
                source_bytes: chain.pixels[source_offset:(usz)width * height * TEXEL_BYTES],
                destination_bytes: chain.pixels[destination_offset:(usz)next_width * next_height * TEXEL_BYTES],
            );
        }
    }

    return chain;
}

macro void write_typed_mip_band(
    $Scalar,
    $srgb,
    $halving,
    uint width,
    uint height,
    uint first_row,
    uint row_count,
    char[] source_bytes,
    char[] destination_bytes,
) @local {
    uint next_width = math::max(1u, width >> 1);
    uint next_height = math::max(1u, height >> 1);
    $Scalar* source = ($Scalar*)source_bytes.ptr;
    $Scalar* destination = ($Scalar*)destination_bytes.ptr;
    bool halves;
    $if $halving:
        halves = (width == 2 * next_width || width == 1) && (height == 2 * next_height || height == 1);
    $endif
    uint step_x = width / next_width;
    uint step_y = height / next_height;

    for (uint destination_y = first_row; destination_y < first_row + row_count; destination_y++) {
        for (uint destination_x = 0; destination_x < next_width; destination_x++) {
            double[RGBA_CHANNELS] sum;
            double area;
            if (halves) {
                area = (double)step_x * step_y;
                uint first_y = destination_y * step_y;
                uint first_x = destination_x * step_x;
                for (uint source_y = first_y; source_y < first_y + step_y; source_y++) {
                    for (uint source_x = first_x; source_x < first_x + step_x; source_x++) {
                        usz source_base = ((usz)source_y * width + source_x) * RGBA_CHANNELS;
                        for (uint channel = 0; channel < RGBA_CHANNELS; channel++) {
                            sum[channel] += load_mip_value(
                                $Scalar: $Scalar,
                                $srgb: $srgb,
                                source: source,
                                base: source_base,
                                channel: channel,
                            );
                        }
                    }
                }
            } else {
                double top = (double)destination_y * height / next_height;
                double bottom = (double)(destination_y + 1) * height / next_height;
                double left = (double)destination_x * width / next_width;
                double right = (double)(destination_x + 1) * width / next_width;
                area = (right - left) * (bottom - top);
                for (uint source_y = (uint)top; source_y < (uint)math::ceil(bottom); source_y++) {
                    double vertical = math::min(bottom, (double)source_y + 1)
                      - math::max(top, (double)source_y);
                    for (uint source_x = (uint)left; source_x < (uint)math::ceil(right); source_x++) {
                        double horizontal = math::min(right, (double)source_x + 1)
                          - math::max(left, (double)source_x);
                        usz source_base = ((usz)source_y * width + source_x) * RGBA_CHANNELS;
                        for (uint channel = 0; channel < RGBA_CHANNELS; channel++) {
                            sum[channel] += load_mip_value(
                                $Scalar: $Scalar,
                                $srgb: $srgb,
                                source: source,
                                base: source_base,
                                channel: channel,
                            ) * horizontal * vertical;
                        }
                    }
                }
            }

            usz destination_base = ((usz)destination_y * next_width + destination_x) * RGBA_CHANNELS;
            for (uint channel = 0; channel < RGBA_CHANNELS; channel++) {
                store_mip_value(
                    $Scalar: $Scalar,
                    $srgb: $srgb,
                    destination: destination,
                    base: destination_base,
                    channel: channel,
                    value: sum[channel] / area,
                );
            }
        }
    }
}

macro double load_mip_value($Scalar, $srgb, source, usz base, uint channel) @local {
    $if $Scalar == float16:
        return (double)half_to_float(bitcast(source[base + channel], ushort));
    $else
        $if $srgb:
            if (channel < RGB_CHANNELS) return srgb_decode_table[(usz)source[base + channel]];
        $endif
        return (double)source[base + channel];
    $endif
}

macro void store_mip_value($Scalar, $srgb, destination, usz base, uint channel, double value) @local {
    $if $Scalar == char:
        $if $srgb:
            if (channel < RGB_CHANNELS) {
                destination[base + channel] = (char)encode_srgb_code(value);
                return;
            }
        $endif
        destination[base + channel] = (char)math::clamp(math::round(value), 0.0, UNORM_MAX);
    $else
        $if $Scalar == float16:
            destination[base + channel] = bitcast(float_to_half((float)value), float16);
        $else
            destination[base + channel] = ($Scalar)value;
        $endif
    $endif
}

fn double srgb_reference_code(double scaled_linear) @private {
    return math::clamp(math::round(encode_srgb(scaled_linear / UNORM_MAX) * UNORM_MAX), 0.0, UNORM_MAX);
}

// Branch-free: data-dependent branches mispredict on image texels and dominate the encode.
fn double encode_srgb_code(double scaled_linear) @private {
    usz count;
    for (usz step = SRGB_CODE_COUNT / 2; step > 0; step >>= 1) {
        count += srgb_encode_thresholds[count + step - 1] <= scaled_linear ? step : 0;
    }
    return (double)count;
}

fn void build_srgb_tables() @init @private {
    for (usz code = 0; code < SRGB_CODE_COUNT; code++) {
        srgb_decode_table[code] = decode_srgb(code / UNORM_MAX) * UNORM_MAX;
    }
    for (usz code = 1; code < SRGB_CODE_COUNT; code++) {
        double below = 0;
        double reaching = UNORM_MAX;
        for (uint step = 0; step < SRGB_BISECTION_LIMIT; step++) {
            double middle = below + (reaching - below) / 2;
            if (middle <= below || middle >= reaching) break;
            if (srgb_reference_code(middle) >= code) {
                reaching = middle;
            } else {
                below = middle;
            }
        }
        srgb_encode_thresholds[code - 1] = reaching;
    }
}

fn double decode_srgb(double encoded) @private {
    return encoded <= SRGB_ENCODED_THRESHOLD
      ? encoded / SRGB_LINEAR_SCALE
      : math::pow((encoded + SRGB_OFFSET) / SRGB_SCALE, SRGB_EXPONENT);
}

fn double encode_srgb(double linear) @private {
    return linear <= SRGB_LINEAR_THRESHOLD
      ? linear * SRGB_LINEAR_SCALE
      : SRGB_SCALE * math::pow(linear, 1.0 / SRGB_EXPONENT) - SRGB_OFFSET;
}

// c3c 0.8.3 ships no half-precision compiler-rt builtins on windows-x64, so no float16 cast may reach the linker.
fn float half_to_float(ushort bits) @private {
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

fn ushort float_to_half(float value) @private {
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
