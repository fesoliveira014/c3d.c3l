module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import std::math;

const char[] LEAF_RGBA8 @local = $embed("../fixtures/texture_fidelity/leaf_rgba8.bin");
const char[] LEAF_RGBA16 @local = $embed("../fixtures/texture_fidelity/leaf_rgba16.bin");
const char[] LEAF_RGBA32 @local = $embed("../fixtures/texture_fidelity/leaf_rgba32.bin");

const uint FILTER_ORACLE_FNV_SEED @local = 0x811c9dc5;
const uint FILTER_ORACLE_FNV_MULTIPLIER @local = 0x01000193;
const uint FILTER_ORACLE_AVALANCHE_FIRST @local = 0x7feb352d;
const uint FILTER_ORACLE_AVALANCHE_SECOND @local = 0x846ca68b;
const uint FILTER_ORACLE_HALF_ONE @local = 0x3c00;
const uint FILTER_ORACLE_HALF_FRACTION_BITS @local = 10;
const int FILTER_ORACLE_HALF_EXPONENT_BIAS @local = 15;
const double FILTER_ORACLE_HALF_SUBNORMAL_UNIT @local = 1.0 / 16777216.0;

struct FilteringExecution @local {
    TextureMipChain chain;
    ulong work;
    ulong progress;
    bool first_skipped;
    bool later_plateau;
}

fn void test_mip_scalar_bands_accept_byte_aligned_half_and_float_storage() @test {
    @pool() {
        foreach (format : (PixelFormat[2]){ RGBA16_FLOAT, RGBA32_FLOAT }) {
            usz scalar_bytes = format == PixelFormat.RGBA16_FLOAT ? ushort::size : float::size;
            usz source_bytes = 4 * 4 * 4 * scalar_bytes;
            usz output_bytes = (2 * 2 + 1) * 4 * scalar_bytes;
            char[] source_storage = alloc::new_array(tmem, char, (sz)source_bytes + 2);
            char[] output_storage = alloc::new_array(tmem, char, (sz)output_bytes + 2);
            source_storage[0] = source_storage[^1] = 0xa5;
            output_storage[0] = output_storage[^1] = 0x5a;
            char[] source = source_storage[1:source_bytes];
            char[] output = output_storage[1:output_bytes];

            for (uint texel = 0; texel < 16; texel++) {
                float value = (float)(texel % 4) / 4;
                uint code = format == PixelFormat.RGBA16_FLOAT
                  ? (uint)asset::encode_texture_half(value) : bitcast(value, uint);

                for (uint channel = 0; channel < 4; channel++) {
                    usz offset = ((usz)texel * 4 + channel) * scalar_bytes;

                    for (usz byte = 0; byte < scalar_bytes; byte++) {
                        source[offset + byte] = (char)(code >> (byte * 8));
                    }
                }
            }

            material::TextureDesc desc = material::texture_2d_desc(4, 4, format);
            TextureMipChain chain = {
                .allocator = tmem,
                .first_mip = 1,
                .mip_count = 2,
                .layer_count = 1,
                .offsets = { [1] = 2 * 2 * 4 * scalar_bytes },
                .pixels = output,
            };

            write_texture_filter_band(
                desc: desc,
                mip: 1,
                layer: 0,
                first_row: 0,
                row_count: 2,
                mip_zero: source,
                chain: &chain,
            )!!;

            for (uint texel = 0; texel < 4; texel++) {
                float expected = texel % 2 ? 0.625f : 0.125f;
                uint code = format == PixelFormat.RGBA16_FLOAT
                  ? (uint)asset::encode_texture_half(expected) : bitcast(expected, uint);

                for (uint channel = 0; channel < 4; channel++) {
                    usz offset = ((usz)texel * 4 + channel) * scalar_bytes;

                    for (usz byte = 0; byte < scalar_bytes; byte++) {
                        assert(output[offset + byte] == (char)(code >> (byte * 8)));
                    }
                }
            }

            assert(source_storage[0] == 0xa5 && source_storage[^1] == 0xa5);
            assert(output_storage[0] == 0x5a && output_storage[^1] == 0x5a);
        }
    };
}

fn AssetStore filtering_store(Allocator allocator) @local {
    return asset::create_asset_store(allocator, {
        .max_geometries = 1, .max_textures = 8, .max_materials = 1, .max_samplers = 5,
    });
}

// The spatial-order contract hashes four words, rather than their byte serialization.
fn uint filtering_oracle_hash(
    uint face,
    uint mip,
    uint x,
    uint y,
) @local {
    uint hash = FILTER_ORACLE_FNV_SEED;

    foreach (word : (uint[4]){ face, mip, x, y }) {
        hash = (uint)((ulong)(hash ^ word) * FILTER_ORACLE_FNV_MULTIPLIER);
    }

    hash ^= hash >> 16;
    hash = (uint)((ulong)hash * FILTER_ORACLE_AVALANCHE_FIRST);
    hash ^= hash >> 15;
    hash = (uint)((ulong)hash * FILTER_ORACLE_AVALANCHE_SECOND);

    return hash ^ (hash >> 16);
}

fn uint filtering_oracle_alpha_code(PixelFormat format, char[] pixels, usz texel) @local {
    usz scalar_bytes = material::texture_block_bytes(format) / 4;
    usz offset = (texel * 4 + 3) * scalar_bytes;
    uint code;

    for (usz byte = 0; byte < scalar_bytes; byte++) code |= (uint)pixels[offset + byte] << (byte * 8);

    return code;
}

fn void filtering_oracle_write_alpha(
    PixelFormat format,
    char[] pixels,
    usz texel,
    uint code,
) @local {
    usz scalar_bytes = material::texture_block_bytes(format) / 4;
    usz offset = (texel * 4 + 3) * scalar_bytes;

    for (usz byte = 0; byte < scalar_bytes; byte++) pixels[offset + byte] = (char)(code >> (byte * 8));
}

fn double filtering_oracle_decode(PixelFormat format, uint code) @local {
    if (format == RGBA8_UNORM) return (double)code / (double)char::max;
    if (format == RGBA32_FLOAT) return (double)bitcast(code, float);

    uint fraction = code & ((1u << FILTER_ORACLE_HALF_FRACTION_BITS) - 1);
    uint exponent = code >> FILTER_ORACLE_HALF_FRACTION_BITS;

    if (!exponent) return (double)fraction * FILTER_ORACLE_HALF_SUBNORMAL_UNIT;

    double value = 1.0 + (double)fraction / (double)(1u << FILTER_ORACLE_HALF_FRACTION_BITS);
    int power = (int)exponent - FILTER_ORACLE_HALF_EXPONENT_BIAS;

    while (power < 0) {
        value *= 0.5;
        power++;
    }

    while (power > 0) {
        value *= 2.0;
        power--;
    }

    return value;
}

