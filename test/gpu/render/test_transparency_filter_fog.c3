module c3d::render::acceptance;

import c3d;
import c3d::render @public;
import c3d::shader;
import c3d::shader::compile;
import c3d::test::transparency_fixtures;
import gpu;
import std::io;
import std::math;

alias FilterExtent @private = uint[<2>];
alias FilterUv @private = double[<2>];

const char[*] FILTER_FOG_SOURCE @private = $embed("transparency_filter_fog.comp.glsl");
const char[*] FILTER_IMAGE_SOURCE @private = $embed("transparency_filter_image.comp.glsl");
const uint FILTER_FOG_OUTPUT_ROWS @private = 16; // mirrored as the output stride in transparency_filter_fog.comp.glsl
const double FILTER_FOG_ABSOLUTE_TOLERANCE @private = 2e-5;
const double FILTER_FOG_RELATIVE_TOLERANCE @private = 2e-4;
const double FILTER_FOG_DENOMINATOR_FLOOR @private = 1e-4; // existing fog.glsl denominator; no additional clamp
const uint FILTER_IMAGE_LEVEL_CAPACITY @private = 16; // mirrored as levels[16] in transparency_filter_image.comp.glsl
const uint FILTER_IMAGE_GROUP_SIZE @private = 8; // mirrored as local_size_x/y in transparency_filter_image.comp.glsl
const uint FILTER_IMAGE_SAMPLE_COUNT @private = 20;
const double FILTER_IMAGE_ABSOLUTE_TOLERANCE @private = 0.003;
const double FILTER_IMAGE_RELATIVE_TOLERANCE @private = 0.005;
const float FILTER_FOG_TABLE_DISTANCE @private = 8;
const double FILTER_FOG_TABLE_HEIGHT_EXTINCTION @private = 0.02;
const double FILTER_FOG_TABLE_AERIAL_EXTINCTION @private = 0.01;

struct FilterFogInput @private {
    gpu::GpuAddress frame;
    gpu::GpuAddress sky;
    Vec4 distances;
    Vec4 aerial_color_extinction;
    Vec4 radiance_coverage;
    Vec4 emission;
    Vec4 direction;
}
$assert FilterFogInput::size == 96;

struct FilterFogRoot @private {
    gpu::GpuAddress input_address;
    gpu::GpuAddress output_address;
    uint count;
    uint[3] padding;
}
$assert FilterFogRoot::size == 32;

struct FilterFogCase @private {
    double density;
    double falloff;
    double vertical_direction;
    double aerial_extinction;
    Vec4 distances;
    Vec4 radiance_coverage;
    Vec4 emission;
}

struct FilterFogTerms @private {
    double[<3>] attenuation;
    double[<3>] scattering;
}

struct FilterImageRoot @private {
    gpu::GpuAddress output_address;
    gpu::GpuAddress frame;
    uint width;
    uint height;
    uint source_width;
    uint source_height;
    uint source;
    uint destination;
    uint sampler_index;
    uint mode;
    uint pattern;
    uint level_count;
    float roughness;
    float ior;
    uint[FILTER_IMAGE_LEVEL_CAPACITY] levels;
}
$assert FilterImageRoot::size == 128;

struct FilterImageResources @private {
    Target[FILTER_IMAGE_LEVEL_CAPACITY] levels;
    Target depth;
    gpu::PipelineHandle pipeline;
    gpu::SamplerIndex sampler;
    gpu::MappedGpuSpan output;
    uint level_count;
    usz[FILTER_IMAGE_LEVEL_CAPACITY] readback_offsets;
    usz sample_offset;
    usz sample_bytes;
}

struct FilterFogTables @private {
    Target volume;
    Target aerial;
    Target sky_view;
    gpu::SamplerIndex sampler;
}

fn gpu::GpuAddress? upload_filter_fog(Renderer* renderer, char[] bytes) @private {
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan upload = frame.upload.take(&renderer.device, bytes.len)!;
    mem::copy(upload.bytes.ptr, bytes.ptr, (sz)bytes.len);
    return upload.address;
}

fn gpu::PipelineHandle? create_filter_fog_pipeline(Renderer* renderer, String source, String name) @private {
    String log;
    char[]? result = compile::compile_glsl(
        allocator: mem,
        source: source,
        stage: ShaderStage.COMPUTE,
        defines: {},
        debug_name: name,
        log: &log,
    );
    defer free(log.ptr);
    if (catch err = result) {
        io::eprintfn("%s GLSL compilation failed:\n%s", name, log);
        return err~;
    }
    char[] spirv = result;
    defer free(spirv.ptr);
    gpu::ComputePipelineDesc desc = { .shader = { .spirv = spirv }, .debug_name = "transparency_filter_fog" };
    return gpu::create_compute_pipeline(&renderer.device, &desc);
}

fn FilterFogTerms filter_fog_expected(FilterFogCase fixture, double distance) @private {
    double height_rate = fixture.falloff * fixture.vertical_direction;
    double clip_start = fixture.distances.w;
    double integrated_density = fixture.density * (distance - clip_start);
    if (height_rate != 0) {
        integrated_density = fixture.density * (math::exp(-height_rate * clip_start)
            - math::exp(-height_rate * distance)) / height_rate;
    }
    double height_attenuation = math::exp(-integrated_density);
    double aerial_attenuation = math::exp(-fixture.aerial_extinction * (distance - clip_start));
    double[<3>] height_color = { 0.1, 0.2, 0.4 };
    double[<3>] aerial_color = { 0.7, 0.3, 0.05 };
    return {
        .attenuation = { height_attenuation * aerial_attenuation,
            height_attenuation * aerial_attenuation, height_attenuation * aerial_attenuation },
        .scattering = height_color * (1 - height_attenuation)
          + height_attenuation * aerial_color * (1 - aerial_attenuation),
    };
}

