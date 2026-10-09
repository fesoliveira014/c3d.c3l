module c3d::render::acceptance;

import c3d;
import c3d::asset @public;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::io;
import std::math;
import std::os::env;
import std::io::file;
import std::core::string;

const char[] FIDELITY_DECODE_SOURCE @private = $embed("texture_fidelity.comp.glsl");
const char[] FIDELITY_SAMPLE_SOURCE @private = $embed("texture_fidelity_sample.comp.glsl");
const char[] FIDELITY_LEAF_BYTE @private = $embed("../../fixtures/texture_fidelity/leaf_rgba8.bin");
const char[] FIDELITY_LEAF_HALF @private = $embed("../../fixtures/texture_fidelity/leaf_rgba16.bin");
const char[] FIDELITY_LEAF_FLOAT @private = $embed("../../fixtures/texture_fidelity/leaf_rgba32.bin");
const char[] FIDELITY_BAKE @private = $embed("texture_fidelity_fixtures/reference_bake.bin");
const char[] FIDELITY_BAKE_RGB @private = $embed("texture_fidelity_fixtures/reference_bake_rgb32f.bin");
const char[] FIDELITY_BAKE_GEOMETRY @private = $embed("texture_fidelity_fixtures/bake_geometry.bin");
const char[] FIDELITY_BAKE_TANGENTS @private = $embed("texture_fidelity_fixtures/bake_tangents.bin");
const char[] FIDELITY_NORMAL_FRAGMENT @private = $embed("texture_fidelity_normal.frag.glsl");
const uint FIDELITY_GROUP_SIZE @private = 64; // One decode workgroup; mirrored in texture_fidelity.comp.glsl.
const uint FIDELITY_SAMPLE_GROUP @private = 8; // One sampling tile; mirrored in texture_fidelity_sample.comp.glsl.
const usz FIDELITY_BUFFER_BYTES @private = 64 << 10; // Holds each fixed corpus in one owned buffer.
const uint FIDELITY_FRAME_LIMIT @private = 8192; // Bounds one-row generation/correction/staging of the fixed leaf.
const double FIDELITY_FLOAT_ANGLE @private = 1e-5; // Float decode parity required before framebuffer quantization.
const double FIDELITY_BYTE_ANGLE @private = 0.02; // Includes eight-bit normal storage quantization.
const uint FIDELITY_BAKE_RECORD_COUNT @private = 60;
const usz FIDELITY_BAKE_RECORD_BYTES @private = 128;
const usz FIDELITY_BAKE_HEADER_BYTES @private = 8;
const uint FIDELITY_BAKE_VALUE_COUNT @private = 15;
const uint FIDELITY_BAKE_TRANSFORM_STEP @private = 15; // Four corpus samples cover the extra transforms.
const double FIDELITY_WORLD_ANGLE @private = 0.02;
const float FIDELITY_IMAGE_TOLERANCE @private = 0.02f;
const float FIDELITY_TRACE_ABSOLUTE_TOLERANCE @private = 0.001f;
const float FIDELITY_VISIBLE_PIXEL_THRESHOLD @private = 0.001f;
const float FIDELITY_BAKE_WEIGHT_MARGIN @private = 0.01f;
const uint FIDELITY_RASTER_EXTENT @private = 64;
const uint FIDELITY_RASTER_CENTER @private = FIDELITY_RASTER_EXTENT / 2;
const uint FIDELITY_RASTER_CENTER_INDEX @private =
  FIDELITY_RASTER_CENTER * FIDELITY_RASTER_EXTENT + FIDELITY_RASTER_CENTER;
const uint FIDELITY_BAKE_MINIMUM_ELIGIBLE @private = 64; // Enough interior pixels to compare the two raster paths.
const PixelFormat[3] FIDELITY_FORMATS @private = { RGBA8_UNORM, RGBA16_FLOAT, RGBA32_FLOAT };

struct FidelityInput @private {
    Vec4 encoded_scale;
    Vec4 normal;
    Vec4 tangent;
    Mat4 model;
}
$assert FidelityInput::size == 112;
$assert $reflect(FidelityInput.normal).offset == 16;
$assert $reflect(FidelityInput.tangent).offset == 32;
$assert $reflect(FidelityInput.model).offset == 48;

struct FidelityRoot @private {
    gpu::GpuAddress inputs;
    gpu::GpuAddress outputs;
    uint count;
    uint mode;
    uint rg;
    uint padding;
}
$assert FidelityRoot::size == 32;

struct FidelitySampleRoot @private {
    gpu::GpuAddress outputs;
    uint mip;
    uint width;
    uint height;
    uint padding;
}
$assert FidelitySampleRoot::size == 24;

struct FidelityHarness @private {
    ComputeShaderId decode;
    ComputeShaderId sample;
    BufferId input;
    BufferId output;
    gpu::MappedGpuSpan readback;
}

struct FidelityDrain @private {
    ulong generated;
    ulong staged;
    ulong credits;
    uint calls;
}

struct FidelityBakeTriangle @private {
    Vec3[3] normals;
    Vec4[3] tangents;
}

struct FidelityRaster @private {
    Scene scene;
    Node* camera;
    Node* mesh;
    RenderTargetId target;
    ViewId view;
}

fn FidelityHarness? create_fidelity_harness(Fixture* fixture) @private {
    Renderer* renderer = &fixture.renderer;

    FidelityHarness harness = {
        .decode = add_compute_shader(fixture, (String)FIDELITY_DECODE_SOURCE)!,
        .sample = add_compute_shader(fixture, (String)FIDELITY_SAMPLE_SOURCE)!,
    };
    harness.input = renderer.create_buffer({
        .size = FIDELITY_BUFFER_BYTES, .usage = BufferUsage.UPLOAD, .debug_name = "fidelity_inputs",
    })!;
    defer catch renderer.destroy_buffer(harness.input)!!;

    harness.output = renderer.create_buffer({ .size = FIDELITY_BUFFER_BYTES, .debug_name = "fidelity_outputs" })!;
    defer catch renderer.destroy_buffer(harness.output)!!;

    gpu::AllocationDesc allocation = {
        .size = FIDELITY_BUFFER_BYTES, .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ, .access = { .graphics }, .debug_name = "fidelity_readback",
    };
    harness.readback = gpu::allocate_mapped_memory(&renderer.device, &allocation)!;

    return harness;
}

fn void destroy_fidelity_harness(Fixture* fixture, FidelityHarness* harness) @private {
    Renderer* renderer = &fixture.renderer;
    render::wait_frames(renderer)!!;

    gpu::GpuAllocation allocation = harness.readback.span.allocation();
    gpu::free_allocation(&renderer.device, &allocation)!!;

    renderer.destroy_buffer(harness.output)!!;
    renderer.destroy_buffer(harness.input)!!;
}

fn void? fidelity_record_readback(Fixture* fixture, FidelityHarness* harness) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::Barrier copied = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &copied)!;

    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(harness.output).allocation)!,
        .dst = harness.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;

    gpu::Barrier host = { .before = { .transfer }, .after = { .host } };
    return gpu::cmd_barrier(&renderer.commands, &host);
}

fn Vec4[]? fidelity_collect(Fixture* fixture, FidelityHarness* harness, usz count) @private {
    render::wait_frames(&fixture.renderer)!;
    gpu::invalidate_mapped_span(&fixture.renderer.device, harness.readback.span)!;

    Vec4[] result = alloc::new_array(tmem, Vec4, (sz)count);
    mem::copy(result.ptr, harness.readback.bytes.ptr, (sz)(count * Vec4::size));

    return result;
}

fn Vec4[]? fidelity_decode(
    Fixture* fixture,
    FidelityHarness* harness,
    FidelityInput[] inputs,
    bool rg,
    bool tangent_frame = false,
) @private {
    Renderer* renderer = &fixture.renderer;

    FidelityRoot root = {
        .inputs = renderer.buffer_address(harness.input), .outputs = renderer.buffer_address(harness.output),
        .count = (uint)inputs.len, .rg = rg ? 1 : 0, .mode = tangent_frame ? 1 : 0,
    };
    BufferId[1] writes = { harness.output };

    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);

    renderer.write_buffer(harness.input, ((char*)inputs.ptr)[:inputs.len * FidelityInput::size])!;

    renderer.dispatch({
        .shader = harness.decode, .root = ((char*)&root)[:FidelityRoot::size],
        .groups = { (root.count + FIDELITY_GROUP_SIZE - 1) / FIDELITY_GROUP_SIZE, 1, 1 },
        .writes = writes[..],
    })!;

    fidelity_record_readback(fixture, harness)!;
    renderer.end_frame()!;

    return fidelity_collect(fixture, harness, inputs.len);
}

fn Vec4[]? fidelity_sample(
    Fixture* fixture,
    FidelityHarness* harness,
    TextureId texture,
    uint mip,
) @private {
    Renderer* renderer = &fixture.renderer;
    material::TextureDesc desc = fixture.assets.texture(texture).desc;
    uint width = material::texture_mip_extent(desc.width, mip);
    uint height = material::texture_mip_extent(desc.height, mip);

    FidelitySampleRoot root = {
        .outputs = renderer.buffer_address(harness.output), .mip = mip, .width = width, .height = height,
    };
    BufferId[1] writes = { harness.output };
    DispatchTexture[1] textures = { render::read_texture(texture, asset::SAMPLER_NEAREST) };

    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);

    renderer.dispatch({
        .shader = harness.sample, .root = ((char*)&root)[:FidelitySampleRoot::size],
        .groups = {
            (width + FIDELITY_SAMPLE_GROUP - 1) / FIDELITY_SAMPLE_GROUP,
            (height + FIDELITY_SAMPLE_GROUP - 1) / FIDELITY_SAMPLE_GROUP, 1,
        },
        .writes = writes[..], .textures = textures[..],
    })!;

    fidelity_record_readback(fixture, harness)!;
    renderer.end_frame()!;

    return fidelity_collect(fixture, harness, (usz)width * height);
}

