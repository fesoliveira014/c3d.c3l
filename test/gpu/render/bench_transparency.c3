module c3d::render::transparency_benchmark;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::transparency_fixtures;
import gpu;
import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;

const uint TRANSPARENCY_BENCH_WARMUP @private = 120;
const uint TRANSPARENCY_BENCH_SAMPLES @private = 240;
const uint TRANSPARENCY_BENCH_RUNS @private = 3;
const uint TRANSPARENCY_BENCH_DRAIN @private = render::FRAMES_IN_FLIGHT + 1;
const uint TRANSPARENCY_BENCH_METRIC_COUNT @private = 9;
const String[TRANSPARENCY_BENCH_METRIC_COUNT] TRANSPARENCY_BENCH_METRICS @private = {
    "cpu_record_ms", "cpu_frame_ms", "gpu_all_categories_ms",
    "TRANSPARENCY_CAPTURE", "TRANSPARENCY_RETAINED", "TRANSPARENCY_REMAINDER",
    "TRANSPARENCY_RESOLVE", "TRANSPARENCY_FILTER", "SCENE_SNAPSHOT",
};
const uint TRANSPARENCY_BENCH_TOTAL @private = TRANSPARENCY_BENCH_WARMUP
  + TRANSPARENCY_BENCH_SAMPLES + TRANSPARENCY_BENCH_DRAIN;
const char[*] TRANSPARENCY_BENCH_GLASS @private = $embed("../../fixtures/transparency/GlassVaseFlowers.glb");
const String TRANSPARENCY_BENCH_GLASS_SHA @private = "430c9937664cfc74299205dcc388e4269bb688817f3d3866ef35aab71e93b852";

struct TransparencyBenchCase @private {
    String corpus;
    uint width;
    uint height;
    uint capacity;
    ShadingPath shading;
}

struct TransparencyBenchScene @private {
    AssetStore assets;
    Scene scene;
    Node* camera;
}

struct TransparencyBenchSample @private {
    double frame_ms;
    double record_ms;
    float[render::PASS_COUNT] gpu_ms;
    bool gpu_ready;
    uint gpu_scopes_dropped;
    TransparencyStats transparency;
}

struct TransparencyBenchSummary @private {
    double median;
    double p95;
}

struct TransparencyBenchRun @private {
    TransparencyBenchSummary[TRANSPARENCY_BENCH_METRIC_COUNT] metrics;
    double setup_ms;
    double prepare_ms;
}

fn GeometryId? transparency_bench_quad(
    AssetStore* assets,
    float distance,
    float minimum_x,
    float maximum_x,
    float minimum_y = -0.75f,
    float maximum_y = 0.75f,
) @private {
    Vec3[4] positions = {
        { minimum_x, minimum_y, -distance }, { maximum_x, minimum_y, -distance },
        { maximum_x, maximum_y, -distance }, { minimum_x, maximum_y, -distance },
    };
    Vec2[4] uv = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } };
    Geometry geometry = {
        .positions = positions[..],
        .uv0 = uv[..],
        .indices = transparency_fixtures::QUAD_INDICES[..],
    };
    geometry.finalize();
    return assets.add_geometry(&geometry);
}

fn MaterialId? transparency_bench_basic(AssetStore* assets, Vec4 color, bool blended = false) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = blended ? AlphaMode.BLEND : AlphaMode.OPAQUE;
    common.double_sided = true;
    return assets.add_material(material::basic({ .color = color }, common));
}

fn void? transparency_bench_checker(
    TransparencyBenchScene* target,
    uint width,
    uint height,
    bool cc0,
) @private {
    @pool() {
        transparency_fixtures::ColorImage checker = {
            .width = width,
            .height = height,
            .pixels = alloc::new_array(tmem, transparency_fixtures::Color, (usz)width * height),
        };
        transparency_fixtures::fill_backdrop(checker, transparency_fixtures::BackdropPattern.CHECKER);
        Vec4[] texels = alloc::new_array(tmem, Vec4, checker.pixels.len);
        foreach (pixel, color : checker.pixels) texels[pixel] = { (float)color.x, (float)color.y, (float)color.z, 1 };
        TextureId texture = target.assets.add_texture({
            .width = width,
            .height = height,
            .layers = 1,
            .mip_levels = 1,
            .format = PixelFormat.RGBA32_FLOAT,
            .debug_name = "transparency_bench_checker",
        }, ((char*)texels.ptr)[:texels.len * Vec4::size])!;
        MaterialId material = target.assets.add_material(material::basic({
            .color = { 1, 1, 1, 1 },
            .map = material::texture_slot(texture, asset::SAMPLER_NEAREST),
        }))!;
        float extent = cc0 ? 0.3f : (float)width / height;
        GeometryId geometry = transparency_bench_quad(
            assets: &target.assets,
            distance: cc0 ? 0.2f : 8.5f,
            minimum_x: -extent,
            maximum_x: extent,
            minimum_y: cc0 ? -0.3f : -1,
            maximum_y: cc0 ? 0.3f : 1,
        )!;
        Node* node = target.scene.add_mesh(geometry, material)!;
        if (cc0) node.local.position = { 0.06f, 0.105f, 0 };
    };
}