fn void check_filter_fog_color(Vec4 actual, double[<3>] expected) @private {
    for (uint channel = 0; channel < 3; channel++) {
        double error = math::abs((double)actual[channel] - expected[channel]);
        assert(error <= FILTER_FOG_ABSOLUTE_TOLERANCE
            + FILTER_FOG_RELATIVE_TOLERANCE * math::abs(expected[channel]),
            "Fog transfer disagrees with the independent double reference.");
    }
}

fn void test_transparency_filter_fog_cumulative_connections_preserve_neutral_layers_and_blends() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    gpu::PipelineHandle pipeline = create_filter_fog_pipeline(
        renderer: renderer,
        source: (String)FILTER_FOG_SOURCE[..],
        name: "transparency_cumulative_fog",
    )!!;
    defer gpu::destroy_pipeline(&renderer.device, pipeline)!!;
    FilterFogCase[10] cases = {
        { .density = 0, .distances = { 1, 2, 4, 0 } },
        { .density = 0.125, .distances = { 1, 2, 4, 0 } },
        { .density = 0.125, .falloff = 0.25, .vertical_direction = 0.5, .distances = { 1, 2, 4, 0 } },
        { .density = 0.125, .aerial_extinction = 0.0625, .distances = { 1, 2, 4, 0 } },
        { .density = 0.125, .falloff = 0.25, .vertical_direction = 0.5,
            .aerial_extinction = 0.0625, .distances = { 1, 2, 4, 0 } },
        { .density = 0.125, .falloff = 0.25, .vertical_direction = -0.5,
            .aerial_extinction = 0.0625, .distances = { 1, 2, 4, 0 } },
        { .density = 0.125, .aerial_extinction = 0.0625, .distances = { 0.5f, 1, 2, 0 } },
        { .density = 0.125, .falloff = 0.25, .vertical_direction = 0.5,
            .aerial_extinction = 0.0625, .distances = { 1, 2, 4, 0.5f } },
        { .density = 0.125, .aerial_extinction = 0.5, .distances = { 4, 8, 16, 0 } },
        { .density = 4, .aerial_extinction = 1, .distances = { 2, 3, 4, 0 } },
    };
    foreach (&entry : cases) {
        entry.radiance_coverage = { 0.8f, 0.6f, 0.4f, 0.375f };
        entry.emission = { 0.25f, 0.5f, 1, 0 };
    }
    gpu::AllocationDesc allocation = {
        .size = cases.len * FILTER_FOG_OUTPUT_ROWS * Vec4::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "transparency_fog_readback",
    };
    gpu::MappedGpuSpan output = gpu::allocate_mapped_memory(&renderer.device, &allocation)!!;
    defer {
        gpu::GpuAllocation owned = output.span.allocation();
        gpu::free_allocation(&renderer.device, &owned)!!;
    }

    renderer.begin_frame()!!;
    FilterFogInput[10] inputs;
    FrameRoot frame_root = { .ambient = { 1, 1, 1, 0 } };
    gpu::GpuAddress frame_address = upload_filter_fog(renderer, ((char*)&frame_root)[:FrameRoot::size])!!;
    foreach (index, entry : cases) {
        SkyFogGpu sky = {
            .fog_albedo_density = { 0.1f, 0.2f, 0.4f, (float)entry.density },
            .fog_falloff = (float)entry.falloff,
            .flags = shader::SKY_FOG_HEIGHT_FOG,
        };
        inputs[index] = {
            .frame = frame_address,
            .sky = upload_filter_fog(renderer, ((char*)&sky)[:SkyFogGpu::size])!!,
            .distances = entry.distances,
            .aerial_color_extinction = { 0.7f, 0.3f, 0.05f, (float)entry.aerial_extinction },
            .radiance_coverage = entry.radiance_coverage,
            .emission = entry.emission,
            .direction = { 0, (float)entry.vertical_direction,
                -(float)math::sqrt(1 - entry.vertical_direction * entry.vertical_direction), 0 },
        };
    }
    FilterFogRoot root = {
        .input_address = upload_filter_fog(renderer, ((char*)&inputs)[:FilterFogInput::size * inputs.len])!!,
        .output_address = output.address,
        .count = (uint)cases.len,
    };
    gpu::GpuAddress address = upload_filter_fog(renderer, ((char*)&root)[:FilterFogRoot::size])!!;
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!!;
    gpu::cmd_dispatch(&renderer.commands, address, { (uint)cases.len, 1, 1 })!!;
    gpu::Barrier host = { .before = { .compute }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!!;
    renderer.work_recorded = true;
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;
    gpu::invalidate_mapped_span(&renderer.device, output.span)!!;

    Vec4* rows = (Vec4*)output.bytes.ptr;
    double maximum_handoff_shift;
    double below_floor_deviation;
    uint signed_scattering_cases;
    foreach (index, entry : cases) {
        Vec4* actual = &rows[index * FILTER_FOG_OUTPUT_ROWS];
        FilterFogTerms near_terms = filter_fog_expected(entry, entry.distances.x);
        FilterFogTerms far_terms = filter_fog_expected(entry, entry.distances.z);
        FilterFogTerms middle_terms = filter_fog_expected(entry, entry.distances.y);
        double[<3>] raw = { entry.radiance_coverage.x, entry.radiance_coverage.y, entry.radiance_coverage.z };
        double[<3>] emission = { entry.emission.x, entry.emission.y, entry.emission.z };
        double[<3>] expected = raw * far_terms.attenuation + far_terms.scattering;
        check_filter_fog_color(actual[0], near_terms.attenuation);
        check_filter_fog_color(actual[1], near_terms.scattering);
        check_filter_fog_color(actual[2], far_terms.attenuation);
        check_filter_fog_color(actual[3], far_terms.scattering);
        double vertical_rate = entry.falloff * entry.vertical_direction;
        double background_attenuation = entry.density > 0 ? 0 : 1;
        if (vertical_rate > 0) {
            double local_density = entry.density * math::exp(-vertical_rate * entry.distances.x);
            background_attenuation = math::exp(-local_density / vertical_rate);
        }
        double[<3>] height_color = { 0.1, 0.2, 0.4 };
        check_filter_fog_color(actual[12], background_attenuation * raw
            + (1 - background_attenuation) * height_color);
        if (actual[11].x < 0 || actual[11].y < 0 || actual[11].z < 0) signed_scattering_cases++;
        if (near_terms.attenuation.x >= FILTER_FOG_DENOMINATOR_FLOOR) {
            check_filter_fog_color(actual[4], expected);
            check_filter_fog_color(actual[5], expected);
            double coverage = entry.radiance_coverage.w;
            double[<3>] over = coverage * (emission * near_terms.attenuation + near_terms.scattering)
              + (1 - coverage) * expected;
            double[<3>] additive = expected + coverage * emission * near_terms.attenuation;
            check_filter_fog_color(actual[6], over);
            check_filter_fog_color(actual[7], over);
            check_filter_fog_color(actual[8], additive);
            check_filter_fog_color(actual[9], additive);
            check_filter_fog_color(actual[15], expected);
            double[<3>] rear_to_front_attenuation = middle_terms.attenuation / near_terms.attenuation;
            double[<3>] rear_to_front_scattering = (middle_terms.scattering - near_terms.scattering)
              / near_terms.attenuation;
            double[<3>] opaque_to_rear_attenuation = far_terms.attenuation / middle_terms.attenuation;
            double[<3>] opaque_to_rear_scattering = (far_terms.scattering - middle_terms.scattering)
              / middle_terms.attenuation;
            double[<3>] rear = emission + 0.625 * (opaque_to_rear_attenuation * raw + opaque_to_rear_scattering);
            double[<3>] front = 0.25 * emission
              + 0.75 * (rear_to_front_attenuation * rear + rear_to_front_scattering);
            check_filter_fog_color(actual[14], near_terms.attenuation * front + near_terms.scattering);
            if (entry.aerial_extinction == 0 || entry.density == 0) {
                check_filter_fog_color(actual[10], expected);
            }
        } else {
            for (uint row = 0; row < FILTER_FOG_OUTPUT_ROWS; row++) {
                for (uint channel = 0; channel < 3; channel++) assert(math::is_finite(actual[row][channel]));
            }
            for (uint channel = 0; channel < 3; channel++) {
                below_floor_deviation = math::max(below_floor_deviation,
                    math::abs((double)actual[5][channel] - expected[channel]));
            }
        }
        if (entry.aerial_extinction && entry.density && index != cases.len - 1) {
            for (uint channel = 0; channel < 3; channel++) {
                maximum_handoff_shift = math::max(maximum_handoff_shift,
                    math::abs((double)actual[10][channel] - actual[4][channel]));
            }
        }
    }
    assert(maximum_handoff_shift > 0, "Combined media did not exercise the retained/remainder shift.");
    assert(signed_scattering_cases > 0, "The combined transfer never exercised signed intermediate scattering.");
    io::printfn(
        "transparency fog cases=%s combined_handoff_shift=%s below_floor_deviation=%s signed_cases=%s",
        cases.len,
        maximum_handoff_shift,
        below_floor_deviation,
        signed_scattering_cases,
    );
    check_validation(renderer);
}

