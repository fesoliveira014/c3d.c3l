module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import std::math;

const char[] LEAF_RGBA8 @local = $embed("../fixtures/texture_fidelity/leaf_rgba8.bin");

struct FilteringExecution @local {
    TextureMipChain chain;
    ulong work;
    ulong progress;
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

fn void test_invalid_threshold_alpha_add_and_owned_publication_preserve_store_and_caller_ownership() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = filtering_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        material::TextureDesc desc = material::texture_2d_desc(2, 1, RGBA32_FLOAT);
        desc.coverage = CoveragePolicy.THRESHOLD;
        desc.alpha_threshold = 0.5;
        float[8] valid_pixels = { 0, 0, 0, 0, 0, 0, 0, 1 };
        char[] valid = ((char*)&valid_pixels)[:valid_pixels.len * float::size];

        TextureId texture = assets.add_texture(desc, valid)!!;
        usz count = assets.textures.items.len - assets.textures.free_count;
        TextureAsset* source = assets.texture(texture);
        char* original_pointer = source.pixels.ptr;
        float[8] invalid_pixels = valid_pixels;
        invalid_pixels[7] = bitcast(0x7fc00000u, float);
        char[] invalid = ((char*)&invalid_pixels)[:invalid_pixels.len * float::size];
        sz before = tracker.allocated();

        assert(@catch(assets.add_texture(desc, invalid)) == c3d::INVALID_ARGUMENT);
        assert(assets.textures.items.len - assets.textures.free_count == count);
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

            assert(tracker.allocated() == with_owned && owned == invalid);
            assert(assets.textures.items.len - assets.textures.free_count == count);
            assert(source.header.revision == 1 && source.coverage_statistics.revision == 1);
            assert(source.coverage_statistics.valid && source.coverage_statistics.passing[0] == 1);
            assert(source.pixels.ptr == original_pointer && source.pixels == valid);
        }
    }

    assert(!tracker.has_leaks());
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

fn FilteringExecution run_filtered_rows(
    material::TextureDesc desc,
    char[] pixels,
    uint maximum_rows,
    bool release_after_filter = false,
) @local {
    AssetStore assets = filtering_store(mem);
    defer asset::destroy_asset_store(&assets);

    TextureId texture = assets.add_texture(desc, pixels)!!;
    GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!!;
    PrepareUnit unit = { .kind = PrepareUnitKind.TEXTURE, .texture = texture, .revision = 1 };
    PrepareRecord record;
    Renderer renderer = { .assets = &assets, .allocator = mem };
    PrepareReport report;
    FilteringExecution execution;
    bool released;
    PrepareStepPlan storage = { .kind = PrepareResourceStep.GENERATION_STORAGE };

    run_prepare_step(
        renderer: &renderer,
        record: &record,
        unit: &unit,
        plan: &storage,
        report: &report,
    )!!;

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
        PrepareStepPlan plan = { .kind = PrepareResourceStep.GENERATE, .band = band,
            .cost = { .generated_texels = (ulong)band.width * rows } };

        run_prepare_step(
            renderer: &renderer,
            record: &record,
            unit: &unit,
            plan: &plan,
            report: &report,
        )!!;

        if (release_after_filter && !released && (record.generation_mip > 1 || record.correcting_coverage)) {
            assets.release_texture_cpu(texture);

            released = true;
        }
    }

    execution.chain = record.chain;
    execution.work = report.generated_texels;
    execution.progress = record.texels_done;

    assert(unit.generated_done == record.texels_done);
    assert(record.texels_done == layout.output_texels * layout.passes);

    return execution;
}

fn bool meets_base_coverage(
    ulong passing,
    ulong texels,
    ulong base_passing,
    ulong base_texels,
) @local {
    ulong nearest = (2 * base_passing * texels + base_texels) / (2 * base_texels);
    ulong actual = passing * base_texels;
    ulong expected = base_passing * texels;
    ulong error = actual > expected ? actual - expected : expected - actual;

    return passing == nearest || error * 50 <= base_texels * texels;
}

