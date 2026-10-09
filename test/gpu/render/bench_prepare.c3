module c3d::bench::prepare;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::test::loading_fixtures;
import gpu;
import std::core::env;
import std::collections::list;
import std::io;
import std::sort;
import std::time;
import std::time::clock;

const uint DEFAULT_EXTENT @local = 4096;
const uint DEFAULT_WARMUPS @local = 5;
const uint DEFAULT_RUNS @local = 30;
const usz UPLOAD_BYTES @local = 128 << 20; // holds the complete 89,478,484-byte chain plus model blocks
const uint BLOCKED_SAMPLES @local = 3; // explicit blocked observations followed by an adequate drain
const ulong TIME_TARGET_NS @local = 1_000_000;
const ulong GENERATED_ALLOWANCE @local = 1 << 20;
const usz DEFAULT_BYTE_ALLOWANCE @local = 1 << 20;
const usz LARGE_BYTE_ALLOWANCE @local = 8 << 20;

enum Population @local { BLOCKED, PROGRESS, DRAIN, WAIT }

struct Configuration @local {
    uint extent;
    uint warmups;
    uint runs;
    String mode;
}

struct Mode @local {
    String name;
    PrepareLimits limits;
    bool legacy;
    bool prefix_then_drain;
}

struct Corpus @local {
    AssetStore assets;
    Renderer renderer;
    TextureId texture;
    ModelId model;
}

struct Sample @local {
    uint run;
    uint call;
    Population population;
    PrepareLimits limits;
    bool legacy;
    ulong call_ns;
    ulong frame_ns;
    PrepareReport report;
    PrepareCounters counters;
    PrepareProgress progress;
}

fn Configuration? configuration(String[] args) @local {
    if (args.len > 5) return c3d::INVALID_ARGUMENT~;
    Configuration result = { .extent = DEFAULT_EXTENT, .warmups = DEFAULT_WARMUPS, .runs = DEFAULT_RUNS, .mode = "all" };
    if (args.len > 1) result.extent = args[1].to_uint()!;
    if (args.len > 2) result.warmups = args[2].to_uint()!;
    if (args.len > 3) result.runs = args[3].to_uint()!;
    if (args.len > 4) result.mode = args[4];
    if (result.extent < 2 || result.extent > DEFAULT_EXTENT || result.warmups > 1000 || !result.runs || result.runs > 1000) {
        return c3d::INVALID_ARGUMENT~;
    }
    return result;
}

fn void? create_corpus(Corpus* corpus, uint extent) @local {
    corpus.assets = asset::create_asset_store(mem, {
        .max_geometries = 1, .max_textures = asset::BUILTIN_TEXTURE_COUNT + 1,
        .max_materials = 1, .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        .max_environments = 1, .max_models = 1, .max_skeletons = 1, .max_clips = 1,
        .max_shaders = 1, .max_compute_shaders = 1, .max_fonts = 1,
    });
    defer catch asset::destroy_asset_store(&corpus.assets);
    @pool() {
        char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, (usz)extent * extent * 4);
        corpus.texture = corpus.assets.add_texture(material::texture_2d_desc(extent, extent, RGBA8_UNORM), pixels, "generated_texture")!;
        Geometry geometry = geometry::box(tmem, 1, 1, 1);
        GeometryId geometry_id = corpus.assets.add_geometry(&geometry, "box")!;
        MaterialId material_id = corpus.assets.add_material(material::basic({
            .color = { 1, 1, 1, 1 },
            .map = material::texture_slot(corpus.texture, asset::SAMPLER_NEAREST),
        }), "textured")!;
        ModelTemplate model = {
            .nodes = alloc::new_array(mem, NodeTemplate, 1),
            .meshes = alloc::new_array(mem, ModelMesh, 1),
        };
        defer catch asset::free_model_template(mem, &model);
        model.nodes[0] = { .parent = -1, .local = maths::TRANSFORM_IDENTITY, .visible = true, .layers = uint::max };
        model.meshes[0] = { .node = 0, .geometry = geometry_id, .material = material_id };
        corpus.model = corpus.assets.add_model_owned(&model, "model")!;
    };
    corpus.renderer = render::create_renderer(mem, &corpus.assets, {
        .validation = false, .application_name = "preparation_benchmark", .upload_ring_bytes = UPLOAD_BYTES,
    })!;
}

