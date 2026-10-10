module c3d::bench::texture_fidelity;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import gpu;
import std::core::env;
import std::io;
import std::math;
import std::time;
import std::time::clock;

const uint DEFAULT_EXTENT @private = 1024;
const uint DEFAULT_WARMUPS @private = 2;
const uint DEFAULT_RUNS @private = 10;
const usz UPLOAD_BYTES @private = 128 << 20; // Holds all formats' complete chains and model blocks.
const PixelFormat[3] FORMATS @private = { RGBA8_UNORM, RGBA16_FLOAT, RGBA32_FLOAT };
const String TEXTURE_COLUMNS @private = "# texture_columns=record,run,format,semantic,coverage,source_bytes,live_source_bytes,cpu_full_chain_bytes,prepare_output_chain_bytes,state_bytes,result_bytes,add_scan_ns,restore_scan_ns,cpu_chain_ns,advance_ns,submission_wait_ns,generated_texels,progress_texels,staged_bytes";
const String TANGENT_COLUMNS @private = "# tangent_columns=record,run,source_vertices,output_vertices,corners,source_bytes,output_stream_bytes,allocated_output_bytes,remap_bytes,port_split_ns,split_tangent_scratch_bytes";

struct Configuration @private {
    uint extent;
    uint warmups;
    uint runs;
}

struct Measurement @private {
    ulong scan_ns;
    ulong restore_ns;
    ulong generation_ns;
    ulong prepare_ns;
    ulong submission_wait_ns;
    ulong generated_texels;
    ulong progress_texels;
    ulong staged_bytes;
    usz source_bytes;
    usz live_source_bytes;
    usz chain_bytes;
    usz prepare_chain_bytes;
    usz result_bytes;
    usz state_bytes;
}

fn Configuration? parse_configuration(String[] args) @private {
    if (args.len > 4) return c3d::INVALID_ARGUMENT~;

    Configuration configuration = { .extent = DEFAULT_EXTENT, .warmups = DEFAULT_WARMUPS, .runs = DEFAULT_RUNS };
    if (args.len > 1) configuration.extent = args[1].to_uint()!;
    if (args.len > 2) configuration.warmups = args[2].to_uint()!;
    if (args.len > 3) configuration.runs = args[3].to_uint()!;

    if (!configuration.extent || configuration.extent > 2048 || !configuration.runs || configuration.runs > 1000
      || configuration.warmups > 1000) return c3d::INVALID_ARGUMENT~;

    return configuration;
}

fn char[] make_pixels(
    Allocator allocator,
    uint extent,
    PixelFormat format,
    TextureSemantic semantic,
) @private {
    usz texels = (usz)extent * extent;
    char[] pixels = alloc::new_array(allocator, char, (sz)(texels * material::texture_block_bytes(format)));

    for (usz index = 0; index < texels; index++) {
        uint x = (uint)(index % extent);
        uint y = (uint)(index / extent);
        uint hash = x * 0x9e3779b9 ^ y * 0x85ebca6b;
        Vec4 value = {
            0.25f + (float)(hash & 255) / 510,
            0.25f + (float)((hash >> 8) & 255) / 510,
            semantic == TextureSemantic.COLOR ? 0.2f : 0.9f,
            (float)((hash >> 16) & 255) / 255,
        };
        switch (format) {
            case RGBA8_UNORM:
                for (uint channel = 0; channel < 4; channel++) {
                    pixels[index * 4 + channel] = (char)math::round(value[channel] * 255);
                }
            case RGBA16_FLOAT:
                ushort* destination = (ushort*)pixels.ptr;

                for (uint channel = 0; channel < 4; channel++) {
                    destination[index * 4 + channel] = asset::encode_texture_half(value[channel]);
                }
            case RGBA32_FLOAT:
                ((Vec4*)pixels.ptr)[index] = value;
            default: unreachable();
        }
    }

    return pixels;
}