fn void? transparency_bench_batches(TransparencyBenchScene* target) @private {
    GeometryId geometry = transparency_bench_quad(
        assets: &target.assets,
        distance: transparency_fixtures::PLANAR_DISTANCES[2],
        minimum_x: -0.75f,
        maximum_x: 0.75f,
    )!;
    MaterialId white = transparency_bench_basic(&target.assets, { 1, 1, 1, 1 }, true)!;
    Transform[2] first = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    first[0].position.z = transparency_fixtures::PLANAR_DISTANCES[2] - transparency_fixtures::PLANAR_DISTANCES[0];
    first[1].position.z = transparency_fixtures::PLANAR_DISTANCES[2] - transparency_fixtures::PLANAR_DISTANCES[4];
    Node* first_batch = target.scene.add_instanced_mesh(
        geometry: geometry,
        material: white,
        capacity: first.len,
        transforms: first[..],
    )!;
    InstancedMesh* first_instances = target.scene.get(first_batch, InstancedMesh);
    for (uint instance = 0; instance < first.len; instance++) {
        uint source = instance == 0 ? 0 : 4;
        transparency_fixtures::Color color = transparency_fixtures::PLANAR_COLORS[source];
        first_instances.colors[instance] = {
            (float)color.x, (float)color.y, (float)color.z,
            (float)transparency_fixtures::PLANAR_COVERAGES[source],
        };
    }
    target.scene.mark_instances_dirty(first_batch);

    transparency_fixtures::Color middle_color = transparency_fixtures::PLANAR_COLORS[2];
    MaterialId middle = transparency_bench_basic(&target.assets, {
        (float)middle_color.x, (float)middle_color.y, (float)middle_color.z,
        (float)transparency_fixtures::PLANAR_COVERAGES[2],
    }, true)!;
    target.scene.add_mesh(geometry, middle)!;

    Transform[2] second = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    second[0].position.z = transparency_fixtures::PLANAR_DISTANCES[2] - transparency_fixtures::PLANAR_DISTANCES[1];
    second[1].position.z = transparency_fixtures::PLANAR_DISTANCES[2] - transparency_fixtures::PLANAR_DISTANCES[3];
    Node* second_batch = target.scene.add_instanced_mesh(
        geometry: geometry,
        material: white,
        capacity: second.len,
        transforms: second[..],
    )!;
    InstancedMesh* second_instances = target.scene.get(second_batch, InstancedMesh);
    for (uint instance = 0; instance < second.len; instance++) {
        uint source = instance == 0 ? 1 : 3;
        transparency_fixtures::Color color = transparency_fixtures::PLANAR_COLORS[source];
        second_instances.colors[instance] = {
            (float)color.x, (float)color.y, (float)color.z,
            (float)transparency_fixtures::PLANAR_COVERAGES[source],
        };
    }
    target.scene.mark_instances_dirty(second_batch);
}