fn double fidelity_angle(Vec3 actual, Vec3 expected) @private {
    assert(math::is_finite(actual.x) && math::is_finite(actual.y) && math::is_finite(actual.z));

    double[<3>] first = (double[<3>])actual;
    double[<3>] second = (double[<3>])expected;
    first /= first.length();
    second /= second.length();

    return math::atan2(first.cross(second).length(), first.dot(second));
}

fn Vec3 fidelity_reference_decode(Vec4 encoded, bool rg) @private {
    double[<3>] normal = (double[<3>])encoded.xyz * 2 - 1;
    if (rg) {
        normal.z = math::sqrt(math::max(0.0, 1.0 - normal.x * normal.x - normal.y * normal.y));
        if (encoded.w == 0) return { 0, 0, 1 };
    }
    normal.x *= encoded.w;
    normal.y *= encoded.w;
    double largest = math::max(math::max(math::abs(normal.x), math::abs(normal.y)), math::abs(normal.z));
    if (largest == 0) return { 0, 0, 1 };
    normal /= largest;
    return (Vec3)(normal / normal.length());
}

fn void test_fidelity_shared_gpu_normal_decoder_matches_double_reference() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityHarness harness = create_fidelity_harness(&fixture)!!;
    defer destroy_fidelity_harness(&fixture, &harness);

    @pool() {
        Vec4[9] values = {
            { 0.8, 0.5, 0.9, 1 }, { 0.8, 0.5, 0.9, -2 }, { 0.8, 0.5, 0.9, 0 },
            { 1.5, -0.5, 0.5, 1 }, { 1.5, -0.5, 0.5, -1 }, { 0.5, 0.5, 0.5, 1 },
            { float::max, -float::max, 0.5, 1 },
            { 2, -2, 1, float::max },
            { 0.500001, 0.499999, 1, 1e-30 },
        };

        FidelityInput[] inputs = alloc::new_array(tmem, FidelityInput, values.len);

        foreach (index, value : values) inputs[index] = { .encoded_scale = value, .model = matrix::IDENTITY4 };

        for (uint encoding = 0; encoding < 2; encoding++) {
            Vec4[] actual = fidelity_decode(
                fixture: &fixture,
                harness: &harness,
                inputs: inputs,
                rg: encoding != 0,
            )!!;

            foreach (index, pixel : actual) {
                Vec3 expected = fidelity_reference_decode(values[index], encoding != 0);
                assert(fidelity_angle(pixel.xyz, expected) <= FIDELITY_FLOAT_ANGLE,
                    "normal encoding %d sample %d", encoding, index);
            }
        }
    };

    check_validation(&fixture.renderer);
}

fn void test_fidelity_mikk_reference_bake_matches_shared_gpu_consumption() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityHarness harness = create_fidelity_harness(&fixture)!!;
    defer destroy_fidelity_harness(&fixture, &harness);

    @pool() {
        assert(FIDELITY_BAKE.len == FIDELITY_BAKE_RECORD_COUNT * FIDELITY_BAKE_RECORD_BYTES
          && FIDELITY_BAKE_RGB.len == FIDELITY_BAKE_RECORD_COUNT * Vec3::size);

        FidelityInput[] inputs = alloc::new_array(tmem, FidelityInput, FIDELITY_BAKE_RECORD_COUNT);
        Vec3[] targets = alloc::new_array(tmem, Vec3, FIDELITY_BAKE_RECORD_COUNT);

        for (usz index = 0; index < inputs.len; index++) {
            double[FIDELITY_BAKE_VALUE_COUNT] values;
            usz sample_offset = index * FIDELITY_BAKE_RECORD_BYTES;
            uint case_index = fidelity_u32(FIDELITY_BAKE, sample_offset);
            uint face_index = fidelity_u32(FIDELITY_BAKE, sample_offset + uint::size);
            FidelityBakeTriangle triangle = fidelity_bake_triangle(case_index, face_index);
            char* sample_values = FIDELITY_BAKE.ptr + sample_offset + FIDELITY_BAKE_HEADER_BYTES;
            mem::copy(&values, sample_values, double::size * values.len);
            Vec3 encoded;
            mem::copy(&encoded, FIDELITY_BAKE_RGB.ptr + index * 3 * float::size, 3 * float::size);
            targets[index] = { (float)values[3], (float)values[4], (float)values[5] };
            inputs[index] = {
                .encoded_scale = { encoded.x, encoded.y, encoded.z, 1 },
                .normal = { (float)values[12], (float)values[13], (float)values[14], 0 },
                .tangent = { (float)values[9], (float)values[10], (float)values[11],
                  triangle.tangents[0].w },
                .model = matrix::IDENTITY4,
            };
        }

        Vec4[] actual = fidelity_decode(
            fixture: &fixture,
            harness: &harness,
            inputs: inputs,
            rg: false,
            tangent_frame: true,
        )!!;

        double maximum;
        uint failures;

        foreach (index, pixel : actual) {
            double angle = fidelity_angle(pixel.xyz, targets[index]);
            maximum = math::max(maximum, angle);
            failures += angle > FIDELITY_WORLD_ANGLE ? 1 : 0;
        }

        io::printfn("mikk shared GPU bake: samples=%d maximum_rad=%.9f above_0_02=%d", actual.len, maximum, failures);
        assert(!failures, "Shared GPU consumption differs from the pinned inverse bake");
    };

    check_validation(&fixture.renderer);
}

fn char[] fidelity_leaf(PixelFormat format) @private {
    switch (format) {
        case RGBA8_UNORM: return FIDELITY_LEAF_BYTE;
        case RGBA16_FLOAT: return FIDELITY_LEAF_HALF;
        case RGBA32_FLOAT: return FIDELITY_LEAF_FLOAT;
        default: unreachable();
    }
}

fn PrepareId? fidelity_texture_job(Fixture* fixture, TextureId texture) @private {
    Renderer* renderer = &fixture.renderer;
    PrepareId id = preparation_texture_only(fixture, texture)!;
    PrepareRecord* record = renderer.prepares.get(id);
    GeneratedTextureLayout layout = render::generated_texture_mip_layout(fixture.assets.texture(texture).desc)!;
    record.units[0].texels = layout.output_texels ? layout.base_texels * layout.passes : 0;
    record.texels_total = record.units[0].texels;
    return id;
}

fn FidelityDrain fidelity_drain(
    Fixture* fixture,
    PrepareId id,
    usz staged_bytes,
    ulong generated_texels,
) @private {
    Renderer* renderer = &fixture.renderer;
    FidelityDrain result;
    PrepareProgress previous = renderer.prepare_progress(id);
    ulong initially_done = previous.texels_done;
    PrepareLimits limits = { .staged_bytes = staged_bytes, .generated_texels = generated_texels, .pipelines = 1 };

    while (previous.state != PrepareState.READY && result.calls < FIDELITY_FRAME_LIMIT) {
        renderer.begin_frame()!!;

        PrepareReport report = renderer.advance_prepares_within(limits)!!;

        if (limits.staged_bytes) assert(report.staged_bytes <= limits.staged_bytes);
        if (limits.generated_texels) assert(report.generated_texels <= limits.generated_texels);

        if (limits.staged_bytes) limits.staged_bytes = math::max(limits.staged_bytes, report.required.staged_bytes);
        if (limits.generated_texels) {
            limits.generated_texels = math::max(limits.generated_texels, report.required.generated_texels);
        }

        result.staged += report.staged_bytes;
        result.generated += report.generated_texels;
        renderer.end_frame()!!;

        PrepareProgress next = renderer.prepare_progress(id);
        assert(next.state != PrepareState.FAILED, "preparation failed: %s", next.failure);
        assert(next.texels_done >= previous.texels_done);

        ulong delta = next.texels_done - previous.texels_done;

        assert(delta >= report.generated_texels);

        result.credits += delta - report.generated_texels;
        previous = next;
        result.calls++;
    }

    assert(previous.state == PrepareState.READY);
    assert(previous.texels_done == previous.texels_total);
    assert(result.generated + result.credits == previous.texels_total - initially_done);

    return result;
}