// Half storage first rounds to float, then to the nearest even half code.
fn uint filtering_oracle_encode(PixelFormat format, double value) @local {
    value = math::clamp(value, 0.0, 1.0);

    if (format == RGBA8_UNORM) return (uint)math::floor(value * (double)char::max + 0.5);
    if (format == RGBA32_FLOAT) return bitcast((float)value, uint);

    value = (double)(float)value;
    uint below;
    uint above = FILTER_ORACLE_HALF_ONE;

    while (below < above) {
        uint middle = below + (above - below) / 2;

        if (filtering_oracle_decode(format, middle) < value) {
            below = middle + 1;
        } else {
            above = middle;
        }
    }

    if (!above) return 0;

    double lower_error = value - filtering_oracle_decode(format, above - 1);
    double upper_error = filtering_oracle_decode(format, above) - value;

    return lower_error < upper_error || (lower_error == upper_error && (above & 1)) ? above - 1 : above;
}

fn uint filtering_oracle_scaled(PixelFormat format, uint code, double scale) @local {
    if (format == RGBA8_UNORM) {
        return (uint)math::clamp(math::floor((double)code * scale + 0.5), 0.0, (double)char::max);
    }

    return filtering_oracle_encode(format, filtering_oracle_decode(format, code) * scale);
}

fn ulong filtering_oracle_group_count(uint[] codes, ulong base_passing, ulong base_total) @local {
    ulong target = base_passing * codes.len;
    ulong best_count;
    ulong best_error = target;

    foreach (candidate : codes) {
        if (!candidate) continue;

        ulong count;

        foreach (code : codes) count += code >= candidate ? 1 : 0;

        ulong actual = count * base_total;
        ulong error = actual >= target ? actual - target : target - actual;

        if (error < best_error || (error == best_error && count < best_count)) {
            best_count = count;
            best_error = error;
        }
    }

    return best_count;
}

fn ulong count_filtered_alpha(material::TextureDesc desc, char[] pixels, double threshold) @local {
    ulong passing;
    usz texels = pixels.len / material::texture_block_bytes(desc.format);

    for (usz texel = 0; texel < texels; texel++) {
        uint code = asset::texture_alpha_code(desc.format, pixels, texel);
        double alpha = asset::decode_texture_alpha(desc.format, code);

        passing += alpha >= threshold ? 1 : 0;
    }

    return passing;
}

fn void test_coverage_publication_is_atomic_and_dirty_invalidity_is_revision_owned() @test {
    AssetStore assets = filtering_store(mem);
    defer asset::destroy_asset_store(&assets);

    material::TextureDesc desc = material::texture_2d_desc(2, 1, RGBA32_FLOAT);
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;
    float[8] pixels = { 0.2, 0.3, 0.4, 0.0, 0.4, 0.5, 0.6, 1.0 };

    TextureId texture = assets.add_texture(desc, ((char*)&pixels)[:pixels.len * float::size])!!;

    TextureAsset* source = assets.texture(texture);

    assert(source.coverage_statistics.valid && source.coverage_statistics.revision == 1);
    assert(source.coverage_statistics.passing[0] == 1 && source.coverage_statistics.total[0] == 2);

    pixels[7] = 1.01;

    if (catch excuse = assets.replace_texture(texture, desc, ((char*)&pixels)[:pixels.len * float::size])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Invalid alpha published");
    }

    assert(source.header.revision == 1 && source.coverage_statistics.passing[0] == 1);

    ((float*)source.pixels.ptr)[7] = bitcast(0x7fc00000u, float);

    assets.mark_texture_dirty(texture);

    assert(source.header.revision == 2 && !source.coverage_statistics.valid);
    assert(source.coverage_statistics.revision == 2 && source.coverage_statistics.failure == c3d::INVALID_ARGUMENT);

    if (catch excuse = check_prepare_texture_source(source)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Invalid dirty revision prepared");
    }

    assets.release_texture_cpu(texture);

    assert(source.coverage_statistics.revision == 2 && source.coverage_statistics.failure == c3d::INVALID_ARGUMENT);

    assets.mark_texture_dirty(texture);

    assert(source.coverage_statistics.revision == 3);
    assert(source.coverage_statistics.failure == c3d::ASSET_DATA_UNAVAILABLE);
}

fn void expect_invalid_threshold_publication_keeps_store_and_pixels(PixelFormat format) @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = filtering_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        material::TextureDesc desc = material::texture_2d_desc(2, 1, format);
        desc.coverage = CoveragePolicy.THRESHOLD;
        desc.alpha_threshold = 0.5;
        char[32] valid_storage;
        char[] valid = valid_storage[:2 * material::texture_block_bytes(format)];
        uint one_code = format == RGBA16_FLOAT ? 0x3c00 : 0x3f800000;

        filtering_oracle_write_alpha(
            format: format,
            pixels: valid,
            texel: 1,
            code: one_code,
        );

        TextureId texture = assets.add_texture(desc, valid)!!;
        usz count = assets.textures.items.len - assets.textures.free_count;
        TextureAsset* source = assets.texture(texture);
        char* original_pointer = source.pixels.ptr;
        uint[3] invalid_codes = format == RGBA16_FLOAT
          ? (uint[3]){ 0x7e00, 0xbc00, 0x3c01 } : (uint[3]){ 0x7fc00000, 0xbf800000, 0x3f800001 };

        foreach (code : invalid_codes) {
            char[32] invalid_storage = valid_storage;
            char[] invalid = invalid_storage[:valid.len];

            filtering_oracle_write_alpha(
                format: format,
                pixels: invalid,
                texel: 1,
                code: code,
            );

            sz before = tracker.allocated();

            assert(@catch(assets.add_texture(desc, invalid)) == c3d::INVALID_ARGUMENT);
            assert(assets.textures.items.len - assets.textures.free_count == count);
            assert(source.header.revision == 1 && source.coverage_statistics.revision == 1);
            assert(source.pixels.ptr == original_pointer && source.pixels == valid);
            assert(tracker.allocated() == before);

            for (uint operation = 0; operation < 2; operation++) {
                char[] owned = alloc::new_array(&tracker, char, (sz)invalid.len);
                defer alloc::free(&tracker, owned.ptr);
                owned[..] = invalid[..];
                sz with_owned = tracker.allocated();

                if (!operation) {
                    assert(@catch(assets.add_texture_owned(desc, owned)) == c3d::INVALID_ARGUMENT);
                } else {
                    assert(@catch(assets.replace_texture_owned(
                        texture: texture,
                        desc: desc,
                        pixels: owned,
                    )) == c3d::INVALID_ARGUMENT);
                }

                assert(tracker.allocated() == with_owned);
                assert(owned == invalid);
                assert(assets.textures.items.len - assets.textures.free_count == count);
                assert(source.header.revision == 1 && source.coverage_statistics.revision == 1);
                assert(source.coverage_statistics.valid && source.coverage_statistics.passing[0] == 1);
                assert(source.pixels.ptr == original_pointer && source.pixels == valid);
            }

            assert(tracker.allocated() == before);
        }
    }

    assert(!tracker.has_leaks());
}

fn void test_invalid_threshold_alpha_add_and_owned_publication_preserve_store_and_caller_ownership() @test {
    foreach (format : (PixelFormat[2]){ RGBA16_FLOAT, RGBA32_FLOAT }) {
        expect_invalid_threshold_publication_keeps_store_and_pixels(format);
    }
}