fn void destroy_corpus(Corpus* corpus) @local {
    render::destroy_renderer(&corpus.renderer);
    asset::destroy_asset_store(&corpus.assets);
}

fn usz texture_bytes(uint extent) @local {
    usz total;
    uint mips = material::texture_mip_count(extent, extent);
    for (uint mip = 0; mip < mips; mip++) {
        uint width = material::texture_mip_extent(extent, mip);
        total += (usz)width * width * 4;
    }
    return total;
}

fn char[]? read_gpu_texture(Corpus* corpus, uint extent) @local {
    Renderer* renderer = &corpus.renderer;
    render::wait_frames(renderer)!;
    TextureRes* mirror = &renderer.textures[corpus.texture.index];
    uint mips = material::texture_mip_count(extent, extent);
    if (!mirror.texture.is_valid() || !mirror.copy_source || mirror.mip_count != mips) return c3d::INVALID_ARGUMENT~;
    usz total = texture_bytes(extent);
    gpu::AllocationDesc allocation_desc = { .size = total, .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ, .access = { .graphics }, .debug_name = "preparation_readback" };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &allocation_desc)!;
    defer (void)gpu::free_allocation(&renderer.device, &allocation);
    gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, allocation)!;
    gpu::MappedGpuSpan mapped = gpu::mapped_gpu_span(&renderer.device, span)!;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::TextureBarrier source = gpu::texture_transition(
        texture: mirror.texture,
        before: mirror.state,
        after: { .layout = gpu::TextureLayout.TRANSFER_SOURCE, .stages = { .transfer }, .access = { .read } },
    )!;
    gpu::cmd_texture_barrier(&renderer.commands, &source)!;
    usz offset;
    for (uint mip = 0; mip < mips; mip++) {
        uint width = material::texture_mip_extent(extent, mip);
        usz bytes = (usz)width * width * 4;
        gpu::TextureBufferCopyDesc copy = {
            .texture = mirror.texture, .dst = span.checked_subspan(offset, bytes)!, .mip = mip,
            .layer_count = 1, .width = width, .height = width, .depth = 1,
        };
        gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
        offset += bytes;
    }
    gpu::TextureBarrier restore = gpu::texture_transition(texture: mirror.texture, before: source.after, after: mirror.state)!;
    gpu::cmd_texture_barrier(&renderer.commands, &restore)!;
    gpu::Barrier host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, span)!;
    return (char[])((String)mapped.bytes).copy(mem);
}

fn void? print_device_identity(Renderer* renderer) @local {
    gpu::AdapterList adapters = gpu::enumerate_adapters(&renderer.runtime)!;
    for (uint index = 0; index < adapters.count; index++) {
        gpu::Adapter adapter = adapters.get(index)!;
        gpu::AdapterInfo info = gpu::get_adapter_info(&adapter)!;
        if (info.name != renderer.adapter_name) continue;
        gpu::AdapterDiagnostics diagnostics = gpu::get_adapter_diagnostics(&adapter)!;
        io::printfn("# gpu=%s vendor_id=%s device_id=%s backend=%s backend_version=%s.%s.%s driver=%s driver_info=%s driver_version=%s",
            info.name, info.vendor_id, info.device_id, diagnostics.backend_name,
            diagnostics.backend_version.major, diagnostics.backend_version.minor, diagnostics.backend_version.patch,
            diagnostics.driver_name, diagnostics.driver_info, diagnostics.driver_version);
        return;
    }
    return c3d::INVALID_ARGUMENT~;
}