fn void test_fidelity_leaf_gpu_counts_reports_and_one_row_progress_match_all_formats() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityHarness harness = create_fidelity_harness(&fixture)!!;
    defer destroy_fidelity_harness(&fixture, &harness);

    foreach (format : FIDELITY_FORMATS) {
        @pool() {
            material::TextureDesc desc = material::texture_2d_desc(32, 32, format);

            desc.coverage = CoveragePolicy.THRESHOLD;
            desc.alpha_threshold = 0.5;

            TextureId texture = fixture.assets.add_texture(desc, fidelity_leaf(format))!!;

            if (catch excuse = fixture.renderer.texture_coverage(texture, 2)) {
                assert(excuse == c3d::ASSET_DATA_UNAVAILABLE);
            } else {
                assert(false);
            }

            PrepareId id = fidelity_texture_job(&fixture, texture)!!;
            fixture.renderer.begin_frame()!!;

            PrepareReport blocked = fixture.renderer.advance_prepares_within({ .generated_texels = 1 })!!;

            assert(blocked.reason == PrepareStopReason.GENERATED_TEXELS);
            assert(blocked.generated_texels == 0 && blocked.required.generated_texels > 1);
            fixture.renderer.end_frame()!!;

            ulong generated_before = fixture.renderer.prepare_counters.generated_texels;

            FidelityDrain drain = fidelity_drain(
                fixture: &fixture,
                id: id,
                staged_bytes: 32 * material::texture_block_bytes(format),
                generated_texels: blocked.required.generated_texels,
            );

            assert(drain.credits > 0 && drain.calls > 1);
            assert(fixture.renderer.prepare_counters.generated_texels - generated_before == drain.generated);

            fixture.renderer.end_prepare(id)!!;

            TextureCoverageResource* resource = fixture.renderer.textures[texture.index].coverage_resource;

            assert(resource && resource.counts.len == 6 && resource.face_count == 1 && resource.mip_count == 6);

            for (uint mip = 0; mip < 6; mip++) {
                Vec4[] pixels = fidelity_sample(
                    fixture: &fixture,
                    harness: &harness,
                    texture: texture,
                    mip: mip,
                )!!;
                ulong passing;

                foreach (pixel : pixels) passing += pixel.w >= 0.5 ? 1 : 0;

                TextureCoverageResult report = fixture.renderer.texture_coverage(texture, mip)!!;

                assert(report.revision == fixture.assets.texture(texture).header.revision);
                assert(report.original_passing == 484 && report.original_total == 1024);
                assert(report.passing == passing && report.total == pixels.len);
                assert(report.small_level == (mip > 2));

                if (mip == 2) {
                    assert(passing == 30 && report.total == 64 && report.plateau);
                    assert(report.absolute_error == 0.00390625);
                    assert(report.error_numerator == 256 && report.error_denominator == 65536);
                }

                if (mip == 1) assert(!report.plateau);
            }

            TextureCoverageResult committed = fixture.renderer.texture_coverage(texture, 2)!!;

            fixture.assets.release_texture_cpu(texture);
            TextureCoverageResult released = fixture.renderer.texture_coverage(texture, 2)!!;
            assert(released.revision == committed.revision && released.passing == committed.passing);

            if (catch excuse = fixture.renderer.texture_coverage(texture, 6)) {
                assert(excuse == c3d::INVALID_ARGUMENT);
            } else {
                assert(false);
            }

            if (catch excuse = fixture.renderer.texture_coverage(texture, 2, 1)) {
                assert(excuse == c3d::INVALID_ARGUMENT);
            } else {
                assert(false);
            }

            fixture.assets.remove_texture(texture);

            if (catch excuse = fixture.renderer.texture_coverage(texture, 2)) {
                assert(excuse == c3d::INVALID_ID);
            } else {
                assert(false);
            }
        };
    }

    check_validation(&fixture.renderer);
}

fn Vec4 fidelity_cpu_pixel(PixelFormat format, char[] pixels, usz index) @private {
    Vec4 result;
    switch (format) {
        case RGBA8_UNORM:
        case RGBA8_SRGB:
            for (uint channel = 0; channel < 4; channel++) result[channel] = (float)pixels[index * 4 + channel] / 255;
        case RGBA16_FLOAT:
            for (uint channel = 0; channel < 4; channel++) {
                ushort value;
                mem::copy(&value, pixels.ptr + (index * 4 + channel) * ushort::size, ushort::size);
                result[channel] = asset::decode_texture_half(value);
            }

        case RGBA32_FLOAT:
            mem::copy(&result, pixels.ptr + index * Vec4::size, Vec4::size);
        default: unreachable();
    }

    return result;
}

fn char[] fidelity_encode_pixels(Allocator allocator, PixelFormat format, Vec4[] values) @private {
    char[] result = alloc::new_array(allocator, char, (sz)(values.len * material::texture_block_bytes(format)));

    foreach (index, value : values) {
        switch (format) {
            case RGBA8_UNORM:
                for (uint channel = 0; channel < 4; channel++) {
                    result[index * 4 + channel] = (char)math::round(value[channel] * 255);
                }
            case RGBA16_FLOAT:
                for (uint channel = 0; channel < 4; channel++) {
                    ushort encoded = asset::encode_texture_half(value[channel]);
                    mem::copy(result.ptr + (index * 4 + channel) * ushort::size, &encoded, ushort::size);
                }

            case RGBA32_FLOAT:
                mem::copy(result.ptr + index * Vec4::size, &value, Vec4::size);
            default: unreachable();
        }
    }

    return result;
}

fn void test_fidelity_generated_normal_mips_match_cpu_in_all_three_storage_formats() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityHarness harness = create_fidelity_harness(&fixture)!!;
    defer destroy_fidelity_harness(&fixture, &harness);

    foreach (format : FIDELITY_FORMATS) {
        for (uint encoding = 0; encoding < 2; encoding++) {
            @pool() {
                Vec4[16] values;

                foreach (index, &value : values) {
                    Vec3 direction = ((Vec3){ (float)(index % 4) * 0.3f - 0.45f,
                        (float)(index / 4) * 0.3f - 0.45f, 1 }).normalize();
                    *value = { 0.5f + 0.5f * direction.x, 0.5f + 0.5f * direction.y,
                        0.5f + 0.5f * direction.z, (float)index / 15 };
                }

                char[] source = fidelity_encode_pixels(tmem, format, values[..]);
                material::TextureDesc desc = material::texture_2d_desc(4, 4, format);
                desc.semantic = encoding == 0 ? TextureSemantic.NORMAL_RGB : TextureSemantic.NORMAL_RG;

                TextureId texture = fixture.assets.add_texture(desc, source)!!;

                fixture.renderer.upload_texture(texture)!!;

                TextureMipChain reference = render::create_texture_mips(tmem, desc, source)!!;
                defer render::destroy_texture_mips(&reference);

                for (uint mip = 0; mip < 3; mip++) {
                    Vec4[] actual = fidelity_sample(
                        fixture: &fixture,
                        harness: &harness,
                        texture: texture,
                        mip: mip,
                    )!!;

                    char[] bytes = reference.pixels[reference.offsets[mip]:material::texture_mip_bytes(desc, mip)!!];

                    foreach (index, pixel : actual) {
                        Vec4 expected = fidelity_cpu_pixel(format, bytes, (usz)index);
                        assert(math::abs(pixel - expected).max() < 1e-6f);
                    }

                    FidelityInput[] inputs = alloc::new_array(tmem, FidelityInput, actual.len);

                    foreach (index, pixel : actual) inputs[index] = {
                        .encoded_scale = { pixel.x, pixel.y, pixel.z, -1.5f }, .model = matrix::IDENTITY4,
                    };

                    Vec4[] decoded = fidelity_decode(
                        fixture: &fixture,
                        harness: &harness,
                        inputs: inputs,
                        rg: encoding != 0,
                    )!!;

                    foreach (index, normal : decoded) {
                        Vec3 expected = fidelity_reference_decode(inputs[index].encoded_scale, encoding != 0);
                        assert(fidelity_angle(normal.xyz, expected)
                          <= (format == RGBA8_UNORM ? FIDELITY_BYTE_ANGLE : FIDELITY_FLOAT_ANGLE));
                    }
                }

                assert(!fixture.renderer.textures[texture.index].coverage_resource);

                if (catch excuse = fixture.renderer.texture_coverage(texture, 0)) {
                    assert(excuse == c3d::ASSET_DATA_UNAVAILABLE);
                } else {
                    assert(false);
                }
            };
        }
    }

    check_validation(&fixture.renderer);
}

fn void test_fidelity_supplied_bc5_keeps_bytes_and_explicit_rg_semantics() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityHarness harness = create_fidelity_harness(&fixture)!!;
    defer destroy_fidelity_harness(&fixture, &harness);

    @pool() {
        char[16] block = { 191, 191, 0, 0, 0, 0, 0, 0, 64, 64, 0, 0, 0, 0, 0, 0 };
        TextureMipData[1] levels = { { .mip = 0, .bytes = block[..] } };
        material::TextureDesc desc = material::texture_2d_desc(4, 4, BC5_UNORM);
        desc.generate_mips = false;
        desc.mip_levels = 1;

        desc.semantic = TextureSemantic.NORMAL_RG;
        TextureId texture = fixture.assets.add_texture_mips(desc, levels[..])!!;

        fixture.renderer.upload_texture(texture)!!;
        assert(fixture.assets.texture(texture).supplied_mips[0].bytes == block[..]);
        assert(fixture.renderer.textures[texture.index].semantic == TextureSemantic.NORMAL_RG);

        Vec4[] samples = fidelity_sample(
            fixture: &fixture,
            harness: &harness,
            texture: texture,
            mip: 0,
        )!!;

        foreach (pixel : samples) {
            assert(math::abs(pixel.x - 191.0f / 255) < 1e-6f
              && math::abs(pixel.y - 64.0f / 255) < 1e-6f);
        }

        desc.coverage = CoveragePolicy.THRESHOLD;
        desc.alpha_threshold = 0.5;
        if (catch excuse = fixture.assets.add_texture_mips(desc, levels[..])) {
            assert(excuse == c3d::UNSUPPORTED);
        } else {
            assert(false);
        }
    };

    check_validation(&fixture.renderer);
}

fn PhysicalMaterialGpu fidelity_read_physical(Fixture* fixture, MaterialId material_id) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::GpuSpan source = renderer.material_heap_span.checked_subspan(
        (usz)material_id.index * render::MATERIAL_STRIDE, PhysicalMaterialGpu::size)!!;
    char[] bytes = preparation_asset_readback(fixture, source, PhysicalMaterialGpu::size)!!;
    defer alloc::free(mem, bytes.ptr);

    PhysicalMaterialGpu result;
    mem::copy(&result, bytes.ptr, PhysicalMaterialGpu::size);

    return result;
}

fn void fidelity_check_flags(PhysicalMaterialGpu block, bool base_rg, bool coat_rg) @private {
    assert(((block.standard.map_flags & shader::MATERIAL_MAP_NORMAL_RG) != 0) == base_rg);
    assert(((block.map_flags & shader::PHYSICAL_MAP_CLEARCOAT_NORMAL_RG) != 0) == coat_rg);
}

