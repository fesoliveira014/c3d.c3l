module c3d::examples::publication_bench;

import c3d;
import c3d::asset @public;
import c3d::asset::gltf;
import c3d::asset::loader;
import c3d::geometry;
import c3d::material;
import c3d::test::loading_fixtures;
import std::core::env;
import std::core::mem::allocators;
import std::core::string;
import std::io;
import std::sort;
import std::thread;
import std::time::clock;

const uint DEFAULT_MODELS @local = 256; // enough decoded entries to spread publication over many owner loops
const uint DEFAULT_NODES @local = 2;
const uint DEFAULT_WARMUP @local = 5; // warm process and allocator pages; every corpus still has a fresh store
const uint DEFAULT_RUNS @local = 30; // retain thirty complete fresh corpora per allowance
const uint MAX_MODELS @local = 1024; // bounds the simultaneously decoded corpus and retained sample storage
const uint MAX_NODES @local = 1024;
const uint MAX_RUNS @local = 1000;
const uint LARGER_MODEL_COUNT @local = 8;
const ulong TINY_ITEM_ALLOWANCE @local = 1; // below the generated model's incoming inventory
const uint MEDIAN_PERCENT @local = 50;
const uint P95_PERCENT @local = 95;
const uint PERCENT_SCALE @local = 100;

enum SampleKind @local { BLOCKED, PROGRESS, DRAIN }

struct Configuration @local {
    uint models;
    uint nodes;
    uint warmup;
    uint runs;
}

struct Source @local {
    char[] bytes;
}

struct Charge @local {
    ulong minimum_reservation;
    ulong complete;
}

struct Mode @local {
    String name;
    ulong items;
    bool blocked_then_drain;
}

struct CallSample @local {
    uint run;
    uint call;
    SampleKind kind;
    ulong limit;
    ulong call_ns;
    ulong frame_ns;
    PublishReport report;
    LoaderCounters counters;
}

fn Configuration? parse_configuration(String[] args) @local {
    if (args.len > 5) return c3d::INVALID_ARGUMENT~;
    Configuration configuration = {
        .models = DEFAULT_MODELS, .nodes = DEFAULT_NODES,
        .warmup = DEFAULT_WARMUP, .runs = DEFAULT_RUNS,
    };
    if (args.len > 1) configuration.models = args[1].to_uint()!;
    if (args.len > 2) configuration.nodes = args[2].to_uint()!;
    if (args.len > 3) configuration.warmup = args[3].to_uint()!;
    if (args.len > 4) configuration.runs = args[4].to_uint()!;
    if (!configuration.models || configuration.models > MAX_MODELS
      || !configuration.nodes || configuration.nodes > MAX_NODES
      || configuration.warmup > MAX_RUNS || !configuration.runs || configuration.runs > MAX_RUNS) {
        return c3d::INVALID_ARGUMENT~;
    }
    return configuration;
}

fn char[]? read_source(void* user, Allocator allocator, String path) @local {
    Source* source = user;
    char[] bytes = alloc::new_array(allocator, char, (sz)source.bytes.len);
    mem::copy(bytes.ptr, source.bytes.ptr, source.bytes.len);
    return bytes;
}

fn AssetStore create_store(Allocator allocator, Source* source, uint models) @local {
    AssetStoreDesc desc = asset::default_asset_store_desc();
    desc.max_models = models;
    desc.max_geometries = models;
    desc.max_materials = models;
    desc.file_source = { .read = &read_source, .user = source };
    return asset::create_asset_store(allocator, desc);
}

fn LoadRequest request_for(String path) @local {
    return { .path = path, .format = ModelFormat.GLTF, .options = asset::LOAD_OPTIONS_DEFAULT };
}

fn String model_path(uint index) @local => string::tformat("model_%d.gltf", index);

fn void? wait_decoded(AsyncLoader* loader, uint expected) @local {
    while (true) {
        LoaderCounters counters = loader.counters();
        if (counters.failed) return c3d::ASSET_FORMAT_ERROR~;
        if (counters.decoded == expected) return;
        thread::yield();
    }
}

