module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import std::math;

const uint COVERAGE_BINS @private = 256; // one bin per 8-bit alpha code; float alpha falls into 1/256 steps
const uint COVERAGE_PASSES @private = 2; // filtering, then the correction of a level outside the tolerance
const ulong COVERAGE_TOLERANCE_DENOMINATOR @private = 50; // a level may differ from mip zero by 2% of its texels
const uint UNORM_ALPHA_ONE_CODE @private = char::max;
const uint HALF_ALPHA_ONE_CODE @private = 0x3c00;
const uint FLOAT_ALPHA_ONE_CODE @private = 0x3f800000;

struct TextureCoverageLevel @private {
    ulong[COVERAGE_BINS] histogram;
    ulong passing;
    ulong group;
    ulong promote;
    ulong spacing;
    uint cutoff;
    double scale;
}

struct TextureCoverageState @private {
    PixelFormat format;
    double threshold;
    uint minimum_passing;
    ulong[material::CUBE_FACE_COUNT] base_passing;
    TextureCoverageLevel level;
}

fn TextureCoverageState begin_texture_coverage(material::TextureDesc desc) @private {
    return {
        .format = desc.format,
        .threshold = desc.alpha_threshold,
        .minimum_passing = minimum_texture_passing_code(desc.format, desc.alpha_threshold),
    };
}

fn uint minimum_texture_passing_code(PixelFormat format, double threshold) @private {
    uint below;
    uint reaching = format == RGBA16_FLOAT ? HALF_ALPHA_ONE_CODE
      : format == RGBA32_FLOAT ? FLOAT_ALPHA_ONE_CODE : UNORM_ALPHA_ONE_CODE;

    while (below < reaching) {
        uint middle = below + (reaching - below) / 2;

        if (asset::decode_texture_alpha(format, middle) >= threshold) {
            reaching = middle;
        } else {
            below = middle + 1;
        }
    }

    return below;
}

fn bool coverage_bins_exact(PixelFormat format) @private {
    return format == PixelFormat.RGBA8_UNORM || format == PixelFormat.RGBA8_SRGB;
}

fn uint coverage_bin(PixelFormat format, uint stored) @private {
    if (coverage_bins_exact(format)) return stored;

    double scaled = asset::decode_texture_alpha(format, stored) * COVERAGE_BINS;

    return (uint)math::clamp(scaled, 0.0, (double)(COVERAGE_BINS - 1));
}

fn double coverage_bin_alpha(PixelFormat format, uint bin) @private {
    return (double)bin / (coverage_bins_exact(format) ? (double)UNORM_ALPHA_ONE_CODE : (double)COVERAGE_BINS);
}

fn void collect_texture_coverage(TextureCoverageState* state, uint stored) @private {
    state.level.histogram[coverage_bin(state.format, stored)]++;
    state.level.passing += asset::decode_texture_alpha(state.format, stored) >= state.threshold ? 1 : 0;
}

fn bool choose_texture_coverage(
    TextureCoverageState* state,
    material::TextureDesc desc,
    uint mip,
    uint layer,
) @private {
    TextureCoverageLevel* level = &state.level;
    uint width = material::texture_mip_extent(desc.width, mip);
    ulong texels = (ulong)width * material::texture_mip_extent(desc.height, mip);
    ulong base_total = (ulong)desc.width * desc.height;
    ulong base_passing = state.base_passing[layer];
    ulong target = (ulong)(((uint128)base_passing * texels * 2 + base_total) / ((uint128)base_total * 2));
    uint128 actual = (uint128)level.passing * base_total;
    uint128 expected = (uint128)base_passing * texels;
    uint128 error = actual > expected ? actual - expected : expected - actual;
    bool within_tolerance = error * COVERAGE_TOLERANCE_DENOMINATOR <= (uint128)base_total * texels;

    if (level.passing == target || within_tolerance) return false;

    ulong reaching;
    uint cutoff = COVERAGE_BINS;

    while (reaching < target) {
        cutoff--;
        reaching += level.histogram[cutoff];
    }

    level.cutoff = cutoff;
    level.group = cutoff < COVERAGE_BINS ? level.histogram[cutoff] : 0;
    level.promote = target - (reaching - level.group);
    level.spacing = level.group / 2;
    level.scale = state.threshold / coverage_bin_alpha(state.format, math::max(cutoff, 1u));

    return true;
}

fn void write_texture_coverage_band(
    TextureCoverageState* state,
    material::TextureDesc desc,
    TextureMipChain* chain,
    uint mip,
    uint layer,
    uint first_row,
    uint row_count,
) @private {
    TextureCoverageLevel* level = &state.level;
    uint width = material::texture_mip_extent(desc.width, mip);
    uint height = material::texture_mip_extent(desc.height, mip);
    usz layer_bytes = (usz)width * height * material::texture_block_bytes(desc.format);
    char[] destination = chain.pixels[chain.offsets[mip - 1] + (usz)layer * layer_bytes:layer_bytes];

    for (uint row = first_row; row < first_row + row_count; row++) {
        for (uint step = 0; step < width; step++) {
            // Odd rows run right to left so evenly spaced promotions alternate between rows, not form columns.
            uint column = row % 2 ? width - 1 - step : step;
            usz texel = (usz)row * width + column;
            uint stored = asset::texture_alpha_code(state.format, destination, texel);
            uint bin = coverage_bin(state.format, stored);
            bool passes = bin > level.cutoff;

            if (bin == level.cutoff) {
                level.spacing += level.promote;
                passes = level.spacing >= level.group;

                if (passes) level.spacing -= level.group;
            }

            uint corrected = asset::scale_texture_alpha(state.format, stored, level.scale);

            if (passes != (asset::decode_texture_alpha(state.format, corrected) >= state.threshold)) {
                corrected = passes ? state.minimum_passing : state.minimum_passing - 1;
            }

            asset::write_texture_alpha_code(
                format: state.format,
                pixels: destination,
                texel: texel,
                code: corrected,
            );
        }
    }
}