fn void test_fidelity_semantic_only_replacements_keep_native_indices_and_update_independent_flags() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    Renderer* renderer = &fixture.renderer;

    @pool() {
        Vec4[4] pixels = { { 0.7, 0.4, 0.95, 1 }, { 0.7, 0.4, 0.95, 1 },
            { 0.7, 0.4, 0.95, 1 }, { 0.7, 0.4, 0.95, 1 } };
        char[] source = ((char*)&pixels)[:pixels.len * Vec4::size];
        material::TextureDesc desc = material::texture_2d_desc(2, 2, RGBA32_FLOAT);

        desc.semantic = TextureSemantic.NORMAL_RGB;
        TextureId base = fixture.assets.add_texture(desc, source)!!;
        TextureId coat = fixture.assets.add_texture(desc, source)!!;

        PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
        params.standard.normal_map = material::texture_slot(base);
        params.standard.metallic_roughness_map = material::texture_slot(base);
        params.clearcoat = 1;
        params.clearcoat_normal_map = material::texture_slot(coat);

        MaterialId material_id = fixture.assets.add_material(material::physical(params))!!;

        renderer.upload_material(material_id)!!;

        gpu::TextureIndex base_index = renderer.textures[base.index].view.index;
        gpu::TextureIndex coat_index = renderer.textures[coat.index].view.index;

        PhysicalMaterialGpu original = fidelity_read_physical(&fixture, material_id);
        fidelity_check_flags(original, false, false);

        uint material_revision = fixture.assets.material(material_id).header.revision;

        desc.semantic = TextureSemantic.NORMAL_RG;
        fixture.assets.replace_texture(base, desc, source)!!;

        renderer.upload_material(material_id)!!;
        fidelity_check_flags(fidelity_read_physical(&fixture, material_id), true, false);
        assert(renderer.textures[base.index].view.index == base_index
          && renderer.textures[coat.index].view.index == coat_index);

        desc.semantic = TextureSemantic.NORMAL_RGB;
        fixture.assets.replace_texture(base, desc, source)!!;

        PrepareId held = fidelity_texture_job(&fixture, base)!!;

        renderer.begin_frame()!!;

        PrepareReport blocked = renderer.advance_prepares_within({ .generated_texels = 1 })!!;

        assert(blocked.reason == PrepareStopReason.GENERATED_TEXELS && !blocked.generated_texels);
        renderer.end_frame()!!;
        assert(renderer.textures[base.index].semantic == TextureSemantic.NORMAL_RG);
        fidelity_check_flags(fidelity_read_physical(&fixture, material_id), true, false);

        fidelity_drain(
            fixture: &fixture,
            id: held,
            staged_bytes: 0,
            generated_texels: 0,
        );

        renderer.end_prepare(held)!!;

        renderer.upload_material(material_id)!!;

        PhysicalMaterialGpu base_changed = fidelity_read_physical(&fixture, material_id);
        fidelity_check_flags(base_changed, false, false);
        assert(base_changed.standard.metallic_roughness_map.texture_index
          == base_changed.standard.normal_map.texture_index);
        assert(base_changed.standard.metallic == original.standard.metallic
          && base_changed.standard.roughness == original.standard.roughness);
        assert(fixture.assets.material(material_id).header.revision == material_revision);

        renderer.begin_frame()!!;

        desc.semantic = TextureSemantic.NORMAL_RG;
        fixture.assets.replace_texture(coat, desc, source)!!;

        renderer.upload_material(material_id)!!;
        assert(renderer.materials[material_id.index].bindings.clearcoat_normal.semantic == TextureSemantic.NORMAL_RG);
        fixture.assets.texture(coat).desc.semantic = TextureSemantic.NORMAL_RGB;
        fixture.assets.mark_texture_dirty(coat);

        Material* material_data = &fixture.assets.material(material_id).data;
        MaterialBindings captured = render::material_prepare_bindings(renderer, material_data)!!;
        assert(captured.clearcoat_normal.semantic == TextureSemantic.NORMAL_RG);
        renderer.end_frame()!!;
        fidelity_check_flags(fidelity_read_physical(&fixture, material_id), false, true);
        assert(renderer.textures[coat.index].view.index == coat_index);

        renderer.upload_material(material_id)!!;
        fidelity_check_flags(fidelity_read_physical(&fixture, material_id), false, false);

        ((Vec4*)fixture.assets.texture(coat).pixels.ptr)[0].x = bitcast(0x7fc00000u, float);
        fixture.assets.mark_texture_dirty(coat);
        if (catch excuse = renderer.upload_material(material_id)) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false);
        }
        fidelity_check_flags(fidelity_read_physical(&fixture, material_id), false, false);

        RenderTargetId target = render::create_render_target(
            renderer: renderer,
            desc: render::render_target_desc(2, 2, RGBA32_FLOAT),
        )!!;
        defer render::destroy_render_target(renderer, target)!!;

        TextureSlot target_slot = {
            .texture = { .kind = TextureRefKind.RENDER_TARGET, .target = target },
            .transform = material::UV_TRANSFORM_IDENTITY,
        };
        params.standard.normal_map = target_slot;
        params.clearcoat_normal_map = target_slot;
        params.standard.metallic_roughness_map = {};

        MaterialId target_material = fixture.assets.add_material(material::physical(params))!!;

        renderer.upload_material(target_material)!!;
        fidelity_check_flags(fidelity_read_physical(&fixture, target_material), false, false);
        assert(renderer.materials[target_material.index].bindings.normal.semantic == TextureSemantic.COLOR);
        assert(renderer.materials[target_material.index].bindings.clearcoat_normal.semantic == TextureSemantic.COLOR);
    };

    check_validation(renderer);
}

fn void fidelity_compare_texture_mips(
    Fixture* fixture,
    FidelityHarness* harness,
    TextureId actual,
    TextureId expected,
) @private {
    material::TextureDesc desc = fixture.assets.texture(actual).desc;
    uint count = material::texture_mip_count(desc.width, desc.height);

    for (uint mip = 0; mip < count; mip++) {
        Vec4[] first = fidelity_sample(
            fixture: fixture,
            harness: harness,
            texture: actual,
            mip: mip,
        )!!;
        Vec4[] second = fidelity_sample(
            fixture: fixture,
            harness: harness,
            texture: expected,
            mip: mip,
        )!!;

        assert(first == second, "retry texture mip %d differs", mip);
    }
}

fn material::TextureDesc fidelity_lifetime_desc(bool coverage) @private {
    material::TextureDesc desc = material::texture_2d_desc(32, 32, RGBA8_UNORM);
    if (coverage) {
        desc.coverage = CoveragePolicy.THRESHOLD;
        desc.alpha_threshold = 0.5;
    } else {
        desc.semantic = TextureSemantic.NORMAL_RGB;
    }
    return desc;
}

fn void fidelity_finalized_abort(bool coverage, bool release_source) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityHarness harness = create_fidelity_harness(&fixture)!!;
    defer destroy_fidelity_harness(&fixture, &harness);

    Renderer* renderer = &fixture.renderer;

    @pool() {
        material::TextureDesc desc = fidelity_lifetime_desc(coverage);

        TextureId texture = fixture.assets.add_texture(desc, FIDELITY_LEAF_BYTE)!!;

        renderer.upload_texture(texture)!!;
        gpu::TextureHandle previous = renderer.textures[texture.index].texture;
        TextureCoverageResource* previous_results = renderer.textures[texture.index].coverage_resource;
        fixture.assets.mark_texture_dirty(texture);
        TextureId expected = fixture.assets.add_texture(desc, FIDELITY_LEAF_BYTE)!!;

        PrepareId id = fidelity_texture_job(&fixture, texture)!!;

        renderer.begin_frame()!!;
        renderer.advance_prepares_within({})!!;
        PrepareRecord* record = renderer.prepares.get(id);
        assert(!record.chain_active && record.units[0].done);
        assert(renderer.textures[texture.index].texture != previous);
        if (coverage) {
            assert(renderer.texture_coverage(texture, 2)!!.revision == 1);
            assert(renderer.textures[texture.index].coverage_resource != previous_results);
        }

        render::abort_frame(renderer);
        assert(renderer.textures[texture.index].texture == previous);
        assert(renderer.textures[texture.index].coverage_resource == previous_results);

        if (release_source) {
            fixture.assets.release_texture_cpu(texture);

            renderer.begin_frame()!!;
            renderer.advance_prepares_within({})!!;
            renderer.end_frame()!!;

            PrepareProgress progress = renderer.prepare_progress(id);
            assert(progress.state == PrepareState.FAILED && progress.failure == c3d::ASSET_DATA_UNAVAILABLE);
            assert(renderer.textures[texture.index].texture == previous);
            if (coverage) assert(renderer.texture_coverage(texture, 2)!!.revision == 1);
        } else {
            ulong before = renderer.prepare_counters.generated_texels;

            fidelity_drain(
                fixture: &fixture,
                id: id,
                staged_bytes: 128,
                generated_texels: 64,
            );
            assert(renderer.prepare_counters.generated_texels > before);

            renderer.upload_texture(expected)!!;

            fidelity_compare_texture_mips(
                fixture: &fixture,
                harness: &harness,
                actual: texture,
                expected: expected,
            );
            if (coverage) assert(renderer.texture_coverage(texture, 2)!!.revision == 2);
        }

        renderer.end_prepare(id)!!;
    };

    check_validation(renderer);
}

fn void test_fidelity_finalized_abort_regenerates_identical_normal_and_coverage_mips() @test {
    fidelity_finalized_abort(false, false);
    fidelity_finalized_abort(true, false);
}

