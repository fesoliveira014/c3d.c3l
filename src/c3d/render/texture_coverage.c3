module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import std::math;

const uint CODE_BITS @private = 8;
const uint ALPHA_RADIX_BINS @private = 256;
const uint UNORM_ALPHA_ONE_CODE @private = char::max;
const uint HALF_ALPHA_ONE_CODE @private = 0x3c00;
const uint FLOAT_ALPHA_ONE_CODE @private = 0x3f800000;
const ulong ALPHA_SCALE_BOUND @private = 0x4950000000000000; // 2^150 activates the smallest positive float alpha
const uint HASH_BYTES @private = 4;
const ulong COVERAGE_TOLERANCE_DENOMINATOR @private = 50;
<* Absolute coverage error allowed before plateau correction. *>
const double COVERAGE_TOLERANCE = 1.0 / (double)COVERAGE_TOLERANCE_DENOMINATOR;
$assert(COVERAGE_TOLERANCE == 0.02);
const uint HASH_INITIAL @private = 0x811c9dc5; // fixed word-FNV seed; spatial selection must reproduce across retries
const uint HASH_WORD_MULTIPLIER @private = 0x01000193;
const uint HASH_AVALANCHE_FIRST @private = 0x7feb352d; // fixed avalanche permutation parameters
const uint HASH_AVALANCHE_SECOND @private = 0x846ca68b;

struct TextureHashChoice @private {
    uint prefix;
    uint length;
    ulong rank;
    ulong bucket;
    ulong seen;
}

struct TextureCoverageState @private {
    ulong[ALPHA_RADIX_BINS] histogram;
    ulong texels;
    PixelFormat format;
    uint width;
    uint height;
    uint face;
    uint mip;
    uint phase;
    uint row;
    uint alpha_bytes;
    uint prefix;
    uint candidate_key;
    uint minimum_code;
    ulong above;
    ulong equal;
    ulong rank;
    ulong positive;
    ulong identity;
    ulong global_count;
    ulong expected;
    ulong promote_count;
    ulong reserved;
    ulong base_pass;
    ulong base_total;
    double cutoff;
    double scale;
    double global_scale;
    TextureHashChoice hash;
    bool endpoint;
    bool zero_critical;
    bool plateau;
}

fn uint texture_coordinate_hash(
    uint face,
    uint mip,
    uint x,
    uint y,
) @private {
    uint hash = HASH_INITIAL;
    uint[4] words = { face, mip, x, y };

    foreach (word : words) hash = (uint)((ulong)(hash ^ word) * HASH_WORD_MULTIPLIER);

    hash ^= hash >> 16;
    hash = (uint)((ulong)hash * HASH_AVALANCHE_FIRST);
    hash ^= hash >> 15;
    hash = (uint)((ulong)hash * HASH_AVALANCHE_SECOND);

    return hash ^ (hash >> 16);
}

fn void select_texture_hash_byte(ulong[ALPHA_RADIX_BINS]* histogram, TextureHashChoice* choice) @private {
    for (uint bin = 0; bin < ALPHA_RADIX_BINS; bin++) {
        ulong count = histogram.[bin];

        if (choice.rank > count) {
            choice.rank -= count;
        } else {
            choice.prefix = (choice.prefix << CODE_BITS) | bin;
            choice.length++;
            choice.bucket = count;
            return;
        }
    }

    unreachable();
}

fn bool selected_texture_hash(TextureHashChoice* choice, uint hash) @private {
    uint prefix = hash >> ((HASH_BYTES - choice.length) * CODE_BITS);

    if (prefix < choice.prefix) return true;
    if (prefix > choice.prefix) return false;

    return choice.seen++ < choice.rank;
}

fn uint minimum_texture_passing_code(PixelFormat format, double cutoff) @private {
    uint below;
    uint reaching = format == RGBA8_UNORM || format == RGBA8_SRGB ? UNORM_ALPHA_ONE_CODE
      : format == RGBA16_FLOAT ? HALF_ALPHA_ONE_CODE : FLOAT_ALPHA_ONE_CODE;

    while (below < reaching) {
        uint middle = below + (reaching - below) / 2;

        if (asset::decode_texture_alpha(format, middle) >= cutoff) { reaching = middle; } else { below = middle + 1; }
    }

    return below;
}

fn uint128 texture_tolerance_floor(ulong total, ulong output) @private {
    ulong remainder = total % COVERAGE_TOLERANCE_DENOMINATOR;
    ulong fractional = remainder * (output / COVERAGE_TOLERANCE_DENOMINATOR)
      + (remainder * (output % COVERAGE_TOLERANCE_DENOMINATOR)) / COVERAGE_TOLERANCE_DENOMINATOR;

    return (uint128)(total / COVERAGE_TOLERANCE_DENOMINATOR) * output + fractional;
}

fn uint128 texture_count_error(ulong count, TextureCoverageState* state) @private {
    uint128 actual = (uint128)count * state.base_total;
    uint128 target = (uint128)state.base_pass * state.texels;

    return actual >= target ? actual - target : target - actual;
}