fn Charge? probe_charge(Allocator allocator, Source* source) @local {
    AssetStore assets = create_store(allocator, source, 1);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(allocator, &assets, 1)!;
    defer loader::destroy_async_loader(&loader);
    LoadId id = loader.request(request_for("charge_probe.gltf"))!;
    wait_decoded(&loader, 1)!;

    PublishReport minimum = loader.publish_within({ .items = TINY_ITEM_ALLOWANCE });
    if (!minimum.deferred || minimum.required_exact || minimum.required_items <= TINY_ITEM_ALLOWANCE
      || minimum.items_used || minimum.published || minimum.failed) return c3d::INVALID_ARGUMENT~;
    PublishReport reserved = loader.publish_within({ .items = minimum.required_items });
    ulong complete_items;
    if (reserved.deferred) {
        if (!reserved.required_exact || reserved.published || reserved.failed
          || reserved.required_items <= minimum.required_items) return c3d::INVALID_ARGUMENT~;
        PublishReport complete = loader.publish_within({ .items = reserved.required_items });
        if (complete.published != 1 || complete.failed || complete.deferred
          || complete.items_used != reserved.required_items) return c3d::INVALID_ARGUMENT~;
        complete_items = complete.items_used;
    } else {
        if (reserved.published != 1 || reserved.failed || !reserved.items_used
          || reserved.items_used > minimum.required_items) return c3d::INVALID_ARGUMENT~;
        complete_items = reserved.items_used;
    }
    if (loader.status(id).phase != LoadPhase.PUBLISHED) return c3d::INVALID_ARGUMENT~;
    return { .minimum_reservation = minimum.required_items, .complete = complete_items };
}

fn bool same_slot(TextureSlot first, TextureSlot second) @local {
    return first.texture.kind == second.texture.kind
      && c3d::same_id(first.texture.asset, second.texture.asset)
      && c3d::same_id(first.sampler, second.sampler) && first.uv_set == second.uv_set
      && first.transform.offset == second.transform.offset && first.transform.scale == second.transform.scale
      && first.transform.rotation == second.transform.rotation;
}

fn void? verify_material(MaterialAsset* actual, MaterialAsset* expected) @local {
    Material* first = &actual.data;
    Material* second = &expected.data;
    if (actual.header.key != expected.header.key || actual.header.revision != expected.header.revision
      || actual.header.replaced_revision != expected.header.replaced_revision
      || first.kind != MaterialKind.STANDARD || second.kind != MaterialKind.STANDARD
      || first.common.alpha_mode != second.common.alpha_mode || first.common.blend_mode != second.common.blend_mode
      || first.common.alpha_cutoff != second.common.alpha_cutoff || first.common.double_sided != second.common.double_sided
      || first.common.depth_write != second.common.depth_write || first.common.depth_test != second.common.depth_test
      || first.common.wireframe != second.common.wireframe) return c3d::INVALID_ARGUMENT~;
    StandardParams* first_params = &first.standard;
    StandardParams* second_params = &second.standard;
    if (first_params.base_color != second_params.base_color || first_params.metallic != second_params.metallic
      || first_params.roughness != second_params.roughness || first_params.emissive != second_params.emissive
      || first_params.emissive_strength != second_params.emissive_strength
      || first_params.normal_scale != second_params.normal_scale
      || first_params.occlusion_strength != second_params.occlusion_strength
      || !same_slot(first_params.base_color_map, second_params.base_color_map)
      || !same_slot(first_params.metallic_roughness_map, second_params.metallic_roughness_map)
      || !same_slot(first_params.normal_map, second_params.normal_map)
      || !same_slot(first_params.occlusion_map, second_params.occlusion_map)
      || !same_slot(first_params.emissive_map, second_params.emissive_map)) return c3d::INVALID_ARGUMENT~;
}