fn void test_fidelity_finalized_abort_after_source_release_fails_without_installing_results() @test {
    fidelity_finalized_abort(false, true);
    fidelity_finalized_abort(true, true);
}

fn void test_fidelity_held_normal_and_coverage_chains_survive_source_release_after_base_copy() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityHarness harness = create_fidelity_harness(&fixture)!!;
    defer destroy_fidelity_harness(&fixture, &harness);

    Renderer* renderer = &fixture.renderer;

    for (uint kind = 0; kind < 2; kind++) {
        @pool() {
            material::TextureDesc desc = fidelity_lifetime_desc(kind != 0);

            TextureId texture = fixture.assets.add_texture(desc, FIDELITY_LEAF_BYTE)!!;
            TextureId expected = fixture.assets.add_texture(desc, FIDELITY_LEAF_BYTE)!!;

            PrepareId id = fidelity_texture_job(&fixture, texture)!!;
            PrepareRecord* record = renderer.prepares.get(id);
            uint frames;

            while (record.units[0].staged.mip == 0 && frames++ < FIDELITY_FRAME_LIMIT) {
                renderer.begin_frame()!!;

                PrepareReport report = renderer.advance_prepares_within({ .staged_bytes = 128 })!!;
                assert(report.staged_bytes <= 128);
                renderer.end_frame()!!;
                assert(renderer.prepare_progress(id).state != PrepareState.FAILED);
            }

            assert(record.units[0].staged.mip == 1 && record.chain_active);

            char* held = record.chain.pixels.ptr;

            fixture.assets.release_texture_cpu(texture);

            assert(record.chain.pixels.ptr == held);

            fidelity_drain(
                fixture: &fixture,
                id: id,
                staged_bytes: 128,
                generated_texels: 64,
            );

            renderer.end_prepare(id)!!;

            renderer.upload_texture(expected)!!;

            fidelity_compare_texture_mips(
                fixture: &fixture,
                harness: &harness,
                actual: texture,
                expected: expected,
            );

            if (kind) assert(renderer.texture_coverage(texture, 2)!!.passing == 30);
        };
    }

    check_validation(renderer);
}

fn void test_fidelity_single_texel_cube_has_zero_generation_and_exact_face_results() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        material::TextureDesc desc = material::texture_cube_desc(1, RGBA8_UNORM);

        desc.coverage = CoveragePolicy.THRESHOLD;
        desc.alpha_threshold = 0.5;
        char[24] pixels = { 1, 2, 3, 0, 1, 2, 3, 255, 1, 2, 3, 0,
            1, 2, 3, 255, 1, 2, 3, 0, 1, 2, 3, 255 };

        TextureId texture = fixture.assets.add_texture(desc, pixels[..])!!;

        PrepareId id = fidelity_texture_job(&fixture, texture)!!;
        assert(fixture.renderer.prepare_progress(id).texels_total == 0);

        FidelityDrain drain = fidelity_drain(
            fixture: &fixture,
            id: id,
            staged_bytes: 4,
            generated_texels: 1,
        );
        assert(drain.generated == 0 && drain.credits == 0);
        assert(!fixture.renderer.prepares.get(id).chain_active);

        fixture.renderer.end_prepare(id)!!;

        TextureCoverageResource* resource = fixture.renderer.textures[texture.index].coverage_resource;

        assert(resource.counts.len == 6 && resource.mip_count == 1 && resource.face_count == 6);

        for (uint face = 0; face < 6; face++) {
            TextureCoverageResult result = fixture.renderer.texture_coverage(texture, 0, face)!!;

            assert(result.total == 1 && result.original_total == 1);
            assert(result.passing == face % 2 && result.original_passing == face % 2);
            assert(result.absolute_error == 0 && !result.small_level);
        }
    };

    check_validation(&fixture.renderer);
}

fn uint fidelity_u32(char[] bytes, usz offset) @private {
    uint value;
    mem::copy(&value, bytes.ptr + offset, uint::size);
    return value;
}

fn FidelityBakeTriangle fidelity_bake_triangle(uint selected_case, uint selected_face) @private {
    usz geometry_offset = 8;
    usz tangent_offset = 8;
    uint cases = fidelity_u32(FIDELITY_BAKE_GEOMETRY, 4);

    assert(cases == fidelity_u32(FIDELITY_BAKE_TANGENTS, 4));

    for (uint index = 0; index < cases; index++) {
        uint vertices = fidelity_u32(FIDELITY_BAKE_GEOMETRY, geometry_offset);
        uint faces = fidelity_u32(FIDELITY_BAKE_GEOMETRY, geometry_offset + 4);
        usz vertex_start = geometry_offset + 12;
        usz indices_start = vertex_start + (usz)vertices * 10 * float::size;
        uint corners = fidelity_u32(FIDELITY_BAKE_TANGENTS, tangent_offset + 4);

        assert(corners == faces * 3);
        if (index == selected_case) {
            assert(selected_face < faces);
            assert(fidelity_u32(FIDELITY_BAKE_TANGENTS, tangent_offset));

            FidelityBakeTriangle result;

            for (uint corner = 0; corner < 3; corner++) {
                usz source_corner = (usz)selected_face * 3 + corner;
                uint source = fidelity_u32(FIDELITY_BAKE_GEOMETRY, indices_start + source_corner * uint::size);
                mem::copy(&result.normals[corner], FIDELITY_BAKE_GEOMETRY.ptr + vertex_start
                  + ((usz)source * 10 + 3) * float::size, Vec3::size);
                mem::copy(&result.tangents[corner], FIDELITY_BAKE_TANGENTS.ptr + tangent_offset + 8
                  + source_corner * Vec4::size, Vec4::size);
            }

            return result;
        }
        geometry_offset = indices_start + (usz)faces * 3 * uint::size;
        tangent_offset += 8 + (usz)corners * Vec4::size;
    }

    unreachable();
}

fn FidelityRaster? create_fidelity_raster(Fixture* fixture) @private {
    FidelityRaster raster;
    raster.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&raster.scene);

    raster.camera = raster.scene.add_camera(camera::orthographic(2, 0.1f, 20))!;
    raster.camera.local.position = { 0, 0, 3 };
    raster.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(FIDELITY_RASTER_EXTENT, FIDELITY_RASTER_EXTENT, RGBA32_FLOAT),
    )!;
    defer catch render::destroy_render_target(&fixture.renderer, raster.target)!!;

    ViewDesc desc = render::texture_view_desc(raster.target);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.depth_prepass = false;
    raster.view = render::create_view(&fixture.renderer, desc)!;
    return raster;
}

fn void destroy_fidelity_raster(Fixture* fixture, FidelityRaster* raster) @private {
    render::destroy_view(&fixture.renderer, raster.view)!!;
    render::destroy_render_target(&fixture.renderer, raster.target)!!;
    scene::destroy_scene(&raster.scene);
}

fn Vec4[]? fidelity_render_raster(
    Fixture* fixture,
    FidelityRaster* raster,
    ShadingPath path,
    bool normal_diagnostic = false,
) @private {
    Renderer* renderer = &fixture.renderer;
    ViewDesc desc = renderer.views.get(raster.view).desc;
    desc.shading = path;
    render::configure_view(renderer, raster.view, desc)!;
    raster.scene.update_world();

    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);

    renderer.render_view(&raster.scene, raster.camera, raster.view)!;
    renderer.finish_view(raster.view)!;
    Target* source = normal_diagnostic && path == ShadingPath.DEFERRED
        ? &renderer.views.get(raster.view).gbuffer[GBufferChannel.NORMAL_ROUGHNESS]
        : &renderer.views.get(raster.view).hdr_color;
    render::composite_target(
        renderer: renderer,
        source: source,
        output: &renderer.targets.get(raster.target).target,
        rect: {},
    )!;
    renderer.end_frame()!;
    return read_float_target(fixture, raster.target);
}

fn ShaderId? fidelity_normal_shader(Fixture* fixture) @private {
    @pool() {
        asset::ShaderDesc desc = {
            .fragment = compile::compile_glsl(tmem, (String)FIDELITY_NORMAL_FRAGMENT, ShaderStage.FRAGMENT)!,
        };
        return fixture.assets.add_shader(&desc);
    };
}

fn Vec3 fidelity_transformed_bake_reference(
    FidelityBakeTriangle* triangle,
    Vec3 weights,
    Vec3 mapped,
    Transform transform,
) @private {
    Mat4 model = transform.to_mat4();
    Mat3 inverse_transpose = maths::normal_matrix(model);
    double[<3>] normal;
    double[<3>] tangent;
    double sign = triangle.tangents[0].w * (transform.scale.x * transform.scale.y * transform.scale.z < 0 ? -1.0 : 1.0);

    for (uint corner = 0; corner < 3; corner++) {
        Vec3 transformed_normal = inverse_transpose.apply(triangle.normals[corner]).normalize();
        normal += (double[<3>])transformed_normal * (double)weights[corner];
        Vec3 transformed_tangent = maths::transform_dir(model, triangle.tangents[corner].xyz).normalize();
        tangent += (double[<3>])transformed_tangent * (double)weights[corner];
    }

    double[<3>] result = tangent * (double)mapped.x + normal.cross(tangent) * sign * (double)mapped.y
      + normal * (double)mapped.z;

    if (transform.scale.z < 0) result = -result;

    return (Vec3)(result / result.length());
}