fn Target? create_filter_image(Renderer* renderer, uint width, uint height) @private {
    gpu::TextureDesc desc = {
        .width = width,
        .height = height,
        .format = gpu::Format.RGBA16_FLOAT,
        .usage = { .sampled, .storage, .transfer_src },
        .access = { .graphics },
        .debug_name = "transparency_linear_filter_image",
    };
    Target image = { .format = desc.format, .width = width, .height = height };
    image.texture = gpu::create_texture(&renderer.device, &desc)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, image.texture);
    image.view = gpu::create_texture_view(&renderer.device, image.texture, null)!;
    return image;
}

fn void destroy_filter_images(Renderer* renderer, FilterImageResources* images) @private {
    render::wait_frames(renderer)!!;
    foreach (&image : images.levels[:images.level_count]) {
        gpu::destroy_texture_view(&renderer.device, image.view)!!;
        gpu::destroy_texture(&renderer.device, image.texture)!!;
    }
    if (images.depth.texture.is_valid()) {
        gpu::destroy_texture_view(&renderer.device, images.depth.view)!!;
        gpu::destroy_texture(&renderer.device, images.depth.texture)!!;
    }
    if (images.pipeline.is_valid()) gpu::destroy_pipeline(&renderer.device, images.pipeline)!!;
    if (images.output.bytes.len) {
        gpu::GpuAllocation owned = images.output.span.allocation();
        gpu::free_allocation(&renderer.device, &owned)!!;
    }
}