fn char[]? synchronous_reference(uint extent) @local {
    Corpus reference;
    create_corpus(&reference, extent)!;
    defer destroy_corpus(&reference);
    print_device_identity(&reference.renderer)!;
    reference.renderer.begin_frame()!;
    defer catch render::abort_frame(&reference.renderer);
    reference.renderer.prepare_model(reference.model)!;
    reference.renderer.end_frame()!;
    return read_gpu_texture(&reference, extent);
}

fn PrepareReport report_difference(PrepareCounters before, PrepareCounters after) @local {
    return {
        .staged_bytes = (usz)(after.staged_bytes - before.staged_bytes),
        .generated_texels = after.generated_texels - before.generated_texels,
        .copied_bytes = after.copied_bytes - before.copied_bytes,
        .pipelines = (uint)(after.pipelines - before.pipelines),
        .objects = (uint)(after.objects - before.objects),
        .views = (uint)(after.views - before.views),
        .allocations = (uint)(after.allocations - before.allocations),
        .pipeline_lookups = (uint)(after.pipeline_lookups - before.pipeline_lookups),
        .pipeline_hits = (uint)(after.pipeline_hits - before.pipeline_hits),
        .pipeline_keys = (uint)(after.pipeline_keys - before.pipeline_keys),
        .restarts = (uint)(after.restarts - before.restarts),
        .generation_ns = after.generation_ns - before.generation_ns,
        .pipeline_ns = after.pipeline_ns - before.pipeline_ns,
        .elapsed_ns = after.elapsed_ns - before.elapsed_ns,
        .overrun_ns = after.overrun_ns - before.overrun_ns,
    };
}

fn bool progressed(PrepareReport report, PrepareProgress before, PrepareProgress after) @local {
    return report.staged_bytes || report.generated_texels || report.copied_bytes || report.pipelines || report.objects
        || report.views || report.allocations || after.units_done != before.units_done || after.bytes_done != before.bytes_done;
}

fn String population_name(Population population) @local {
    switch (population) {
        case BLOCKED: return "BLOCKED";
        case PROGRESS: return "PROGRESS";
        case DRAIN: return "DRAIN";
        case WAIT: return "WAIT";
    }
}

fn void print_sample(String mode, Sample* sample) @local {
    PrepareReport* report = &sample.report;
    PrepareCounters* counters = &sample.counters;
    PrepareProgress* progress = &sample.progress;
    io::printfn(
        "sample,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
        mode, sample.run, sample.call, population_name(sample.population), sample.legacy,
        sample.limits.staged_bytes, sample.limits.generated_texels, sample.limits.pipelines, sample.limits.time_ns,
        sample.call_ns, sample.frame_ns, report.staged_bytes, report.generated_texels, report.copied_bytes,
        report.pipelines, report.objects, report.views, report.allocations,
        report.pipeline_lookups, report.pipeline_hits, report.pipeline_keys, report.restarts,
        report.generation_ns, report.pipeline_ns, report.elapsed_ns, report.overrun_ns,
        report.reason, report.required.staged_bytes, report.required.generated_texels, report.required.pipelines,
        progress.state, progress.phase, progress.bytes_done, progress.bytes_total,
        progress.texels_done, progress.texels_total, progress.units_done, progress.units_total,
        counters.staged_bytes, counters.generated_texels, counters.copied_bytes, counters.pipelines,
        counters.objects, counters.views, counters.allocations, counters.restarts,
        counters.pipeline_lookups, counters.pipeline_hits, counters.pipeline_keys,
        counters.generation_ns, counters.pipeline_ns, counters.elapsed_ns, counters.overrun_ns,
    );
}

fn void distribution(String mode, String population, String metric, ulong[] values) @local {
    if (!values.len) {
        io::printfn("distribution,%s,%s,%s,0,NA,NA,NA", mode, population, metric);
        return;
    }
    sort::quicksort(values);
    usz median = (values.len * 50 + 99) / 100 - 1;
    usz p95 = (values.len * 95 + 99) / 100 - 1;
    io::printfn("distribution,%s,%s,%s,%s,%s,%s,%s", mode, population, metric,
        values.len, values[median], values[p95], values[^1]);
}