fn TransparencyBenchScene? create_transparency_bench_scene(TransparencyBenchCase configuration) @private {
    TransparencyBenchScene target = {
        .assets = asset::create_asset_store(mem, asset::default_asset_store_desc()),
        .scene = scene::create_scene(mem, scene::default_scene_desc()),
    };
    defer catch {
        scene::destroy_scene(&target.scene);
        asset::destroy_asset_store(&target.assets);
    }

    if (configuration.corpus == "cc0") {
        ModelId model = gltf::load_model_memory(
            assets: &target.assets,
            bytes: TRANSPARENCY_BENCH_GLASS[..],
            base_dir: "",
            key: "glass_vase_flowers",
        )!;
        model::instantiate(&target.assets, &target.scene, model)!;
        target.camera = target.scene.add_camera(camera::perspective_deg(30, 0.01f, 10))!;
        target.camera.local.position = { 0.06f, 0.105f, 0.45f };
        target.camera.local.rotation = maths::look_rotation({ 0, 0, -1 }, { 0, 1, 0 });
        Node* sun = target.scene.add_light(light::directional({ 1, 1, 1 }, 1, false))!;
        sun.local.rotation = maths::look_rotation((Vec3){ -1, -2, -3 }.normalize(), { 0, 1, 0 });
        target.scene.environment = target.assets.add_environment(light::solid_environment(
            color: { 0.25f, 0.25f, 0.25f },
            settings: { .conversion_size = 32, .specular_size = 32 },
        ))!;
        transparency_bench_checker(
            target: &target,
            width: 32,
            height: 32,
            cc0: true,
        )!;
    } else {
        target.camera = target.scene.add_camera(camera::orthographic(
            height: 2,
            near: transparency_fixtures::PLANAR_NEAR,
            far: transparency_fixtures::PLANAR_FAR,
        ))!;
        if (configuration.corpus == "rough") {
            transparency_bench_checker(
                target: &target,
                width: configuration.width,
                height: configuration.height,
                cc0: false,
            )!;
            PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
            params.standard.base_color = { 1, 1, 1, 1 };
            params.standard.metallic = 0;
            params.standard.roughness = 1;
            params.ior = 1.5f;
            params.specular = 0;
            params.transmission = 1;
            MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
            common.double_sided = true;
            common.depth_write = false;
            MaterialId glass = target.assets.add_material(material::physical(params, common))!;
            float extent = (float)configuration.width / configuration.height;
            GeometryId geometry = transparency_bench_quad(
                assets: &target.assets,
                distance: 3,
                minimum_x: -extent,
                maximum_x: extent,
                minimum_y: -1,
                maximum_y: 1,
            )!;
            target.scene.add_mesh(geometry, glass)!;
        } else {
            GeometryId backdrop = transparency_bench_quad(
                assets: &target.assets,
                distance: 8.5f,
                minimum_x: -0.75f,
                maximum_x: 0.75f,
            )!;
            MaterialId material = transparency_bench_basic(&target.assets, { 0.125f, 0.25f, 0.5f, 1 })!;
            target.scene.add_mesh(backdrop, material)!;
            if (configuration.corpus == "batch") {
                transparency_bench_batches(&target)!;
                target.scene.update_world();
                return target;
            }

            transparency_fixtures::DepthFragment[17] fragments;
            uint count = configuration.corpus == "six" ? 6 : 17;
            if (count == 6) {
                transparency_fixtures::make_planar_fragments(fragments[:count]);
            } else {
                transparency_fixtures::make_dense_fragments(fragments[:count]);
            }
            foreach (fragment : fragments[:count]) {
                GeometryId sheet = transparency_bench_quad(
                    assets: &target.assets,
                    distance: 9 - 8 * fragment.depth,
                    minimum_x: -0.75f,
                    maximum_x: 0.75f,
                )!;
                MaterialId surface = transparency_bench_basic(&target.assets, {
                    (float)fragment.radiance.x,
                    (float)fragment.radiance.y,
                    (float)fragment.radiance.z,
                    (float)fragment.coverage,
                }, true)!;
                target.scene.add_mesh(sheet, surface)!;
            }
        }
    }

    target.scene.update_world();
    return target;
}

fn void destroy_transparency_bench_scene(TransparencyBenchScene* target) @private {
    scene::destroy_scene(&target.scene);
    asset::destroy_asset_store(&target.assets);
    *target = {};
}

fn void transparency_bench_gpu_sample(
    Renderer* renderer,
    TransparencyBenchSample[] samples,
    ulong first_frame,
) @private {
    if (renderer.stats.gpu_timing_state != GpuTimingState.READY) return;
    ulong completed = renderer.stats.gpu_frame_index;
    if (completed < first_frame || completed - first_frame >= samples.len) return;

    TransparencyBenchSample* sample = &samples[completed - first_frame];
    sample.gpu_ms = renderer.stats.gpu_pass_ms;
    sample.gpu_scopes_dropped = renderer.stats.gpu_scopes_dropped;
    sample.gpu_ready = true;
}

fn TransparencyBenchSummary transparency_bench_summary(double[] samples) @private {
    sort::quicksort(samples);
    usz middle = samples.len / 2;
    usz percentile = (samples.len * 95 + 99) / 100 - 1;
    return {
        .median = samples.len % 2 ? samples[middle] : (samples[middle - 1] + samples[middle]) / 2,
        .p95 = samples[percentile],
    };
}