fn void test_normal_filter_normalizes_sources_and_cancellation_uses_positive_z() @test {
    material::TextureDesc desc = material::texture_2d_desc(2, 1, RGBA32_FLOAT);
    desc.semantic = TextureSemantic.NORMAL_RGB;
    float[8] source = { 1.0, 0.5, 0.5, 0.2, 0.0, 0.5, 0.5, 0.8 };

    TextureMipChain chain = create_texture_mips(mem, desc, ((char*)&source)[:source.len * float::size])!!;
    defer destroy_texture_mips(&chain);

    float* output = (float*)(chain.pixels.ptr + chain.offsets[1]);

    assert(output[0] == 0.5 && output[1] == 0.5 && output[2] == 1.0 && output[3] == 0.5);
    assert(chain.pixels[:source.len * float::size] == ((char*)&source)[:source.len * float::size]);

    source = { 1.0, 0.5, 0.5, 0.2, 0.5, 0.75, 0.5, 0.8 };

    TextureMipChain unequal = create_texture_mips(mem, desc, ((char*)&source)[:source.len * float::size])!!;
    defer destroy_texture_mips(&unequal);

    output = (float*)(unequal.pixels.ptr + unequal.offsets[1]);
    double expected = 0.5 + 0.5 / math::sqrt(2.0);

    assert(math::abs((double)output[0] - expected) < 1e-7);
    assert(math::abs((double)output[1] - expected) < 1e-7 && output[3] == 0.5);
}

fn void test_rg_reconstruction_precedes_filtering_and_ignores_unused_blue() @test {
    material::TextureDesc desc = material::texture_2d_desc(2, 1, RGBA32_FLOAT);
    desc.semantic = TextureSemantic.NORMAL_RG;
    float[8] pixels = { 0.8, 0.5, 0.0, 0.1, 0.8, 0.5, bitcast(0x7fc00000u, float), 0.9 };

    TextureMipChain chain = create_texture_mips(mem, desc, ((char*)&pixels)[:pixels.len * float::size])!!;
    defer destroy_texture_mips(&chain);

    float* output = (float*)(chain.pixels.ptr + chain.offsets[1]);

    assert(math::abs(output[0] - 0.8f) < 1e-7f && output[1] == 0.5 && output[3] == 0.5);
    assert(math::abs(output[2] - 0.9f) < 1e-7f);

    pixels[0] = 1.5;
    pixels[4] = 1.5;

    TextureMipChain outside = create_texture_mips(mem, desc, ((char*)&pixels)[:pixels.len * float::size])!!;
    defer destroy_texture_mips(&outside);

    output = (float*)(outside.pixels.ptr + outside.offsets[1]);

    assert(output[0] == 1.0 && output[1] == 0.5 && output[2] == 0.5);
}

fn void test_nonfinite_normal_fails_even_when_no_generated_level_consumes_it() @test {
    material::TextureDesc desc = material::texture_2d_desc(1, 1, RGBA32_FLOAT);
    desc.semantic = TextureSemantic.NORMAL_RGB;
    float[4] pixels = { 0.5, 0.5, bitcast(0x7f800000u, float), 1.0 };

    if (catch excuse = create_texture_mips(mem, desc, ((char*)&pixels)[:pixels.len * float::size])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Nonfinite normal accepted");
    }

    desc.semantic = TextureSemantic.NORMAL_RG;

    TextureMipChain chain = create_texture_mips(mem, desc, ((char*)&pixels)[:pixels.len * float::size])!!;
    defer destroy_texture_mips(&chain);

    assert(chain.mip_count == 1 && chain.pixels == ((char*)&pixels)[:pixels.len * float::size]);

    GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!!;

    TextureMipChain generated = create_generated_texture_mips(mem, desc)!!;
    defer destroy_texture_mips(&generated);

    assert(layout.output_texels == 0 && layout.byte_count == 0 && !generated.pixels.len);
}

fn void test_explicit_normal_srgb_and_supplied_coverage_are_rejected() @test {
    AssetStore assets = filtering_store(mem);
    defer asset::destroy_asset_store(&assets);

    material::TextureDesc desc = material::texture_2d_desc(2, 1, RGBA8_SRGB);
    desc.semantic = TextureSemantic.NORMAL_RGB;
    char[8] pixels;

    if (catch excuse = assets.add_texture(desc, pixels[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "sRGB normal accepted");
    }

    desc.semantic = TextureSemantic.COLOR;
    desc.generate_mips = false;
    desc.coverage = CoveragePolicy.ALL_PASS;
    TextureMipData[1] levels = { { .bytes = pixels[..] } };

    if (catch excuse = assets.add_texture_mips(desc, levels[..])) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "Supplied coverage accepted");
    }
}

fn void test_pass_billing_crosses_whole_cycles_without_overflow() @test {
    ulong base = ulong::max / 9;
    ulong output = ulong::max / 9;

    assert(texture_scan_charge(
        base_texels: base,
        position: 0,
        output_total: output,
        passes: 9,
    ) == 0);
    assert(texture_scan_charge(
        base_texels: base,
        position: 9 * output,
        output_total: output,
        passes: 9,
    ) == 9 * base);
    assert(texture_scan_charge(
        base_texels: base,
        position: 4 * output + 17,
        output_total: output,
        passes: 9,
    ) == 4 * base + 17);

    for (ulong position = 0; position <= 9 * 13; position++) {
        ulong reference = 101 * position / 13;

        assert(texture_scan_charge(
            base_texels: 101,
            position: position,
            output_total: 13,
            passes: 9,
        ) == reference);
    }
}

fn void test_hash_prefix_collision_quota_keeps_raster_ties() @test {
    TextureHashChoice choice = { .prefix = 0x12345678, .length = 4, .rank = 2, .bucket = 3 };

    assert(selected_texture_hash(&choice, 0x12345677));
    assert(selected_texture_hash(&choice, 0x12345678));

    TextureHashChoice resumed = choice;

    assert(selected_texture_hash(&choice, 0x12345678));
    assert(selected_texture_hash(&resumed, 0x12345678));
    assert(!selected_texture_hash(&choice, 0x12345678));
    assert(!selected_texture_hash(&resumed, 0x12345678));
    assert(!selected_texture_hash(&choice, 0x12345679));
}