fn void? create_filter_images(Renderer* renderer, FilterImageResources* images, FilterExtent extent) @private {
    defer catch destroy_filter_images(renderer, images);
    uint width = extent.x;
    uint height = extent.y;
    usz readback_bytes;
    while (true) {
        uint index = images.level_count;
        images.levels[index] = create_filter_image(renderer, width, height)!;
        images.level_count++;
        images.readback_offsets[index] = readback_bytes;
        readback_bytes += (usz)width * height * 4 * ushort::size;
        readback_bytes = (readback_bytes + 15) & ~(usz)15;
        if (width == 1 && height == 1) break;
        width = math::max(1u, width / 2);
        height = math::max(1u, height / 2);
    }
    images.depth = create_filter_image(renderer, extent.x, extent.y)!;
    images.pipeline = create_filter_fog_pipeline(
        renderer: renderer,
        source: (String)FILTER_IMAGE_SOURCE[..],
        name: "transparency_area_box_filter",
    )!;
    gpu::SamplerDesc sampler = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .mip_filter = gpu::Filter.LINEAR,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
        .debug_name = "transparency_linear_filter_sampler",
    };
    images.sampler = gpu::intern_sampler(&renderer.device, &sampler)!;
    images.sample_offset = readback_bytes;
    images.sample_bytes = (usz)extent.x * extent.y * Vec4::size;
    gpu::AllocationDesc output = {
        .size = images.sample_offset + images.sample_bytes * (FILTER_IMAGE_SAMPLE_COUNT + 3),
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "transparency_filter_readback",
    };
    images.output = gpu::allocate_mapped_memory(&renderer.device, &output)!;
}

fn void? dispatch_filter_image(Renderer* renderer, FilterImageResources* images, FilterImageRoot root) @private {
    gpu::GpuAddress address = upload_filter_fog(renderer, ((char*)&root)[:FilterImageRoot::size])!;
    gpu::cmd_bind_pipeline(&renderer.commands, images.pipeline)!;
    gpu::cmd_dispatch(&renderer.commands, address, {
        (root.width + FILTER_IMAGE_GROUP_SIZE - 1) / FILTER_IMAGE_GROUP_SIZE,
        (root.height + FILTER_IMAGE_GROUP_SIZE - 1) / FILTER_IMAGE_GROUP_SIZE,
        1,
    })!;
}