fn void? verify_geometry(GeometryAsset* actual, GeometryAsset* expected) @local {
    Geometry* first = &actual.data;
    Geometry* second = &expected.data;
    if (actual.header.key != expected.header.key || actual.header.revision != expected.header.revision
      || actual.header.replaced_revision != expected.header.replaced_revision
      || actual.vertex_count != expected.vertex_count || actual.index_count != expected.index_count
      || actual.target_count != expected.target_count || actual.shape.skinned != expected.shape.skinned
      || actual.shape.joint_bound != expected.shape.joint_bound
      || actual.shape.target_streams.len || expected.shape.target_streams.len
      || actual.morph_bounds.len || expected.morph_bounds.len
      || actual.skin_bounds.joints.len || expected.skin_bounds.joints.len
      || actual.skin_bounds.morph_deltas.len || expected.skin_bounds.morph_deltas.len
      || actual.skin_bounds.used.len || expected.skin_bounds.used.len
      || actual.skin_bounds.target_count != expected.skin_bounds.target_count
      || first.topology != second.topology || first.bounds.min != second.bounds.min || first.bounds.max != second.bounds.max
      || first.positions.len != second.positions.len || first.normals.len != second.normals.len
      || first.tangents.len != second.tangents.len || first.uv0.len != second.uv0.len || first.uv1.len != second.uv1.len
      || first.colors.len != second.colors.len || first.indices.len != second.indices.len
      || first.joints.len || second.joints.len || first.weights.len || second.weights.len
      || first.targets.len || second.targets.len || first.channels.len || second.channels.len
      || first.custom_data.len || second.custom_data.len || first.custom_stride != second.custom_stride) {
        return c3d::INVALID_ARGUMENT~;
    }
    foreach (index, value : first.positions) if (value != second.positions[index]) return c3d::INVALID_ARGUMENT~;
    foreach (index, value : first.normals) if (value != second.normals[index]) return c3d::INVALID_ARGUMENT~;
    foreach (index, value : first.tangents) if (value != second.tangents[index]) return c3d::INVALID_ARGUMENT~;
    foreach (index, value : first.uv0) if (value != second.uv0[index]) return c3d::INVALID_ARGUMENT~;
    foreach (index, value : first.uv1) if (value != second.uv1[index]) return c3d::INVALID_ARGUMENT~;
    foreach (index, value : first.colors) if (value != second.colors[index]) return c3d::INVALID_ARGUMENT~;
    foreach (index, value : first.indices) if (value != second.indices[index]) return c3d::INVALID_ARGUMENT~;
}