fn FilteringExecution run_filtered_rows(
    material::TextureDesc desc,
    char[] pixels,
    uint maximum_rows,
    bool release_after_filter = false,
) @local {
    AssetStore assets = filtering_store(mem);
    defer asset::destroy_asset_store(&assets);

    TextureId texture = assets.add_texture(desc, pixels)!!;

    TextureAsset* source = assets.texture(texture);
    GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!!;
    PrepareUnit unit = { .kind = PrepareUnitKind.TEXTURE, .texture = texture, .revision = 1 };
    PrepareRecord record = {
        .chain = create_generated_texture_mips(mem, desc)!!,
        .chain_active = true, .generation_mip = 1,
        .generation_desc = desc, .generation_statistics = source.coverage_statistics,
    };

    if (desc.coverage == CoveragePolicy.THRESHOLD) record.coverage = begin_texture_coverage(
        desc: desc,
        mip: 1,
        face: 0,
        statistics: &record.generation_statistics,
    );

    Renderer renderer = { .assets = &assets };
    PrepareReport report;
    FilteringExecution execution;
    bool released;

    while (record.generation_mip <= layout.mip_count) {
        uint height = material::texture_mip_extent(desc.height, record.generation_mip);
        uint rows = math::min(maximum_rows, height - record.generation_row);
        TextureBand band = texture_band(
            desc: desc,
            mip: record.generation_mip,
            layer: record.generation_layer,
            slice: 0,
            first_block_row: record.generation_row,
            block_rows: rows,
        )!!;
        ulong before = texture_scan_charge(
            base_texels: layout.base_texels,
            position: record.generation_outputs,
            output_total: layout.output_texels,
            passes: layout.passes,
        );
        ulong after = texture_scan_charge(
            base_texels: layout.base_texels,
            position: record.generation_outputs + (ulong)band.width * rows,
            output_total: layout.output_texels,
            passes: layout.passes,
        );
        uint previous_mip = record.generation_mip;
        uint previous_phase = record.coverage.phase;
        PrepareStepPlan plan = { .kind = PrepareResourceStep.GENERATE, .band = band,
            .cost = { .generated_texels = after - before } };

        run_prepare_step(
            renderer: &renderer,
            record: &record,
            unit: &unit,
            plan: &plan,
            report: &report,
        )!!;

        if (previous_mip == 1 && previous_phase == 0 && record.coverage.phase >= 5) execution.first_skipped = true;

        if (record.generation_mip > 1 && record.coverage.plateau) execution.later_plateau = true;

        if (release_after_filter && !released && (record.generation_mip > 1 || record.coverage.phase > 0)) {
            assets.release_texture_cpu(texture);

            released = true;
        }
    }

    execution.chain = record.chain;
    execution.work = report.generated_texels;
    execution.progress = record.texels_done;

    assert(unit.generated_done == record.texels_done);
    assert(record.generation_outputs == layout.output_texels * layout.passes);

    return execution;
}

fn void test_later_plateau_engages_after_skipped_hashes_and_held_source_resumes() @test {
    material::TextureDesc desc = material::texture_2d_desc(16, 16, RGBA8_UNORM);
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;
    char[1024] pixels;

    for (uint y = 0; y < 16; y++) {
        for (uint x = 0; x < 16; x++) {
            usz texel = (usz)y * 16 + x;
            pixels[texel * 4] = (char)(x * 13);
            pixels[texel * 4 + 1] = (char)(y * 11);
            pixels[texel * 4 + 2] = 64;
            pixels[texel * 4 + 3] = ((x / 2 + y / 2) & 1) ? 255 : 0;
        }
    }

    FilteringExecution single = run_filtered_rows(desc, pixels[..], 1);
    defer destroy_texture_mips(&single.chain);

    FilteringExecution whole = run_filtered_rows(desc, pixels[..], 16);
    defer destroy_texture_mips(&whole.chain);

    FilteringExecution held = run_filtered_rows(
        desc: desc,
        pixels: pixels[..],
        maximum_rows: 1,
        release_after_filter: true,
    );
    defer destroy_texture_mips(&held.chain);

    assert(single.chain.pixels == whole.chain.pixels && single.chain.pixels == held.chain.pixels);
    assert(single.first_skipped && single.later_plateau && held.first_skipped && held.later_plateau);
    assert(single.progress == 6 * 256 && single.work < single.progress);
    assert(single.work == whole.work && single.work == held.work && held.progress == single.progress);

    char[] first = single.chain.pixels[:256];
    char[] second = single.chain.pixels[single.chain.offsets[1]:64];

    assert(count_filtered_alpha(desc, first, 0.5) == 32);
    assert(count_filtered_alpha(desc, second, 0.5) == 8);

    material::TextureDesc ordinary = desc;
    ordinary.coverage = CoveragePolicy.NONE;

    TextureMipChain color = create_texture_mips(mem, ordinary, pixels[..])!!;
    defer destroy_texture_mips(&color);

    assert(first == color.pixels[color.offsets[1]:256]);

    for (usz texel = 0; texel < 16; texel++) {
        for (usz channel = 0; channel < 3; channel++) {
            assert(second[texel * 4 + channel] == color.pixels[color.offsets[2] + texel * 4 + channel]);
        }
    }
}

fn void test_zero_output_cube_has_zero_work_and_no_generation_allocation() @test {
    material::TextureDesc desc = material::texture_cube_desc(1, RGBA16_FLOAT);
    desc.semantic = TextureSemantic.NORMAL_RG;
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;
    GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!!;

    assert(layout.output_texels == 0 && layout.byte_count == 0 && layout.passes == 7);

    TextureMipChain generated = create_generated_texture_mips(mem, desc)!!;
    defer destroy_texture_mips(&generated);

    assert(!generated.pixels.len && generated.mip_count == 0 && generated.layer_count == 6);
}

fn void expect_frozen_leaf(PixelFormat format, char[] pixels) @local {
    material::TextureDesc desc = material::texture_2d_desc(32, 32, format);
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;

    CoverageStatistics statistics = asset::create_coverage_statistics(desc, pixels)!!;

    assert(statistics.passing[0] == 484 && statistics.total[0] == 1024);

    FilteringExecution single = run_filtered_rows(desc, pixels, 1);
    defer destroy_texture_mips(&single.chain);

    FilteringExecution whole = run_filtered_rows(desc, pixels, 16);
    defer destroy_texture_mips(&whole.chain);

    assert(single.chain.pixels == whole.chain.pixels && single.progress == whole.progress);

    uint passes = format == RGBA8_UNORM ? 6 : format == RGBA16_FLOAT ? 7 : 9;

    assert(single.progress == (ulong)passes * 1024 && single.work == whole.work);
    assert(single.work < single.progress);

    usz mip_two_bytes = material::texture_mip_bytes(desc, 2)!!;
    char[] mip_two = single.chain.pixels[single.chain.offsets[1]:mip_two_bytes];

    assert(count_filtered_alpha(desc, mip_two, 0.5) == 30);

    for (uint mip = 1; mip <= 2; mip++) {
        usz bytes = material::texture_mip_bytes(desc, mip)!!;
        ulong count = count_filtered_alpha(desc, single.chain.pixels[single.chain.offsets[mip - 1]:bytes], 0.5);
        ulong width = material::texture_mip_extent(desc.width, mip);
        ulong height = material::texture_mip_extent(desc.height, mip);
        ulong total = width * height;
        double error = math::abs((double)count / (double)total - 484.0 / 1024.0);

        assert(error <= COVERAGE_TOLERANCE);
    }

    TextureMipChain synchronous = create_texture_mips(
        allocator: mem,
        desc: desc,
        pixels: pixels,
        statistics: &statistics,
    )!!;
    defer destroy_texture_mips(&synchronous);

    assert(synchronous.pixels[:pixels.len] == pixels);
    assert(synchronous.pixels[pixels.len..] == single.chain.pixels);
}

