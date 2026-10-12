module c3d::asset;

import c3d;
import c3d::material;
import std::math;

<*
 Count texels whose alpha passes the coverage threshold.
 @param texels : "Tightly packed texels of the format."
 @return? c3d::INVALID_ARGUMENT
 @require format == RGBA8_UNORM || format == RGBA8_SRGB || format == RGBA16_FLOAT || format == RGBA32_FLOAT
*>
fn ulong? count_passing_alpha(PixelFormat format, double threshold, char[] texels) {
    ulong passing;
    usz count = texels.len / material::texture_block_bytes(format);

    for (usz texel = 0; texel < count; texel++) {
        double alpha = decode_texture_alpha(format, texture_alpha_code(format, texels, texel));

        if (!math::is_finite(alpha) || alpha < 0.0 || alpha > 1.0) return c3d::INVALID_ARGUMENT~;

        passing += alpha >= threshold ? 1 : 0;
    }

    return passing;
}

fn void? check_coverage_alpha(TextureDesc desc, char[] pixels) @private {
    if (desc.coverage == CoveragePolicy.NONE) return;
    if (!pixels.len) return c3d::ASSET_DATA_UNAVAILABLE~;

    usz layer_bytes = material::texture_mip_bytes(desc, 0)!;

    if (layer_bytes > (usz)sz::max / desc.layers || pixels.len != layer_bytes * desc.layers) {
        return c3d::INVALID_ARGUMENT~;
    }

    (void)count_passing_alpha(desc.format, desc.alpha_threshold, pixels)!;
}

<*
 Validate explicit pixel interpretation and coverage eligibility.
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
*>
fn void? check_texture_semantics(TextureDesc desc) {
    if (desc.semantic != TextureSemantic.COLOR) {
        switch (desc.format) {
            case RGBA8_SRGB:
            case BC1_RGBA_SRGB:
            case BC3_SRGB:
            case BC7_SRGB: return c3d::INVALID_ARGUMENT~;

            case R16_UINT: return c3d::UNSUPPORTED~;

            case RGBA8_UNORM:
            case RGBA16_FLOAT:
            case RGBA32_FLOAT:
            case BC1_RGBA_UNORM:
            case BC3_UNORM:
            case BC4_UNORM:
            case BC5_UNORM:
            case BC6H_UFLOAT:
            case BC7_UNORM: break;
        }
    }

    if (desc.coverage == CoveragePolicy.NONE) return;
    if (desc.coverage == CoveragePolicy.THRESHOLD
      && (!math::is_finite(desc.alpha_threshold) || desc.alpha_threshold <= 0.0 || desc.alpha_threshold > 1.0)) {
        return c3d::INVALID_ARGUMENT~;
    }

    if (!desc.width || !desc.height || !desc.layers) return c3d::INVALID_ARGUMENT~;

    if (!desc.generate_mips || desc.depth || desc.storage || material::texture_is_compressed(desc.format)
      || desc.format == PixelFormat.R16_UINT) return c3d::UNSUPPORTED~;

    if (desc.mip_levels != 1) return c3d::INVALID_ARGUMENT~;

    if (desc.is_cube) {
        if (desc.layers != material::CUBE_FACE_COUNT || desc.width != desc.height) return c3d::INVALID_ARGUMENT~;
    } else if (desc.layers != 1) {
        return c3d::UNSUPPORTED~;
    }
}