fn void? verify_model(
    AssetStore* actual_store,
    ModelId actual_id,
    AssetStore* expected_store,
    ModelId expected_id,
) @local {
    ModelAsset* actual = actual_store.model(actual_id);
    ModelAsset* expected = expected_store.model(expected_id);
    ModelTemplate* first = &actual.data;
    ModelTemplate* second = &expected.data;
    if (actual.header.key != expected.header.key || actual.header.revision != expected.header.revision
      || actual.header.replaced_revision != expected.header.replaced_revision
      || first.nodes.len != second.nodes.len || first.meshes.len != second.meshes.len
      || first.skins.len || second.skins.len || first.lod_groups.len || second.lod_groups.len
      || first.clips.len || second.clips.len || first.lights.len || second.lights.len
      || first.cameras.len || second.cameras.len) return c3d::INVALID_ARGUMENT~;
    foreach (index, node : first.nodes) {
        NodeTemplate other = second.nodes[index];
        if (node.parent != other.parent || node.name != other.name || node.layers != other.layers
          || node.visible != other.visible || node.local.position != other.local.position
          || node.local.rotation.v != other.local.rotation.v || node.local.scale != other.local.scale) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    foreach (index, mesh : first.meshes) {
        ModelMesh other = second.meshes[index];
        if (mesh.node != other.node || mesh.default_morph_weights.len || other.default_morph_weights.len) {
            return c3d::INVALID_ARGUMENT~;
        }
        verify_geometry(actual_store.geometry(mesh.geometry), expected_store.geometry(other.geometry))!;
        verify_material(actual_store.material(mesh.material), expected_store.material(other.material))!;
    }
}

fn void print_sample(String mode, CallSample* sample) @local {
    io::printfn(
        "sample,%s,%d,%d,%s,%d,%d,%d,%d,%d,%d,%d,%d,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
        mode, sample.run, sample.call, sample.kind, sample.limit, sample.call_ns, sample.frame_ns,
        sample.report.published, sample.report.failed, sample.report.items_used, sample.report.required_items,
        sample.counters.publication_items, sample.report.required_exact, sample.report.deferred,
        sample.counters.queued, sample.counters.decoding, sample.counters.decoded, sample.counters.cancelling,
        sample.counters.published, sample.counters.failed, sample.counters.cancelled, sample.counters.publications,
        sample.counters.decode_failures, sample.counters.commit_failures, sample.counters.cancellations,
        sample.counters.decode_ns, sample.counters.publication_ns, sample.counters.publication_items,
    );
}

fn void print_distribution(
    String mode,
    String population,
    String metric,
    ulong[] values,
) @local {
    if (!values.len) {
        io::printfn("distribution,%s,%s,%s,0,NA,NA,NA", mode, population, metric);
        return;
    }
    sort::quicksort(values);
    usz median = (values.len * MEDIAN_PERCENT + PERCENT_SCALE - 1) / PERCENT_SCALE - 1;
    usz p95 = (values.len * P95_PERCENT + PERCENT_SCALE - 1) / PERCENT_SCALE - 1;
    io::printfn(
        "distribution,%s,%s,%s,%d,%d,%d,%d",
        mode, population, metric, values.len, values[median], values[p95], values[values.len - 1],
    );
}

fn void summarize(Allocator allocator, String mode, CallSample[] samples) @local {
    ulong[] values = alloc::new_array(allocator, ulong, (sz)samples.len);
    defer alloc::free(allocator, values.ptr);
    foreach (kind : SampleKind::values) {
        usz count;
        foreach (sample : samples) if (sample.kind == kind) values[count++] = sample.call_ns;
        print_distribution(
            mode: mode,
            population: SampleKind::names[(uint)kind],
            metric: "call_ns",
            values: values[:count],
        );
        count = 0;
        foreach (sample : samples) if (sample.kind == kind) values[count++] = sample.frame_ns;
        print_distribution(
            mode: mode,
            population: SampleKind::names[(uint)kind],
            metric: "frame_ns",
            values: values[:count],
        );
    }
}

fn usz? run_corpus(
    Allocator allocator,
    Source* source,
    Configuration configuration,
    Mode mode,
    uint run,
    bool measured,
    AssetStore* reference,
    CallSample[] samples,
    ulong* completion_ns,
) @local {
    AssetStore assets = create_store(allocator, source, configuration.models);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(allocator, &assets, configuration.models)!;
    defer loader::destroy_async_loader(&loader);
    LoadId[] requests = alloc::new_array(allocator, LoadId, configuration.models);
    defer alloc::free(allocator, requests.ptr);
    std::time::Clock decode_started = clock::now();
    @pool() {
        foreach (index, &request : requests) *request = loader.request(request_for(model_path((uint)index)))!;
    };
    std::time::Clock wait_started = clock::now();
    wait_decoded(&loader, configuration.models)!;
    ulong wait_ns = (ulong)wait_started.to_now();
    ulong decode_wall_ns = (ulong)decode_started.to_now();

    uint published;
    usz count;
    ulong limit = mode.items;
    std::time::Clock completion_started = clock::now();
    while (published < configuration.models) {
        std::time::Clock frame_started = clock::now();
        std::time::Clock call_started = clock::now();
        PublishReport report = loader.publish_within({ .items = limit });
        ulong call_ns = (ulong)call_started.to_now();
        published += report.published;
        CallSample sample = {
            .run = run, .call = (uint)count, .limit = limit, .call_ns = call_ns, .report = report,
            .kind = mode.blocked_then_drain ? (count ? SampleKind.DRAIN : SampleKind.BLOCKED) : SampleKind.PROGRESS,
        };
        sample.counters = loader.counters();
        samples[count++] = sample;
        if (report.failed || (limit && report.items_used > limit)) return c3d::INVALID_ARGUMENT~;
        if (mode.blocked_then_drain && count == 1) {
            if (!report.deferred || report.published || report.items_used || report.required_exact) {
                return c3d::INVALID_ARGUMENT~;
            }
            limit = 0;
        } else if (!report.published || count > (usz)configuration.models + 1) {
            return c3d::INVALID_ARGUMENT~;
        }
        samples[count - 1].frame_ns = (ulong)frame_started.to_now();
    }
    *completion_ns = (ulong)completion_started.to_now();

    LoaderCounters counters = loader.counters();
    if (counters.queued || counters.decoding || counters.decoded || counters.cancelling || counters.failed
      || counters.cancelled || counters.decode_failures || counters.commit_failures || counters.cancellations
      || counters.published != configuration.models || counters.publications != configuration.models
      || assets.keys.len() != reference.keys.len()) return c3d::INVALID_ARGUMENT~;
    @pool() {
        foreach (index, request : requests) {
            LoadStatus status = loader.status(request);
            if (status.phase != LoadPhase.PUBLISHED || status.failure) return c3d::INVALID_ARGUMENT~;
            verify_model(
                actual_store: &assets,
                actual_id: status.model,
                expected_store: reference,
                expected_id: reference.find_model(model_path((uint)index))!,
            )!;
        }
    };
    if (measured) {
        foreach (&sample : samples[:count]) print_sample(mode.name, sample);
        io::printfn(
            "run,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%s",
            mode.name, run, mode.items, count, decode_wall_ns, wait_ns, *completion_ns,
            counters.queued, counters.decoding, counters.decoded, counters.cancelling,
            counters.published, counters.failed, counters.cancelled, counters.publications,
            counters.decode_failures, counters.commit_failures, counters.cancellations,
            counters.publication_items, counters.decode_ns, counters.publication_ns, "sync_equal",
        );
    }
    return count;
}

fn void? benchmark(Configuration configuration) @local {
    Allocator allocator = &allocators::LIBC_ALLOCATOR;
    Source source = { .bytes = loading_fixtures::small_model_gltf(allocator, configuration.nodes) };
    defer alloc::free(allocator, source.bytes.ptr);
    Charge charge = probe_charge(allocator, &source)!;
    if (charge.complete > ulong::max / LARGER_MODEL_COUNT) return c3d::INVALID_ARGUMENT~;
    Mode[4] modes = {
        { .name = "tiny", .items = TINY_ITEM_ALLOWANCE, .blocked_then_drain = true },
        { .name = "one_model", .items = charge.complete },
        { .name = "eight_models", .items = charge.complete * LARGER_MODEL_COUNT },
        { .name = "unbounded", .items = 0 },
    };
    AssetStore reference = create_store(allocator, &source, configuration.models);
    defer asset::destroy_asset_store(&reference);
    @pool() {
        for (uint index = 0; index < configuration.models; index++) gltf::load_model(&reference, model_path(index))!;
    };

    io::printfn(
        "# fixture_version=%d models=%d generated_nodes=%d source_bytes=%d warmup=%d runs=%d compiler_code_opt_level=%s safe=%s",
        loading_fixtures::FIXTURE_VERSION, configuration.models, configuration.nodes, source.bytes.len,
        configuration.warmup, configuration.runs, env::COMPILER_OPT_LEVEL, env::COMPILER_SAFE_MODE,
    );
    ModelAsset* exemplar = reference.model(reference.find_model("model_0.gltf")!);
    GeometryAsset* geometry = reference.geometry(exemplar.data.meshes[0].geometry);
    io::printfn(
        "# per_model template_nodes=%d meshes=%d lod_groups=%d skins=%d clips=%d lights=%d cameras=%d vertices=%d indices=%d morph_targets=%d morph_channels=%d",
        exemplar.data.nodes.len, exemplar.data.meshes.len, exemplar.data.lod_groups.len,
        exemplar.data.skins.len, exemplar.data.clips.len, exemplar.data.lights.len, exemplar.data.cameras.len,
        geometry.vertex_count, geometry.index_count, geometry.target_count, geometry.data.channels.len,
    );
    io::printfn(
        "# minimum_reservation_items=%d complete_one_model_items=%d tiny_items=%d eight_model_items=%d",
        charge.minimum_reservation, charge.complete, TINY_ITEM_ALLOWANCE, charge.complete * LARGER_MODEL_COUNT,
    );
    io::printn(
        x: "# cold_corpus=fresh_store_and_loader_each_run process_cache=warm_after_warmup source=generated_in_memory",
    );
    io::printn(
        x: "# gpu_device=none publication_frame=cpu_owner_loop_including_accounting one_publish_call_per_frame validation=not_applicable",
    );
    io::printn(
        x: "# completion_ns=owner_loop_including_counter_snapshots excluding_decode_logging_and_equivalence_verification",
    );
    io::printn(
        x: "# nanoseconds=monotonic_clock percentiles=nearest_rank thresholds=none tiny_completion=explicit_items_0_drain",
    );
    io::printn(
        x: "# sample_columns=record,mode,run,call,population,limit_items,call_ns,frame_ns,published,commit_failed,items_used,required_items,cumulative_items,required_exact,deferred,queued,decoding,decoded,cancelling,published_phase,failed_phase,cancelled_phase,publications,decode_failures,commit_failures,cancellations,decode_ns,publication_ns,publication_items",
    );
    io::printn(
        x: "# run_columns=record,mode,run,limit_items,calls,decode_wall_ns,wait_ns,completion_ns,queued,decoding,decoded,cancelling,published_phase,failed_phase,cancelled_phase,publications,decode_failures,commit_failures,cancellations,publication_items,decode_ns,publication_ns,verification",
    );
    io::printn(
        x: "# distribution_columns=record,mode,population,metric,count,median_ns,p95_ns,max_ns",
    );

    usz capacity = (usz)configuration.runs * ((usz)configuration.models + 1);
    CallSample[] samples = alloc::new_array(allocator, CallSample, (sz)capacity);
    defer alloc::free(allocator, samples.ptr);
    ulong[] completion = alloc::new_array(allocator, ulong, configuration.runs);
    defer alloc::free(allocator, completion.ptr);
    foreach (mode : modes) {
        usz count;
        for (uint run = 0; run < configuration.warmup + configuration.runs; run++) {
            bool measured = run >= configuration.warmup;
            ulong completion_ns;
            usz added = run_corpus(
                allocator: allocator,
                source: &source,
                configuration: configuration,
                mode: mode,
                run: measured ? run - configuration.warmup : run,
                measured: measured,
                reference: &reference,
                samples: samples[count..],
                completion_ns: &completion_ns,
            )!;
            if (measured) {
                count += added;
                completion[run - configuration.warmup] = completion_ns;
            }
        }
        summarize(allocator, mode.name, samples[:count]);
        print_distribution(
            mode: mode.name,
            population: "COMPLETE",
            metric: "completion_ns",
            values: completion,
        );
    }
}

fn void? run_benchmark(String[] args) @local {
    benchmark(parse_configuration(args)!)!;
}

<* Measure fresh decoded-model publication without a GPU device. *>
fn int main(String[] args) {
    if (catch excuse = run_benchmark(args)) {
        io::eprintfn("Publication benchmark failed: %s", excuse);
        io::eprintn("Usage: publication_bench [models=256] [nodes=2] [warmup=5] [runs=30]");
        return 1;
    }
    return 0;
}
