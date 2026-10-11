module c3d::render::acceptance;

import c3d::light;
import c3d::render @public;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::math;
import std::math::vector;
import std::io;
import std::hash::sha256;
import std::encoding::hex;

const char[*] TRACE_SEGMENT_SOURCE @private = $embed("trace_segment.comp.glsl");
const uint TRACE_SEGMENT_ROWS @private = 8; // Mirrored by trace_segment.comp.glsl's output stride.
const uint TRACE_SEGMENT_TRANSMITTANCE_WIDTH @private = shader::SKY_TRANSMITTANCE_WIDTH;
const uint TRACE_SEGMENT_TRANSMITTANCE_HEIGHT @private = shader::SKY_TRANSMITTANCE_HEIGHT;
const uint TRACE_SEGMENT_MULTIPLE_SIZE @private = shader::SKY_MULTI_SCATTERING_SIZE;
const uint TRACE_SEGMENT_REFERENCE_LOW @private = 2048;
const uint TRACE_SEGMENT_REFERENCE_HIGH @private = 4096;
const uint TRACE_SEGMENT_CASE_CAPACITY @private = 1536;
const uint TRACE_SEGMENT_CASE_COUNT @private = 2854;
const double TRACE_SEGMENT_ATMOSPHERE_ABSOLUTE @private = 0.0005;
const double TRACE_SEGMENT_ATMOSPHERE_RELATIVE @private = 0.01;
const double TRACE_SEGMENT_HEIGHT_ABSOLUTE @private = 2e-5;
const double TRACE_SEGMENT_HEIGHT_RELATIVE @private = 2e-4;
const double TRACE_SEGMENT_HDR_ABSOLUTE @private = 0.003;
const double TRACE_SEGMENT_HDR_RELATIVE @private = 0.005;
const Vec3[3] TRACE_SEGMENT_ORIGINS @private = { { 0, 0, 0 }, { 2, 3, -1 }, { 0, 1, 6 } };
const float[9] TRACE_SEGMENT_LENGTHS @private = { 0, 1, 2, 4, 10, 100, 1000, 10000, 100000 };
const ZString[9] TRACE_SEGMENT_QUANTITIES @private = {
    "atmosphere_T", "atmosphere_S", "height_T", "height_S", "combined_T", "combined_S",
    "float_color", "additive", "half_color",
};

struct TraceSegmentCase @private {
    Vec3 origin;
    Vec3 direction;
    Vec3 sun;
    float distance;
    float density;
    float falloff;
    float base_height;
    float camera_altitude;
    float exposure;
    float radiance_scale;
    bool height;
    bool atmosphere;
    bool quotient;
}

struct TraceSegmentInput @private {
    gpu::GpuAddress frame;
    gpu::GpuAddress sky;
    Vec4 origin_length;
    Vec4 direction;
    Vec4 radiance;
    Vec4 emission;
}
$assert TraceSegmentInput::size == 80;
$assert $reflect(TraceSegmentInput.origin_length).offset == 16;
$assert $reflect(TraceSegmentInput.emission).offset == 64;

struct TraceSegmentRoot @private {
    gpu::GpuAddress inputs;
    gpu::GpuAddress outputs;
    gpu::TextureIndex output_image;
    uint count;
    uint[2] padding;
}
$assert TraceSegmentRoot::size == 32;
$assert $reflect(TraceSegmentRoot.output_image).offset == 16;

struct TraceSegmentTextures @private {
    Target transmittance;
    Target multiple;
    Target sky_view;
    gpu::SamplerIndex sampler;
}

fn gpu::GpuAddress? upload_trace_segment(Renderer* renderer, char[] bytes) @private {
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan upload = frame.upload.take(&renderer.device, bytes.len, render::STREAM_ALIGNMENT)!;
    mem::copy(upload.bytes.ptr, bytes.ptr, (sz)bytes.len);
    return upload.address;
}