fn void test_fidelity_raster_interpolation_matches_pinned_bake_and_transform_convention() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityRaster raster = create_fidelity_raster(&fixture)!!;
    defer destroy_fidelity_raster(&fixture, &raster);

    ShaderId diagnostic = fidelity_normal_shader(&fixture)!!;
    Transform[4] transforms = {
        maths::TRANSFORM_IDENTITY,
        { .rotation = { .v = { 0, 0, 0, 1 } }, .scale = { 1.5, 0.8, 1.2 } },
        { .rotation = { .v = { 0, 0, 0, 1 } }, .scale = { 1.3, 0.7, -0.9 } },
        { .rotation = { .v = { 0, 0, 0, 1 } }, .scale = { 2, 2, 2 } },
    };

    for (uint sample = 0; sample < FIDELITY_BAKE_RECORD_COUNT; sample++) {
        @pool() {
            usz sample_offset = (usz)sample * FIDELITY_BAKE_RECORD_BYTES;
            uint case_index = fidelity_u32(FIDELITY_BAKE, sample_offset);
            uint face_index = fidelity_u32(FIDELITY_BAKE, sample_offset + uint::size);
            FidelityBakeTriangle triangle = fidelity_bake_triangle(case_index, face_index);
            double[FIDELITY_BAKE_VALUE_COUNT] reference;
            char* sample_values = FIDELITY_BAKE.ptr + sample_offset + FIDELITY_BAKE_HEADER_BYTES;
            mem::copy(&reference, sample_values, reference.len * double::size);

            Vec3 weights = { (float)reference[0], (float)reference[1], (float)reference[2] };
            Vec3 encoded;
            mem::copy(&encoded, FIDELITY_BAKE_RGB.ptr + (usz)sample * 3 * float::size, Vec3::size);
            Vec4 pixel = { encoded.x, encoded.y, encoded.z, 1 };
            material::TextureDesc desc = material::texture_2d_desc(1, 1, RGBA32_FLOAT);

            desc.semantic = TextureSemantic.NORMAL_RGB;

            TextureId texture = fixture.assets.add_texture(desc, ((char*)&pixel)[:Vec4::size])!!;
            StandardParams params = material::STANDARD_PARAMS_DEFAULT;
            params.normal_map = material::texture_slot(texture);

            MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
            common.double_sided = true;

            MaterialId standard = fixture.assets.add_material(material::standard(params, common))!!;

            MaterialId probe = fixture.assets.add_material(material::custom(
                shader: diagnostic,
                references: { [0] = standard },
                common: common,
            ))!!;

            Vec3[3] positions = { { -1, -1, 0 }, { 1, -1, 0 }, { -1, 1, 0 } };
            Vec2[3] coordinates = { { 0, 0 }, { 1, 0 }, { 0, 1 } };

            Geometry geometry = {
                .positions = positions[..], .normals = triangle.normals[..], .tangents = triangle.tangents[..],
                .uv0 = coordinates[..],
            };
            geometry.finalize();

            GeometryId geometry_id = fixture.assets.add_geometry(&geometry)!!;

            raster.mesh = raster.scene.add_mesh(geometry_id, probe)!!;
            raster.scene.get(raster.mesh, Mesh).cast_shadow = false;

            for (uint transform_index = 0; transform_index < transforms.len; transform_index++) {
                if (transform_index && sample % FIDELITY_BAKE_TRANSFORM_STEP != 0) continue;

                Transform transform = transforms[transform_index];
                raster.mesh.local = transform;
                Vec3 point = positions[0] * weights.x + positions[1] * weights.y + positions[2] * weights.z;
                Vec3 world = maths::transform_point(transform.to_mat4(), point);
                raster.camera.local.position = world
                  + (Vec3){ -1.0f / FIDELITY_RASTER_EXTENT, 1.0f / FIDELITY_RASTER_EXTENT, 3 };

                Vec3 expected = transform_index == 0
                    ? (Vec3){ (float)reference[3], (float)reference[4], (float)reference[5] }
                    : fidelity_transformed_bake_reference(
                        triangle: &triangle,
                        weights: weights,
                        mapped: encoded * 2 - 1,
                        transform: transform,
                    );

                for (uint path = 0; path < 2; path++) {
                    raster.scene.get(raster.mesh, Mesh).material = path == 0 ? probe : standard;

                    Vec4[] pixels = fidelity_render_raster(
                        fixture: &fixture,
                        raster: &raster,
                        path: path == 0 ? ShadingPath.FORWARD : ShadingPath.DEFERRED,
                        normal_diagnostic: true,
                    )!!;
                    defer free(pixels);

                    Vec4 measured = pixels[FIDELITY_RASTER_CENTER_INDEX];
                    Vec3 actual = path == 0 ? measured.xyz : render::decode_octahedral(measured.xy);

                    assert(fidelity_angle(actual, expected) <= FIDELITY_WORLD_ANGLE,
                        "raster bake sample %d path %d transform %d: actual %s expected %s angle %.9f",
                        sample, path, transform_index, actual, expected, fidelity_angle(actual, expected));
                    if (sample == 0) fidelity_export_bake_region(
                        triangle: &triangle,
                        transform: transform,
                        camera_position: raster.camera.local.position,
                        mapped: encoded * 2 - 1,
                        measured: pixels,
                        deferred: path != 0,
                        name: string::tformat("bake_transform%d_path%d", transform_index, path),
                    )!!;
                }
            }

            raster.scene.remove(raster.mesh);

            fixture.assets.remove_material(probe);
            fixture.assets.remove_material(standard);
            fixture.assets.remove_geometry(geometry_id);

            fixture.assets.remove_texture(texture);
        };
    }

    check_validation(&fixture.renderer);
}

fn GeometryId? fidelity_quad(Fixture* fixture, bool mirrored = false) @private {
    Vec3[4] positions = { { -1, -1, 0 }, { 1, -1, 0 }, { 1, 1, 0 }, { -1, 1, 0 } };
    Vec3[4] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
    Vec2[4] coordinates = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } };
    uint[6] indices = { 0, 1, 2, 0, 2, 3 };
    if (mirrored) foreach (&coordinate : coordinates) coordinate.x = 1 - coordinate.x;

    Geometry source = {
        .positions = positions[..], .normals = normals[..], .uv0 = coordinates[..], .indices = indices[..],
    };

    source.finalize();

    TangentGeometry owner = geometry::create_tangent_geometry(fixture.allocator, &source)!;
    defer geometry::destroy_tangent_geometry(&owner);

    return fixture.assets.add_geometry(&owner.data);
}

fn void? fidelity_export_image(
    String name,
    Vec4[] pixels,
    uint width,
    uint height,
) @private {
    @pool() {
        String? directory_result = env::tget_var("C3D_FIDELITY_OUTPUT");
        if (catch excuse = directory_result) {
            io::printfn("NOT RUN: image export %s; C3D_FIDELITY_OUTPUT is unset", name);
            return;
        }

        String directory = directory_result;
        char[] rgba = alloc::new_array(tmem, char, (sz)(pixels.len * 4));

        foreach (index, pixel : pixels) {
            for (uint channel = 0; channel < 3; channel++) {
                assert(math::is_finite(pixel[channel]));
                rgba[index * 4 + channel] = (char)math::round(math::clamp(pixel[channel], 0.0f, 1.0f) * 255);
            }

            rgba[index * 4 + 3] = 255;
        }

        image::write_png(
            path: string::tformat("%s/%s.png", directory, name),
            width: width,
            height: height,
            pixels: rgba,
        )!;

        File output = file::open(string::tformat("%s/%s.rgba32f", directory, name), "wb")!;
        defer (void)output.close();

        output.write(((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
    };
}

fn float fidelity_compare_images(Vec4[] first, Vec4[] second, float tolerance) @private {
    assert(first.len == second.len);
    float maximum;

    foreach (index, pixel : first) {
        Vec4 delta = math::abs(pixel - second[index]);

        for (uint channel = 0; channel < 3; channel++) {
            assert(math::is_finite(pixel[channel]) && math::is_finite(second[index][channel]));
            assert(delta[channel] <= tolerance,
                "image sample %d channel %d difference %f", index, channel, delta[channel]);
            maximum = math::max(maximum, delta[channel]);
        }
    }

    return maximum;
}

fn void? fidelity_export_difference(String name, Vec4[] first, Vec4[] second) @private {
    @pool() {
        Vec4[] difference = alloc::new_array(tmem, Vec4, (sz)first.len);

        foreach (index, pixel : first) difference[index] = math::abs(pixel - second[index]) * 8;

        fidelity_export_image(
            name: name,
            pixels: difference,
            width: FIDELITY_RASTER_EXTENT,
            height: FIDELITY_RASTER_EXTENT,
        )!;
    };
}

fn TextureId? fidelity_normal_texture(Fixture* fixture, bool rg) @private {
    Vec3 direction = ((Vec3){ 0.3f, -0.25f, 1 }).normalize();
    Vec4 pixel = {
        direction.x * 0.5f + 0.5f, direction.y * 0.5f + 0.5f,
        rg ? 0.1f : direction.z * 0.5f + 0.5f, 1,
    };
    material::TextureDesc desc = material::texture_2d_desc(1, 1, RGBA32_FLOAT);
    desc.semantic = rg ? TextureSemantic.NORMAL_RG : TextureSemantic.NORMAL_RGB;
    return fixture.assets.add_texture(desc, ((char*)&pixel)[:Vec4::size]);
}

fn void test_fidelity_rgb_rg_base_and_coat_match_under_mirrors_scales_and_both_raster_paths() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityRaster raster = create_fidelity_raster(&fixture)!!;
    defer destroy_fidelity_raster(&fixture, &raster);

    raster.scene.ambient_intensity = 0;

    Node* sun = raster.scene.add_light(light::directional({ 1, 1, 1 }, 3, false))!!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -0.3f, -1 }).normalize(), { 0, 1, 0 });

    TextureId[2] textures = { fidelity_normal_texture(&fixture, false)!!, fidelity_normal_texture(&fixture, true)!! };

    Vec3[3] scales = { { 1, 1, 1 }, { 1.3, 0.7, 1.1 }, { -1.3, 0.7, 1.1 } };
    float[3] strengths = { 1, -1.5, 0 };

    for (uint mirrored = 0; mirrored < 2; mirrored++) {
        GeometryId geometry_id = fidelity_quad(&fixture, mirrored != 0)!!;

        raster.mesh = raster.scene.add_mesh(geometry_id, fixture.plain)!!;
        raster.scene.get(raster.mesh, Mesh).cast_shadow = false;

        for (uint layer = 0; layer < 2; layer++) {
            foreach (uint scale_index, scale : scales) {
                raster.mesh.local.scale = scale;

                foreach (uint strength_index, strength : strengths) {
                    MaterialId[2] materials;

                    for (uint encoding = 0; encoding < 2; encoding++) {
                        PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
                        params.standard.base_color = { 0.5, 0.6, 0.7, 1 };
                        params.standard.metallic = 0;
                        params.standard.roughness = 0.6;
                        params.standard.normal_map = layer == 0
                          ? material::texture_slot(textures[encoding]) : material::texture_slot();
                        params.standard.normal_scale = strength;
                        params.clearcoat = layer == 1 ? 0.8f : 0;
                        params.clearcoat_roughness = 0.25;
                        params.clearcoat_normal_map = material::texture_slot(textures[encoding]);
                        params.clearcoat_normal_scale = strength;

                        MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
                        common.double_sided = true;
                        materials[encoding] = fixture.assets.add_material(material::physical(params, common))!!;
                    }

                    for (uint path = 0; path < 2; path++) {
                        raster.scene.get(raster.mesh, Mesh).material = materials[0];

                        Vec4[] rgb = fidelity_render_raster(
                            fixture: &fixture,
                            raster: &raster,
                            path: path == 0 ? ShadingPath.FORWARD : ShadingPath.DEFERRED,
                        )!!;
                        defer free(rgb);

                        raster.scene.get(raster.mesh, Mesh).material = materials[1];

                        Vec4[] rg = fidelity_render_raster(
                            fixture: &fixture,
                            raster: &raster,
                            path: path == 0 ? ShadingPath.FORWARD : ShadingPath.DEFERRED,
                        )!!;
                        defer free(rg);

                        fidelity_compare_images(rgb, rg, FIDELITY_IMAGE_TOLERANCE);
                        if (!mirrored && strength_index == 0) {
                            @pool() {
                                String stem = string::tformat(
                                    "normal_layer%d_scale%d_path%d", layer, scale_index, path);

                                fidelity_export_image(
                                    name: string::tformat("%s_rgb", stem),
                                    pixels: rgb,
                                    width: FIDELITY_RASTER_EXTENT,
                                    height: FIDELITY_RASTER_EXTENT,
                                )!!;

                                fidelity_export_image(
                                    name: string::tformat("%s_rg", stem),
                                    pixels: rg,
                                    width: FIDELITY_RASTER_EXTENT,
                                    height: FIDELITY_RASTER_EXTENT,
                                )!!;

                                fidelity_export_difference(string::tformat("%s_diff", stem), rgb, rg)!!;
                            };
                        }
                    }

                    fixture.assets.remove_material(materials[0]);
                    fixture.assets.remove_material(materials[1]);
                }
            }
        }

        raster.scene.remove(raster.mesh);
    }

    check_validation(&fixture.renderer);
}