fn void? run_filter_images(
    Renderer* renderer,
    FilterImageResources* images,
    transparency_fixtures::BackdropPattern pattern,
) @private {
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    foreach (&image : images.levels[:images.level_count]) {
        image.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    }
    images.depth.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    FilterImageRoot root = {
        .width = images.levels[0].width,
        .height = images.levels[0].height,
        .destination = (uint)images.levels[0].view.index,
        .sampler_index = (uint)images.sampler,
        .pattern = (uint)pattern,
        .level_count = images.level_count,
    };
    foreach (index, image : images.levels[:images.level_count]) root.levels[index] = (uint)image.view.index;
    dispatch_filter_image(renderer, images, root)!;
    root.destination = (uint)images.depth.view.index;
    root.pattern = 6;
    dispatch_filter_image(renderer, images, root)!;
    images.depth.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
    for (uint level = 1; level < images.level_count; level++) {
        Target* source = &images.levels[level - 1];
        Target* target = &images.levels[level];
        source.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
        root.mode = 1;
        root.width = target.width;
        root.height = target.height;
        root.source_width = source.width;
        root.source_height = source.height;
        root.source = (uint)source.view.index;
        root.destination = (uint)target.view.index;
        dispatch_filter_image(renderer, images, root)!;
    }
    images.levels[images.level_count - 1].transition(&renderer.commands,
        gpu::storage_at({ .compute }, { .read }))!;
    root.width = images.levels[0].width;
    root.height = images.levels[0].height;
    FrameRoot frame_root = {
        .view = bitcast(matrix::IDENTITY4{float}, Mat4f),
        .view_proj = bitcast(matrix::IDENTITY4{float}, Mat4f),
        .proj = {{ 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, -1, 0 }, { 0, 0, 0, 1 }},
        .camera_params = { 0, 0, (float)root.width, (float)root.height },
        .scene_color = images.levels[0].view.index,
        .scene_depth = images.depth.view.index,
        .scene_sampler = images.sampler,
    };
    SkyFogGpu sky = { .fog_albedo_density = { 0, 0, 0, 1 }, .flags = shader::SKY_FOG_HEIGHT_FOG };
    frame_root.sky_fog = upload_filter_fog(renderer, ((char*)&sky)[:SkyFogGpu::size])!;
    root.frame = upload_filter_fog(renderer, ((char*)&frame_root)[:FrameRoot::size])!;
    root.mode = 2;
    uint sample;
    foreach (roughness : transparency_fixtures::ROUGHNESS_VALUES) {
        foreach (ior : transparency_fixtures::IOR_VALUES) {
            root.roughness = (float)roughness;
            root.ior = (float)ior;
            root.output_address = (gpu::GpuAddress)((ulong)images.output.address
                + images.sample_offset + sample * images.sample_bytes);
            dispatch_filter_image(renderer, images, root)!;
            sample++;
        }
    }
    root.mode = 4;
    root.roughness = 0;
    root.ior = 1;
    root.output_address = (gpu::GpuAddress)((ulong)images.output.address
        + images.sample_offset + FILTER_IMAGE_SAMPLE_COUNT * images.sample_bytes);
    dispatch_filter_image(renderer, images, root)!;
    root.mode = 3;
    root.roughness = 1;
    root.ior = 1.5f;
    root.output_address = (gpu::GpuAddress)((ulong)root.output_address + images.sample_bytes);
    dispatch_filter_image(renderer, images, root)!;
    root.mode = 5;
    root.output_address = (gpu::GpuAddress)((ulong)root.output_address + images.sample_bytes);
    dispatch_filter_image(renderer, images, root)!;
    foreach (level, &image : images.levels[:images.level_count]) {
        image.transition(&renderer.commands, {
            .layout = gpu::TextureLayout.TRANSFER_SOURCE,
            .stages = { .transfer },
            .access = { .read },
        })!;
        usz image_bytes = (usz)image.width * image.height * 4 * ushort::size;
        gpu::TextureBufferCopyDesc copy = {
            .texture = image.texture,
            .dst = images.output.span.checked_subspan(images.readback_offsets[level], image_bytes)!,
        };
        gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
    }
    gpu::Barrier host = { .before = { .compute, .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, images.output.span)!;
}

fn double filter_half_value(ushort encoded) @private {
    uint exponent = (encoded >> 10) & 31;
    double mantissa = (double)(encoded & 1023);
    double value = exponent ? math::pow(2.0, (double)exponent - 15) * (1 + mantissa / 1024)
      : math::pow(2.0, -24.0) * mantissa;
    return encoded & 32768 ? -value : value;
}

fn transparency_fixtures::Color filter_bilinear(transparency_fixtures::ColorImage image, FilterUv uv) @private {
    double x = uv.x * image.width - 0.5;
    double y = uv.y * image.height - 0.5;
    int left = (int)math::floor(x);
    int top = (int)math::floor(y);
    double horizontal = x - left;
    double vertical = y - top;
    transparency_fixtures::Color result;
    for (int row = 0; row < 2; row++) {
        for (int column = 0; column < 2; column++) {
            uint source_x = (uint)math::clamp(left + column, 0, (int)image.width - 1);
            uint source_y = (uint)math::clamp(top + row, 0, (int)image.height - 1);
            double weight = (column ? horizontal : 1 - horizontal) * (row ? vertical : 1 - vertical);
            result += image.pixels[(usz)source_y * image.width + source_x] * weight;
        }
    }
    return result;
}

fn void check_filter_image_color(Vec4 actual, transparency_fixtures::Color expected) @private {
    for (uint channel = 0; channel < 3; channel++) {
        assert(math::abs((double)actual[channel] - expected[channel]) <= FILTER_IMAGE_ABSOLUTE_TOLERANCE
            + FILTER_IMAGE_RELATIVE_TOLERANCE * math::abs(expected[channel]),
            "Scene-linear image filter differs from the independent area-box reference.");
    }
}

fn void check_filter_images(FilterImageResources* images, transparency_fixtures::BackdropPattern pattern) @private {
    transparency_fixtures::ColorImage[FILTER_IMAGE_LEVEL_CAPACITY] reference;
    defer foreach (image : reference) free(image.pixels.ptr);
    foreach (level, image : images.levels[:images.level_count]) {
        reference[level] = {
            .width = image.width,
            .height = image.height,
            .pixels = mem::new_array(transparency_fixtures::Color, (usz)image.width * image.height),
        };
        if (level == 0) {
            transparency_fixtures::fill_backdrop(reference[level], pattern);
        } else {
            transparency_fixtures::reduce_area_box(reference[level - 1], reference[level]);
        }
        ushort* actual = (ushort*)(images.output.bytes.ptr + images.readback_offsets[level]);
        foreach (pixel, color : reference[level].pixels) {
            for (uint channel = 0; channel < 3; channel++) {
                double decoded = filter_half_value(actual[4 * pixel + channel]);
                assert(math::abs(decoded - color[channel]) <= FILTER_IMAGE_ABSOLUTE_TOLERANCE
                    + FILTER_IMAGE_RELATIVE_TOLERANCE * math::abs(color[channel]),
                    "An area-box mip texel changed its scene-linear footprint.");
            }
        }
    }
    uint sample;
    Vec4* smooth = (Vec4*)(images.output.bytes.ptr + images.sample_offset
        + FILTER_IMAGE_SAMPLE_COUNT * images.sample_bytes);
    foreach (roughness : transparency_fixtures::ROUGHNESS_VALUES) {
        foreach (ior : transparency_fixtures::IOR_VALUES) {
            double lod = transparency_fixtures::rough_transmission_lod(
                width: reference[0].width,
                height: reference[0].height,
                roughness: roughness,
                ior: ior,
            );
            uint low = (uint)math::floor(lod);
            uint high = math::min(low + 1, images.level_count - 1);
            double fraction = lod - low;
            Vec4* actual = (Vec4*)(images.output.bytes.ptr + images.sample_offset + sample * images.sample_bytes);
            for (uint y = 0; y < reference[0].height; y++) {
                for (uint x = 0; x < reference[0].width; x++) {
                    usz pixel = (usz)y * reference[0].width + x;
                    FilterUv uv = { ((double)x + 0.5) / reference[0].width, ((double)y + 0.5) / reference[0].height };
                    transparency_fixtures::Color expected = filter_bilinear(reference[low], uv) * (1 - fraction)
                      + filter_bilinear(reference[high], uv) * fraction;
                    check_filter_image_color(actual[pixel], expected);
                    assert(math::abs((double)actual[pixel].w - lod) <= FILTER_FOG_ABSOLUTE_TOLERANCE
                        + FILTER_FOG_RELATIVE_TOLERANCE * math::abs(lod));
                    if (roughness == 0) {
                        for (uint channel = 0; channel < 3; channel++) {
                            assert(bitcast(actual[pixel][channel], uint) == bitcast(smooth[pixel][channel], uint),
                                "Roughness zero changed the existing scene_color_at sample bits.");
                        }
                    }
                }
            }
            sample++;
        }
    }
    Vec4* anchored = (Vec4*)(images.output.bytes.ptr + images.sample_offset
        + (FILTER_IMAGE_SAMPLE_COUNT + 1) * images.sample_bytes);
    Vec4* sorted = (Vec4*)(images.output.bytes.ptr + images.sample_offset
        + (FILTER_IMAGE_SAMPLE_COUNT + 2) * images.sample_bytes);
    transparency_fixtures::Color filtered = reference[images.level_count - 1].pixels[0];
    for (uint y = 0; y < reference[0].height; y++) {
        for (uint x = 0; x < reference[0].width; x++) {
            usz pixel = (usz)y * reference[0].width + x;
            double depth = x < reference[0].width / 2 ? 1 : 2;
            check_filter_image_color(anchored[pixel], filtered * math::exp(-(depth - 0.5)));
            check_filter_image_color(sorted[pixel], filtered * math::exp(-(depth - 0.5)));
            for (uint channel = 0; channel < 3; channel++) {
                assert(math::abs((double)sorted[pixel][channel] - anchored[pixel][channel])
                    <= FILTER_FOG_ABSOLUTE_TOLERANCE
                    + FILTER_FOG_RELATIVE_TOLERANCE * math::abs((double)sorted[pixel][channel]),
                    "One-layer homogeneous LAYERED changed the SORTED fog_behind representative transfer.");
            }
            assert(anchored[pixel].w == depth, "Representative depth was filtered across the silhouette.");
        }
    }
    io::printfn(
        "transparency filter %sx%s pattern=%s levels=%s samples=%s smooth=bit_identical",
        reference[0].width,
        reference[0].height,
        pattern,
        images.level_count,
        sample,
    );
    transparency_fixtures::Color exact_edge_sum;
    foreach (pixel, raw : reference[0].pixels) {
        uint x = (uint)(pixel % reference[0].width);
        double depth = x < reference[0].width / 2 ? 1 : 2;
        exact_edge_sum += raw * math::exp(-(depth - 0.5));
    }
    exact_edge_sum /= (double)reference[0].pixels.len;
    io::printfn(
        "transparency rough_depth_edge pattern=%s exact_cpu=%s representative_near=%s representative_far=%s",
        pattern,
        exact_edge_sum,
        filtered * math::exp(-0.5),
        filtered * math::exp(-1.5),
    );
}

fn void test_transparency_filter_fog_area_box_and_representative_depth_match_the_double_reference() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FilterExtent[2] extents = {{ 256, 128 }, { 257, 129 }};
    transparency_fixtures::BackdropPattern[6] patterns = {
        transparency_fixtures::BackdropPattern.BLACK,
        transparency_fixtures::BackdropPattern.BLUE,
        transparency_fixtures::BackdropPattern.HDR,
        transparency_fixtures::BackdropPattern.IMPULSE,
        transparency_fixtures::BackdropPattern.CHECKER,
        transparency_fixtures::BackdropPattern.STEP,
    };
    foreach (extent : extents) {
        FilterImageResources images;
        create_filter_images(&fixture.renderer, &images, extent)!!;
        defer destroy_filter_images(&fixture.renderer, &images);
        foreach (pattern : patterns) {
            run_filter_images(&fixture.renderer, &images, pattern)!!;
            check_filter_images(&images, pattern);
        }
    }
    double representative = math::exp(-0.5);
    double exact_sum = 0.5 * (math::exp(-0.5) + math::exp(-1.5));
    assert(math::abs(representative - 0.6065306597126334) <= 1e-10);
    assert(math::abs(exact_sum - 0.4148304099305316) <= 1e-10);
    io::printfn("transparency fog depth_edge exact_sum=%s representative=%s characterization_only",
        exact_sum, representative);
    check_validation(&fixture.renderer);
}