fn ulong nearest_texture_target(TextureCoverageState* state) @private {
    ulong upper = texture_target_rank(state.base_pass, state.base_total, state.texels);

    if ((uint128)upper * state.base_total == (uint128)state.base_pass * state.texels) return upper;

    return texture_count_error(upper, state) < texture_count_error(upper - 1, state) ? upper : upper - 1;
}

fn void skip_texture_coverage_to(TextureCoverageState* state, uint phase) @private {
    ulong skipped = (ulong)(phase - state.phase) * state.texels;
    state.reserved += skipped;
    state.phase = phase;
    state.row = 0;
    state.histogram = {};
}

fn void choose_texture_correction(TextureCoverageState* state) @private {
    state.scale = state.global_scale;
    state.expected = state.global_count;

    if (!state.endpoint && texture_count_error(state.global_count, state)
      > texture_tolerance_floor(state.base_total, state.texels)) {
        state.plateau = true;
        state.expected = nearest_texture_target(state);
        state.promote_count = state.expected - state.above;
        state.minimum_code = minimum_texture_passing_code(state.format, state.cutoff);

        if (!state.zero_critical) {
            state.scale = state.identity == state.above ? 1.0
              : bitcast(first_texture_alpha_scale(state.format, state.prefix, state.cutoff) - 1, double);
        }

        if (state.promote_count && state.promote_count < state.equal) {
            state.hash.rank = state.promote_count;
            skip_texture_coverage_to(state, state.alpha_bytes);
            return;
        }
    }

    skip_texture_coverage_to(state, state.alpha_bytes + HASH_BYTES);
}

fn void select_texture_alpha_byte(TextureCoverageState* state) @private {
    for (uint bin = ALPHA_RADIX_BINS; bin > 0; bin--) {
        ulong count = state.histogram[bin - 1];

        if (state.rank > count) {
            state.rank -= count;
            state.above += count;
        } else {
            state.prefix = (state.prefix << CODE_BITS) | (bin - 1);
            state.equal = count;
            return;
        }
    }

    unreachable();
}

fn void choose_texture_global(TextureCoverageState* state) @private {
    ulong higher = state.above + state.equal;
    bool choose_high = texture_count_error(higher, state) < texture_count_error(state.above, state);

    state.global_count = choose_high ? higher : state.above;
    state.global_scale = 1.0;

    if (state.identity != state.global_count) {
        ulong activation = first_texture_alpha_scale(state.format, state.prefix, state.cutoff);
        state.global_scale = bitcast(choose_high ? activation : activation - 1, double);
    }

    if (state.zero_critical) {
        state.prefix = 0;
        state.above = state.positive;
        state.equal = state.texels - state.positive;
    }

    choose_texture_correction(state);
}

fn void finish_texture_coverage_pass(TextureCoverageState* state) @private {
    uint completed = state.phase;
    bool single_prefix = completed && completed < state.alpha_bytes && state.equal == 1;

    state.phase++;
    state.row = 0;

    if (completed == 0) {
        state.rank = texture_target_rank(state.base_pass, state.base_total, state.texels);

        if (!state.rank) {
            state.endpoint = true;
            state.global_count = 0;
            state.global_scale = state.identity ? 0.0 : 1.0;

            choose_texture_correction(state);

            return;
        }

        if (state.identity == nearest_texture_target(state) && texture_count_error(state.identity, state)
          <= texture_tolerance_floor(state.base_total, state.texels)) {
            state.global_count = state.identity;
            state.global_scale = 1.0;

            choose_texture_correction(state);

            return;
        }

        if (!state.positive) {
            state.zero_critical = true;
            state.prefix = 0;
            state.above = 0;
            state.equal = state.texels;
            state.global_count = 0;
            state.global_scale = 1.0;

            choose_texture_correction(state);

            return;
        }

        if (state.rank > state.positive) {
            state.zero_critical = true;
            state.rank = state.positive;

            if (state.identity == state.positive) {
                state.prefix = 0;
                state.above = state.positive;
                state.equal = state.texels - state.positive;
                state.global_count = state.positive;
                state.global_scale = 1.0;

                choose_texture_correction(state);

                return;
            }
        }
    }

    if (completed < state.alpha_bytes) {
        select_texture_alpha_byte(state);

        if (single_prefix) state.prefix = state.candidate_key;
        if (state.phase == state.alpha_bytes || single_prefix) {
            choose_texture_global(state);
            return;
        }

        if (state.equal == 1) {
            ulong higher = state.above + 1;
            ulong chosen = texture_count_error(higher, state) < texture_count_error(state.above, state)
              ? higher : state.above;

            if (state.identity == chosen && texture_count_error(chosen, state)
              <= texture_tolerance_floor(state.base_total, state.texels)) {
                state.global_count = chosen;
                state.global_scale = 1.0;

                choose_texture_correction(state);

                return;
            }
        }
    } else if (completed < state.alpha_bytes + HASH_BYTES) {
        select_texture_hash_byte(&state.histogram, &state.hash);

        if (state.hash.rank == state.hash.bucket || state.hash.length == HASH_BYTES) {
            skip_texture_coverage_to(state, state.alpha_bytes + HASH_BYTES);
            return;
        }
    }

    state.histogram = {};
}