fn void summarize(String mode, Sample[] samples, ulong[] completion) @local {
    @pool() {
        ulong[] values = alloc::new_array(tmem, ulong, samples.len);
        foreach (population : Population::values) {
            usz count;
            foreach (sample : samples) {
                if (sample.population == population) values[count++] = sample.call_ns;
            }
            distribution(mode: mode, population: population_name(population), metric: "call_ns", values: values[:count]);
            count = 0;
            foreach (sample : samples) {
                if (sample.population == population) values[count++] = sample.frame_ns;
            }
            distribution(mode: mode, population: population_name(population), metric: "frame_ns", values: values[:count]);
        }
        distribution(mode: mode, population: "COMPLETE", metric: "completion_ns", values: completion);
    };
}

fn ulong? run_corpus(
    Configuration configuration,
    Mode mode,
    uint run,
    bool measured,
    char[] reference,
    List{Sample}* retained,
) @local {
    Corpus corpus;
    create_corpus(&corpus, configuration.extent)!;
    defer destroy_corpus(&corpus);
    Renderer* renderer = &corpus.renderer;
    if (measured && run == 0) io::printfn("# adapter=%s mode=%s validation=%s", renderer.adapter_name, mode.name, renderer.validation);
    PrepareId id = renderer.begin_prepare_model(corpus.model)!;
    defer (void)renderer.end_prepare(id);
    PrepareProgress progress = renderer.prepare_progress(id);
    List{Sample} samples;
    samples.init(mem);
    defer samples.free();
    bool draining;
    uint blocked;
    uint calls;
    PrepareCounters baseline = renderer.prepare_counters;
    std::time::Clock completion_started = clock::now();
    while (progress.state != PrepareState.READY) {
        PrepareLimits limits = draining ? (PrepareLimits){} : mode.limits;
        bool legacy = !draining && mode.legacy;
        PrepareProgress before_progress = progress;
        PrepareCounters before = renderer.prepare_counters;
        std::time::Clock frame_started = clock::now();
        renderer.begin_frame()!;
        defer catch render::abort_frame(renderer);
        std::time::Clock call_started = clock::now();
        PrepareReport report;
        if (legacy) {
            renderer.advance_prepares(limits.staged_bytes)!;
            report = report_difference(before, renderer.prepare_counters);
        } else {
            report = renderer.advance_prepares_within(limits)!;
        }
        ulong call_ns = (ulong)call_started.to_now();
        if (!legacy && ((limits.staged_bytes && report.staged_bytes > limits.staged_bytes)
          || (limits.generated_texels && report.generated_texels > limits.generated_texels)
          || (limits.pipelines && report.pipelines > limits.pipelines))) return c3d::INVALID_ARGUMENT~;
        renderer.end_frame()!;
        progress = renderer.prepare_progress(id);
        ulong frame_ns = (ulong)frame_started.to_now();
        if (progress.state == PrepareState.FAILED) return progress.failure~;
        bool did_work = progressed(report, before_progress, progress);
        Population population = draining ? Population.DRAIN : did_work ? Population.PROGRESS
            : report.reason == PrepareStopReason.NONE ? Population.WAIT : Population.BLOCKED;
        samples.push({ .run = run, .call = calls++, .population = population, .limits = limits,
            .legacy = legacy, .call_ns = call_ns, .frame_ns = frame_ns, .report = report,
            .counters = renderer.prepare_counters, .progress = progress });
        if (mode.prefix_then_drain && !draining) {
            if (mode.legacy) {
                if (!report.staged_bytes || report.staged_bytes > (usz)configuration.extent * 4) return c3d::INVALID_ARGUMENT~;
                draining = true;
            } else if (!did_work) {
                if (report.reason != PrepareStopReason.STAGED_BYTES || report.required.staged_bytes != (usz)configuration.extent * 4) {
                    return c3d::INVALID_ARGUMENT~;
                }
                if (++blocked == BLOCKED_SAMPLES) draining = true;
            }
        } else if (!draining && !did_work && report.reason != PrepareStopReason.NONE && report.reason != PrepareStopReason.TIME) {
            draining = true;
        }
    }
    ulong completion_ns = (ulong)completion_started.to_now();
    PrepareCounters totals = renderer.prepare_counters;
    usz expected_texture_bytes = texture_bytes(configuration.extent);
    if (progress.bytes_done != progress.bytes_total || progress.units_done != progress.units_total
      || totals.staged_bytes - baseline.staged_bytes != progress.bytes_total
      || totals.staged_bytes < expected_texture_bytes
      || totals.generated_texels - baseline.generated_texels != (ulong)configuration.extent * configuration.extent) {
        return c3d::INVALID_ARGUMENT~;
    }
    char[] actual = read_gpu_texture(&corpus, configuration.extent)!;
    defer free(actual.ptr);
    if (actual != reference) return c3d::INVALID_ARGUMENT~;
    if (measured) {
        foreach (&sample : samples) {
            print_sample(mode.name, sample);
            retained.push(*sample);
        }
        io::printfn(
            "run,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
            mode.name, run, configuration.extent, calls, completion_ns, expected_texture_bytes, progress.bytes_total,
            totals.staged_bytes - baseline.staged_bytes, totals.generated_texels - baseline.generated_texels,
            totals.copied_bytes - baseline.copied_bytes, totals.pipelines - baseline.pipelines,
            totals.objects - baseline.objects, totals.views - baseline.views, totals.allocations - baseline.allocations,
            totals.pipeline_lookups - baseline.pipeline_lookups, totals.pipeline_hits - baseline.pipeline_hits,
            totals.pipeline_keys - baseline.pipeline_keys, totals.restarts - baseline.restarts,
            totals.generation_ns - baseline.generation_ns, totals.pipeline_ns - baseline.pipeline_ns,
            totals.elapsed_ns - baseline.elapsed_ns, totals.overrun_ns - baseline.overrun_ns,
            progress.units_done, actual.len, "sync_gpu_equal",
        );
    }
    return completion_ns;
}

