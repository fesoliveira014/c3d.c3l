module c3d::asset;

import c3d;
import c3d::material;
import std::math;

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

<* Decode an IEEE half without native half conversions. *>
fn float decode_texture_half(ushort bits) {
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

<* Encode an IEEE half with round-to-nearest-even. *>
fn ushort encode_texture_half(float value) {
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

<* Stored alpha code of one tightly packed RGBA texel. *>
fn uint texture_alpha_code(PixelFormat format, char[] pixels, usz texel) {
    usz scalar_bytes = material::texture_block_bytes(format) / 4;
    usz offset = (texel * 4 + 3) * scalar_bytes;
    uint code;

    for (usz byte = 0; byte < scalar_bytes; byte++) code |= (uint)pixels[offset + byte] << (byte * 8);

    return code;
}

<* Write one stored alpha code without changing RGB. *>
fn void write_texture_alpha_code(
    PixelFormat format,
    char[] pixels,
    usz texel,
    uint code,
) {
    usz scalar_bytes = material::texture_block_bytes(format) / 4;
    usz offset = (texel * 4 + 3) * scalar_bytes;

    for (usz byte = 0; byte < scalar_bytes; byte++) pixels[offset + byte] = (char)(code >> (byte * 8));
}

<* Decode a stored alpha with the texture's destination codec. *>
fn double decode_texture_alpha(PixelFormat format, uint code) {
    switch (format) {
        case RGBA8_UNORM:
        case RGBA8_SRGB: return (double)code / char::max;
        case RGBA16_FLOAT: return (double)decode_texture_half((ushort)code);
        case RGBA32_FLOAT: return (double)bitcast(code, float);
        default: unreachable();
    }
}

<* Encode normalized alpha with the texture's destination codec. *>
fn uint encode_texture_alpha(PixelFormat format, double value) {
    switch (format) {
        case RGBA8_UNORM:
        case RGBA8_SRGB: return (uint)math::clamp(math::round(value * char::max), 0.0, (double)char::max);
        case RGBA16_FLOAT: return (uint)encode_texture_half((float)value);
        case RGBA32_FLOAT: return bitcast((float)value, uint);
        default: unreachable();
    }
}

<* Canonical nonnegative code used by alpha radix ordering. *>
fn uint texture_alpha_key(PixelFormat format, uint code) {
    return decode_texture_alpha(format, code) == 0.0 ? 0 : code;
}

<* Scale alpha using its unchanged destination conversion order. *>
fn uint scale_texture_alpha(PixelFormat format, uint code, double scale) {
    if (scale == 1.0) return code;

    if (format == PixelFormat.RGBA8_UNORM || format == PixelFormat.RGBA8_SRGB) {
        return (uint)math::clamp(math::round((double)code * scale), 0.0, (double)char::max);
    }

    return encode_texture_alpha(format,
    math::clamp(decode_texture_alpha(format, code) * scale, 0.0, 1.0));
}