fn ModelId? make_model(AssetStore* assets, TextureId texture) @private {
    TangentGeometry temporary = { .allocator = mem, .data = geometry::box(
        allocator: mem,
        width: 1,
        height: 1,
        depth: 1,
    ) };
    defer geometry::destroy_tangent_geometry(&temporary);

    GeometryId geometry_id = assets.add_geometry(&temporary.data)!;

    MaterialId material_id = assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 }, .map = material::texture_slot(texture, asset::SAMPLER_NEAREST),
    }))!;

    ModelTemplate model = {
        .nodes = alloc::new_array(mem, NodeTemplate, 1),
        .meshes = alloc::new_array(mem, ModelMesh, 1),
    };
    defer catch asset::free_model_template(mem, &model);

    model.nodes[0] = { .parent = -1, .local = maths::TRANSFORM_IDENTITY, .visible = true, .layers = uint::max };
    model.meshes[0] = { .node = 0, .geometry = geometry_id, .material = material_id };

    return assets.add_model_owned(&model);
}

fn Measurement? measure_texture(
    Configuration configuration,
    PixelFormat format,
    TextureSemantic semantic,
    CoveragePolicy coverage,
) @private {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    char[] pixels = make_pixels(
        allocator: mem,
        extent: configuration.extent,
        format: format,
        semantic: semantic,
    );
    defer alloc::free(mem, pixels.ptr);

    material::TextureDesc desc = material::texture_2d_desc(configuration.extent, configuration.extent, format);
    desc.semantic = semantic;
    desc.coverage = coverage;
    desc.alpha_threshold = 0.5;

    Measurement result = { .source_bytes = pixels.len, .state_bytes = TextureCoverageState::size };

    std::time::Clock started = clock::now();
    TextureId texture = assets.add_texture(desc, pixels)!;
    result.scan_ns = (ulong)started.to_now();

    assets.release_texture_cpu(texture);

    char[] restored = ((String)pixels).copy(assets.allocator);

    started = clock::now();
    assets.restore_texture_cpu(texture, restored);
    result.restore_ns = (ulong)started.to_now();
    result.live_source_bytes = pixels.len + assets.texture(texture).pixels.len;
    result.prepare_chain_bytes = render::generated_texture_mip_layout(desc)!.byte_count;

    {
        started = clock::now();
        TextureMipChain chain = render::create_texture_mips(mem, desc, pixels)!;
        defer render::destroy_texture_mips(&chain);

        result.generation_ns = (ulong)started.to_now();
        result.chain_bytes = chain.pixels.len;
    }

    ModelId model = make_model(&assets, texture)!;

    Renderer renderer = render::create_renderer(mem, &assets, {
        .validation = false, .application_name = "texture_fidelity_benchmark", .upload_ring_bytes = UPLOAD_BYTES,
    })!;
    defer render::destroy_renderer(&renderer);

    PrepareId id = renderer.begin_prepare_model(model)!;
    defer renderer.end_prepare(id)!!;

    PrepareRecord* record = renderer.prepares.get(id);

    foreach (&unit : record.units) {
        if (unit.kind == PrepareUnitKind.TEXTURE && c3d::same_id(unit.texture, texture)) {
            usz full_bytes = render::prepare_texture_bytes(&renderer, texture, true);
            record.bytes_total += full_bytes - unit.bytes;
            unit.bytes = full_bytes;
            unit.full_reader = true;
        }
    }

    renderer.begin_frame()!;
    defer catch render::abort_frame(&renderer);

    started = clock::now();
    PrepareReport report = renderer.advance_prepares_within({})!;
    result.prepare_ns = (ulong)started.to_now();
    result.generated_texels = report.generated_texels;
    result.staged_bytes = report.staged_bytes;
    renderer.end_frame()!;

    started = clock::now();
    render::wait_frames(&renderer)!;
    result.submission_wait_ns = (ulong)started.to_now();

    PrepareProgress progress = renderer.prepare_progress(id);
    if (progress.state == PrepareState.FAILED) return progress.failure~;
    if (progress.state != PrepareState.READY || progress.texels_done != progress.texels_total
      || progress.bytes_done != progress.bytes_total) return c3d::INVALID_ARGUMENT~;

    result.progress_texels = progress.texels_total;
    if (coverage == CoveragePolicy.THRESHOLD) {
        TextureCoverageResource* resource = renderer.textures[texture.index].coverage_resource;
        if (resource) {
            result.result_bytes = TextureCoverageResource::size + resource.counts.len * TextureCoverageCounts::size;
        }
    }

    return result;
}