fn gpu::PipelineHandle? create_trace_segment_pipeline(Renderer* renderer) @private {
    String log;
    char[]? compiled = compile::compile_glsl(
        allocator: mem,
        source: (String)TRACE_SEGMENT_SOURCE[..],
        stage: ShaderStage.COMPUTE,
        defines: {},
        debug_name: "trace_segment",
        log: &log,
    );
    defer free(log.ptr);
    if (catch excuse = compiled) {
        io::eprintfn("World-segment GLSL compilation failed:\n%s", log);
        return excuse~;
    }

    char[] spirv = compiled;
    defer free(spirv.ptr);
    gpu::ComputePipelineDesc desc = { .shader = { .spirv = spirv }, .debug_name = "trace_segment" };
    return gpu::create_compute_pipeline(&renderer.device, &desc);
}

fn Target? create_trace_segment_texture(
    Renderer* renderer,
    uint width,
    uint height,
    ZString name,
) @private {
    gpu::TextureDesc desc = {
        .width = width,
        .height = height,
        .mip_levels = 1,
        .format = gpu::Format.RGBA16_FLOAT,
        .usage = { .sampled, .storage, .transfer_src, .transfer_dst },
        .access = { .graphics },
        .debug_name = name,
    };
    Target target = { .format = desc.format, .width = width, .height = height };
    target.texture = gpu::create_texture(&renderer.device, &desc)!;
    defer catch render::release_storage_target(&renderer.device, &target);
    target.view = gpu::create_texture_view(&renderer.device, target.texture, null)!;
    return target;
}

fn void release_trace_segment_textures(Renderer* renderer, TraceSegmentTextures* textures) @private {
    render::release_storage_target(&renderer.device, &textures.transmittance);
    render::release_storage_target(&renderer.device, &textures.multiple);
    render::release_storage_target(&renderer.device, &textures.sky_view);
}

fn SkyFogGpu trace_segment_sky(Atmosphere atmosphere, TraceSegmentCase entry, TraceSegmentTextures* textures) @private {
    return {
        .sun_direction_cos_radius = { entry.sun.x, entry.sun.y, entry.sun.z, 0 },
        .sun_illuminance = { 1, 1, 1, 0 },
        .rayleigh_scattering_height = {
            atmosphere.rayleigh_scattering.x, atmosphere.rayleigh_scattering.y,
            atmosphere.rayleigh_scattering.z, atmosphere.rayleigh_scale_height,
        },
        .mie = {
            atmosphere.mie_scattering, atmosphere.mie_absorption,
            atmosphere.mie_scale_height, atmosphere.mie_anisotropy,
        },
        .ozone_absorption_center = {
            atmosphere.ozone_absorption.x, atmosphere.ozone_absorption.y,
            atmosphere.ozone_absorption.z, atmosphere.ozone_center_altitude,
        },
        .ground_albedo_ozone_width = {
            atmosphere.ground_albedo.x, atmosphere.ground_albedo.y,
            atmosphere.ground_albedo.z, atmosphere.ozone_half_width,
        },
        .fog_albedo_density = { 0.1f, 0.2f, 0.4f, entry.density },
        .planet_radius = atmosphere.planet_radius,
        .top_radius = atmosphere.planet_radius + atmosphere.atmosphere_height,
        .camera_altitude = entry.camera_altitude,
        .fog_base_height = entry.base_height,
        .fog_falloff = entry.falloff,
        .flags = (entry.height ? shader::SKY_FOG_HEIGHT_FOG : 0)
          | (entry.atmosphere ? shader::SKY_FOG_ATMOSPHERE : 0),
        .transmittance_lut = textures.transmittance.view.index,
        .multi_scattering_lut = textures.multiple.view.index,
        .sky_view_lut = textures.sky_view.view.index,
        .lut_sampler = textures.sampler,
    };
}

fn double trace_segment_half(ushort bits) @private {
    uint exponent = (bits >> 10) & 31;
    double fraction = (double)(bits & 1023);
    if (exponent == 31) return fraction ? double::nan : double::inf;

    double value = exponent ? math::pow(2.0, (double)exponent - 15) * (1 + fraction / 1024)
      : math::pow(2.0, -24.0) * fraction;
    return bits & 32768 ? -value : value;
}