fn void test_frozen_leaf_meets_stored_coverage_in_each_codec_and_every_row_resume() @test {
    expect_frozen_leaf(RGBA8_UNORM, LEAF_RGBA8);
    expect_frozen_leaf(RGBA16_FLOAT, LEAF_RGBA16);
    expect_frozen_leaf(RGBA32_FLOAT, LEAF_RGBA32);
}

fn void test_coordinate_sorting_oracle_matches_known_word_hash_vectors() @test {
    uint[5][5] vectors = {
        { 0, 0, 0, 0, 0xc8b27205 },
        { 0, 2, 2, 1, 0x20522d93 },
        { 5, 3, 17, 29, 0x08022be2 },
        { uint::max, uint::max, uint::max, uint::max, 0xb7227c7d },
        { 5, 31, uint::max, 0x80000000, 0x1294bce2 },
    };

    foreach (vector : vectors) {
        assert(filtering_oracle_hash(
            face: vector[0],
            mip: vector[1],
            x: vector[2],
            y: vector[3],
        ) == vector[4]);
    }
}

fn void test_leaf_critical_group_matches_independent_hash_raster_sort_and_failing_bytes() @test {
    PixelFormat[3] formats = { RGBA8_UNORM, RGBA16_FLOAT, RGBA32_FLOAT };
    char[][3] fixtures = { LEAF_RGBA8, LEAF_RGBA16, LEAF_RGBA32 };
    ulong[3] scale_bits = { 4604627005528307182, 4604628067664354920, 4604631199764785486 };
    uint[3] minimum_codes = { 128, 0x3800, 0x3f000000 };

    foreach (format_index, format : formats) {
        material::TextureDesc ordinary = material::texture_2d_desc(32, 32, format);
        TextureMipChain unscaled = create_texture_mips(mem, ordinary, fixtures[format_index])!!;
        defer destroy_texture_mips(&unscaled);

        material::TextureDesc threshold = ordinary;
        threshold.coverage = CoveragePolicy.THRESHOLD;
        threshold.alpha_threshold = 0.5;
        TextureMipChain corrected = create_texture_mips(mem, threshold, fixtures[format_index])!!;
        defer destroy_texture_mips(&corrected);

        usz level_bytes = material::texture_mip_bytes(ordinary, 2)!!;
        char[] raw = unscaled.pixels[unscaled.offsets[2]:level_bytes];
        char[] actual = corrected.pixels[corrected.offsets[2]:level_bytes];
        uint[64] codes;

        for (usz texel = 0; texel < codes.len; texel++) {
            codes[texel] = filtering_oracle_alpha_code(format, raw, texel);
        }

        uint critical;
        uint critical_groups;

        foreach (candidate : codes) {
            if (candidate == critical && critical_groups) continue;

            uint above;
            uint equal;

            foreach (code : codes) {
                above += code > candidate ? 1 : 0;
                equal += code == candidate ? 1 : 0;
            }

            if (above == 24 && equal == 8) {
                critical = candidate;
                critical_groups++;
            }
        }

        assert(critical_groups == 1);

        uint[8] ranked;
        usz members;

        foreach (index, code : codes) {
            if (code == critical) ranked[members++] = (uint)index;
        }

        for (usz index = 1; index < members; index++) {
            uint candidate = ranked[index];
            uint candidate_hash = filtering_oracle_hash(
                face: 0,
                mip: 2,
                x: candidate % 8,
                y: candidate / 8,
            );
            usz insertion = index;

            while (insertion) {
                uint previous = ranked[insertion - 1];
                uint previous_hash = filtering_oracle_hash(
                    face: 0,
                    mip: 2,
                    x: previous % 8,
                    y: previous / 8,
                );

                if (previous_hash < candidate_hash || (previous_hash == candidate_hash && previous < candidate)) break;

                ranked[insertion] = previous;
                insertion--;
            }

            ranked[insertion] = candidate;
        }

        bool[64] promoted;

        for (usz rank = 0; rank < 6; rank++) promoted[ranked[rank]] = true;

        foreach (index : (uint[6]){ 10, 13, 17, 22, 41, 46 }) assert(promoted[index]);

        char[1024] baseline_storage;
        char[] baseline = baseline_storage[:level_bytes];
        baseline[..] = raw[..];
        double scale = bitcast(scale_bits[format_index], double);
        uint minimum = minimum_codes[format_index];
        uint baseline_passing;

        assert(filtering_oracle_decode(format, minimum) >= 0.5);
        assert(filtering_oracle_decode(format, minimum - 1) < 0.5);

        for (usz texel = 0; texel < codes.len; texel++) {
            uint code = filtering_oracle_scaled(format, codes[texel], scale);

            filtering_oracle_write_alpha(
                format: format,
                pixels: baseline,
                texel: texel,
                code: code,
            );
            baseline_passing += filtering_oracle_decode(format, code) >= 0.5 ? 1 : 0;

            if (codes[texel] == critical) assert(filtering_oracle_decode(format, code) < 0.5);
        }

        assert(baseline_passing == 24);

        for (usz texel = 0; texel < codes.len; texel++) {
            if (promoted[texel]) filtering_oracle_write_alpha(
                format: format,
                pixels: baseline,
                texel: texel,
                code: minimum,
            );
        }

        assert(actual == baseline);
        assert(count_filtered_alpha(threshold, actual, 0.5) == 30);
    }
}

fn TextureCoverageState solve_stored_groups(
    material::TextureDesc desc,
    char[] stored,
    ulong base_passing,
    ulong base_total,
) @local {
    usz texels = stored.len / material::texture_block_bytes(desc.format);
    TextureCoverageState state = {
        .texels = (ulong)texels, .format = desc.format, .width = (uint)texels, .height = 1,
        .mip = 1, .alpha_bytes = (uint)material::texture_block_bytes(desc.format) / 4,
        .base_pass = base_passing, .base_total = base_total, .cutoff = desc.alpha_threshold,
    };

    for (usz texel = 0; texel < texels; texel++) {
        collect_texture_filter_output(&state, asset::texture_alpha_code(desc.format, stored, texel));
    }

    state.reserved += state.texels;
    finish_texture_coverage_pass(&state);

    while (state.phase < texture_generation_passes(desc)) {
        write_texture_coverage_band(
            desc: desc,
            destination: stored,
            state: &state,
            row_count: 1,
        );

        state.reserved += state.texels;
        state.row = 1;
        finish_texture_coverage_pass(&state);
    }

    assert(count_filtered_alpha(desc, stored, desc.alpha_threshold) == state.expected);
    assert(state.reserved == state.texels * texture_generation_passes(desc));

    return state;
}

fn void test_canonical_zero_group_retains_minimal_positive_global_scale_within_tolerance() @test {
    material::TextureDesc desc = material::texture_2d_desc(100, 1, RGBA32_FLOAT);
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;
    float[400] pixels;

    for (usz texel = 0; texel < 99; texel++) pixels[texel * 4 + 3] = bitcast(1u, float);

    TextureCoverageState state = solve_stored_groups(
        desc: desc,
        stored: ((char*)&pixels)[:pixels.len * float::size],
        base_passing: 100,
        base_total: 100,
    );

    assert(!state.plateau && state.zero_critical && state.global_count == 99 && state.expected == 99);
    assert(state.scale == state.global_scale && state.scale > 1.0);

    for (usz texel = 0; texel < 99; texel++) assert(pixels[texel * 4 + 3] == 0.5);

    assert(pixels[399] == 0.0);
}