fn void? measure_tangents(uint run, bool measured) @private {
    TangentGeometry temporary = { .allocator = mem, .data = geometry::sphere(
        allocator: mem,
        radius: 1,
        slices: 32,
        stacks: 16,
    ) };
    defer geometry::destroy_tangent_geometry(&temporary);

    Geometry source = temporary.data;

    std::time::Clock started = clock::now();
    TangentGeometry owner = geometry::create_tangent_geometry(mem, &source)!;
    defer geometry::destroy_tangent_geometry(&owner);

    ulong elapsed = (ulong)started.to_now();

    usz source_bytes = source.positions.len * Vec3::size + source.normals.len * Vec3::size
      + source.uv0.len * Vec2::size + source.indices.len * uint::size;
    usz output_bytes = owner.data.positions.len * Vec3::size + owner.data.normals.len * Vec3::size
      + owner.data.tangents.len * Vec4::size + owner.data.uv0.len * Vec2::size + owner.data.indices.len * uint::size;
    usz capacity = math::min((usz)source.positions.len + (usz)source.indices.len, (usz)uint::max);
    usz allocated_output = output_bytes;
    usz split_tangent_scratch = capacity * Vec4::size;
    usz remap_bytes = capacity * 2 * uint::size + source.positions.len * bool::size;

    if (measured) io::printfn("tangent,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d", run, source.positions.len,
        owner.data.positions.len, source.indices.len, source_bytes, output_bytes, allocated_output,
        remap_bytes, elapsed, split_tangent_scratch);
}

fn void? run_benchmark(String[] args) @private {
    Configuration configuration = parse_configuration(args)!;

    io::printfn("# compiler_optimization=%s safe=%s validation=off thresholds=none extent=%d warmups=%d runs=%d",
        env::COMPILER_OPT_LEVEL, env::COMPILER_SAFE_MODE,
        configuration.extent, configuration.warmups, configuration.runs);
    io::printn(TEXTURE_COLUMNS);
    io::printn(TANGENT_COLUMNS);

    for (uint sample = 0; sample < configuration.warmups + configuration.runs; sample++) {
        bool measured = sample >= configuration.warmups;
        uint run = measured ? sample - configuration.warmups : sample;

        foreach (format : FORMATS) {
            for (uint kind = 0; kind < 4; kind++) {
                TextureSemantic semantic = kind < 2 ? TextureSemantic.COLOR
                  : kind == 2 ? TextureSemantic.NORMAL_RGB : TextureSemantic.NORMAL_RG;
                CoveragePolicy coverage = kind == 1 ? CoveragePolicy.THRESHOLD : CoveragePolicy.NONE;

                Measurement result = measure_texture(
                    configuration: configuration,
                    format: format,
                    semantic: semantic,
                    coverage: coverage,
                )!;

                if (measured) io::printfn("texture,%d,%s,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
                    run, format, semantic, coverage, result.source_bytes, result.live_source_bytes,
                    result.chain_bytes, result.prepare_chain_bytes, result.state_bytes,
                    result.result_bytes, result.scan_ns, result.restore_ns, result.generation_ns, result.prepare_ns,
                    result.submission_wait_ns, result.generated_texels, result.progress_texels, result.staged_bytes);
            }
        }

        measure_tangents(run, measured)!;
    }
}

<* Measure texture scans, normal and coverage chains, GPU preparation and tangent splits. *>
fn int main(String[] args) {
    if (catch excuse = run_benchmark(args)) {
        io::eprintfn("Texture fidelity benchmark failed: %s", excuse);
        io::eprintn("Usage: texture_fidelity_bench [extent=1024] [warmups=2] [runs=10]");
        return 1;
    }
    return 0;
}