fn TraceSegmentVector[]? read_trace_segment_texture(Renderer* renderer, Target* target) @private {
    usz count = (usz)target.width * target.height;
    gpu::AllocationDesc desc = {
        .size = count * 4 * ushort::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "trace_segment_table_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    defer {
        gpu::GpuAllocation owned = readback.span.allocation();
        gpu::free_allocation(&renderer.device, &owned)!!;
    }

    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::TextureState previous = target.state;
    target.transition(&renderer.commands, render::TRANSFER_SOURCE_STATE)!;
    gpu::TextureBufferCopyDesc copy = {
        .texture = target.texture,
        .dst = readback.span,
        .width = target.width,
        .height = target.height,
    };
    gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    target.transition(&renderer.commands, previous)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;

    char[32] digest = sha256::hash(readback.bytes);
    char[64] encoded_hash;
    io::printfn("world segment frozen texture=%sx%s sha256=%s",
        target.width, target.height, hex::encode_into(encoded_hash[..], digest[..]));

    ushort* encoded = (ushort*)readback.bytes.ptr;
    TraceSegmentVector[] values = mem::new_array(TraceSegmentVector, (sz)count);
    foreach (pixel, &value : values) {
        for (uint channel = 0; channel < 3; channel++) {
            (*value)[channel] = trace_segment_half(encoded[4 * pixel + channel]);
        }
    }
    return values;
}

fn void? generate_trace_segment_tables(
    Renderer* renderer,
    Atmosphere atmosphere,
    TraceSegmentTextures* textures,
) @private {
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    TraceSegmentCase entry = { .sun = { 0, 1, 0 }, .atmosphere = true };
    SkyFogGpu sky = trace_segment_sky(atmosphere, entry, textures);
    gpu::GpuAddress address = upload_trace_segment(renderer, ((char*)&sky)[:SkyFogGpu::size])!;
    render::record_sky_table(
        renderer: renderer,
        commands: &renderer.commands,
        pipeline: SKY_TRANSMITTANCE,
        handle: &renderer.sky_pipelines.transmittance,
        texture: textures.transmittance.texture,
        view: textures.transmittance.view,
        width: textures.transmittance.width,
        height: textures.transmittance.height,
        sky_fog: address,
        previous: textures.transmittance.state,
    )!;
    textures.transmittance.state = renderer.sampled_state;
    render::record_sky_table(
        renderer: renderer,
        commands: &renderer.commands,
        pipeline: SKY_MULTI_SCATTERING,
        handle: &renderer.sky_pipelines.multi_scattering,
        texture: textures.multiple.texture,
        view: textures.multiple.view,
        width: textures.multiple.width,
        height: textures.multiple.height,
        sky_fog: address,
        previous: textures.multiple.state,
    )!;
    textures.multiple.state = renderer.sampled_state;

    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan white = frame.upload.take(&renderer.device, 4 * ushort::size)!;
    *(ushort[4]*)white.bytes.ptr = { 0x3c00, 0x3c00, 0x3c00, 0x3c00 };
    textures.sky_view.transition(&renderer.commands, {
        .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
        .stages = { .transfer },
        .access = { .write },
    })!;
    gpu::BufferTextureCopyDesc copy = { .src = white.span, .texture = textures.sky_view.texture };
    gpu::cmd_copy_buffer_to_texture(&renderer.commands, &copy)!;
    textures.sky_view.transition(&renderer.commands, renderer.sampled_state)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
}