fn ulong first_texture_alpha_scale(PixelFormat format, uint code, double cutoff) @private {
    ulong below;
    ulong reaching = ALPHA_SCALE_BOUND;

    while (below + 1 < reaching) {
        ulong middle = below + (reaching - below) / 2;

        if (asset::decode_texture_alpha(
            format: format,
            code: asset::scale_texture_alpha(
                format: format,
                code: code,
                scale: bitcast(middle, double),
            ),
        ) >= cutoff) {
            reaching = middle;
        } else {
            below = middle;
        }
    }

    return reaching;
}

fn ulong texture_target_rank(ulong passing, ulong total, ulong output) @private {
    uint128 product = (uint128)passing * output;
    ulong below;
    ulong reaching = output;

    while (below < reaching) {
        ulong middle = below + (reaching - below) / 2;

        if ((uint128)middle * total >= product) {
            reaching = middle;
        } else {
            below = middle + 1;
        }
    }

    return below;
}

fn TextureCoverageState begin_texture_coverage(
    material::TextureDesc desc,
    uint mip,
    uint face,
    CoverageStatistics* statistics,
) @private {
    uint width = material::texture_mip_extent(desc.width, mip);
    uint height = material::texture_mip_extent(desc.height, mip);

    return {
        .texels = (ulong)width * height, .format = desc.format,
        .width = width, .height = height, .face = face, .mip = mip,
        .alpha_bytes = (uint)material::texture_block_bytes(desc.format) / 4,
        .base_pass = statistics.passing[face], .base_total = statistics.total[face],
        .cutoff = desc.alpha_threshold,
    };
}

fn void collect_texture_filter_output(TextureCoverageState* state, uint stored) @private {
    uint code = asset::texture_alpha_key(state.format, stored);
    state.histogram[code >> ((state.alpha_bytes - 1) * CODE_BITS)]++;
    state.positive += code ? 1 : 0;
    state.identity += asset::decode_texture_alpha(state.format, stored) >= state.cutoff ? 1 : 0;
}

fn void write_texture_coverage_band(
    material::TextureDesc desc,
    char[] destination,
    TextureCoverageState* state,
    uint row_count,
) @private {
    uint last = state.row + row_count;

    for (uint row = state.row; row < last; row++) {
        for (uint column = 0; column < state.width; column++) {
            usz index = (usz)row * state.width + column;
            uint stored = asset::texture_alpha_code(desc.format, destination, index);
            uint code = asset::texture_alpha_key(desc.format, stored);

            if (state.phase < state.alpha_bytes) {
                uint shift = (state.alpha_bytes - state.phase - 1) * CODE_BITS;

                if ((code >> (shift + CODE_BITS)) == state.prefix) {
                    state.histogram[(code >> shift) & (ALPHA_RADIX_BINS - 1)]++;

                    if (state.equal == 1) state.candidate_key = code;
                }
            } else if (state.phase < state.alpha_bytes + HASH_BYTES) {
                if (code == state.prefix) {
                    uint hash = texture_coordinate_hash(
                        face: state.face,
                        mip: state.mip,
                        x: column,
                        y: row,
                    );
                    uint shift = (HASH_BYTES - state.hash.length - 1) * CODE_BITS;

                    if (!state.hash.length || (hash >> (shift + CODE_BITS)) == state.hash.prefix) {
                        state.histogram[(hash >> shift) & (ALPHA_RADIX_BINS - 1)]++;
                    }
                }
            } else {
                uint corrected = asset::scale_texture_alpha(desc.format, stored, state.scale);

                if (state.plateau && code == state.prefix) {
                    bool promote = state.promote_count == state.equal;

                    if (state.promote_count && state.promote_count < state.equal) {
                        promote = selected_texture_hash(
                            choice: &state.hash,
                            hash: texture_coordinate_hash(
                                face: state.face,
                                mip: state.mip,
                                x: column,
                                y: row,
                            ),
                        );
                    }

                    if (promote) corrected = state.minimum_code;
                }

                asset::write_texture_alpha_code(
                    format: desc.format,
                    pixels: destination,
                    texel: index,
                    code: corrected,
                );
            }
        }
    }
}

fn uint texture_generation_passes(material::TextureDesc desc) @private {
    if (desc.coverage != CoveragePolicy.THRESHOLD) return 1;

    return (uint)material::texture_block_bytes(desc.format) / 4 + HASH_BYTES + 1;
}

<*
 Charge a cumulative reserved scan range in mip-zero texels.
 @require output_total > 0, passes > 0
 @require position / output_total < passes || (position / output_total == passes && position % output_total == 0)
 @require base_texels <= ulong::max / passes
 @pure
*>
fn ulong texture_scan_charge(
    ulong base_texels,
    ulong position,
    ulong output_total,
    uint passes,
) {
    ulong whole = position / output_total;
    ulong remainder = position % output_total;

    return whole * base_texels + generated_mip_charge(base_texels, remainder, output_total);
}