fn void test_zero_underflow_group_promotes_without_zero_activation_search() @test {
    material::TextureDesc desc = material::texture_2d_desc(2, 1, RGBA32_FLOAT);
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;
    float[8] pixels;
    TextureCoverageState state = solve_stored_groups(
        desc: desc,
        stored: ((char*)&pixels)[:pixels.len * float::size],
        base_passing: 1,
        base_total: 2,
    );

    assert(state.plateau && state.zero_critical && state.global_count == 0 && state.expected == 1);
    assert(state.global_scale == 1.0 && state.scale == 1.0 && state.promote_count == 1);

    uint first_hash = filtering_oracle_hash(
        face: 0,
        mip: 1,
        x: 0,
        y: 0,
    );
    uint second_hash = filtering_oracle_hash(
        face: 0,
        mip: 1,
        x: 1,
        y: 0,
    );
    uint promoted = first_hash <= second_hash ? 0 : 1;

    assert(pixels[promoted * 4 + 3] == 0.5 && pixels[(1 - promoted) * 4 + 3] == 0.0);
}

fn void test_exact_tolerance_boundary_preserves_global_bytes_then_neighbor_engages() @test {
    PixelFormat[3] formats = { RGBA8_UNORM, RGBA16_FLOAT, RGBA32_FLOAT };

    foreach (format : formats) {
        material::TextureDesc desc = material::texture_2d_desc(100, 1, format);
        desc.coverage = CoveragePolicy.THRESHOLD;
        desc.alpha_threshold = 0.5;
        char[1600] storage;
        char[] pixels = storage[:100 * material::texture_block_bytes(format)];
        uint code = asset::encode_texture_alpha(format, 0.5);

        for (usz texel = 0; texel < 51; texel++) {
            asset::write_texture_alpha_code(
                format: format,
                pixels: pixels,
                texel: texel,
                code: code,
            );
        }

        char[1600] original = storage;
        TextureCoverageState equality = solve_stored_groups(
            desc: desc,
            stored: pixels,
            base_passing: 49,
            base_total: 100,
        );

        assert(!equality.plateau && equality.global_count == 51 && equality.scale == 1.0);
        assert(pixels == original[:pixels.len]);

        TextureCoverageState inside = solve_stored_groups(
            desc: desc,
            stored: pixels,
            base_passing: 50,
            base_total: 100,
        );

        assert(!inside.plateau && inside.global_count == 51 && inside.scale == 1.0);
        assert(pixels == original[:pixels.len]);

        TextureCoverageState outside = solve_stored_groups(
            desc: desc,
            stored: pixels,
            base_passing: 48,
            base_total: 100,
        );

        assert(outside.plateau && outside.expected == 48 && outside.promote_count == 48);
    }
}

fn void test_missing_base_faults_before_remaining_filter_row_without_advancing_state() @test {
    material::TextureDesc desc = material::texture_2d_desc(8, 8, RGBA8_UNORM);
    desc.semantic = TextureSemantic.NORMAL_RG;
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;
    char[256] pixels;

    for (usz texel = 0; texel < 64; texel++) {
        pixels[texel * 4] = 128;
        pixels[texel * 4 + 1] = 128;
        pixels[texel * 4 + 3] = (texel & 1) ? 255 : 0;
    }

    CoverageStatistics statistics = asset::create_coverage_statistics(desc, pixels[..], 1)!!;
    TextureMipChain chain = create_generated_texture_mips(mem, desc)!!;
    defer destroy_texture_mips(&chain);

    TextureCoverageState state = begin_texture_coverage(
        desc: desc,
        mip: 1,
        face: 0,
        statistics: &statistics,
    );
    write_texture_filter_band(
        desc: desc,
        mip: 1,
        layer: 0,
        first_row: 0,
        row_count: 1,
        mip_zero: pixels[..],
        chain: &chain,
        coverage: &state,
    )!!;
    TextureCoverageState saved = state;

    if (catch excuse = write_texture_filter_band(
        desc: desc,
        mip: 1,
        layer: 0,
        first_row: 1,
        row_count: 1,
        mip_zero: {},
        chain: &chain,
        coverage: &state,
    )) {
        assert(excuse == c3d::ASSET_DATA_UNAVAILABLE);
    } else {
        assert(false, "Missing base row accepted");
    }

    assert(state.histogram[..] == saved.histogram[..]);
    assert(state.identity == saved.identity && state.phase == saved.phase);
}

fn void test_pass_billing_matches_independent_wide_integer_boundary_values() @test {
    assert(texture_scan_charge(
        base_texels: 3074457345618258595,
        position: 3074457345618258590,
        output_total: 3074457345618258591,
        passes: 6,
    ) == 3074457345618258593);
    assert(texture_scan_charge(
        base_texels: 3074457345618258595,
        position: 3074457345618258592,
        output_total: 3074457345618258591,
        passes: 6,
    ) == 3074457345618258596);
    assert(texture_scan_charge(
        base_texels: 3074457345618258595,
        position: 15372286728091292972,
        output_total: 3074457345618258591,
        passes: 6,
    ) == 15372286728091292992);
    assert(texture_scan_charge(
        base_texels: 3074457345618258595,
        position: 18446744073709551539,
        output_total: 3074457345618258591,
        passes: 6,
    ) == 18446744073709551562);
    assert(texture_scan_charge(
        base_texels: 3074457345618258595,
        position: 18446744073709551546,
        output_total: 3074457345618258591,
        passes: 6,
    ) == 18446744073709551570);
    assert(texture_scan_charge(
        base_texels: 2635249153387078795,
        position: 2635249153387078790,
        output_total: 2635249153387078791,
        passes: 7,
    ) == 2635249153387078793);
    assert(texture_scan_charge(
        base_texels: 2635249153387078795,
        position: 2635249153387078792,
        output_total: 2635249153387078791,
        passes: 7,
    ) == 2635249153387078796);
    assert(texture_scan_charge(
        base_texels: 2635249153387078795,
        position: 15811494920322472763,
        output_total: 2635249153387078791,
        passes: 7,
    ) == 15811494920322472787);
    assert(texture_scan_charge(
        base_texels: 2635249153387078795,
        position: 18446744073709551530,
        output_total: 2635249153387078791,
        passes: 7,
    ) == 18446744073709551557);
    assert(texture_scan_charge(
        base_texels: 2635249153387078795,
        position: 18446744073709551537,
        output_total: 2635249153387078791,
        passes: 7,
    ) == 18446744073709551565);
    assert(texture_scan_charge(
        base_texels: 2049638230412172394,
        position: 2049638230412172389,
        output_total: 2049638230412172390,
        passes: 9,
    ) == 2049638230412172392);
    assert(texture_scan_charge(
        base_texels: 2049638230412172394,
        position: 2049638230412172391,
        output_total: 2049638230412172390,
        passes: 9,
    ) == 2049638230412172395);
    assert(texture_scan_charge(
        base_texels: 2049638230412172394,
        position: 16397105843297379137,
        output_total: 2049638230412172390,
        passes: 9,
    ) == 16397105843297379169);
    assert(texture_scan_charge(
        base_texels: 2049638230412172394,
        position: 18446744073709551503,
        output_total: 2049638230412172390,
        passes: 9,
    ) == 18446744073709551538);
    assert(texture_scan_charge(
        base_texels: 2049638230412172394,
        position: 18446744073709551510,
        output_total: 2049638230412172390,
        passes: 9,
    ) == 18446744073709551546);
}