fn uint fill_trace_segment_cases(TraceSegmentCase[] cases, bool height_cases) @private {
    Vec3[5] directions = {
        { 0, 0, -1 }, ((Vec3){ 1, 0.5f, -1 }).normalize(), ((Vec3){ 1, -0.5f, 0 }).normalize(),
        { 0, 1, 0 }, { 0, -1, 0 },
    };
    uint count;
    foreach (origin : TRACE_SEGMENT_ORIGINS) foreach (direction : directions) {
        foreach (distance : TRACE_SEGMENT_LENGTHS) foreach (sun_y : (float[2]){ 1, -1 }) {
            if (distance == 100000 && direction.y != 0) continue;

            cases[count++] = {
                .origin = origin,
                .direction = direction,
                .sun = { 0, sun_y, 0 },
                .distance = distance,
                .density = 0.125f,
                .falloff = 0.25f,
                .base_height = 2,
                .height = true,
                .atmosphere = true,
                .exposure = 1,
            };
        }
        foreach (density : (float[2]){ 0, 0.125f }) {
            foreach (falloff : (float[2]){ 0, 0.25f }) foreach (base : (float[2]){ 0, 2 }) {
                cases[count++] = {
                    .origin = origin,
                    .direction = direction,
                    .sun = { 0, 1, 0 },
                    .distance = -1,
                    .density = density,
                    .falloff = falloff,
                    .base_height = base,
                    .height = true,
                    .atmosphere = true,
                    .exposure = 1,
                };
                if (!height_cases) continue;

                foreach (distance : TRACE_SEGMENT_LENGTHS) {
                    if (distance == 100000 && direction.y != 0) continue;

                    cases[count++] = {
                        .origin = origin,
                        .direction = direction,
                        .sun = { 0, 1, 0 },
                        .distance = distance,
                        .density = density,
                        .falloff = falloff,
                        .base_height = base,
                        .height = true,
                        .exposure = 1,
                    };
                }
            }
        }
    }
    uint distance_bits = bitcast(0.04f, uint);
    foreach (bits : (uint[3]){ distance_bits - 1, distance_bits, distance_bits + 1 }) {
        cases[count++] = {
            .origin = { 2, 3, -1 },
            .direction = { 0, 1, 0 },
            .sun = { 0, 1, 0 },
            .distance = bitcast(bits, float),
            .density = 0.125f,
            .falloff = 0.25f,
            .base_height = 2,
            .height = true,
            .exposure = 1,
        };
    }
    cases[count++] = { .quotient = true, .exposure = 1 };
    cases[count++] = {
        .origin = { 2, 3, -1 },
        .direction = ((Vec3){ 1, 0.5f, -1 }).normalize(),
        .sun = { 0, 1, 0 },
        .distance = 4,
        .density = 0.125f,
        .falloff = 0.25f,
        .base_height = 2,
        .height = true,
        .atmosphere = true,
        .radiance_scale = 1024,
        .exposure = 1,
    };
    foreach (exposure : (float[3]){ 0.25f, 1, 4 }) {
        cases[count++] = {
            .origin = { 2, 3, -1 },
            .direction = ((Vec3){ 1, 0.5f, -1 }).normalize(),
            .sun = { 0, 1, 0 },
            .distance = 4,
            .density = 0.125f,
            .falloff = 0.25f,
            .base_height = 2,
            .camera_altitude = exposure * 1000,
            .height = true,
            .atmosphere = true,
            .exposure = exposure,
        };
    }
    return count;
}

fn bool trace_segment_component_matches(
    uint variant,
    uint row,
    ZString quantity,
    Vec4 actual,
    TraceSegmentVector expected,
    double absolute,
    double relative,
    bool finite_only,
) @private {
    uint worst_channel;
    double worst_ratio = -1;
    double worst_error;
    double worst_bound;
    bool actual_finite = true;
    bool reference_finite = true;
    for (uint channel = 0; channel < 3; channel++) {
        bool finite_actual = math::is_finite(actual[channel]);
        bool finite_reference = math::is_finite(expected[channel]);
        double error = math::abs((double)actual[channel] - expected[channel]);
        double bound = absolute + relative * math::abs(expected[channel]);
        double ratio = finite_actual && finite_reference ? error / bound : double::inf;
        actual_finite &= finite_actual;
        reference_finite &= finite_reference;
        if (ratio > worst_ratio) {
            worst_ratio = ratio;
            worst_channel = channel;
            worst_error = error;
            worst_bound = bound;
        }
    }
    bool matches = actual_finite && (finite_only || (reference_finite && worst_ratio <= 1));
    if (!matches) {
        io::printfn("segment_error,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
            variant,
            row,
            quantity,
            worst_channel,
            actual[worst_channel],
            expected[worst_channel],
            worst_error,
            worst_bound,
            actual_finite,
            reference_finite,
        );
    }
    return matches;
}