fn Target? create_filter_fog_table(Renderer* renderer, uint depth) @private {
    gpu::TextureDesc desc = {
        .width = 1,
        .height = 1,
        .depth = depth,
        .format = gpu::Format.RGBA32_FLOAT,
        .usage = { .sampled, .transfer_dst },
        .access = { .graphics },
        .debug_name = "transparency_cumulative_fog_table",
    };
    Target table = { .format = desc.format, .width = 1, .height = 1, .depth = depth };
    table.texture = gpu::create_texture(&renderer.device, &desc)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, table.texture);
    table.view = gpu::create_texture_view(&renderer.device, table.texture, null)!;
    return table;
}

fn void destroy_filter_fog_tables(Renderer* renderer, FilterFogTables* tables) @private {
    render::wait_frames(renderer)!!;
    Target*[3] targets = { &tables.volume, &tables.aerial, &tables.sky_view };
    foreach (target : targets) {
        if (!target.texture.is_valid()) continue;
        gpu::destroy_texture_view(&renderer.device, target.view)!!;
        gpu::destroy_texture(&renderer.device, target.texture)!!;
    }
}

fn void? upload_filter_fog_table(Renderer* renderer, Target* target, Vec4[] pixels) @private {
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan upload = frame.upload.take(&renderer.device, pixels.len * Vec4::size)!;
    mem::copy(upload.bytes.ptr, pixels.ptr, (sz)(pixels.len * Vec4::size));
    target.transition(&renderer.commands, {
        .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
        .stages = { .transfer },
        .access = { .write },
    })!;
    gpu::BufferTextureCopyDesc copy = { .src = upload.span, .texture = target.texture };
    gpu::cmd_copy_buffer_to_texture(&renderer.commands, &copy)!;
    target.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
}

