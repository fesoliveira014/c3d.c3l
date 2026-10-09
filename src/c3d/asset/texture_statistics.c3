module c3d::asset;

import c3d;
import c3d::material;
import std::math;

<* Owned mip-zero coverage counts and their source identity. *>
struct CoverageStatistics {
    uint revision;
    bool valid;
    fault failure;
    TextureSourceKind source_kind;
    TextureSemantic semantic;
    CoveragePolicy coverage;
    double alpha_threshold;
    PixelFormat format;
    uint width;
    uint height;
    uint layers;
    bool is_cube;
    ulong[material::CUBE_FACE_COUNT] passing;
    ulong[material::CUBE_FACE_COUNT] total;
}

<*
 Scan mip-zero alpha into owned per-face coverage counts.
 @param pixels : "Complete borrowed mip-zero layers."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
*>
fn CoverageStatistics? create_coverage_statistics(TextureDesc desc, char[] pixels, uint revision = 0) {
    check_texture_semantics(desc)!;

    CoverageStatistics statistics = texture_statistics_identity(desc, TextureSourceKind.MIP_ZERO, revision);

    if (desc.coverage == CoveragePolicy.NONE) return statistics;
    if (!pixels.len) return c3d::ASSET_DATA_UNAVAILABLE~;

    usz layer_bytes = material::texture_mip_bytes(desc, 0)!;

    if (layer_bytes > (usz)sz::max / desc.layers || pixels.len != layer_bytes * desc.layers) {
        return c3d::INVALID_ARGUMENT~;
    }

    ulong texels = (ulong)desc.width * desc.height;

    for (uint layer = 0; layer < desc.layers; layer++) {
        statistics.total[layer] = texels;

        for (usz texel = 0; texel < (usz)texels; texel++) {
            uint code = texture_alpha_code(desc.format, pixels, (usz)layer * (usz)texels + texel);
            double alpha = decode_texture_alpha(desc.format, code);

            if (!math::is_finite(alpha) || alpha < 0.0 || alpha > 1.0) return c3d::INVALID_ARGUMENT~;

            switch (desc.coverage) {
                case NONE: break;
                case THRESHOLD: statistics.passing[layer] += alpha >= desc.alpha_threshold ? 1 : 0;
                case ALL_PASS: statistics.passing[layer]++;
                case ALL_FAIL: break;
            }
        }
    }

    return statistics;
}

<*
 Validate a statistic against the required revision and description.
 @param [&in] statistics : "Owned source identity and counts."
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_DATA_UNAVAILABLE
*>
fn void? check_coverage_statistics(TextureDesc desc, CoverageStatistics* statistics, uint revision) {
    if (desc.coverage == CoveragePolicy.NONE) return;
    if (statistics.revision != revision || !texture_statistics_match(desc, statistics)
      || statistics.source_kind != TextureSourceKind.MIP_ZERO) return c3d::INVALID_ARGUMENT~;

    if (!statistics.valid) {
        return statistics.failure == c3d::ASSET_DATA_UNAVAILABLE
            ? c3d::ASSET_DATA_UNAVAILABLE~ : c3d::INVALID_ARGUMENT~;
    }

    ulong texels = (ulong)desc.width * desc.height;

    for (uint face = 0; face < desc.layers; face++) {
        if (statistics.total[face] != texels || statistics.passing[face] > texels) return c3d::INVALID_ARGUMENT~;
    }
}

fn CoverageStatistics texture_statistics_identity(
    TextureDesc desc,
    TextureSourceKind source_kind,
    uint revision,
) @private {
    return {
        .revision = revision, .valid = true, .source_kind = source_kind,
        .semantic = desc.semantic, .coverage = desc.coverage, .alpha_threshold = desc.alpha_threshold,
        .format = desc.format, .width = desc.width, .height = desc.height,
        .layers = desc.layers, .is_cube = desc.is_cube,
    };
}

fn bool texture_statistics_match(TextureDesc desc, CoverageStatistics* statistics) @private {
    return statistics.semantic == desc.semantic && statistics.coverage == desc.coverage
      && (desc.coverage != CoveragePolicy.THRESHOLD || statistics.alpha_threshold == desc.alpha_threshold)
      && statistics.format == desc.format
      && statistics.width == desc.width && statistics.height == desc.height
      && statistics.layers == desc.layers && statistics.is_cube == desc.is_cube;
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
            default: break;
        }

        if (desc.format == PixelFormat.R16_UINT) return c3d::UNSUPPORTED~;
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