fn void test_trace_segment_world_connections_match_converged_tables_and_height_limits() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    gpu::PipelineHandle pipeline = create_trace_segment_pipeline(renderer)!!;
    defer gpu::destroy_pipeline(&renderer.device, pipeline)!!;
    TraceSegmentTextures textures;
    defer release_trace_segment_textures(renderer, &textures);
    textures.transmittance = create_trace_segment_texture(
        renderer: renderer,
        width: TRACE_SEGMENT_TRANSMITTANCE_WIDTH,
        height: TRACE_SEGMENT_TRANSMITTANCE_HEIGHT,
        name: "trace_segment_transmittance",
    )!!;
    textures.multiple = create_trace_segment_texture(
        renderer: renderer,
        width: TRACE_SEGMENT_MULTIPLE_SIZE,
        height: TRACE_SEGMENT_MULTIPLE_SIZE,
        name: "trace_segment_multiple",
    )!!;
    textures.sky_view = create_trace_segment_texture(
        renderer: renderer,
        width: 1,
        height: 1,
        name: "trace_segment_height_source",
    )!!;
    gpu::SamplerDesc sampler = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .debug_name = "trace_segment_tables",
    };
    textures.sampler = gpu::intern_sampler(&renderer.device, &sampler)!!;
    TraceSegmentCase[] cases = mem::new_array(TraceSegmentCase, TRACE_SEGMENT_CASE_CAPACITY);
    defer free(cases);
    TraceSegmentInput[] inputs = mem::new_array(TraceSegmentInput, TRACE_SEGMENT_CASE_CAPACITY);
    defer free(inputs);
    uint mismatches;
    uint unconverged;
    usz checked;
    double max_convergence;
    double max_atmosphere_error;
    io::printfn("segment_error,variant,row,quantity,channel,actual,ref,error,bound,finite,ref_finite");
    for (uint variant = 0; variant < 5; variant++) {
        Atmosphere atmosphere = light::ATMOSPHERE_EARTH;
        switch (variant) {
            case 0:
                atmosphere = light::ATMOSPHERE_EARTH;
            case 1:
                atmosphere.mie_scattering = atmosphere.mie_absorption = 0;
                atmosphere.ozone_absorption = {};
            case 2:
                atmosphere.rayleigh_scattering = {};
                atmosphere.ozone_absorption = {};
            case 3:
                atmosphere.ozone_absorption = {};
            case 4:
                atmosphere.rayleigh_scattering = atmosphere.ozone_absorption = {};
                atmosphere.mie_scattering = atmosphere.mie_absorption = 0;
        }
        generate_trace_segment_tables(renderer, atmosphere, &textures)!!;
        TraceSegmentTableData tables = {
            .transmittance = read_trace_segment_texture(renderer, &textures.transmittance)!!,
            .multiple = read_trace_segment_texture(renderer, &textures.multiple)!!,
        };
        defer free(tables.transmittance);
        defer free(tables.multiple);
        uint count = fill_trace_segment_cases(cases, variant == 0);
        assert(count <= cases.len);
        Target colors = create_trace_segment_texture(
            renderer: renderer,
            width: count,
            height: 1,
            name: "trace_segment_color",
        )!!;
        defer render::release_storage_target(&renderer.device, &colors);
        gpu::AllocationDesc allocation = {
            .size = (usz)count * TRACE_SEGMENT_ROWS * Vec4::size,
            .alignment = 16,
            .memory_class = gpu::MemoryClass.CPU_READ,
            .access = { .graphics },
            .debug_name = "trace_segment_readback",
        };
        gpu::MappedGpuSpan output = gpu::allocate_mapped_memory(&renderer.device, &allocation)!!;
        defer {
            gpu::GpuAllocation owned = output.span.allocation();
            gpu::free_allocation(&renderer.device, &owned)!!;
        }
        renderer.begin_frame()!!;
        foreach (index, entry : cases[:count]) {
            SkyFogGpu sky = trace_segment_sky(atmosphere, entry, &textures);
            FrameRoot frame = { .ambient = { 1, 1, 1, 0 }, .camera_position = { 0, 20, 30, entry.exposure } };
            frame.sky_fog = upload_trace_segment(renderer, ((char*)&sky)[:SkyFogGpu::size])!!;
            float radiance_scale = entry.radiance_scale > 0 ? entry.radiance_scale : 1;
            inputs[index] = {
                .frame = upload_trace_segment(renderer, ((char*)&frame)[:FrameRoot::size])!!,
                .sky = frame.sky_fog,
                .origin_length = { entry.origin.x, entry.origin.y, entry.origin.z, entry.distance },
                .direction = { entry.direction.x, entry.direction.y, entry.direction.z, entry.quotient ? 2 : 0 },
                .radiance = { 0.8f * radiance_scale, 0.6f * radiance_scale, 0.4f * radiance_scale, entry.exposure },
                .emission = { 0.25f, 0.5f, 1, 0 },
            };
        }
        colors.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!!;
        TraceSegmentRoot root = {
            .inputs = upload_trace_segment(renderer, ((char*)inputs.ptr)[:count * TraceSegmentInput::size])!!,
            .outputs = output.address,
            .output_image = colors.view.index,
            .count = count,
        };
        gpu::GpuAddress address = upload_trace_segment(renderer, ((char*)&root)[:TraceSegmentRoot::size])!!;
        gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!!;
        gpu::cmd_dispatch(&renderer.commands, address, { count, 1, 1 })!!;
        gpu::Barrier host = { .before = { .compute }, .after = { .host } };
        gpu::cmd_barrier(&renderer.commands, &host)!!;
        renderer.work_recorded = true;
        renderer.end_frame()!!;
        render::wait_frames(renderer)!!;
        gpu::invalidate_mapped_span(&renderer.device, output.span)!!;
        TraceSegmentVector[] actual_color = read_trace_segment_texture(renderer, &colors)!!;
        defer free(actual_color);
        Vec4* rows = (Vec4*)output.bytes.ptr;
        foreach (index, entry : cases[:count]) {
            TraceSegmentTerms low = trace_segment_atmosphere_reference(
                entry: entry,
                atmosphere: atmosphere,
                tables: &tables,
                steps: TRACE_SEGMENT_REFERENCE_LOW,
            );
            TraceSegmentTerms high = trace_segment_atmosphere_reference(
                entry: entry,
                atmosphere: atmosphere,
                tables: &tables,
                steps: TRACE_SEGMENT_REFERENCE_HIGH,
            );
            TraceSegmentTerms height = trace_segment_height_reference(entry);
            TraceSegmentTerms combined = {
                .transmittance = height.transmittance * high.transmittance,
                .scattering = height.scattering + height.transmittance * high.scattering,
            };
            double radiance_scale = entry.radiance_scale > 0 ? entry.radiance_scale : 1;
            TraceSegmentVector reference_color = combined.transmittance
              * (TraceSegmentVector){ 0.8, 0.6, 0.4 } * radiance_scale
              + combined.scattering;
            TraceSegmentVector reference_additive = combined.transmittance * (TraceSegmentVector){ 0.25, 0.5, 1 };
            Vec4* actual = &rows[index * TRACE_SEGMENT_ROWS];
            for (uint channel = 0; channel < 3; channel++) {
                double transmittance_change = math::abs(high.transmittance[channel] - low.transmittance[channel]);
                double scattering_change = math::abs(high.scattering[channel] - low.scattering[channel]);
                max_convergence = math::max(max_convergence, math::max(transmittance_change, scattering_change));
                double attenuation_bound = TRACE_SEGMENT_ATMOSPHERE_ABSOLUTE
                  + TRACE_SEGMENT_ATMOSPHERE_RELATIVE * math::abs(high.transmittance[channel]);
                double scattering_bound = TRACE_SEGMENT_ATMOSPHERE_ABSOLUTE
                  + TRACE_SEGMENT_ATMOSPHERE_RELATIVE * math::abs(high.scattering[channel]);
                if (transmittance_change > attenuation_bound / 4 || scattering_change > scattering_bound / 4) {
                    unconverged++;
                }
                if (!entry.quotient) {
                    double error = math::max(math::abs((double)actual[0][channel] - high.transmittance[channel]),
                        math::abs((double)actual[1][channel] - high.scattering[channel]));
                    max_atmosphere_error = math::max(max_atmosphere_error, error);
                }
            }
            TraceSegmentVector[9] expected_values = {
                high.transmittance, high.scattering, height.transmittance, height.scattering,
                combined.transmittance, combined.scattering, reference_color, reference_additive, reference_color,
            };
            Vec4[9] actual_values = {
                actual[0], actual[1], actual[2], actual[3], actual[4], actual[5], actual[6], actual[7],
                { (float)actual_color[index].x, (float)actual_color[index].y, (float)actual_color[index].z, 1 },
            };
            double[9] absolute_bounds = {
                TRACE_SEGMENT_ATMOSPHERE_ABSOLUTE, TRACE_SEGMENT_ATMOSPHERE_ABSOLUTE,
                TRACE_SEGMENT_HEIGHT_ABSOLUTE, TRACE_SEGMENT_HEIGHT_ABSOLUTE,
                TRACE_SEGMENT_ATMOSPHERE_ABSOLUTE, TRACE_SEGMENT_ATMOSPHERE_ABSOLUTE,
                TRACE_SEGMENT_HDR_ABSOLUTE, TRACE_SEGMENT_HDR_ABSOLUTE, TRACE_SEGMENT_HDR_ABSOLUTE,
            };
            double[9] relative_bounds = {
                TRACE_SEGMENT_ATMOSPHERE_RELATIVE, TRACE_SEGMENT_ATMOSPHERE_RELATIVE,
                TRACE_SEGMENT_HEIGHT_RELATIVE, TRACE_SEGMENT_HEIGHT_RELATIVE,
                TRACE_SEGMENT_ATMOSPHERE_RELATIVE, TRACE_SEGMENT_ATMOSPHERE_RELATIVE,
                TRACE_SEGMENT_HDR_RELATIVE, TRACE_SEGMENT_HDR_RELATIVE, TRACE_SEGMENT_HDR_RELATIVE,
            };
            bool matches = true;
            foreach (quantity, expected : expected_values) {
                matches &= trace_segment_component_matches(
                    variant: variant,
                    row: (uint)index,
                    quantity: TRACE_SEGMENT_QUANTITIES[quantity],
                    actual: actual_values[quantity],
                    expected: expected,
                    absolute: absolute_bounds[quantity],
                    relative: relative_bounds[quantity],
                    finite_only: entry.quotient,
                );
            }
            if (!matches) {
                io::printfn("segment_origin,%s,%s,%s,%s,%s,%s",
                    variant,
                    index,
                    entry.origin.x,
                    entry.origin.y,
                    entry.origin.z,
                    entry.distance,
                );
                io::printfn("segment_direction,%s,%s,%s,%s,%s,%s,%s,%s",
                    variant,
                    index,
                    entry.direction.x,
                    entry.direction.y,
                    entry.direction.z,
                    entry.sun.x,
                    entry.sun.y,
                    entry.sun.z,
                );
                io::printfn("segment_medium,%s,%s,%s,%s,%s,%s,%s",
                    variant,
                    index,
                    entry.density,
                    entry.falloff,
                    entry.base_height,
                    entry.atmosphere,
                    entry.height,
                );
                mismatches++;
            }
            if (entry.quotient) {
                assert(actual[1].x < 0 && math::is_finite(actual[1].x),
                    "The existing quotient floor clamped signed scattering.");
                io::printfn("world segment floor scattering=%s exact_unfloored=-250000 deviation=%s",
                    actual[1].x, math::abs((double)actual[1].x + 250000));
            }
            checked++;
        }
        for (uint control = count - 2; control < count; control++) {
            for (uint row = 0; row < TRACE_SEGMENT_ROWS; row++) {
                for (uint channel = 0; channel < 4; channel++) {
                    assert(bitcast(rows[control * TRACE_SEGMENT_ROWS + row][channel], uint)
                      == bitcast(rows[(count - 3) * TRACE_SEGMENT_ROWS + row][channel], uint),
                        "Camera altitude or exposure changed raw world-segment output.");
                }
            }
        }
        io::printfn("world segment variant=%s rows=%s converged_delta_max=%s required_native_error_max=%s",
            variant, count, max_convergence, max_atmosphere_error);
    }
    io::printfn("world segment required rows=%s mismatches=%s unconverged=%s reference_steps=%s/%s",
        checked, mismatches, unconverged, TRACE_SEGMENT_REFERENCE_LOW, TRACE_SEGMENT_REFERENCE_HIGH);
    assert(checked == TRACE_SEGMENT_CASE_COUNT, "The world-segment case inventory changed.");
    assert(unconverged == 0, "The independently refined double segment reference did not converge.");
    assert(mismatches == 0, "The approved 64-step world-segment bounds failed.");
    check_validation(renderer);
}