fn FilterFogTerms filter_table_expected(double distance, bool aerial) @private {
    uint count = aerial ? shader::AERIAL_PERSPECTIVE_SIZE : shader::FOG_VOLUME_SLICES;
    double fractional_boundary = math::sqrt(distance / FILTER_FOG_TABLE_DISTANCE) * count;
    double coordinate = aerial ? fractional_boundary - 0.5 : math::max(fractional_boundary, 1.0) - 1;
    int low = (int)math::floor(coordinate);
    double fraction = coordinate - low;
    double attenuation;
    for (int side = 0; side < 2; side++) {
        int index = math::clamp(low + side, 0, (int)count - 1);
        double share = ((double)index + (aerial ? 0.5 : 1)) / count;
        double sample_distance = share * share * FILTER_FOG_TABLE_DISTANCE;
        double sigma = aerial ? FILTER_FOG_TABLE_AERIAL_EXTINCTION : FILTER_FOG_TABLE_HEIGHT_EXTINCTION;
        attenuation += math::exp(-sigma * sample_distance) * (side ? fraction : 1 - fraction);
    }
    double weight = aerial ? math::min(1.0, fractional_boundary * fractional_boundary * 4)
      : math::min(1.0, fractional_boundary);
    double[<3>] color = aerial ? (double[<3>]){ 0.7, 0.3, 0.05 } : (double[<3>]){ 0.1, 0.2, 0.4 };
    attenuation = 1 - (1 - attenuation) * weight;
    if (!aerial && distance > FILTER_FOG_TABLE_DISTANCE) {
        attenuation *= math::exp(-FILTER_FOG_TABLE_HEIGHT_EXTINCTION * (distance - FILTER_FOG_TABLE_DISTANCE));
    }
    return { .attenuation = { attenuation, attenuation, attenuation }, .scattering = color * (1 - attenuation) };
}

fn FilterFogTerms filter_lookup_expected(double distance, uint mode, double clip_start = 0) @private {
    FilterFogTerms height = { .attenuation = { 1, 1, 1 } };
    FilterFogTerms aerial = { .attenuation = { 1, 1, 1 } };
    if (mode == 0 || mode == 2) height = filter_table_expected(distance, false);
    if (mode == 1 || mode == 2) aerial = filter_table_expected(distance, true);
    if (clip_start > 0) {
        if (mode == 0 || mode == 2) {
            FilterFogTerms clipped = filter_table_expected(clip_start, false);
            height.attenuation /= clipped.attenuation;
            height.scattering = (height.scattering - clipped.scattering) / clipped.attenuation;
        }
        if (mode == 1 || mode == 2) {
            FilterFogTerms clipped = filter_table_expected(clip_start, true);
            aerial.attenuation /= clipped.attenuation;
            aerial.scattering = (aerial.scattering - clipped.scattering) / clipped.attenuation;
        }
    }
    return {
        .attenuation = height.attenuation * aerial.attenuation,
        .scattering = height.scattering + height.attenuation * aerial.scattering,
    };
}