fn void test_fidelity_leaf_fixed_mip_lit_cutouts_export_forward_deferred_and_ordinary_control() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityRaster raster = create_fidelity_raster(&fixture)!!;
    defer destroy_fidelity_raster(&fixture, &raster);

    raster.scene.ambient_intensity = 0;
    raster.scene.background.color = { 0, 0, 0, 1 };
    raster.scene.add_light(light::directional({ 1, 1, 1 }, 3, false))!!;
    GeometryId quad = fidelity_quad(&fixture)!!;

    raster.mesh = raster.scene.add_mesh(quad, fixture.plain)!!;
    raster.scene.get(raster.mesh, Mesh).cast_shadow = false;

    foreach (format : FIDELITY_FORMATS) {
        @pool() {
            material::TextureDesc desc = material::texture_2d_desc(32, 32, format);

            desc.coverage = CoveragePolicy.THRESHOLD;
            desc.alpha_threshold = 0.5;

            TextureMipChain corrected = render::create_texture_mips(tmem, desc, fidelity_leaf(format))!!;
            defer render::destroy_texture_mips(&corrected);

            desc.coverage = CoveragePolicy.NONE;

            TextureMipChain ordinary = render::create_texture_mips(tmem, desc, fidelity_leaf(format))!!;
            defer render::destroy_texture_mips(&ordinary);

            usz level_bytes = material::texture_mip_bytes(desc, 2)!!;

            material::TextureDesc level = material::texture_2d_desc(8, 8, format);
            level.generate_mips = false;

            TextureId[2] textures = {
                fixture.assets.add_texture(level, corrected.pixels[corrected.offsets[2]:level_bytes])!!,
                fixture.assets.add_texture(level, ordinary.pixels[ordinary.offsets[2]:level_bytes])!!,
            };

            MaterialId[3] materials;

            for (uint kind = 0; kind < 3; kind++) {
                StandardParams params = material::STANDARD_PARAMS_DEFAULT;
                params.base_color_map = material::texture_slot(textures[kind == 1 ? 1 : 0], asset::SAMPLER_NEAREST);
                params.metallic = 0;
                params.roughness = 1;

                MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
                common.alpha_mode = kind == 2 ? AlphaMode.OPAQUE : AlphaMode.MASK;
                common.alpha_cutoff = 0.5;
                materials[kind] = fixture.assets.add_material(material::standard(params, common))!!;
            }

            Vec4[][2] fixed;

            for (uint path = 0; path < 2; path++) {
                for (uint kind = 0; kind < 3; kind++) {
                    raster.scene.get(raster.mesh, Mesh).material = materials[kind];

                    Vec4[] pixels = fidelity_render_raster(
                        fixture: &fixture,
                        raster: &raster,
                        path: path == 0 ? ShadingPath.FORWARD : ShadingPath.DEFERRED,
                    )!!;
                    defer { if (kind != 0) free(pixels); }

                    if (kind == 0) fixed[path] = pixels;

                    ulong visible;

                    foreach (pixel : pixels) {
                        visible += pixel.x + pixel.y + pixel.z > FIDELITY_VISIBLE_PIXEL_THRESHOLD ? 1 : 0;
                    }
                    if (kind == 0) assert(visible == 30 * FIDELITY_RASTER_EXTENT, "leaf rendered coverage %d", visible);
                    if (kind == 2) assert(visible == FIDELITY_RASTER_EXTENT * FIDELITY_RASTER_EXTENT);

                    fidelity_export_image(
                        name: string::tformat("leaf_%s_path%d_kind%d", format, path, kind),
                        pixels: pixels,
                        width: FIDELITY_RASTER_EXTENT,
                        height: FIDELITY_RASTER_EXTENT,
                    )!!;
                }
            }
            defer free(fixed[0]);
            defer free(fixed[1]);

            fidelity_compare_images(fixed[0], fixed[1], FIDELITY_IMAGE_TOLERANCE);

            fidelity_export_difference(string::tformat("leaf_%s_path_diff", format), fixed[0], fixed[1])!!;
        };
    }

    check_validation(&fixture.renderer);
}

fn void test_fidelity_rgb_rg_decals_match_on_mirrored_nonuniform_projectors_and_signed_scales() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    DecalScene target = decal_create_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);

    DecalView shot = decal_create_view(&fixture)!!;
    defer decal_destroy_view(&fixture, &shot);

    target.scene.ambient_intensity = 0;

    Node* sun = target.scene.add_light(light::directional({ 1, 1, 1 }, 3, false))!!;
    sun.local.rotation = maths::look_rotation(((Vec3){ 0, 1, -1 }).normalize(), { 0, 0, 1 });
    target.scene.get(target.projector, Decal).weights = { .base_color = 0, .normal = 1, .roughness = 0, .metallic = 0 };

    TextureId[2] textures = { fidelity_normal_texture(&fixture, false)!!, fidelity_normal_texture(&fixture, true)!! };

    float[3] strengths = { 1, -1.5, 0 };

    for (uint mirrored = 0; mirrored < 2; mirrored++) {
        target.scene.get(target.receiver, Mesh).geometry = target.quads[mirrored];
        target.projector.local.scale = { 1.25f, mirrored ? -1.5f : 1.5f, 0.75f };

        foreach (strength : strengths) {
            foreach (path : DECAL_PATHS) {
                decal_configure_view(&fixture, &shot, path)!!;

                Vec4[][2] outputs;

                for (uint encoding = 0; encoding < 2; encoding++) {
                    StandardParams* params = &fixture.assets.material(target.source).data.standard;
                    params.normal_map = material::texture_slot(textures[encoding]);
                    params.normal_scale = strength;
                    fixture.assets.mark_material_dirty(target.source);

                    outputs[encoding] = decal_render_pixels(
                        fixture: &fixture,
                        target: &target,
                        shot: &shot,
                        raw_hdr: true,
                    )!!;
                }
                defer free(outputs[0]);
                defer free(outputs[1]);

                fidelity_compare_images(outputs[0], outputs[1], FIDELITY_IMAGE_TOLERANCE);
            }
        }
    }

    check_validation(&fixture.renderer);
}