fn void test_threshold_restore_verifies_counts_once_and_retains_or_advances_revision() @test {
    AssetStore assets = filtering_store(mem);
    defer asset::destroy_asset_store(&assets);

    material::TextureDesc desc = material::texture_2d_desc(2, 1, RGBA32_FLOAT);
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;
    float[8] original = { 0.2, 0.3, 0.4, 0.0, 0.4, 0.5, 0.6, 1.0 };
    char[] bytes = ((char*)&original)[:original.len * float::size];

    TextureId texture = assets.add_texture(desc, bytes)!!;

    TextureAsset* source = assets.texture(texture);

    assets.release_texture_cpu(texture);
    char[] restored = alloc::new_array(mem, char, (sz)bytes.len);
    restored[..] = bytes[..];
    assets.restore_texture_cpu(texture, restored);

    assert(source.header.revision == 1 && source.coverage_statistics.revision == 1);
    assert(source.coverage_statistics.valid && source.coverage_statistics.passing[0] == 1);

    assets.release_texture_cpu(texture);
    restored = alloc::new_array(mem, char, (sz)bytes.len);
    restored[..] = bytes[..];
    ((float*)restored.ptr)[3] = 0.75;
    assets.restore_texture_cpu(texture, restored);

    assert(source.header.revision == 2 && source.coverage_statistics.revision == 2);
    assert(source.coverage_statistics.valid && source.coverage_statistics.passing[0] == 2);

    assets.release_texture_cpu(texture);
    restored = alloc::new_array(mem, char, (sz)bytes.len);
    restored[..] = bytes[..];
    ((float*)restored.ptr)[3] = bitcast(0x7fc00000u, float);
    assets.restore_texture_cpu(texture, restored);

    assert(source.header.revision == 3 && source.coverage_statistics.revision == 3);
    assert(!source.coverage_statistics.valid && source.coverage_statistics.failure == c3d::INVALID_ARGUMENT);

    if (catch excuse = check_prepare_texture_source(source)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Invalid restored alpha prepared");
    }
}

fn void test_coverage_result_owner_uses_one_allocation_and_exact_scalar_error() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    material::TextureDesc desc = material::texture_2d_desc(32, 32, RGBA8_UNORM);
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;

    CoverageStatistics statistics = asset::create_coverage_statistics(desc, LEAF_RGBA8, 7)!!;
    TextureCoverageResource* resource = create_texture_coverage_resource(
        allocator: &tracker,
        desc: desc,
        statistics: &statistics,
        revision: 7,
    );

    assert(tracker.allocs_total == 1 && resource.counts.len == 6);

    TextureMipChain chain = create_resource_texture_mips(
        allocator: mem,
        desc: desc,
        pixels: LEAF_RGBA8,
        statistics: &statistics,
        coverage_resource: resource,
    )!!;
    defer destroy_texture_mips(&chain);

    TextureCoverageResult leaf = texture_coverage_result(resource, 2, 0);

    assert(leaf.revision == 7 && leaf.original_passing == 484 && leaf.original_total == 1024);
    assert(leaf.passing == 30 && leaf.total == 64 && leaf.absolute_error == 0.00390625);
    assert(leaf.error_numerator == 256 && leaf.error_denominator == 65536 && leaf.plateau && !leaf.small_level);

    TextureCoverageResult terminal = texture_coverage_result(resource, 5, 0);

    assert(terminal.total == 1 && terminal.small_level);

    RetireList retired;
    retired.init(mem, 1);
    defer retired.free();

    retired.push({ .kind = RetiredKind.TEXTURE_COVERAGE, .coverage_resource = resource });
    drain_retired(null, &retired);

    assert(retired.len() == 0 && tracker.allocated() == 0);
}

fn void test_small_alpha_multisets_choose_exact_global_or_nearest_plateau_count() @test {
    PixelFormat[3] formats = { RGBA8_UNORM, RGBA16_FLOAT, RGBA32_FLOAT };
    double[4] values = { 0.0, 0.25, 0.5, 1.0 };

    foreach (format : formats) {
        for (uint texels = 1; texels <= 4; texels++) {
            uint combinations = 1u << (2 * texels);

            for (uint combination = 0; combination < combinations; combination++) {
                uint[4] codes;
                uint selection = combination;

                for (uint texel = 0; texel < texels; texel++) {
                    codes[texel] = asset::encode_texture_alpha(format, values[selection & 3]);
                    selection >>= 2;
                }

                for (ulong passing = 0; passing <= 8; passing++) {
                    ulong target = passing * texels;
                    ulong best_count;
                    ulong best_error = target;

                    for (uint candidate = 0; candidate < texels; candidate++) {
                        if (!codes[candidate]) continue;

                        ulong count;

                        for (uint texel = 0; texel < texels; texel++) count += codes[texel] >= codes[candidate] ? 1 : 0;

                        ulong actual = count * 8;
                        ulong error = actual >= target ? actual - target : target - actual;

                        if (error < best_error || (error == best_error && count < best_count)) {
                            best_error = error;
                            best_count = count;
                        }
                    }

                    char[64] storage;
                    char[] pixels = storage[:texels * material::texture_block_bytes(format)];

                    for (uint texel = 0; texel < texels; texel++) asset::write_texture_alpha_code(
                        format: format,
                        pixels: pixels,
                        texel: texel,
                        code: codes[texel],
                    );

                    material::TextureDesc desc = material::texture_2d_desc(texels, 1, format);
                    desc.coverage = CoveragePolicy.THRESHOLD;
                    desc.alpha_threshold = 0.5;
                    TextureCoverageState state = solve_stored_groups(
                        desc: desc,
                        stored: pixels,
                        base_passing: passing,
                        base_total: 8,
                    );

                    assert(state.global_count == best_count);

                    if (best_error * 50 <= (ulong)8 * texels) {
                        assert(!state.plateau && state.expected == best_count);
                    } else {
                        ulong nearest = target / 8;

                        if (target % 8 > 4) nearest++;

                        assert(state.plateau && state.expected == nearest);

                        ulong actual = nearest * 8;
                        ulong error = actual >= target ? actual - target : target - actual;

                        assert(error <= 4);
                    }
                }
            }
        }
    }
}