fn void test_transparency_filter_fog_real_froxel_and_aerial_tables_keep_cumulative_cuts() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    FilterFogTables tables;
    defer destroy_filter_fog_tables(renderer, &tables);
    tables.volume = create_filter_fog_table(renderer, shader::FOG_VOLUME_SLICES)!!;
    tables.aerial = create_filter_fog_table(renderer, shader::AERIAL_PERSPECTIVE_SIZE)!!;
    tables.sky_view = create_filter_fog_table(renderer, 0)!!;
    gpu::SamplerDesc sampler = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
        .debug_name = "transparency_fog_table_sampler",
    };
    tables.sampler = gpu::intern_sampler(&renderer.device, &sampler)!!;
    gpu::PipelineHandle pipeline = create_filter_fog_pipeline(
        renderer: renderer,
        source: (String)FILTER_FOG_SOURCE[..],
        name: "transparency_fog_volume_connections",
    )!!;
    defer gpu::destroy_pipeline(&renderer.device, pipeline)!!;
    const uint CASE_COUNT = 12;
    gpu::AllocationDesc allocation = {
        .size = CASE_COUNT * FILTER_FOG_OUTPUT_ROWS * Vec4::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "transparency_fog_table_readback",
    };
    gpu::MappedGpuSpan output = gpu::allocate_mapped_memory(&renderer.device, &allocation)!!;
    defer {
        gpu::GpuAllocation owned = output.span.allocation();
        gpu::free_allocation(&renderer.device, &owned)!!;
    }
    Vec4[shader::FOG_VOLUME_SLICES] volume_pixels;
    foreach (index, &pixel : volume_pixels) {
        double share = (double)(index + 1) / volume_pixels.len;
        double attenuation = math::exp(-FILTER_FOG_TABLE_HEIGHT_EXTINCTION
            * share * share * FILTER_FOG_TABLE_DISTANCE);
        *pixel = { (float)(0.1 * (1 - attenuation)), (float)(0.2 * (1 - attenuation)),
            (float)(0.4 * (1 - attenuation)), (float)attenuation };
    }
    Vec4[shader::AERIAL_PERSPECTIVE_SIZE] aerial_pixels;
    foreach (index, &pixel : aerial_pixels) {
        double share = ((double)index + 0.5) / aerial_pixels.len;
        double attenuation = math::exp(-FILTER_FOG_TABLE_AERIAL_EXTINCTION
            * share * share * FILTER_FOG_TABLE_DISTANCE);
        *pixel = { (float)(0.7 * (1 - attenuation)), (float)(0.3 * (1 - attenuation)),
            (float)(0.05 * (1 - attenuation)), (float)(1 - attenuation) };
    }
    Vec4[1] sky_pixels = {{ 1, 1, 1, 1 }};
    renderer.begin_frame()!!;
    upload_filter_fog_table(renderer, &tables.volume, volume_pixels[..])!!;
    upload_filter_fog_table(renderer, &tables.aerial, aerial_pixels[..])!!;
    upload_filter_fog_table(renderer, &tables.sky_view, sky_pixels[..])!!;
    FrameRoot frame_root = { .ambient = { 1, 1, 1, 0 } };
    gpu::GpuAddress frame_address = upload_filter_fog(renderer, ((char*)&frame_root)[:FrameRoot::size])!!;
    FilterFogInput[CASE_COUNT] inputs;
    foreach (index, &input : inputs) {
        uint mode = (uint)index % 3;
        SkyFogGpu sky = {
            .fog_albedo_density = { 0.1f, 0.2f, 0.4f, (float)FILTER_FOG_TABLE_HEIGHT_EXTINCTION },
            .sun_illuminance = { 1, 1, 1, 0 },
            .sun_direction_cos_radius = { 0, 1, 0, 0 },
            .planet_radius = 6371,
            .camera_altitude = 1,
            .fog_max_distance = FILTER_FOG_TABLE_DISTANCE,
            .aerial_perspective_distance = FILTER_FOG_TABLE_DISTANCE,
            .lut_sampler = tables.sampler,
            .sky_view_lut = tables.sky_view.view.index,
        };
        if (mode != 1) {
            sky.flags |= shader::SKY_FOG_HEIGHT_FOG;
            sky.fog_volume = tables.volume.view.index;
        }
        if (mode != 0) {
            sky.flags |= shader::SKY_FOG_ATMOSPHERE;
            sky.aerial_perspective_lut = tables.aerial.view.index;
        }
        *input = {
            .frame = frame_address,
            .sky = upload_filter_fog(renderer, ((char*)&sky)[:SkyFogGpu::size])!!,
            .distances = { 0.5f, 1, 4, 0 },
            .radiance_coverage = { 0.8f, 0.6f, 0.4f, 0.375f },
            .emission = { 0.25f, 0.5f, 1, 0 },
            .direction = { 0, 0, -1, 1 },
        };
        if (index >= 3 && index < 6) input.distances = { 1e-5f, 1e-4f, 0.5f, 0 };
        if (index >= 6 && index < 9) input.distances = { 4, 8, 12, 0 };
        if (index >= 9) input.distances = { 1, 2, 4, 0.5f };
    }
    FilterFogRoot root = {
        .input_address = upload_filter_fog(renderer, ((char*)&inputs)[:FilterFogInput::size * inputs.len])!!,
        .output_address = output.address,
        .count = CASE_COUNT,
    };
    gpu::GpuAddress address = upload_filter_fog(renderer, ((char*)&root)[:FilterFogRoot::size])!!;
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!!;
    gpu::cmd_dispatch(&renderer.commands, address, { CASE_COUNT, 1, 1 })!!;
    gpu::Barrier host = { .before = { .compute }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!!;
    renderer.work_recorded = true;
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;
    gpu::invalidate_mapped_span(&renderer.device, output.span)!!;
    Vec4* rows = (Vec4*)output.bytes.ptr;
    foreach (index, input : inputs) {
        uint mode = (uint)index % 3;
        Vec4* actual = &rows[index * FILTER_FOG_OUTPUT_ROWS];
        FilterFogTerms near_terms = filter_lookup_expected(input.distances.x, mode, input.distances.w);
        FilterFogTerms far_terms = filter_lookup_expected(input.distances.z, mode, input.distances.w);
        double[<3>] raw = { input.radiance_coverage.x, input.radiance_coverage.y, input.radiance_coverage.z };
        double[<3>] expected = far_terms.attenuation * raw + far_terms.scattering;
        check_filter_fog_color(actual[0], near_terms.attenuation);
        check_filter_fog_color(actual[1], near_terms.scattering);
        check_filter_fog_color(actual[2], far_terms.attenuation);
        check_filter_fog_color(actual[3], far_terms.scattering);
        check_filter_fog_color(actual[4], expected);
        check_filter_fog_color(actual[5], expected);
        check_filter_fog_color(actual[15], expected);
        double coverage = input.radiance_coverage.w;
        double[<3>] emission = { input.emission.x, input.emission.y, input.emission.z };
        double[<3>] over = coverage * (near_terms.attenuation * emission + near_terms.scattering)
          + (1 - coverage) * expected;
        double[<3>] additive = expected + coverage * near_terms.attenuation * emission;
        check_filter_fog_color(actual[6], over);
        check_filter_fog_color(actual[7], over);
        check_filter_fog_color(actual[8], additive);
        check_filter_fog_color(actual[9], additive);
        double[<3>] background = mode == 1 ? raw : (double[<3>]){ 0.1, 0.2, 0.4 };
        check_filter_fog_color(actual[12], background);
    }
    io::printfn("transparency real_tables cases=%s froxel_slices=%s aerial_slices=%s neutral=cpu_equal",
        CASE_COUNT, shader::FOG_VOLUME_SLICES, shader::AERIAL_PERSPECTIVE_SIZE);
    check_validation(renderer);
}