fn void test_fidelity_rgb_rg_trace_and_raster_normals_agree_for_signed_scales_and_mirrored_frames() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);

    FidelityRaster raster = create_fidelity_raster(&fixture)!!;
    defer destroy_fidelity_raster(&fixture, &raster);

    raster.scene.ambient_intensity = 0;
    raster.scene.background.color = { 0, 0, 0, 1 };

    Node* sun = raster.scene.add_light(light::directional({ 1, 1, 1 }, 3, false))!!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.5f, -0.2f, -1 }).normalize(), { 0, 1, 0 });

    TextureId[2] textures = { fidelity_normal_texture(&fixture, false)!!, fidelity_normal_texture(&fixture, true)!! };

    float[3] strengths = { 1, -1.5, 0 };

    for (uint mirrored = 0; mirrored < 2; mirrored++) {
        GeometryId quad = fidelity_quad(&fixture, mirrored != 0)!!;

        raster.mesh = raster.scene.add_mesh(quad, fixture.plain)!!;
        raster.scene.get(raster.mesh, Mesh).cast_shadow = false;
        raster.mesh.local.scale = { mirrored ? -1.2f : 1.2f, 0.8f, 1.1f };

        foreach (strength : strengths) {
            Vec4[2][2] centers;

            for (uint encoding = 0; encoding < 2; encoding++) {
                StandardParams params = material::STANDARD_PARAMS_DEFAULT;
                params.base_color = { 0.8, 0.8, 0.8, 1 };
                params.roughness = 0.6;
                params.normal_scale = strength;
                params.normal_map = material::texture_slot(textures[encoding]);

                MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
                common.double_sided = true;

                MaterialId material_id = fixture.assets.add_material(material::standard(params, common))!!;
                raster.scene.get(raster.mesh, Mesh).material = material_id;

                for (uint path = 0; path < 2; path++) {
                    ViewDesc desc = fixture.renderer.views.get(raster.view).desc;
                    desc.path_trace = { .max_bounces = 1, .samples_per_frame = 4 };
                    render::configure_view(&fixture.renderer, raster.view, desc)!!;

                    Vec4[] pixels = fidelity_render_raster(
                        fixture: &fixture,
                        raster: &raster,
                        path: path == 0 ? ShadingPath.FORWARD : ShadingPath.PATH_TRACED,
                    )!!;
                    defer free(pixels);

                    centers[encoding][path] = pixels[FIDELITY_RASTER_CENTER_INDEX];
                }
            }

            assert(math::abs(centers[0][0].xyz - centers[1][0].xyz).max() <= FIDELITY_IMAGE_TOLERANCE);
            assert(math::abs(centers[0][1].xyz - centers[1][1].xyz).max() <= FIDELITY_IMAGE_TOLERANCE);

            for (uint encoding = 0; encoding < 2; encoding++) {
                Vec3 tolerance = centers[encoding][0].xyz * FIDELITY_IMAGE_TOLERANCE
                  + FIDELITY_TRACE_ABSOLUTE_TOLERANCE;
                Vec3 difference = math::abs(centers[encoding][1].xyz - centers[encoding][0].xyz);
                assert(difference.x <= tolerance.x && difference.y <= tolerance.y && difference.z <= tolerance.z);
            }
        }

        raster.scene.remove(raster.mesh);
    }

    check_validation(&fixture.renderer);
}

fn void test_fidelity_restore_matching_changed_and_invalid_counts_preserves_committed_renderer_revisions() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    Renderer second = render::create_renderer(mem, &fixture.assets, {
        .validation = true, .application_name = "coverage_second_renderer",
    })!!;
    defer render::destroy_renderer(&second);

    @pool() {
        material::TextureDesc desc = material::texture_2d_desc(32, 32, RGBA32_FLOAT);

        desc.coverage = CoveragePolicy.THRESHOLD;
        desc.alpha_threshold = 0.5;

        TextureId texture = fixture.assets.add_texture(desc, FIDELITY_LEAF_FLOAT)!!;

        fixture.renderer.upload_texture(texture)!!;
        second.upload_texture(texture)!!;

        gpu::TextureHandle original = fixture.renderer.textures[texture.index].texture;
        TextureCoverageResource* original_results = fixture.renderer.textures[texture.index].coverage_resource;

        fixture.assets.release_texture_cpu(texture);

        fixture.assets.restore_texture_cpu(texture, ((String)FIDELITY_LEAF_FLOAT).copy(fixture.assets.allocator));

        assert(fixture.assets.texture(texture).header.revision == 1);

        fixture.renderer.upload_texture(texture)!!;
        assert(fixture.renderer.textures[texture.index].texture == original);
        assert(fixture.renderer.textures[texture.index].coverage_resource == original_results);
        assert(fixture.renderer.texture_coverage(texture, 2)!!.revision == 1
          && second.texture_coverage(texture, 2)!!.revision == 1);

        char[] changed = alloc::new_array(tmem, char, (sz)FIDELITY_LEAF_FLOAT.len);
        changed[..] = FIDELITY_LEAF_FLOAT[..];
        usz selected;

        for (usz index = 0; index < 1024; index++) {
            if (((Vec4*)changed.ptr)[index].w < 0.5) { selected = index; break; }
        }

        ((Vec4*)changed.ptr)[selected].w = 1;

        fixture.assets.release_texture_cpu(texture);

        fixture.assets.restore_texture_cpu(texture, ((String)changed).copy(fixture.assets.allocator));

        assert(fixture.assets.texture(texture).header.revision == 2);
        assert(fixture.assets.texture(texture).coverage_statistics.passing[0] == 485);
        assert(fixture.renderer.texture_coverage(texture, 2)!!.revision == 1);

        fixture.renderer.upload_texture(texture)!!;

        TextureCoverageResult first = fixture.renderer.texture_coverage(texture, 2)!!;
        TextureCoverageResult held = second.texture_coverage(texture, 2)!!;
        assert(first.revision == 2 && first.original_passing == 485);
        assert(held.revision == 1 && held.original_passing == 484);
        assert(fixture.renderer.textures[texture.index].coverage_resource != original_results);

        ((Vec4*)changed.ptr)[selected].w = bitcast(0x7fc00000u, float);

        fixture.assets.release_texture_cpu(texture);

        fixture.assets.restore_texture_cpu(texture, ((String)changed).copy(fixture.assets.allocator));

        assert(fixture.assets.texture(texture).header.revision == 3);
        assert(!fixture.assets.texture(texture).coverage_statistics.valid);

        PrepareId id = fidelity_texture_job(&fixture, texture)!!;
        fixture.renderer.begin_frame()!!;
        fixture.renderer.advance_prepares_within({})!!;
        fixture.renderer.end_frame()!!;

        PrepareProgress failure = fixture.renderer.prepare_progress(id);

        assert(failure.state == PrepareState.FAILED && failure.failure == c3d::INVALID_ARGUMENT);
        assert(fixture.renderer.texture_coverage(texture, 2)!!.revision == 2);
        assert(second.texture_coverage(texture, 2)!!.revision == 1);

        fixture.renderer.end_prepare(id)!!;
    };

    check_validation(&second);

    check_validation(&fixture.renderer);
}

fn void? fidelity_export_bake_region(
    FidelityBakeTriangle* triangle,
    Transform transform,
    Vec3 camera_position,
    Vec3 mapped,
    Vec4[] measured,
    bool deferred,
    String name,
) @private {
    @pool() {
        Vec4[] reference = alloc::new_array(tmem, Vec4, (sz)measured.len);
        Vec4[] actual = alloc::new_array(tmem, Vec4, (sz)measured.len);
        uint eligible;

        double maximum;

        for (uint row = 0; row < FIDELITY_RASTER_EXTENT; row++) {
            for (uint column = 0; column < FIDELITY_RASTER_EXTENT; column++) {
                Vec3 point = {
                    camera_position.x + ((float)column + 0.5f) / FIDELITY_RASTER_CENTER - 1,
                    camera_position.y + 1 - ((float)row + 0.5f) / FIDELITY_RASTER_CENTER, 0,
                };
                point /= transform.scale;

                Vec3 weights = { 0, (point.x + 1) * 0.5f, (point.y + 1) * 0.5f };
                weights.x = 1 - weights.y - weights.z;
                if (weights.x < FIDELITY_BAKE_WEIGHT_MARGIN
                  || weights.y < FIDELITY_BAKE_WEIGHT_MARGIN || weights.z < FIDELITY_BAKE_WEIGHT_MARGIN) continue;

                uint index = row * FIDELITY_RASTER_EXTENT + column;

                Vec3 expected = fidelity_transformed_bake_reference(
                    triangle: triangle,
                    weights: weights,
                    mapped: mapped,
                    transform: transform,
                );
                Vec3 normal = deferred ? render::decode_octahedral(measured[index].xy) : measured[index].xyz;

                double angle = fidelity_angle(normal, expected);

                assert(angle <= FIDELITY_WORLD_ANGLE, "bake image %s row %d column %d: %.9f", name, row, column, angle);
                maximum = math::max(maximum, angle);
                eligible++;

                Vec3 expected_color = expected * 0.5f + 0.5f;
                Vec3 actual_color = normal * 0.5f + 0.5f;
                reference[index] = { expected_color.x, expected_color.y, expected_color.z, 1 };
                actual[index] = { actual_color.x, actual_color.y, actual_color.z, 1 };
            }
        }

        assert(eligible >= FIDELITY_BAKE_MINIMUM_ELIGIBLE);

        io::printfn("bake image %s: eligible=%d maximum_rad=%.9f", name, eligible, maximum);

        fidelity_export_image(
            name: string::tformat("%s_normal", name),
            pixels: actual,
            width: FIDELITY_RASTER_EXTENT,
            height: FIDELITY_RASTER_EXTENT,
        )!;

        fidelity_export_image(
            name: string::tformat("%s_reference", name),
            pixels: reference,
            width: FIDELITY_RASTER_EXTENT,
            height: FIDELITY_RASTER_EXTENT,
        )!;

        fidelity_export_difference(string::tformat("%s_difference", name), actual, reference)!;
    };
}