fn void test_plateau_level_promotes_its_target_and_keeps_color() @test {
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
    assert(single.progress == 2 * 85 && single.work < single.progress);
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

fn void test_opaque_threshold_texture_keeps_ordinary_mips() @test {
    material::TextureDesc desc = material::texture_2d_desc(8, 4, RGBA8_SRGB);
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;
    char[128] pixels;

    foreach (index, &value : pixels) *value = index % 4 == 3 ? 255 : (char)(index * 7);

    TextureMipChain masked = create_texture_mips(mem, desc, pixels[..])!!;
    defer destroy_texture_mips(&masked);

    desc.coverage = CoveragePolicy.NONE;

    TextureMipChain color = create_texture_mips(mem, desc, pixels[..])!!;
    defer destroy_texture_mips(&color);

    assert(masked.pixels == color.pixels);
}

fn void test_zero_output_cube_has_zero_work_and_no_generation_allocation() @test {
    material::TextureDesc desc = material::texture_cube_desc(1, RGBA16_FLOAT);
    desc.semantic = TextureSemantic.NORMAL_RG;
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;
    GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!!;

    assert(layout.output_texels == 0 && layout.byte_count == 0 && layout.passes == 2);

    TextureMipChain generated = create_generated_texture_mips(mem, desc)!!;
    defer destroy_texture_mips(&generated);

    assert(!generated.pixels.len && generated.mip_count == 0 && generated.layer_count == 6);
}

fn void test_leaf_levels_keep_mip_zero_coverage_in_every_row_resume() @test {
    material::TextureDesc desc = material::texture_2d_desc(32, 32, RGBA8_UNORM);
    desc.coverage = CoveragePolicy.THRESHOLD;
    desc.alpha_threshold = 0.5;
    ulong base_passing = count_filtered_alpha(desc, LEAF_RGBA8, 0.5);

    FilteringExecution single = run_filtered_rows(desc, LEAF_RGBA8, 1);
    defer destroy_texture_mips(&single.chain);

    FilteringExecution whole = run_filtered_rows(desc, LEAF_RGBA8, 16);
    defer destroy_texture_mips(&whole.chain);

    assert(single.chain.pixels == whole.chain.pixels && single.progress == whole.progress);
    assert(single.progress == 2 * 341 && single.work == whole.work);

    for (uint mip = 1; mip <= single.chain.mip_count; mip++) {
        usz bytes = material::texture_mip_bytes(desc, mip)!!;
        ulong passing = count_filtered_alpha(desc, single.chain.pixels[single.chain.offsets[mip - 1]:bytes], 0.5);
        uint width = material::texture_mip_extent(desc.width, mip);
        ulong texels = (ulong)width * material::texture_mip_extent(desc.height, mip);

        assert(meets_base_coverage(
            passing: passing,
            texels: texels,
            base_passing: base_passing,
            base_texels: 1024,
        ), "mip %d passes %d", mip, passing);
    }

    TextureMipChain synchronous = create_texture_mips(mem, desc, LEAF_RGBA8)!!;
    defer destroy_texture_mips(&synchronous);

    assert(synchronous.pixels[:LEAF_RGBA8.len] == LEAF_RGBA8);
    assert(synchronous.pixels[LEAF_RGBA8.len..] == single.chain.pixels);
}

fn void correct_stored_level(material::TextureDesc desc, char[] level, ulong base_passing) @local {
    TextureCoverageState state = begin_texture_coverage(desc);
    state.base_passing[0] = base_passing;
    usz texels = level.len / material::texture_block_bytes(desc.format);

    for (usz texel = 0; texel < texels; texel++) {
        collect_texture_coverage(&state, asset::texture_alpha_code(desc.format, level, texel));
    }

    TextureMipChain chain = { .first_mip = 1, .mip_count = 1, .layer_count = 1, .pixels = level };

    if (choose_texture_coverage(
        state: &state,
        desc: desc,
        mip: 1,
        layer: 0,
    )) {
        write_texture_coverage_band(
            state: &state,
            desc: desc,
            chain: &chain,
            mip: 1,
            layer: 0,
            first_row: 0,
            row_count: 1,
        );
    }
}

fn void test_levels_within_tolerance_keep_their_bytes_and_others_meet_the_nearest_count() @test {
    foreach (format : (PixelFormat[3]){ RGBA8_UNORM, RGBA16_FLOAT, RGBA32_FLOAT }) {
        material::TextureDesc desc = material::texture_2d_desc(200, 1, format);
        desc.coverage = CoveragePolicy.THRESHOLD;
        desc.alpha_threshold = 0.5;
        char[1600] storage;
        char[] level = storage[:100 * material::texture_block_bytes(format)];
        uint code = asset::encode_texture_alpha(format, 0.5);

        for (usz texel = 0; texel < 51; texel++) {
            asset::write_texture_alpha_code(
                format: format,
                pixels: level,
                texel: texel,
                code: code,
            );
        }

        char[1600] original = storage;

        correct_stored_level(desc, level, 98);

        assert(level == original[:level.len], "format %s at the tolerance changed", format);

        correct_stored_level(desc, level, 96);

        assert(count_filtered_alpha(desc, level, 0.5) == 48, "format %s outside the tolerance", format);

        storage = {};
        correct_stored_level(desc, level, 100);

        assert(count_filtered_alpha(desc, level, 0.5) == 50, "format %s from zero alpha", format);
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

    TextureMipChain chain = create_generated_texture_mips(mem, desc)!!;
    defer destroy_texture_mips(&chain);

    TextureCoverageState state = begin_texture_coverage(desc);
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

    assert(state.level.histogram[..] == saved.level.histogram[..] && state.level.passing == saved.level.passing);
    assert(state.base_passing[..] == saved.base_passing[..]);
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