fn void? benchmark(Configuration configuration) @local {
    char[] reference = synchronous_reference(configuration.extent)!;
    defer free(reference.ptr);
    usz row = (usz)configuration.extent * 4;
    Mode[9] modes = {
        { .name = "tiny_bytes", .limits = { .staged_bytes = row - 1 }, .prefix_then_drain = true },
        { .name = "legacy_tiny", .limits = { .staged_bytes = row - 1 }, .legacy = true, .prefix_then_drain = true },
        { .name = "default_bytes", .limits = { .staged_bytes = DEFAULT_BYTE_ALLOWANCE } },
        { .name = "large_bytes", .limits = { .staged_bytes = LARGE_BYTE_ALLOWANCE } },
        { .name = "unbounded" },
        { .name = "generated_texels", .limits = { .generated_texels = GENERATED_ALLOWANCE } },
        { .name = "pipelines", .limits = { .pipelines = 1 } },
        { .name = "time", .limits = { .time_ns = TIME_TARGET_NS } },
        { .name = "combined", .limits = { .staged_bytes = DEFAULT_BYTE_ALLOWANCE,
            .generated_texels = GENERATED_ALLOWANCE, .pipelines = 1, .time_ns = TIME_TARGET_NS } },
    };
    io::printfn("# fixture_version=%s seed=%s width=%s height=%s format=RGBA8_UNORM mip_bytes=%s warmups=%s runs=%s upload_ring_bytes=%s compiler_code_opt_level=%s safe=%s",
        loading_fixtures::FIXTURE_VERSION, loading_fixtures::PREPARATION_IMAGE_SEED, configuration.extent,
        configuration.extent, reference.len, configuration.warmups, configuration.runs, UPLOAD_BYTES,
        env::COMPILER_OPT_LEVEL, env::COMPILER_SAFE_MODE);
    io::printn("# fresh_corpus=store_renderer_and_empty_model_pipeline_cache_each_run driver_cache=process_and_driver_managed_warmed_by_preceding_reference_and_warmups validation=off headless=true thresholds=none");
    io::printn("# call_ns=advance_only frame_ns=application_begin_advance_end_progress_including_GPU_slot_wait completion_ns=full_loop_excluding_setup_logging_and_full_mip_verification");
    io::printn("# gpu_verification=all_mip_RGBA8_bytes_transfer_readback_equal_synchronous no_sampling_or_readback_inside_timing");
    io::printn("# creation_metrics=explicit_create_API_calls views_allocations_separate sampler_interning_excluded pipeline_ns=creation_API_elapsed_including_driver");
    io::printn("# percentiles=nearest_rank med50_p95_max blocked_and_progress_separate tiny_completion=explicit_allzero_drain legacy_tiny=one_minimum_then_allzero_drain");
    io::printn("# sample_columns=record,mode,run,call,population,legacy,staged_limit,generated_limit,pipeline_limit,time_limit_ns,call_ns,frame_ns,staged_bytes,generated_texels,copied_bytes,pipeline_calls,objects,views,allocations,pipeline_lookups,pipeline_hits,pipeline_keys,restarts,generation_ns,pipeline_ns,elapsed_ns,overrun_ns,stop_reason,required_bytes,required_texels,required_pipelines,state,phase,bytes_done,bytes_total,texels_done,texels_total,units_done,units_total,cumulative_staged,cumulative_generated,cumulative_copied,cumulative_pipelines,cumulative_objects,cumulative_views,cumulative_allocations,cumulative_restarts,cumulative_lookups,cumulative_hits,cumulative_keys,cumulative_generation_ns,cumulative_pipeline_ns,cumulative_elapsed_ns,cumulative_overrun_ns");
    io::printn("# run_columns=record,mode,run,extent,calls,completion_ns,texture_bytes,planned_bytes,actual_staged,actual_generated,actual_copied,pipeline_calls,objects,views,allocations,lookups,hits,keys,restarts,generation_ns,pipeline_ns,elapsed_ns,overrun_ns,units_done,verified_bytes,verification");
    io::printn("# distribution_columns=record,mode,population,metric,count,median_ns,p95_ns,max_ns");
    bool selected;
    foreach (mode : modes) {
        if (configuration.mode != "all" && configuration.mode != mode.name) continue;
        selected = true;
        List{Sample} retained;
        retained.init(mem);
        defer retained.free();
        ulong[] completion = alloc::new_array(mem, ulong, configuration.runs);
        defer free(completion.ptr);
        io::printfn("# mode=%s staged_bytes=%s generated_texels=%s pipelines=%s time_ns=%s legacy=%s", mode.name,
            mode.limits.staged_bytes, mode.limits.generated_texels, mode.limits.pipelines, mode.limits.time_ns, mode.legacy);
        for (uint run = 0; run < configuration.warmups + configuration.runs; run++) {
            bool measured = run >= configuration.warmups;
            ulong elapsed = run_corpus(
                configuration: configuration, mode: mode, run: measured ? run - configuration.warmups : run,
                measured: measured, reference: reference, retained: &retained,
            )!;
            if (measured) completion[run - configuration.warmups] = elapsed;
        }
        summarize(mode.name, retained.array_view(), completion);
    }
    if (!selected) return c3d::INVALID_ARGUMENT~;
}

fn void? run_benchmark(String[] args) @local {
    benchmark(configuration(args)!)!;
}

<* Measure fresh GPU preparation and emit raw calls and nearest-rank summaries. *>
fn int main(String[] args) {
    if (catch excuse = run_benchmark(args)) {
        io::eprintfn("Preparation benchmark failed: %s", excuse);
        io::eprintn("Usage: prepare_bench [extent=4096] [warmups=5] [runs=30] [mode=all]");
        return 1;
    }
    return 0;
}