fn void test_targeted_alpha_groups_through_twenty_five_texels_match_nearest_counts() @test {
    PixelFormat[3] formats = { RGBA8_UNORM, RGBA16_FLOAT, RGBA32_FLOAT };
    double[5] values = { 0.0, 0.125, 0.25, 0.5, 1.0 };

    foreach (format : formats) {
        foreach (texels : (uint[4]){ 5, 9, 17, 25 }) {
            uint[25] storage_codes;
            uint[] codes = storage_codes[:texels];

            foreach (index, &code : codes) {
                *code = filtering_oracle_encode(format, values[(index * 3 + index / 5) % values.len]);
            }

            ulong base_total = 2 * (ulong)texels;

            for (ulong base_passing = 0; base_passing <= base_total; base_passing++) {
                ulong target = base_passing * texels;
                ulong best_count = filtering_oracle_group_count(codes, base_passing, base_total);
                ulong global = best_count * base_total;
                ulong global_error = global >= target ? global - target : target - global;
                bool plateau = global_error * 50 > base_total * texels;
                ulong expected = best_count;

                if (plateau) {
                    expected = target / base_total;
                    if ((target % base_total) * 2 > base_total) expected++;
                }

                char[400] storage;
                char[] pixels = storage[:texels * material::texture_block_bytes(format)];

                foreach (index, code : codes) filtering_oracle_write_alpha(
                    format: format,
                    pixels: pixels,
                    texel: (usz)index,
                    code: code,
                );

                material::TextureDesc desc = material::texture_2d_desc(texels, 1, format);
                desc.coverage = CoveragePolicy.THRESHOLD;
                desc.alpha_threshold = 0.5;
                TextureCoverageState state = solve_stored_groups(
                    desc: desc,
                    stored: pixels,
                    base_passing: base_passing,
                    base_total: base_total,
                );

                assert(state.global_count == best_count && state.plateau == plateau && state.expected == expected);

                ulong actual = state.expected * base_total;
                ulong error = actual >= target ? actual - target : target - actual;

                assert(error * 2 <= base_total);
                if (plateau && (target % base_total) * 2 == base_total) assert(expected == target / base_total);
            }
        }
    }
}

fn void test_adjacent_half_and_float_alpha_codes_keep_exact_identity_and_threshold_boundary() @test {
    uint[2][5] half_pairs = {
        { 0x0001, 0x0002 },
        { 0x03ff, 0x0400 },
        { 0x37ff, 0x3800 },
        { 0x3800, 0x3801 },
        { 0x3bff, 0x3c00 },
    };
    uint[2][5] float_pairs = {
        { 0x00000001, 0x00000002 },
        { 0x007fffff, 0x00800000 },
        { 0x3effffff, 0x3f000000 },
        { 0x3f000000, 0x3f000001 },
        { 0x3f7fffff, 0x3f800000 },
    };

    foreach (format : (PixelFormat[2]){ RGBA16_FLOAT, RGBA32_FLOAT }) {
        for (usz index = 0; index < half_pairs.len; index++) {
            uint lower = format == RGBA16_FLOAT ? half_pairs[index][0] : float_pairs[index][0];
            uint upper = format == RGBA16_FLOAT ? half_pairs[index][1] : float_pairs[index][1];
            double lower_value = filtering_oracle_decode(format, lower);
            double upper_value = filtering_oracle_decode(format, upper);

            assert(upper == lower + 1 && lower_value < upper_value);
            assert(asset::decode_texture_alpha(format, lower) == lower_value);
            assert(asset::decode_texture_alpha(format, upper) == upper_value);
            assert(asset::encode_texture_alpha(format, lower_value) == lower);
            assert(asset::encode_texture_alpha(format, upper_value) == upper);

            char[32] storage;
            char[] pixels = storage[:2 * material::texture_block_bytes(format)];

            filtering_oracle_write_alpha(
                format: format,
                pixels: pixels,
                texel: 0,
                code: lower,
            );
            filtering_oracle_write_alpha(
                format: format,
                pixels: pixels,
                texel: 1,
                code: upper,
            );

            char[32] original = storage;
            material::TextureDesc desc = material::texture_2d_desc(2, 1, format);
            desc.coverage = CoveragePolicy.THRESHOLD;
            desc.alpha_threshold = (float)upper_value;
            TextureCoverageState state = solve_stored_groups(
                desc: desc,
                stored: pixels,
                base_passing: 1,
                base_total: 2,
            );

            assert(!state.plateau && state.global_count == 1 && state.expected == 1 && state.scale == 1.0);
            assert(pixels == original[:pixels.len]);
        }
    }
}

fn void test_scalar_coverage_query_keeps_committed_revision_release_and_typed_faults() @test {
    AssetStore assets = filtering_store(mem);
    defer asset::destroy_asset_store(&assets);

    material::TextureDesc desc = material::texture_2d_desc(32, 32, RGBA8_UNORM);
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;

    TextureId texture = assets.add_texture(desc, LEAF_RGBA8)!!;

    TextureAsset* source = assets.texture(texture);

    Renderer renderer = { .assets = &assets,
        .textures = alloc::new_array(mem, TextureRes, (sz)assets.textures.items.len) };
    defer alloc::free(mem, renderer.textures.ptr);
    renderer.pending_texture_uploads.init(mem);
    defer renderer.pending_texture_uploads.free();
    renderer.pending_prepare_installs.init(mem);
    defer renderer.pending_prepare_installs.free();

    if (catch excuse = renderer.texture_coverage(texture, 2)) {
        assert(excuse == c3d::ASSET_DATA_UNAVAILABLE);
    } else {
        assert(false, "Uncommitted result exposed");
    }

    TextureCoverageResource* resource = create_texture_coverage_resource(
        allocator: mem,
        desc: desc,
        statistics: &source.coverage_statistics,
        revision: 1,
    );
    defer destroy_texture_coverage_resource(resource);

    TextureMipChain chain = create_resource_texture_mips(
        allocator: mem,
        desc: desc,
        pixels: LEAF_RGBA8,
        statistics: &source.coverage_statistics,
        coverage_resource: resource,
    )!!;
    defer destroy_texture_mips(&chain);

    resource.committed = true;
    renderer.textures[texture.index] = { .asset = texture, .revision = 1, .coverage_resource = resource };

    TextureCoverageResult leaf = renderer.texture_coverage(texture, 2)!!;

    assert(leaf.revision == 1 && leaf.passing == 30 && leaf.total == 64 && leaf.plateau);

    assets.release_texture_cpu(texture);

    assert(renderer.texture_coverage(texture, 2)!!.absolute_error == 0.00390625);

    if (catch excuse = renderer.texture_coverage(texture, 6)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Out-of-range mip accepted");
    }

    if (catch excuse = renderer.texture_coverage(texture: texture, mip: 2, face: 1)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Out-of-range face accepted");
    }

    TextureCoverageResource* candidate = create_texture_coverage_resource(
        allocator: mem,
        desc: desc,
        statistics: &source.coverage_statistics,
        revision: 2,
    );
    defer destroy_texture_coverage_resource(candidate);
    renderer.pending_prepare_installs.push({ .kind = PrepareUnitKind.TEXTURE,
        .old_texture = renderer.textures[texture.index] });

    renderer.textures[texture.index].coverage_resource = candidate;

    assert(renderer.texture_coverage(texture, 2)!!.revision == 1);

    assets.remove_texture(texture);

    if (catch excuse = renderer.texture_coverage(texture, 2)) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false, "Stale texture id accepted");
    }
}