fn TransparencyBenchSummary transparency_bench_report(
    TransparencyBenchCase configuration,
    uint run,
    String metric,
    double[] values,
) @private {
    TransparencyBenchSummary summary = transparency_bench_summary(values);
    io::printfn("timing,%s,%s,%s,%s,%s,%s,%s,%.6f,%.6f",
        configuration.corpus, configuration.capacity, configuration.shading == FORWARD ? "forward" : "deferred",
        configuration.width, configuration.height, run, metric, summary.median, summary.p95);
    return summary;
}

fn TransparencyBenchRun? measure_transparency_bench(TransparencyBenchCase configuration, uint run) @private {
    TransparencyBenchRun result;
    time::Clock setup_start = clock::now();
    TransparencyBenchScene target = create_transparency_bench_scene(configuration)!;
    defer destroy_transparency_bench_scene(&target);

    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets: &target.assets,
        desc: {
            .validation = false,
            .gpu_timings = true,
            .application_name = "transparency_benchmark",
        },
    )!;
    defer render::destroy_renderer(&renderer);

    RenderTargetId output = render::create_render_target(
        renderer: &renderer,
        desc: render::render_target_desc(configuration.width, configuration.height, PixelFormat.RGBA32_FLOAT),
    )!;
    ViewDesc desc = render::texture_view_desc(output);
    desc.shading = configuration.shading;
    desc.depth_prepass = false;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.transparency = configuration.capacity
      ? (TransparencyDesc){ .mode = LAYERED, .layer_capacity = configuration.capacity } : (TransparencyDesc){};
    ViewId view = render::create_view(&renderer, desc)!;
    result.setup_ms = (double)(clock::now() - setup_start) / 1_000_000;
    time::Clock prepare_start = clock::now();
    renderer.prepare_scene(&target.scene)!;
    render::wait_frames(&renderer)!;
    result.prepare_ms = (double)(clock::now() - prepare_start) / 1_000_000;

    for (uint warm = 0; warm < TRANSPARENCY_BENCH_DRAIN; warm++) {
        renderer.begin_frame()!;
        renderer.render_view(&target.scene, target.camera, view)!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
    }

    TransparencyBenchSample[] samples = mem::new_array(TransparencyBenchSample, TRANSPARENCY_BENCH_TOTAL);
    defer free(samples);
    ulong first_frame = renderer.frame_index;
    for (uint frame = 0; frame < TRANSPARENCY_BENCH_TOTAL; frame++) {
        time::Clock frame_start = clock::now();
        renderer.begin_frame()!;
        transparency_bench_gpu_sample(&renderer, samples[..], first_frame);
        time::Clock record_start = clock::now();
        renderer.render_view(&target.scene, target.camera, view)!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
        samples[frame].record_ms = (double)(clock::now() - record_start) / 1_000_000;
        samples[frame].frame_ms = (double)(clock::now() - frame_start) / 1_000_000;
        samples[frame].transparency = renderer.view_stats(view)!.transparency;
    }

    render::wait_frames(&renderer)!;
    gpu::MemoryStats memory = gpu::get_memory_stats(&renderer.device)!;
    ulong allocation_bytes;
    ulong block_bytes;
    foreach (heap : memory.heaps[:memory.heap_count]) {
        allocation_bytes += heap.allocation_bytes;
        block_bytes += heap.block_bytes;
    }

    Vec4[] pixels = mem::new_array(Vec4, (usz)configuration.width * configuration.height);
    defer free(pixels);
    renderer.read_render_target(output, ((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
    double checksum;
    foreach (color : pixels) {
        foreach (channel : color) {
            if (!math::is_finite(channel)) return c3d::INVALID_ARGUMENT~;
            checksum += channel;
        }
    }

    io::printfn("# adapter=%s corpus=%s capacity=%s path=%s extent=%sx%s run=%s",
        renderer.adapter_name, configuration.corpus, configuration.capacity,
        configuration.shading == FORWARD ? "forward" : "deferred", configuration.width, configuration.height, run);
    io::printfn("setup,%s,%s,%s,%.6f,%.6f,%.6f", configuration.corpus, configuration.capacity, run,
        result.setup_ms, result.prepare_ms, checksum);
    TransparencyStats work = samples[TRANSPARENCY_BENCH_WARMUP].transparency;
    ViewRecord* record = renderer.views.get(view);
    io::printfn("payload,%s,%s,%s,%s,%s,%s,%s", configuration.corpus, configuration.capacity, run,
        work.payload_bytes, record.transparency.texel_bytes, record.scene_pyramid.texel_bytes,
        TransparencyState::size + TransparencyPyramid::size);
    io::printfn("device_memory,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
        configuration.corpus, configuration.capacity, configuration.shading == FORWARD ? "forward" : "deferred",
        configuration.width, configuration.height, run, allocation_bytes, block_bytes,
        memory.live_allocation_count, memory.texture_count, memory.texture_view_count, memory.heap_count);
    io::printfn("passes,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s", configuration.corpus,
        configuration.capacity, run, work.capture_passes, work.retained_passes, work.remainder_passes,
        work.resolve_passes, work.filter_passes, work.filter_dispatches, work.filtered_mips,
        work.overflow_pixels, work.overflow, work.fallback_draws);
    double[TRANSPARENCY_BENCH_SAMPLES] values;
    for (uint index = 0; index < values.len; index++) {
        values[index] = samples[TRANSPARENCY_BENCH_WARMUP + index].record_ms;
    }
    result.metrics[0] = transparency_bench_report(
        configuration: configuration,
        run: run,
        metric: "cpu_record_ms",
        values: values[..],
    );
    for (uint index = 0; index < values.len; index++) {
        values[index] = samples[TRANSPARENCY_BENCH_WARMUP + index].frame_ms;
    }
    result.metrics[1] = transparency_bench_report(
        configuration: configuration,
        run: run,
        metric: "cpu_frame_ms",
        values: values[..],
    );
    uint complete;
    foreach (sample : samples[TRANSPARENCY_BENCH_WARMUP:TRANSPARENCY_BENCH_SAMPLES]) {
        if (sample.gpu_ready && sample.gpu_scopes_dropped == 0) complete++;
    }
    io::printfn("gpu_samples,%s,%s,%s,%s,%s", configuration.corpus, configuration.capacity, run,
        complete, TRANSPARENCY_BENCH_SAMPLES);
    if (complete != TRANSPARENCY_BENCH_SAMPLES) return c3d::UNSUPPORTED~;
    for (uint index = 0; index < values.len; index++) {
        double sum;
        foreach (duration : samples[TRANSPARENCY_BENCH_WARMUP + index].gpu_ms) sum += duration;
        values[index] = sum;
    }
    result.metrics[2] = transparency_bench_report(
        configuration: configuration,
        run: run,
        metric: "gpu_all_categories_ms",
        values: values[..],
    );
    uint metric_index = 3;
    foreach (pass : (Pass[6]){ TRANSPARENCY_CAPTURE, TRANSPARENCY_RETAINED, TRANSPARENCY_REMAINDER,
        TRANSPARENCY_RESOLVE, TRANSPARENCY_FILTER, SCENE_SNAPSHOT }) {
        for (uint index = 0; index < values.len; index++) {
            values[index] = samples[TRANSPARENCY_BENCH_WARMUP + index].gpu_ms[pass.ordinal];
        }
        result.metrics[metric_index++] = transparency_bench_report(
            configuration: configuration,
            run: run,
            metric: Pass::names[pass.ordinal],
            values: values[..],
        );
    }
    return result;
}

fn void transparency_bench_spread(
    TransparencyBenchCase configuration,
    TransparencyBenchRun[] runs,
) @private {
    for (uint metric = 0; metric < TRANSPARENCY_BENCH_METRIC_COUNT; metric++) {
        double median_low = runs[0].metrics[metric].median;
        double median_high = median_low;
        double p95_low = runs[0].metrics[metric].p95;
        double p95_high = p95_low;
        foreach (run : runs[1..]) {
            median_low = math::min(median_low, run.metrics[metric].median);
            median_high = math::max(median_high, run.metrics[metric].median);
            p95_low = math::min(p95_low, run.metrics[metric].p95);
            p95_high = math::max(p95_high, run.metrics[metric].p95);
        }
        io::printfn("spread,%s,%s,%s,%s,%s,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
            configuration.corpus, configuration.capacity, configuration.shading == FORWARD ? "forward" : "deferred",
            configuration.width, configuration.height, TRANSPARENCY_BENCH_METRICS[metric],
            median_low, median_high, median_high - median_low, p95_low, p95_high, p95_high - p95_low);
    }
}

fn int main(String[] args) {
    if (args.len == 5 || args.len > 6) {
        io::printn("usage: bench_transparency [all|six|dense|rough|cc0|batch] [all|sorted|k1|k4|k16] "
            "[all|forward|deferred] [width height]");
        return 1;
    }

    String corpus_filter = args.len > 1 ? args[1] : "all";
    String mode_filter = args.len > 2 ? args[2] : "all";
    String path_filter = args.len > 3 ? args[3] : "all";
    uint width = args.len > 4 ? args[4].to_uint()!! : 0;
    uint height = args.len > 5 ? args[5].to_uint()!! : 0;
    if (args.len == 6 && (!width || !height || width > 4096 || height > 4096)) return 1;

    io::printn("# protocol=measurement_only optimization=O3 validation=off profiler=GPU+INTERNAL "
        "prewarm=FRAMES_IN_FLIGHT+1 warmup=120 measured=240 runs=3 fresh_renderer_per_run "
        "cpu_record_excludes_begin_slot_wait image_readback_after_timing_only optical_shadows=off");
    io::printfn("# cc0_sha256=%s bytes=%s authored_identity=true", TRANSPARENCY_BENCH_GLASS_SHA,
        TRANSPARENCY_BENCH_GLASS.len);
    io::printn("# timing_columns=record,corpus,capacity,path,width,height,run,metric,median_ms,p95_ms");
    io::printn("# setup_columns=record,corpus,capacity,run,setup_ms,prepare_and_wait_ms,post_loop_checksum");
    io::printn("# payload_columns=record,corpus,capacity,run,transparency_payload_bytes,layer_image_bytes,"
        "scene_pyramid_bytes,resource_owner_header_bytes");
    io::printn("# device_memory_phase=post_timing_pre_image_readback whole_device_heaps=true "
        "transparency_payload_is_image_and_counter_readback_bytes=true");
    io::printn("# device_memory_columns=record,corpus,capacity,path,width,height,run,allocation_bytes,block_bytes,"
        "live_allocation_count,texture_count,texture_view_count,heap_count");
    io::printn("# passes_columns=record,corpus,capacity,run,capture,retained,remainder,resolve,"
        "filter,filter_dispatch,mips,"
        "completed_overflow_pixels,completed_overflow,fallback_draws");
    io::printn("# spread_columns=record,corpus,capacity,path,width,height,metric,min_median_ms,max_median_ms,"
        "median_spread_ms,min_p95_ms,max_p95_ms,p95_spread_ms");
    if (corpus_filter == "batch") {
        io::printn("# batch_fixture=interleaved_planar groups=5 first_batch_distances=3/7 "
            "middle_mesh_distance=5 second_batch_distances=4/6 colors_and_coverage=planar_fixture "
            "default_extent=128x128 variants=ordinary_instanced_only default_all_excludes_batch=true");
    }
    uint selected;
    foreach (corpus : (String[5]){ "six", "dense", "rough", "cc0", "batch" }) {
        if (corpus == "batch" && corpus_filter == "all") continue;
        if (corpus_filter != "all" && corpus_filter != corpus) continue;
        foreach (mode_index, capacity : (uint[4]){ 0, 1, 4, 16 }) {
            String name = ((String[4]){ "sorted", "k1", "k4", "k16" })[mode_index];
            if (mode_filter != "all" && mode_filter != name) continue;
            foreach (shading : (ShadingPath[2]){ FORWARD, DEFERRED }) {
                if (path_filter != "all" && path_filter != (shading == FORWARD ? "forward" : "deferred")) continue;
                TransparencyBenchCase configuration = {
                    .corpus = corpus,
                    .width = width ? width : corpus == "cc0" ? 512 : corpus == "rough" ? 129 : 128,
                    .height = height ? height : corpus == "cc0" ? 288 : corpus == "rough" ? 65 : 128,
                    .capacity = capacity,
                    .shading = shading,
                };
                selected++;
                TransparencyBenchRun[TRANSPARENCY_BENCH_RUNS] runs;
                for (uint run = 0; run < TRANSPARENCY_BENCH_RUNS; run++) {
                    TransparencyBenchRun? measured = measure_transparency_bench(configuration, run);
                    if (catch excuse = measured) {
                        io::printfn("NOT_MEASURED corpus=%s capacity=%s path=%s run=%s fault=%s", corpus,
                            capacity, shading == FORWARD ? "forward" : "deferred", run, excuse);
                        return 2;
                    }
                    runs[run] = measured;
                }
                transparency_bench_spread(configuration, runs[..]);
            }
        }
    }
    return selected ? 0 : 1;
}
