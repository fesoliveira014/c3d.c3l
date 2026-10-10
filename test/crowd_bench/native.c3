module c3d::test::crowd_bench @feat(C3D_CROWD_BENCH_NATIVE);

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::maths;
import c3d::model;
import c3d::profile;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import c3d::test::animated_lod_fixtures;
import gpu;
import std::hash::sha256;
import std::io;
import std::io::file;
import std::math;
import std::sort;
import std::time;
import std::time::clock;

const uint NATIVE_WIDTH = 640;
const uint NATIVE_HEIGHT = 480;
const uint NATIVE_SHADOW_RESOLUTION = 256;
const uint NATIVE_CAPTURE_FRAMES = WARMUPS + SAMPLES;
const uint NATIVE_DRAIN_FRAMES = render::FRAMES_IN_FLIGHT + 1;
const uint NATIVE_GPU_SCOPES = 2048; // Matches the GPU adapter's existing default query budget.
const uint NATIVE_GPU_LABEL_BYTES = 65536; // Matches the GPU adapter's existing copied-label budget.
const char[*] NATIVE_DEPTH_PROBE = $embed("../gpu/render/probe_readback.comp.glsl");

enum NativeLodMode {
    OFF,
    NEAR,
    MIDDLE,
    FAR,
}

enum NativeTraceMode {
    OFF,
    SOFTWARE,
    HARDWARE,
}

struct NativeRowMode {
    NativeLodMode lod;
    NativeTraceMode trace;
    uint posed_capacity;
    uint[3] triangles;
    ulong lod_host;
    bool validation;
    uint repetitions;
    uint skip_rows;
}

NativeRowMode native_row_mode @private;
struct NativeRevision {
    Entity owner;
    ulong playback_identity;
    ulong lod_identity;
    ulong source_epoch;
    uint descriptor_revision;
    uint publication_revision;
    uint source_batch_revision;
    ModelId model;
    uint model_revision;
    uint admitted_model_revision;
    uint representation;
    uint level;
    uint logical_part;
    uint template_node;
    GeometryId geometry;
    uint geometry_revision;
    uint admitted_geometry_revision;
    SkeletonId skeleton;
    uint skeleton_revision;
    uint admitted_skeleton_revision;
    SkeletonId source_skeleton;
    uint source_skeleton_revision;
    uint admitted_source_skeleton_revision;
    uint logical_weights;
    uint live;
}
struct NativeFiles {
    File raw;
    File gpu;
    File summary;
    File storage;
    File metadata;
    File failures;
    File lod_history;
    File revisions;
}

struct NativeSample {
    ulong submission;
    ulong evaluate_ns;
    ulong publish_ns;
    ulong world_ns;
    ulong render_ns;
    AllocationCounters allocations;
    ulong upload_bytes;
    ulong upload_peak;
    ulong device_copy_bytes;
    ulong current_palette;
    ulong current_morph;
    ulong current_records;
    ulong current_bounds;
    ulong previous_palette;
    ulong previous_morph;
    ulong previous_matrices;
    ulong previous_headers;
    ulong history_host;
    ulong persistent_instances;
    ulong renderer_host;
    ulong renderer_peak;
    ulong gpu_allocations;
    ulong gpu_blocks;
    ulong driver_usage;
    uint tested;
    uint visible;
    ulong cull_submission;
    bool cull_ready;
    uint draws;
    uint triangles;
    uint instances;
    uint cull_dispatches;
    uint cull_overflows;
    uint sort_dispatches;
    uint sort_overflows;
    uint shadow_layers;
    uint shared_shadows;
    uint events;
    uint dropped_events;
    double gpu_frame_ns;
    double[render::PASS_COUNT] gpu_pass_ns;
    bool[render::PASS_COUNT] gpu_pass_valid;
    bool gpu_frame_valid;
    uint[3] lod_selected;
    uint[3] lod_visible;
    uint lod_tested;
    uint lod_fallbacks;
    ulong selected_authored_triangles;
    ulong visible_authored_triangles;
    ulong current_part_locals;
    ulong lod_history_host;
    ulong lod_history_gpu;
    uint trace_instances;
    uint trace_posed;
    uint trace_overflow;
    uint trace_skipped;
    ulong trace_posed_bytes;
    uint trace_poses;
    uint trace_refits;
    uint blas_builds;
    uint blas_updates;
    NativeRevision[] revisions;
    ulong instance_copy_bytes;
    ulong instance_publication_copy_bytes;
    ulong instance_cold_copy_bytes;
    ulong instance_other_copy_bytes;
    ulong geometry_copy_bytes;
    ulong geometry_revision_copy_bytes;
    ulong geometry_cold_copy_bytes;
    ulong geometry_other_copy_bytes;
}

struct NativeDepthRoot {
    gpu::GpuAddress output_address;
    gpu::TextureIndex atlas;
    uint width;
    uint height;
    uint padding;
}
$assert NativeDepthRoot::size == 24;

fn void close_native_files(NativeFiles* files) {
    (void)files.raw.close();
    (void)files.gpu.close();
    (void)files.summary.close();
    (void)files.storage.close();
    (void)files.metadata.close();
    (void)files.failures.close();
    (void)files.lod_history.close();
    (void)files.revisions.close();
}

fn void? create_native_files(String directory, NativeFiles* files) {
    defer catch close_native_files(files);
    files.raw = file::open(joined_path(directory, "native-raw.csv")!, "wb")!;
    files.gpu = file::open(joined_path(directory, "native-gpu.csv")!, "wb")!;
    files.summary = file::open(joined_path(directory, "native-summary.csv")!, "wb")!;
    files.storage = file::open(joined_path(directory, "native-storage.csv")!, "wb")!;
    files.metadata = file::open(joined_path(directory, "native-metadata.csv")!, "wb")!;
    files.failures = file::open(joined_path(directory, "native-failures.csv")!, "wb")!;
    files.lod_history = file::open(joined_path(directory, "native-lod-history.csv")!, "wb")!;
    files.revisions = file::open(joined_path(directory, "native-revisions.csv")!, "wb")!;
    io::fprintn(
        out: &files.raw,
        x: "fixture,script,configured,live,repetition,views,lod_mode,trace_kind,posed_capacity,sample,script_frame,submission_frame,"
          "seed,dt,evaluate_ms,publish_ms,world_ms,record_submit_ms,upload_ring_bytes,upload_high_"
          "water,device_copy_bytes,current_palette_payload,current_morph_payload,current_part_"
          "record_payload,current_bounds_payload,previous_palette_payload,previous_morph_payload,"
          "previous_matrix_payload,previous_header_payload,history_host_payload,persistent_"
          "instance_gpu_bytes,renderer_host_requested,renderer_host_high_water,gpu_requested_"
          "allocations,gpu_blocks,driver_heap_usage_estimate,tested,visible,cull_submission,cull_"
          "ready,draws,cpu_known_triangles,cpu_known_instance_draws,cull_dispatches,cull_overflows,"
          "sort_dispatches,sort_overflows,shadow_layers,shared_shadow_sets,events,dropped_events,"
          "evaluate_publish_acquires,evaluate_publish_resizes,evaluate_publish_requested_bytes,current_part_local_payload,lod_history_host_payload,"
          "lod_history_gpu_bytes,lod_selected_0,lod_selected_1,lod_selected_2,lod_visible_0,"
          "lod_visible_1,lod_visible_2,lod_sources_tested,lod_fallbacks,selected_authored_triangles,"
          "visible_authored_triangles,trace_instances,trace_posed,trace_overflow,trace_skipped,"
          "trace_posed_gpu_bytes,trace_poses,trace_refits,blas_builds,blas_updates,"
          "evaluate_publish_releases,instance_stream_copy_bytes,instance_publication_revision_copy_bytes,"
          "instance_cold_or_grown_copy_bytes,instance_other_copy_bytes,geometry_copy_bytes,"
          "geometry_asset_revision_copy_bytes,geometry_cold_copy_bytes,geometry_other_copy_bytes",
    )!;
    io::fprintn(
        out: &files.gpu,
        x: "fixture,script,configured,live,repetition,views,lod_mode,trace_kind,posed_capacity,script_frame,submission_frame,scope_"
          "kind,has_view,view_index,view_generation,pass_ordinal,label,start_ns,duration_ns,gpu_"
          "state,dropped_scopes",
    )!;
    io::fprintn(&files.summary, "fixture,script,configured,live,repetition,views,lod_mode,trace_kind,posed_capacity,metric,samples,median_ms,p95_ms")!;
    io::fprintn(&files.storage, "fixture,script,configured,live,repetition,views,lod_mode,trace_kind,posed_capacity,category,bytes")!;
    io::fprintn(&files.metadata, "key,value")!;
    io::fprintn(&files.revisions,
        "fixture,script,configured,live,repetition,views,lod_mode,trace_kind,posed_capacity,"
        "script_frame,submission_frame,owner_index,owner_generation,playback_identity,lod_identity,"
        "source_epoch,descriptor_revision,publication_revision,source_batch_revision,model_index,"
        "model_generation,model_revision,admitted_model_revision,representation,level,logical_part,"
        "template_node,geometry_index,geometry_generation,geometry_revision,admitted_geometry_revision,"
        "skeleton_index,skeleton_generation,skeleton_revision,admitted_skeleton_revision,"
        "source_skeleton_index,source_skeleton_generation,source_skeleton_revision,"
        "admitted_source_skeleton_revision,logical_weights,source_live")!;
    io::fprintn(&files.lod_history,
        "fixture,script,configured,live,repetition,views,lod_mode,trace_kind,posed_capacity,"
        "capture_submission,view_index,source_index,available,level,generation,reject_history,authored_triangles")!;
    io::fprintn(
        out: &files.failures,
        x: "fixture,script,configured,live,repetition,views,lod_mode,trace_kind,posed_capacity,fault,seed,dt,action_capacity,event_capacity",
    )!;
}

fn void? native_metadata(NativeFiles* files, String key, String value) {
    csv_string(&files.metadata, key)!;
    csv_string(&files.metadata, value, true)!;
}

fn void? native_metadata_uint(NativeFiles* files, String key, ulong value) {
    csv_string(&files.metadata, key)!;
    csv_uint(&files.metadata, value, true)!;
}

fn void? native_key(
    File* output,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    uint views,
) {
    row_key(
        output: output,
        corpus: corpus,
        script: script,
        live: live,
        repetition: repetition,
    )!;
    csv_uint(output, views)!;
    csv_string(output, native_lod_name(native_row_mode.lod))!;
    csv_string(output, native_trace_name(native_row_mode.trace))!;
    csv_uint(output, native_row_mode.trace == NativeTraceMode.OFF ? 0 : native_row_mode.posed_capacity)!;
}

fn ulong native_history_bytes(ViewHistory* history) {
    ulong bytes = (ulong)history.models.len * Mat4::size + (ulong)history.owners.len * Entity::size
      + (ulong)history.seen.len * ulong::size + (ulong)history.poses.len * PoseRecord::size;
    foreach (&pose : history.poses) bytes += native_pose_bytes(pose);
    return bytes;
}

fn void native_previous_payload(ViewHistory* history, NativeSample* sample) {
    if (!history.valid) return;
    foreach (&pose : history.poses) native_previous_pose(pose, sample);
}

fn void native_pair_counters(Renderer* renderer, NativeSample[] samples) {
    Stats* stats = &renderer.stats;
    if (!stats.lod_counts_valid || stats.lod_frame_index >= samples.len) return;
    NativeSample* sample = &samples[stats.lod_frame_index];
    sample.tested = stats.instances_tested;
    sample.visible = stats.instances_visible;
    sample.cull_submission = stats.lod_frame_index;
    sample.cull_ready = true;
    sample.lod_tested = stats.lod_instances_tested;
    sample.lod_fallbacks = stats.lod_fallbacks;
    for (uint level = 0; level < 3; level++) {
        sample.lod_selected[level] = stats.lod_selected[level];
        sample.lod_visible[level] = stats.lod_visible[level];
        sample.selected_authored_triangles += (ulong)stats.lod_selected[level] * native_row_mode.triangles[level];
        sample.visible_authored_triangles += (ulong)stats.lod_visible[level] * native_row_mode.triangles[level];
    }
}

fn void? native_render_frame(
    Renderer* renderer,
    Scene* scene,
    Node* camera,
    ViewId[] views,
    NativeSample* sample,
    NativeSample[] samples,
    Node* source_owner,
    CounterAllocator* renderer_counter,
    double time,
    float delta,
) {
    time::Clock started = clock::now();
    renderer.begin_frame({ .time = time, .delta = delta })!;
    defer catch render::abort_frame(renderer);
    sample.submission = renderer.frame_index;
    stage_native_revision_uploads(
        renderer: renderer,
        scene: scene,
        owner: source_owner,
        sample: sample,
    )!;
    foreach (view : views) {
        native_previous_payload(&renderer.views.get(view).history, sample);
        renderer.render_view(scene, camera, view)!;
        renderer.finish_view(view)!;
    }
    if (native_row_mode.trace != NativeTraceMode.OFF) {
        renderer.prepare_scene_trace(scene, native_row_mode.trace == NativeTraceMode.HARDWARE
            ? TraceKind.HARDWARE : TraceKind.SOFTWARE)!;
    }
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    sample.upload_bytes = frame.upload.head;
    foreach (allocation : frame.upload.overflow) {
        sample.upload_bytes += gpu::get_allocation_span(
            device: &renderer.device,
            allocation: allocation,
        )!.size;
    }
    sample.current_palette = (ulong)(renderer.deformation.crowd_palettes.len() + renderer.deformation.animated_palettes.len());
    sample.current_morph = (ulong)(renderer.deformation.crowd_morphs.len() + renderer.deformation.animated_morphs.len());
    sample.current_part_locals = (ulong)renderer.deformation.animated_parts.len();
    sample.current_bounds = (ulong)renderer.deformation.crowd_bounds.len();
    foreach (slot : renderer.instances.slots) {
        if (slot.key.scene != scene.identity || slot.last_seen != sample.submission) continue;
        sample.current_records += (ulong)slot.capacity * shader::InstanceGpu::size;
        if (slot.allocation.is_valid()) {
            sample.persistent_instances += gpu::get_allocation_span(
                device: &renderer.device,
                allocation: slot.allocation,
            )!.size;
        }
    }
    renderer.end_frame()!;
    sample.render_ns = (ulong)started.to_now();
    sample.device_copy_bytes = renderer.stats.upload_bytes;
    sample.draws = renderer.stats.draws;
    sample.triangles = renderer.stats.triangles;
    sample.instances = renderer.stats.instances;
    sample.cull_dispatches = renderer.stats.cull_dispatches;
    sample.cull_overflows = renderer.stats.cull_overflows;
    sample.sort_dispatches = renderer.stats.sort_dispatches;
    sample.sort_overflows = renderer.stats.sort_overflows;
    sample.shadow_layers = renderer.stats.shadow_layers;
    sample.shared_shadows = renderer.stats.shadow_sets_shared;
    sample.trace_instances = renderer.stats.trace_instances;
    sample.trace_posed = renderer.stats.trace_posed_instances;
    sample.trace_overflow = renderer.stats.trace_posed_overflow;
    sample.trace_skipped = renderer.stats.trace_skipped;
    sample.trace_posed_bytes = renderer.stats.trace_posed_bytes;
    sample.trace_poses = renderer.stats.trace_poses;
    sample.trace_refits = renderer.stats.trace_refits;
    sample.blas_builds = renderer.stats.blas_builds;
    sample.blas_updates = renderer.stats.blas_updates;
    sample.renderer_host = (ulong)renderer_counter.tracker.usage;
    sample.renderer_peak = (ulong)renderer_counter.tracker.max_usage;
    foreach (view : views) {
        ViewRecord* record = renderer.views.get(view);
        sample.history_host += native_history_bytes(&record.history);
        sample.lod_history_host += record.lod_history.entries.len * LodHistoryEntry::size;
        foreach (entry : record.lod_history.entries) {
            if (!entry.allocation.is_valid()) continue;
            sample.lod_history_gpu += gpu::get_allocation_span(&renderer.device, entry.allocation)!.size;
        }
    }
    gpu::MemoryStats memory = gpu::get_memory_stats(&renderer.device)!;
    foreach (heap : memory.heaps[:memory.heap_count]) {
        sample.gpu_allocations += heap.allocation_bytes;
        sample.gpu_blocks += heap.block_bytes;
        sample.driver_usage += heap.usage;
    }
    native_pair_counters(renderer, samples);
}

fn void? write_native_gpu(
    NativeFiles* files,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    uint views,
    profile::Recorder* recorder,
    NativeSample[] samples,
) {
    for (uint frame = WARMUPS; frame < NATIVE_CAPTURE_FRAMES; frame++) {
        profile::FrameCaptureView capture = recorder.frame(frame)!;
        if (capture.gpu_state != profile::CaptureState.READY || capture.dropped_gpu_scopes) {
            return c3d::CAPACITY_EXCEEDED~;
        }
        foreach (scope : capture.gpu) {
            if (scope.renderer_frame != samples[frame].submission) return c3d::INVALID_ARGUMENT~;
            if (scope.info.kind == profile::GpuScopeKind.FRAME) {
                samples[frame].gpu_frame_ns = scope.duration_ns;
                samples[frame].gpu_frame_valid = true;
            }
            if (scope.info.kind == profile::GpuScopeKind.PASS || scope.info.kind == profile::GpuScopeKind.COMPUTE_DISPATCH) {
                samples[frame].gpu_pass_ns[scope.info.pass_ordinal] += scope.duration_ns;
                samples[frame].gpu_pass_valid[scope.info.pass_ordinal] = true;
            }
            native_key(
                output: &files.gpu,
                corpus: corpus,
                script: script,
                live: live,
                repetition: repetition,
                views: views,
            )!;
            csv_uint(&files.gpu, frame)!;
            csv_uint(&files.gpu, scope.renderer_frame)!;
            char[128] text;
            csv_string(&files.gpu, (String)io::bprintf(text[..], "%s", scope.info.kind)!)!;
            csv_uint(&files.gpu, scope.info.has_view ? 1 : 0)!;
            csv_uint(&files.gpu, scope.info.view_index)!;
            csv_uint(&files.gpu, scope.info.view_generation)!;
            csv_uint(&files.gpu, scope.info.pass_ordinal)!;
            csv_string(&files.gpu, scope.label)!;
            csv_float(&files.gpu, scope.start_ns)!;
            csv_float(&files.gpu, scope.duration_ns)!;
            csv_string(&files.gpu, "READY")!;
            csv_uint(&files.gpu, capture.dropped_gpu_scopes, true)!;
        }
    }
}

fn void? write_native_samples(
    NativeFiles* files,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    uint views,
    NativeSample[] samples,
) {
    for (uint frame = WARMUPS; frame < NATIVE_CAPTURE_FRAMES; frame++) {
        NativeSample sample = samples[frame];
        if (!sample.cull_ready || sample.cull_submission != sample.submission || !sample.gpu_frame_valid) {
            return c3d::INVALID_ARGUMENT~;
        }
        native_key(
            output: &files.raw,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
            views: views,
        )!;
        csv_uint(&files.raw, (ulong)(frame - WARMUPS))!;
        csv_uint(&files.raw, frame)!;
        csv_uint(&files.raw, sample.submission)!;
        csv_uint(&files.raw, SCRIPT_SEED)!;
        csv_float(&files.raw, FIXED_DT)!;
        foreach (elapsed : (ulong[4]){ sample.evaluate_ns, sample.publish_ns, sample.world_ns, sample.render_ns }) {
            csv_float(&files.raw, (double)elapsed / NANOSECONDS_PER_MILLISECOND)!;
        }
        ulong[67] fields = {
            sample.upload_bytes, sample.upload_peak, sample.device_copy_bytes, sample.current_palette,
            sample.current_morph, sample.current_records, sample.current_bounds, sample.previous_palette,
            sample.previous_morph, sample.previous_matrices, sample.previous_headers, sample.history_host,
            sample.persistent_instances, sample.renderer_host, sample.renderer_peak, sample.gpu_allocations,
            sample.gpu_blocks, sample.driver_usage, sample.tested, sample.visible, sample.cull_submission,
            sample.cull_ready ? 1 : 0, sample.draws, sample.triangles, sample.instances, sample.cull_dispatches,
            sample.cull_overflows, sample.sort_dispatches, sample.sort_overflows, sample.shadow_layers,
            sample.shared_shadows, sample.events, sample.dropped_events, sample.allocations.acquire_calls,
            sample.allocations.resize_calls, sample.allocations.requested_bytes,
            sample.current_part_locals, sample.lod_history_host, sample.lod_history_gpu,
            sample.lod_selected[0], sample.lod_selected[1], sample.lod_selected[2],
            sample.lod_visible[0], sample.lod_visible[1], sample.lod_visible[2],
            sample.lod_tested, sample.lod_fallbacks, sample.selected_authored_triangles,
            sample.visible_authored_triangles, sample.trace_instances, sample.trace_posed,
            sample.trace_overflow, sample.trace_skipped, sample.trace_posed_bytes, sample.trace_poses,
            sample.trace_refits, sample.blas_builds, sample.blas_updates,
            sample.allocations.release_calls, sample.instance_copy_bytes, sample.instance_publication_copy_bytes,
            sample.instance_cold_copy_bytes, sample.instance_other_copy_bytes, sample.geometry_copy_bytes,
            sample.geometry_revision_copy_bytes, sample.geometry_cold_copy_bytes, sample.geometry_other_copy_bytes,
        };
        foreach (index, value : fields) csv_uint(&files.raw, value, index + 1 == fields.len)!;
    }
    String[12] metrics = { "evaluate", "publish", "world", "record_submit", "gpu_frame", "gpu_selection_cull", "gpu_depth", "gpu_velocity", "gpu_shadow", "gpu_sort", "gpu_trace_pose_refit", "gpu_acceleration_build" };
    render::Pass[7] passes = { render::Pass.INSTANCE_CULL, render::Pass.DEPTH_PREPASS, render::Pass.VELOCITY, render::Pass.SHADOW_ATLAS, render::Pass.INSTANCE_SORT, render::Pass.TRACE_POSE, render::Pass.ACCELERATION_BUILD };
    foreach (metric, label : metrics) {
        double[SAMPLES] sorted;
        uint count;
        foreach (sample : samples[WARMUPS:SAMPLES]) {
            double value;
            switch (metric) {
                case 0: value = (double)sample.evaluate_ns;
                case 1: value = (double)sample.publish_ns;
                case 2: value = (double)sample.world_ns;
                case 3: value = (double)sample.render_ns;
                case 4: value = sample.gpu_frame_ns;
                default:
                    render::Pass pass = passes[metric - 5];
                    if (!sample.gpu_pass_valid[pass]) continue;
                    value = sample.gpu_pass_ns[pass];
            }
            sorted[count++] = value;
        }
        sort::quicksort(sorted[:count]);
        native_key(
            output: &files.summary,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
            views: views,
        )!;
        csv_string(&files.summary, label)!;
        csv_uint(&files.summary, count)!;
        if (!count) {
            csv_string(&files.summary, "NA")!;
            csv_string(&files.summary, "NA", true)!;
        } else {
            csv_float(&files.summary, sorted[(count * 50 + 99) / 100 - 1] / NANOSECONDS_PER_MILLISECOND)!;
            csv_float(&files.summary, sorted[(count * 95 + 99) / 100 - 1] / NANOSECONDS_PER_MILLISECOND, true)!;
        }
    }
}

fn void? write_native_storage(
    NativeFiles* files,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    uint views,
    Storage storage,
    profile::Recorder* recorder,
    Renderer* renderer,
    NativeSample sample,
) {
    String[27] names = {
        "playback_fixed", "actions", "masks", "order", "spaces", "cursors", "references", "crowd_events",
        "event_scratch", "outputs", "parts", "scene_overhead", "scene_requested_total", "scene_requested_high_water",
        "fixed_per_instance", "fixed_global", "formula_total", "renderer_requested_host", "renderer_host_high_water",
        "history_retained_host_payload", "persistent_instance_gpu", "profiler_recorder_host", "profiler_adapter_host",
        "lod_history_host_payload", "lod_history_gpu_bytes", "posed_trace_gpu_bytes", "lod_attach_host_subset_scene_overhead",
    };
    ulong[27] bytes = {
        storage.fixed_playback, storage.actions, storage.masks, storage.order, storage.spaces, storage.cursors,
        storage.references, storage.crowd_events, storage.event_scratch, storage.outputs, storage.parts,
        storage.scene_overhead, storage.total, storage.high_water, storage.fixed_per_instance, storage.fixed_global,
        storage.formula_total, sample.renderer_host, sample.renderer_peak, sample.history_host, sample.persistent_instances,
        recorder.allocated_bytes, renderer.gpu_profile.adapter.allocated_bytes,
        sample.lod_history_host, sample.lod_history_gpu, sample.trace_posed_bytes, native_row_mode.lod_host,
    };
    foreach (index, name : names) {
        native_key(
            output: &files.storage,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
            views: views,
        )!;
        csv_string(&files.storage, name)!;
        csv_uint(&files.storage, bytes[index], true)!;
    }
}

fn String native_hash(char[] bytes) {
    char[32] digest = sha256::hash(bytes);
    char[] hexadecimal = alloc::new_array(tmem, char, 64);
    foreach (index, value : digest) {
        hexadecimal[index * 2] = HEX_DIGITS[value >> 4];
        hexadecimal[index * 2 + 1] = HEX_DIGITS[value & 15];
    }
    return (String)hexadecimal;
}

fn void? capture_native_images(
    AssetStore* assets,
    Renderer* renderer,
    Scene* scene,
    Node* camera,
    ViewId view,
    RenderTargetId target,
    Corpus corpus,
    String directory,
    NativeFiles* files,
) {
    @pool() {
        char[] spirv = compile::compile_glsl(tmem, (String)NATIVE_DEPTH_PROBE[..], ShaderStage.COMPUTE)!;
        ComputeShaderDesc desc = { .compute = spirv };
        ComputeShaderId shader = assets.add_compute_shader(&desc)!;
        uint pixels = NATIVE_WIDTH * NATIVE_HEIGHT;
        gpu::AllocationDesc allocation = {
            .size = (usz)pixels * Vec4::size,
            .alignment = render::STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.CPU_READ,
            .access = { .graphics },
            .debug_name = "crowd_native_capture",
        };
        gpu::MappedGpuSpan mapped = gpu::allocate_mapped_memory(&renderer.device, &allocation)!;
        defer {
            gpu::GpuAllocation owned = mapped.span.allocation();
            gpu::free_allocation(&renderer.device, &owned)!!;
        }
        BufferId output = renderer.create_buffer({ .size = allocation.size, .debug_name = "crowd_native_depth" })!;
        ulong capture_frame = renderer.frame_index;
        renderer.begin_frame({ .time = (double)NATIVE_CAPTURE_FRAMES * FIXED_DT, .delta = 0 })!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(scene, camera, view)!;
        Target* depth = &renderer.views.get(view).depth;
        depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
        NativeDepthRoot root = {
            .output_address = renderer.buffer_address(output),
            .atlas = depth.view.index,
            .width = NATIVE_WIDTH,
            .height = NATIVE_HEIGHT,
        };
        BufferId[1] writes = { output };
        renderer.dispatch({
            .shader = shader,
            .root = ((char*)&root)[:NativeDepthRoot::size],
            .groups = { NATIVE_WIDTH / 8, NATIVE_HEIGHT / 8, 1 },
            .writes = writes[..],
        })!;
        gpu::Barrier written = { .before = { .compute }, .after = { .transfer } };
        gpu::cmd_barrier(&renderer.commands, &written)!;
        gpu::BufferCopyDesc copy = {
            .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(output).allocation)!,
            .dst = mapped.span,
        };
        gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
        gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
        gpu::cmd_barrier(&renderer.commands, &copied)!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
        render::wait_frames(renderer)!;
        gpu::invalidate_mapped_span(&renderer.device, mapped.span)!;
        float[] depths = alloc::new_array(tmem, float, pixels);
        Vec4* vectors = (Vec4*)mapped.bytes.ptr;
        uint covered;
        for (uint index = 0; index < pixels; index++) {
            depths[index] = vectors[index].x;
            if (depths[index] > 0) covered++;
        }
        char[] color = alloc::new_array(tmem, char, (sz)pixels * Vec4::size);
        renderer.read_render_target(target, color)!;
        char[] depth_bytes = ((char*)depths.ptr)[:depths.len * float::size];
        String prefix = native_row_mode.lod == NativeLodMode.OFF && native_row_mode.trace == NativeTraceMode.OFF
          ? corpus.label : string::tformat("%s-%s-%s", corpus.label,
              native_lod_name(native_row_mode.lod), native_trace_name(native_row_mode.trace));
        String color_name = string::tformat("%s-color.rgba32f.bin", prefix);
        String depth_name = string::tformat("%s-depth.r32f.bin", prefix);
        file::save(joined_path(directory, color_name)!, color)!;
        file::save(joined_path(directory, depth_name)!, depth_bytes)!;
        native_metadata(files, color_name, native_hash(color))!;
        native_metadata(files, depth_name, native_hash(depth_bytes))!;
        native_metadata_uint(files, string::tformat("%s_capture_submission", corpus.label), capture_frame)!;
        native_metadata_uint(files, string::tformat("%s_capture_covered_pixels", corpus.label), covered)!;
    };
}

fn void? measure_native_row(
    AssetStore* assets,
    ModelId model_id,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    uint view_count,
    String directory,
    bool capture,
    NativeFiles* files,
    AnimatedLodFixtures* levels = null,
) {
    native_row_mode.lod_host = 0;
    CounterAllocator counter;
    counter.tracker.init(mem);
    defer counter.tracker.free();
    Scene scene = scene::create_scene(&counter, { .max_nodes = SCENE_CAPACITY });
    defer scene::destroy_scene(&scene);
    ModelTemplate* template = &assets.model(model_id).data;
    ClipId base_clip = corpus.quaternius ? clip_named(assets, template, "Walk_Loop")! : template.clips[0];
    ClipId moving_clip = corpus.quaternius ? clip_named(assets, template, "Jog_Fwd_Loop")! : base_clip;
    ClipId idle_clip = corpus.quaternius ? clip_named(assets, template, "Idle_Loop")! : base_clip;
    float duration = assets.clip(base_clip).data.duration;
    @pool() {
        CrowdInstance[] instances = alloc::new_array(tmem, CrowdInstance, live);
        uint columns = (uint)math::ceil(math::sqrt((float)live));
        foreach (uint index, &instance : instances) {
            *instance = {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = base_clip, .time = initial_fraction(index) * duration, .speed = 1, .loop = true },
                .color = { 1, 1, 1, 1 },
            };
            instance.placement.position = { (float)(index % columns) * PLACEMENT_SPACING, 0, -(float)(index / columns) * PLACEMENT_SPACING };
        }
        Node* root = model::add_crowd(
            assets: assets,
            scene: &scene,
            model: model_id,
            capacity: live,
            pose_bounds: corpus.bounds,
            instances: instances,
            name: "crowd_bench",
            trace: native_row_mode.trace != NativeTraceMode.OFF,
            actions_per_instance: ACTION_CAPACITY,
            event_capacity: EVENT_CAPACITY,
        )!;
        AnimatedCrowd* crowd = scene.get(root, AnimatedCrowd);
        configure_script(
            assets: assets,
            crowd: crowd,
            script: script,
            base_clip: base_clip,
            moving_clip: moving_clip,
            idle_clip: idle_clip,
        )!;
        if (native_row_mode.lod != NativeLodMode.OFF) {
            ulong before = (ulong)counter.tracker.usage;
            model::attach_animated_lod(
                assets: assets,
                scene: &scene,
                owner: root,
                desc: native_lod_desc(assets, model_id, levels),
            )!;
            native_row_mode.lod_host = (ulong)counter.tracker.usage - before;
            scene.get(root, LodGroup).state.effects.trace = native_row_mode.trace != NativeTraceMode.OFF;
        }
        Node* camera = scene.add_camera(camera::orthographic(210, 0.1f, 1000))!;
        camera.local.position = { 94.5f, 220, 94.5f };
        camera.local.rotation = maths::look_rotation((Vec3){ 0, -220, -189 }.normalize(), { 0, 1, 0 });
        Light sun = light::directional({ 1, 1, 1 }, 2);
        sun.shadow.cascades = 1;
        sun.shadow.max_distance = 600;
        Node* sun_node = scene.add_light(sun)!;
        sun_node.local.rotation = maths::look_rotation((Vec3){ -0.3f, -1, -0.2f }.normalize(), { 0, 1, 0 });
        scene.update_world();
        Storage storage = storage_inventory(&counter, &scene, crowd)!;
        profile::Recorder recorder = profile::create_recorder(mem, {
            .frame_capacity = NATIVE_CAPTURE_FRAMES,
            .gpu_scopes_per_frame = NATIVE_GPU_SCOPES,
            .label_bytes_per_frame = NATIVE_GPU_LABEL_BYTES,
        })!;
        defer profile::destroy_recorder(&recorder);
        CounterAllocator renderer_counter;
        renderer_counter.tracker.init(mem);
        defer renderer_counter.tracker.free();
        Renderer renderer = render::create_renderer(
            allocator: &renderer_counter,
            assets: assets,
            desc: {
                .validation = native_row_mode.validation,
                .gpu_timings = true,
                .profiler = &recorder,
                .ray_queries = native_row_mode.trace == NativeTraceMode.HARDWARE,
                .max_posed_trace_instances = native_row_mode.posed_capacity,
                .max_trace_instances = math::max(1u, live * (uint)template.meshes.len),
                .shadow_resolution = NATIVE_SHADOW_RESOLUTION,
                .max_shadow_layers = 1,
                .application_name = "crowd_bench_native",
            },
        )!;
        defer render::destroy_renderer(&renderer);
        if (!renderer.caps.timestamps.queues.graphics) return gpu::UNSUPPORTED_FEATURE~;
        native_metadata(files, "adapter", renderer.adapter_name)!;
        native_metadata_uint(files, "timestamp_graphics_valid_bits", renderer.caps.timestamps.graphics_valid_bits)!;
        csv_string(&files.metadata, "timestamp_period_ns")!;
        csv_float(&files.metadata, renderer.caps.timestamps.period_ns, true)!;
        ViewId[2] views;
        RenderTargetId[2] targets;
        for (uint index = 0; index < view_count; index++) {
            targets[index] = render::create_render_target(
                &renderer,
                render::render_target_desc(NATIVE_WIDTH, NATIVE_HEIGHT, PixelFormat.RGBA32_FLOAT),
            )!;
            ViewDesc desc = render::texture_view_desc(targets[index]);
            desc.post.anti_aliasing = AntiAliasing.TAA;
            desc.post.motion_blur = true;
            if (native_row_mode.lod != NativeLodMode.OFF) {
                float[3] biases = { 16, -2, -16 };
                desc.lod_bias = biases[native_row_mode.lod.ordinal - 1];
            }
            views[index] = render::create_view(&renderer, desc)!;
        }
        NativeSample[] samples = alloc::new_array(tmem, NativeSample, NATIVE_CAPTURE_FRAMES);
        ulong high_water;
        for (uint frame = 0; frame < NATIVE_CAPTURE_FRAMES + NATIVE_DRAIN_FRAMES; frame++) {
            NativeSample drain;
            NativeSample* sample = frame < NATIVE_CAPTURE_FRAMES ? &samples[frame] : &drain;
            if (frame < NATIVE_CAPTURE_FRAMES) {
                script_controls(crowd, script, frame);
                AllocationCounters started = counter.snapshot();
                time::Clock evaluated = clock::now();
                crowd.playback.update(assets, FIXED_DT);
                sample.evaluate_ns = (ulong)evaluated.to_now();
                time::Clock published = clock::now();
                anim::publish_crowd_pose(assets, &scene, crowd);
                sample.publish_ns = (ulong)published.to_now();
                sample.allocations = difference(counter.snapshot(), started);
                sample.events = crowd.playback.event_count;
                sample.dropped_events = crowd.playback.events_dropped;
                time::Clock world = clock::now();
                scene.update_world();
                sample.world_ns = (ulong)world.to_now();
                profile::@capture(&recorder, (ulong)frame) {
                    native_render_frame(
                        renderer: &renderer,
                        scene: &scene,
                        camera: camera,
                        views: views[:view_count],
                        sample: sample,
                        samples: samples[..],
                        source_owner: root,
                        renderer_counter: &renderer_counter,
                        time: (double)frame * FIXED_DT,
                        delta: FIXED_DT,
                    )!;
                };
            } else {
                native_render_frame(
                    renderer: &renderer,
                    scene: &scene,
                    camera: camera,
                    views: views[:view_count],
                    sample: sample,
                    samples: samples[..],
                    source_owner: root,
                    renderer_counter: &renderer_counter,
                    time: (double)(NATIVE_CAPTURE_FRAMES - 1) * FIXED_DT,
                    delta: 0,
                )!;
            }
            sample.current_palette *= (ulong)live * crowd.joint_count * Mat4f::size;
            sample.current_morph *= (ulong)live * shader::MorphWeightsGpu::size;
            sample.current_bounds *= (ulong)live * Mat4f::size;
            sample.current_part_locals *= (ulong)live * shader::InstanceGpu::size;
            high_water = math::max(high_water, sample.upload_bytes);
            sample.upload_peak = high_water;
        }
        render::wait_frames(&renderer)!;
        write_native_gpu(
            files: files,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
            views: view_count,
            recorder: &recorder,
            samples: samples[..],
        )!;
        write_native_samples(
            files: files,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
            views: view_count,
            samples: samples[..],
        )!;
        write_native_revisions(
            files: files,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
            views: view_count,
            samples: samples[..],
        )!;
        write_native_storage(
            files: files,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
            views: view_count,
            storage: storage,
            recorder: &recorder,
            renderer: &renderer,
            sample: samples[NATIVE_CAPTURE_FRAMES - 1],
        )!;
        capture_native_lod_history(
            renderer: &renderer,
            scene: &scene,
            owner: root,
            camera: camera,
            views: views[:view_count],
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
            files: files,
        )!;
        if (capture) {
            capture_native_images(
                assets: assets,
                renderer: &renderer,
                scene: &scene,
                camera: camera,
                view: views[0],
                target: targets[0],
                corpus: corpus,
                directory: directory,
                files: files,
            )!;
        }
        io::printfn("native %s %s", corpus.label, script_name(script));
        io::printfn("live=%s views=%s lod=%s trace=%s capacity=%s", live, view_count,
            native_lod_name(native_row_mode.lod), native_trace_name(native_row_mode.trace), native_row_mode.posed_capacity);
        io::printfn("repetition=%s measured=%s", repetition, SAMPLES);
    };
}

fn void? native_failure(
    NativeFiles* files,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    uint views,
    fault excuse,
) {
    native_key(
        output: &files.failures,
        corpus: corpus,
        script: script,
        live: live,
        repetition: repetition,
        views: views,
    )!;
    char[128] text;
    csv_string(&files.failures, (String)io::bprintf(text[..], "%s", excuse)!)!;
    csv_uint(&files.failures, SCRIPT_SEED)!;
    csv_float(&files.failures, FIXED_DT)!;
    csv_uint(&files.failures, ACTION_CAPACITY)!;
    csv_uint(&files.failures, EVENT_CAPACITY, true)!;
}

fn void? run_native(String[] args) {
    if (args.len < 2 || args.len > 10) return c3d::INVALID_ARGUMENT~;
    @pool() {
        String repository = args.len > 2 ? args[2] : ".";
        uint population = args.len > 3 ? args[3].to_uint()! : 0;
        String fixture = args.len > 4 ? args[4] : "all";
        String selected_script = args.len > 5 ? args[5] : "all";
        uint selected_views = args.len > 6 ? args[6].to_uint()! : 0;
        String selected_lod = args.len > 7 ? args[7] : "off";
        NativeLodMode[] modes = alloc::new_array(tmem, NativeLodMode, selected_lod == "all" ? 3 : 1);
        if (selected_lod == "all") {
            modes[0] = NativeLodMode.NEAR;
            modes[1] = NativeLodMode.MIDDLE;
            modes[2] = NativeLodMode.FAR;
        } else {
            modes[0] = native_lod_mode(selected_lod)!;
        }
        native_row_mode.trace = native_trace_mode(args.len > 8 ? args[8] : "off")!;
        native_row_mode.posed_capacity = args.len > 9 ? args[9].to_uint()! : render::DEFAULT_MAX_POSED_TRACE_INSTANCES;
        if (!native_row_mode.posed_capacity) return c3d::INVALID_ARGUMENT~;
        String validation_mode = args.len > 10 ? args[10] : "on";
        if (validation_mode != "on" && validation_mode != "off") return c3d::INVALID_ARGUMENT~;
        native_row_mode.validation = validation_mode == "on";
        native_row_mode.repetitions = args.len > 11 ? args[11].to_uint()! : REPETITIONS;
        native_row_mode.skip_rows = args.len > 12 ? args[12].to_uint()! : 0;
        if (!native_row_mode.repetitions || native_row_mode.repetitions > REPETITIONS) {
            return c3d::INVALID_ARGUMENT~;
        }
        if (population && population != 64 && population != 512 && population != 4096) return c3d::INVALID_ARGUMENT~;
        if (fixture != "all" && fixture != "quaternius" && fixture != "morph") return c3d::INVALID_ARGUMENT~;
        if (selected_script != "all" && selected_script != "base" && selected_script != "layered4"
          && selected_script != "space4") return c3d::INVALID_ARGUMENT~;
        if (selected_views > 2) return c3d::INVALID_ARGUMENT~;
        NativeFiles files;
        create_native_files(args[1], &files)!;
        defer close_native_files(&files);
        native_metadata(&files, "domain", "native_gpu_measurement_not_correctness")!;
        native_metadata(&files, "validation", native_row_mode.validation
            ? "true_validation_overhead_included" : "false_optimized_measurement_only")!;
        native_metadata(&files, "profiling", "GPU_INTERNAL_timestamps_and_collector_enabled_overhead_not_subtracted")!;
        native_metadata(
            files: &files,
            key: "cpu_scope",
            value: "evaluate_publish_match_cpu_scaffold_world_separate_record_submit_includes_wait_and_collector",
        )!;
        native_metadata(
            files: &files,
            key: "upload_scope",
            value: "ring_head_plus_overflow_includes_alignment_roots_and_staging_payload_categories_exclude_alignment",
        )!;
        native_metadata(
            files: &files,
            key: "part_records",
            value: "admitted_persistent_instance_stream_capacity_times_InstanceGpu_size_published_every_measured_frame",
        )!;
        native_metadata(
            files: &files,
            key: "draw_counters",
            value: "draws_count_submitted_calls_CPU_known_triangles_instances_exclude_GPU_culled_ranges_"
              "actual_tested_visible_are_delayed_GPU_counters",
        )!;
        native_metadata(
            files: &files,
            key: "previous_payload",
            value: "retained_nested_previous_palette_part_matrices_and_morph_payload_fixed_count_positive_parity_per_view_excludes_alignment",
        )!;
        native_metadata(
            files: &files,
            key: "tracking",
            value: "requested_scene_renderer_bytes_exclude_tracker_maps_backtraces_assets_scaffold_process_and_driver",
        )!;
        native_metadata(&files, "history", "retained_array_capacity_payload_subset_of_renderer_requested_host")!;
        native_metadata(&files, "gpu_memory", "VMA_requested_allocations_and_blocks_driver_heap_usage_is_estimate")!;
        native_metadata(
            files: &files,
            key: "timing_join",
            value: "recorder_capture_script_frame_and_scope_renderer_frame_match_submission_cull_rows_join_"
              "lod_frame_index",
        )!;
        native_metadata(&files, "missing_gpu_pass", "NA_no_recorded_scope_zero_dispatches_mean_no_sort_work")!;
        native_metadata(
            files: &files,
            key: "camera",
            value: "ortho210_near0.1_far1000_position94.5_220_94.5_direction0_-220_-189_fixed_all_sizes",
        )!;
        native_metadata(
            files: &files,
            key: "views",
            value: "one_or_two_identical_camera_RGBA32_FLOAT_TAA_motion_blur_shared_parent_shadow_set",
        )!;
        native_metadata(&files, "shadows", "directional_one_cascade_resolution256_max_distance600")!;
        native_metadata(
            files: &files,
            key: "captures",
            value: "outside_measured_interval_RGBA32_FLOAT_and_reverse_Z_R32_FLOAT_row_major_host_endian",
        )!;
        uint endian = 1;
        native_metadata(
            files: &files,
            key: "capture_byte_order",
            value: ((char*)&endian)[0] == 1 ? "little_endian_IEEE754_binary32" : "big_endian_IEEE754_binary32",
        )!;
        native_metadata(&files, "schema_version", "3")!;
        native_metadata(&files, "lod_modes_requested", selected_lod)!;
        native_metadata(&files, "trace_kind", native_trace_name(native_row_mode.trace))!;
        native_metadata_uint(&files, "trace_posed_capacity", native_row_mode.trace == NativeTraceMode.OFF
            ? 0 : native_row_mode.posed_capacity)!;
        native_metadata(&files, "lod_fixture",
            "Quaternius_verified_committed_three_levels_MorphCube_original_geometry_repeated_no_simplification_claim")!;
        native_metadata(&files, "lod_level_biases", "near16_middle-2_far-16_thresholds1_0.001_0")!;
        native_metadata(&files, "authored_triangle_counts",
            "per_level_input_indices_or_vertices_divided_by3_selected_visible_weight_delayed_GPU_object_counts_not_indirect_args")!;
        native_metadata(&files, "lod_history_readback",
            "per_view_per_logical_slot_GPU_levels_generations_and_authored_triangles_untimed_final_fixed_pose_submission")!;
        native_metadata(&files, "lod_host",
            "actual_scene_allocator_attach_delta_subset_of_scene_overhead_not_added_again_to_playback_formula")!;
        native_metadata(&files, "lod_current_part_payload",
            "animated_parts_cache_records_live_times_InstanceGpu_per_representation_excludes_alignment")!;
        native_metadata(&files, "indirect_triangle_readback", "NA_no_indirect_argument_readback")!;
        native_metadata(&files, "upload_revision_accounting",
            "actual_new_pending_copy_src_equals_dst_sizes_and_pending_instance_upload_records_no_byte_estimate")!;
        native_metadata(&files, "instance_copy_reasons",
            "exclusive_priority_cold_or_capacity_growth_then_live_publication_revision_mismatch_then_other_world_origin_incarnation")!;
        native_metadata(&files, "geometry_copy_reasons",
            "exclusive_priority_asset_header_revision_mismatch_for_same_live_mirror_then_cold_mirror_then_other")!;
        native_metadata(&files, "binding_revision_identity",
            "no_standalone_counter_descriptor_incarnation_and_admitted_model_geometry_selected_source_skeleton_header_revisions")!;
        native_metadata(&files, "palette_upload_kind",
            "model_space_pose_palette_is_frame_ring_payload_not_persistent_asset_revision_buffer_copy")!;
        native_metadata(&files, "revision_export_scope",
            "per_frame_per_representation_global_source_identifiers_shared_by_all_views_legacy_admitted_fields_zero")!;
        native_metadata(&files, "revision_export_overhead",
            "same_production_geometry_and_instance_resolvers_pre_staged_before_view_no_extra_bins_or_dispatches_CPU_capture_overhead_in_record_submit")!;
        native_metadata(&files, "script_version", "1")!;
        native_metadata(&files, "placement", "ceil_sqrt_grid_spacing3_positive_x_negative_z_identity_scale_rotation")!;
        native_metadata(&files, "compiler", "C3_0.8.3")!;
        char[64] text;
        native_metadata(
            files: &files,
            key: "compiler_optimization",
            value: (String)io::bprintf(text[..], "%s", env::COMPILER_OPT_LEVEL)!,
        )!;
        native_metadata(&files, "compiler_safe", (String)io::bprintf(text[..], "%s", env::COMPILER_SAFE_MODE)!)!;
        native_metadata_uint(&files, "seed", SCRIPT_SEED)!;
        native_metadata_uint(&files, "dt_bits", bitcast(FIXED_DT, uint))!;
        native_metadata_uint(&files, "warmups", WARMUPS)!;
        native_metadata_uint(&files, "samples", SAMPLES)!;
        native_metadata_uint(&files, "repetitions", native_row_mode.repetitions)!;
        native_metadata_uint(&files, "skipped_prefix_rows", native_row_mode.skip_rows)!;
        native_metadata_uint(&files, "drain_frames", NATIVE_DRAIN_FRAMES)!;
        native_metadata_uint(&files, "action_capacity", ACTION_CAPACITY)!;
        native_metadata_uint(&files, "event_capacity", EVENT_CAPACITY)!;
        native_metadata_uint(&files, "viewport_width", NATIVE_WIDTH)!;
        native_metadata_uint(&files, "viewport_height", NATIVE_HEIGHT)!;
        native_metadata_uint(&files, "profiler_scopes_per_frame", NATIVE_GPU_SCOPES)!;
        native_metadata_uint(&files, "profiler_label_bytes_per_frame", NATIVE_GPU_LABEL_BYTES)!;
        bool failed;
        uint row_ordinal;
        foreach (corpus : CORPUS) {
            if (fixture != "all" && fixture != corpus.label) continue;
            char[] bytes = file::load(mem, joined_path(repository, corpus.relative_path)!)!;
            defer alloc::free(mem, bytes.ptr);
            verify_input(bytes, corpus)!;
            native_metadata(&files, corpus.label, corpus.sha256)!;
            AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
            defer asset::destroy_asset_store(&assets);
            AnimatedLodFixtures levels;
            ModelId model_id;
            if (selected_lod != "off" && corpus.quaternius) {
                levels = animated_lod_fixtures::load_animated_lod_fixtures(&assets, repository)!;
                model_id = levels.model;
            } else {
                model_id = gltf::load_model_memory(
                    assets: &assets,
                    bytes: bytes,
                    base_dir: "",
                    key: corpus.relative_path,
                )!;
            }
            ModelTemplate* template = &assets.model(model_id).data;
            native_metadata_uint(&files, string::tformat("%s_template_nodes", corpus.label), template.nodes.len)!;
            native_metadata_uint(&files, string::tformat("%s_template_meshes", corpus.label), template.meshes.len)!;
            native_metadata_uint(&files, string::tformat("%s_template_clips", corpus.label), template.clips.len)!;
            if (selected_lod != "off" && corpus.quaternius) {
                for (uint primitive = 0; primitive < 2; primitive++) {
                    for (uint level = 1; level < 3; level++) {
                        String relative = string::tformat("test/fixtures/animated_lod/primitive_%s_lod_%s.bin", primitive, level);
                        char[] derived = file::load(mem, joined_path(repository, relative)!)!;
                        defer alloc::free(mem, derived.ptr);
                        native_metadata(&files, relative, native_hash(derived))!;
                    }
                }
            }
            uint triangles = native_model_triangles(&assets, template);
            native_row_mode.triangles[..] = triangles;
            if (selected_lod != "off" && corpus.quaternius) {
                for (uint level = 0; level < 3; level++) {
                    native_row_mode.triangles[level] = 0;
                    for (uint primitive = 0; primitive < 2; primitive++) {
                        native_row_mode.triangles[level] += levels.layouts[primitive][level].index_count / 3;
                    }
                }
            }
            bool[4] captured;
            foreach (NativeLodMode mode : modes) {
                native_row_mode.lod = mode;
                foreach (live : POPULATIONS) {
                    if (population && population != live) continue;
                    foreach (Script script : { BASE, LAYERED4, SPACE4 }) {
                        if (selected_script != "all" && selected_script != script_name(script)) continue;
                        foreach (uint views : { 1u, 2u }) {
                            if (selected_views && selected_views != views) continue;
                            for (uint repetition = 0; repetition < native_row_mode.repetitions; repetition++) {
                                if (row_ordinal++ < native_row_mode.skip_rows) continue;
                                if (catch excuse = measure_native_row(
                                    assets: &assets,
                                    model_id: model_id,
                                    corpus: corpus,
                                    script: script,
                                    live: live,
                                    repetition: repetition,
                                    view_count: views,
                                    directory: args[1],
                                    capture: !captured[mode.ordinal],
                                    files: &files,
                                    levels: mode != NativeLodMode.OFF && corpus.quaternius ? &levels : null,
                                )) {
                                    native_failure(
                                        files: &files,
                                        corpus: corpus,
                                        script: script,
                                        live: live,
                                        repetition: repetition,
                                        views: views,
                                        excuse: excuse,
                                    )!;
                                    failed = true;
                                } else {
                                    captured[mode.ordinal] = true;
                                }
                            }
                        }
                    }
                }
            }
        }
        if (failed || row_ordinal < native_row_mode.skip_rows) return c3d::INVALID_ARGUMENT~;
    };
}

fn int main(String[] args) {
    if (catch excuse = run_native(args)) {
        io::eprintfn("crowd_bench_native: %s", excuse);
        io::eprintn("usage: crowd_bench_native OUTPUT_DIRECTORY [REPOSITORY_"
          "ROOT] [0|64|512|4096] [all|quaternius|morph] [all|base|layered4|space4] [0|1|2] "
          "[off|near|middle|far|all] [off|software|hardware] [POSED_CAPACITY] "
          "[on|off validation] [1..3 repetitions] [SKIP_PREFIX_ROWS]");
        return 1;
    }
    return 0;
}

fn String native_lod_name(NativeLodMode mode) {
    switch (mode) {
        case OFF: return "off";
        case NEAR: return "near";
        case MIDDLE: return "middle";
        case FAR: return "far";
    }
}

fn String native_trace_name(NativeTraceMode mode) {
    switch (mode) {
        case OFF: return "off";
        case SOFTWARE: return "software";
        case HARDWARE: return "hardware";
    }
}

fn NativeLodMode? native_lod_mode(String name) {
    if (name == "off") return NativeLodMode.OFF;
    if (name == "near") return NativeLodMode.NEAR;
    if (name == "middle") return NativeLodMode.MIDDLE;
    if (name == "far") return NativeLodMode.FAR;
    return c3d::INVALID_ARGUMENT~;
}

fn NativeTraceMode? native_trace_mode(String name) {
    if (name == "off") return NativeTraceMode.OFF;
    if (name == "software") return NativeTraceMode.SOFTWARE;
    if (name == "hardware") return NativeTraceMode.HARDWARE;
    return c3d::INVALID_ARGUMENT~;
}

fn ulong native_pose_bytes(PoseRecord* pose) {
    ulong bytes = (ulong)pose.palette.len * Mat4f::size + (ulong)pose.instances.len * Mat4f::size
      + (ulong)pose.morphs.len * shader::MorphWeightsGpu::size
      + (ulong)pose.crowd_generations.len * uint::size + (ulong)pose.vertices.len * Vec3::size;
    if (pose.animated_lod) {
        bytes += AnimatedLodPoseHistory::size + pose.animated_lod.parts.len * AnimatedLodPartPose::size;
        foreach (&part : pose.animated_lod.parts) bytes += native_pose_bytes(&part.pose);
    }
    return bytes;
}

fn void native_previous_pose(PoseRecord* pose, NativeSample* sample) {
    sample.previous_palette += (ulong)pose.palette.len * Mat4f::size;
    sample.previous_morph += (ulong)pose.morphs.len * shader::MorphWeightsGpu::size;
    if (pose.instances.len) {
        sample.previous_matrices += (ulong)pose.instance_count * Mat4f::size;
        sample.previous_headers += shader::PreviousPoseGpu::size;
    }
    if (pose.animated_lod) {
        foreach (&part : pose.animated_lod.parts) native_previous_pose(&part.pose, sample);
    }
}

fn uint native_model_triangles(AssetStore* assets, ModelTemplate* template) {
    uint triangles;
    foreach (mesh : template.meshes) {
        Geometry* data = &assets.geometry(mesh.geometry).data;
        triangles += (uint)(data.indices.len ? data.indices.len / 3 : data.positions.len / 3);
    }
    return triangles;
}

fn AnimatedLodDesc native_lod_desc(
    AssetStore* assets,
    ModelId model_id,
    AnimatedLodFixtures* fixtures,
) {
    ModelTemplate* template = &assets.model(model_id).data;
    uint count = (uint)template.meshes.len;
    LodLevel[] levels = alloc::new_array(tmem, LodLevel, 3);
    AnimatedLodPart[] parts = alloc::new_array(tmem, AnimatedLodPart, (sz)count * 3);
    for (uint level = 0; level < 3; level++) {
        levels[level] = {
            .first_part = count * level,
            .part_count = count,
            .min_screen_size = level == 0 ? 1 : (level == 1 ? 0.001f : 0),
        };
        foreach (uint index, mesh : template.meshes) {
            ModelSkin skin;
            foreach (candidate : template.skins) if (candidate.mesh_node == mesh.node) skin = candidate;
            parts[count * level + index] = {
                .draw = {
                    .geometry = fixtures ? fixtures.levels[index][level] : mesh.geometry,
                    .material = mesh.material,
                    .local = matrix::IDENTITY4,
                },
                .mesh_index = index,
                .skin = skin,
                .default_morph_weights = mesh.default_morph_weights,
            };
        }
    }
    return { .levels = levels, .parts = parts };
}

fn void? capture_native_lod_history(
    Renderer* renderer,
    Scene* scene,
    Node* owner,
    Node* camera,
    ViewId[] views,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    NativeFiles* files,
) {
    if (native_row_mode.lod == NativeLodMode.OFF) return;
    gpu::MappedGpuSpan[2] readbacks;
    defer {
        foreach (mapped : readbacks) {
            if (!mapped.bytes.len) continue;
            gpu::GpuAllocation allocation = mapped.span.allocation();
            gpu::free_allocation(&renderer.device, &allocation)!!;
        }
    }
    foreach (index, view : views) {
        gpu::AllocationDesc desc = {
            .size = (usz)live * shader::LodHistoryGpu::size,
            .alignment = render::STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.CPU_READ,
            .access = { .graphics },
            .debug_name = "crowd_lod_history_readback",
        };
        readbacks[index] = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    }
    bool[2] available;
    ulong submission = renderer.frame_index;
    renderer.begin_frame({ .time = (double)NATIVE_CAPTURE_FRAMES * FIXED_DT, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    foreach (index, view : views) {
        renderer.render_view(scene, camera, view)!;
        LodHistoryEntry* history = &renderer.views.get(view).lod_history.entries[owner.id.index];
        available[index] = history.allocation.is_valid() && history.pending.valid;
        if (available[index]) {
            usz bytes = (usz)live * shader::LodHistoryGpu::size;
            usz offset = (usz)(history.committed_slot ^ 1) * history.capacity * shader::LodHistoryGpu::size;
            gpu::Barrier selected = { .before = { .compute }, .after = { .transfer } };
            gpu::cmd_barrier(&renderer.commands, &selected)!;
            gpu::BufferCopyDesc copy = {
                .src = gpu::get_allocation_span(&renderer.device, history.allocation)!.checked_subspan(offset, bytes)!,
                .dst = readbacks[index].span,
            };
            gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
        }
        renderer.finish_view(view)!;
    }
    gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &copied)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    foreach (index, view : views) {
        if (available[index]) gpu::invalidate_mapped_span(&renderer.device, readbacks[index].span)!;
        shader::LodHistoryGpu[] rows = ((shader::LodHistoryGpu*)readbacks[index].bytes.ptr)[:live];
        for (uint source = 0; source < live; source++) {
            native_key(
                output: &files.lod_history,
                corpus: corpus,
                script: script,
                live: live,
                repetition: repetition,
                views: (uint)views.len,
            )!;
            csv_uint(&files.lod_history, submission)!;
            csv_uint(&files.lod_history, (ulong)index)!;
            csv_uint(&files.lod_history, source)!;
            csv_uint(&files.lod_history, available[index] ? 1 : 0)!;
            if (available[index]) {
                if (rows[source].level >= 3) return c3d::INVALID_ARGUMENT~;
                csv_uint(&files.lod_history, rows[source].level)!;
                csv_uint(&files.lod_history, rows[source].generation)!;
                csv_uint(&files.lod_history, rows[source].reject_history)!;
                csv_uint(&files.lod_history, native_row_mode.triangles[rows[source].level], true)!;
            } else {
                csv_string(&files.lod_history, "NA")!;
                csv_string(&files.lod_history, "NA")!;
                csv_string(&files.lod_history, "NA")!;
                csv_string(&files.lod_history, "NA", true)!;
            }
        }
    }
}


fn GpuInstances native_instance_before(Renderer* renderer, InstanceKey key) {
    if (try index = renderer.instances.lookup.get(key)) return renderer.instances.slots[index];
    return {};
}

fn ulong? native_queued_copy_bytes(
    Renderer* renderer,
    sz first,
    gpu::GpuAllocation allocation,
) {
    ulong bytes;
    for (sz index = first; index < renderer.pending_copies.len(); index++) {
        gpu::BufferCopyDesc copy = renderer.pending_copies[index];
        gpu::GpuAllocation destination = copy.dst.allocation();
        if (destination.owner != allocation.owner || destination.index != allocation.index
          || destination.generation != allocation.generation) continue;
        if (copy.src.size != copy.dst.size) return c3d::INVALID_ARGUMENT~;
        bytes += copy.src.size;
    }
    return bytes;
}

fn void native_classify_instance_copy(
    NativeSample* sample,
    GpuInstances before,
    uint capacity,
    uint publication,
    ulong bytes,
) {
    sample.instance_copy_bytes += bytes;
    if (!before.allocation.is_valid() || before.capacity < capacity) {
        sample.instance_cold_copy_bytes += bytes;
    } else if (before.revision && before.revision != publication) {
        sample.instance_publication_copy_bytes += bytes;
    } else {
        sample.instance_other_copy_bytes += bytes;
    }
}

fn void? native_stage_geometry(Renderer* renderer, GeometryId geometry, NativeSample* sample) {
    GpuGeometry before = renderer.geometries[geometry.index];
    uint revision = renderer.assets.geometry(geometry).header.revision;
    sz copies = renderer.pending_copies.len();
    sz uploads = renderer.pending_geometry_uploads.len();
    GpuGeometry* resolved = render::resolve_geometry(renderer, geometry)!;
    if (renderer.pending_geometry_uploads.len() == uploads) return;
    ulong bytes = native_queued_copy_bytes(renderer, copies, resolved.allocation)!;
    sample.geometry_copy_bytes += bytes;
    if (c3d::same_id(before.asset, geometry) && before.revision && before.revision != revision) {
        sample.geometry_revision_copy_bytes += bytes;
    } else if (!c3d::same_id(before.asset, geometry) || !before.revision) {
        sample.geometry_cold_copy_bytes += bytes;
    } else {
        sample.geometry_other_copy_bytes += bytes;
    }
}

fn void? stage_native_revision_uploads(
    Renderer* renderer,
    Scene* scene,
    Node* owner,
    NativeSample* sample,
) {
    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    ModelTemplate* template = &renderer.assets.model(crowd.model).data;
    LodGroup* group = scene.get(owner, LodGroup);
    if (group) {
        model::sync_animated_lod(renderer.assets, scene, owner)!;
        LodGroupState* state = group.state;
        InstanceKey key = { .scene = scene.identity, .node = owner.id, .kind = shader::INSTANCE_KIND_LOD };
        GpuInstances before = native_instance_before(renderer, key);
        sz copies = renderer.pending_copies.len();
        sz uploads = renderer.pending_instance_uploads.len();
        LodSelection selection = {
            .scene = scene,
            .scene_identity = scene.identity,
            .node = owner,
            .state = state,
        };
        render::resolve_lod_instances(renderer, &selection)!;
        if (renderer.pending_instance_uploads.len() != uploads) {
            ulong bytes = native_queued_copy_bytes(renderer, copies, selection.instances.allocation)!;
            native_classify_instance_copy(
                sample: sample,
                before: before,
                capacity: (uint)state.transforms.len,
                publication: state.revision,
                bytes: bytes,
            );
        }
        foreach (part : state.desc.parts) native_stage_geometry(renderer, part.geometry, sample)!;
    } else {
        foreach (part : crowd.parts) {
            Node* node = scene.node(part.batch);
            InstancedMesh* batch = scene.get(node, InstancedMesh);
            InstanceKey key = { .scene = scene.identity, .node = node.id, .kind = shader::INSTANCE_KIND_MESH };
            GpuInstances before = native_instance_before(renderer, key);
            sz copies = renderer.pending_copies.len();
            sz uploads = renderer.pending_instance_uploads.len();
            MeshCandidate candidate = {
                .node = node,
                .geometry = batch.geometry,
                .material = batch.material,
                .batch = batch,
                .scene_identity = scene.identity,
                .instance_count = batch.count,
            };
            render::attach_crowd(scene, &candidate);
            render::resolve_instances(renderer, &candidate)!;
            if (renderer.pending_instance_uploads.len() != uploads) {
                uint index = renderer.instances.lookup.get(key)!;
                ulong bytes = native_queued_copy_bytes(renderer, copies, renderer.instances.slots[index].allocation)!;
                native_classify_instance_copy(
                    sample: sample,
                    before: before,
                    capacity: (uint)batch.transforms.len,
                    publication: batch.revision,
                    bytes: bytes,
                );
            }
            native_stage_geometry(renderer, batch.geometry, sample)!;
        }
    }
    usz count = group ? group.state.desc.parts.len : template.meshes.len;
    sample.revisions = alloc::new_array(tmem, NativeRevision, (sz)count);
    for (uint representation = 0; representation < count; representation++) {
        uint mesh_index = group ? group.state.animated.parts[representation].mesh_index : representation;
        ModelMesh mesh = template.meshes[mesh_index];
        AnimatedLodPartBinding binding;
        if (group) {
            binding = group.state.animated.parts[representation];
        } else {
            binding.mesh_index = mesh_index;
            binding.template_node = mesh.node;
            binding.weight_count = (uint)mesh.default_morph_weights.len;
            foreach (skin : template.skins) {
                if (skin.mesh_node != mesh.node) continue;
                binding.skinned = true;
                binding.skeleton = skin.skeleton;
                binding.source_skeleton = skin.skeleton;
            }
        }
        GeometryId geometry = group ? group.state.desc.parts[representation].geometry : mesh.geometry;
        uint level;
        if (group) {
            foreach (uint index, selected : group.state.desc.levels) {
                if (representation >= selected.first_part
                  && representation < selected.first_part + selected.part_count) level = index;
            }
        }
        InstancedMesh* batch = scene.world.get(crowd.parts[mesh_index].batch, InstancedMesh);
        sample.revisions[representation] = {
            .owner = owner.id,
            .playback_identity = crowd.playback.identity,
            .lod_identity = group ? group.state.identity : 0,
            .source_epoch = group ? group.state.instance_epoch : crowd.playback.identity,
            .descriptor_revision = group ? group.state.descriptor_revision : 0,
            .publication_revision = group ? group.state.revision : batch.revision,
            .source_batch_revision = batch.revision,
            .model = crowd.model,
            .model_revision = renderer.assets.model(crowd.model).header.revision,
            .admitted_model_revision = group ? group.state.animated.model_revision : 0,
            .representation = representation,
            .level = level,
            .logical_part = mesh_index,
            .template_node = binding.template_node,
            .geometry = geometry,
            .geometry_revision = renderer.assets.geometry(geometry).header.revision,
            .admitted_geometry_revision = binding.geometry_revision,
            .skeleton = binding.skeleton,
            .skeleton_revision = binding.skeleton.generation ? renderer.assets.skeleton(binding.skeleton).header.revision : 0,
            .admitted_skeleton_revision = binding.skeleton_revision,
            .source_skeleton = binding.source_skeleton,
            .source_skeleton_revision = binding.source_skeleton.generation
              ? renderer.assets.skeleton(binding.source_skeleton).header.revision : 0,
            .admitted_source_skeleton_revision = binding.source_skeleton_revision,
            .logical_weights = binding.weight_count,
            .live = crowd.count,
        };
    }
}

fn void? write_native_revisions(
    NativeFiles* files,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    uint views,
    NativeSample[] samples,
) {
    for (uint frame = WARMUPS; frame < NATIVE_CAPTURE_FRAMES; frame++) {
        foreach (revision : samples[frame].revisions) {
            native_key(
                output: &files.revisions,
                corpus: corpus,
                script: script,
                live: live,
                repetition: repetition,
                views: views,
            )!;
            csv_uint(&files.revisions, frame)!;
            csv_uint(&files.revisions, samples[frame].submission)!;
            ulong[30] fields = {
                revision.owner.index, revision.owner.generation, revision.playback_identity,
                revision.lod_identity, revision.source_epoch, revision.descriptor_revision,
                revision.publication_revision, revision.source_batch_revision,
                revision.model.index, revision.model.generation, revision.model_revision, revision.admitted_model_revision,
                revision.representation, revision.level, revision.logical_part, revision.template_node,
                revision.geometry.index, revision.geometry.generation, revision.geometry_revision, revision.admitted_geometry_revision,
                revision.skeleton.index, revision.skeleton.generation, revision.skeleton_revision, revision.admitted_skeleton_revision,
                revision.source_skeleton.index, revision.source_skeleton.generation, revision.source_skeleton_revision,
                revision.admitted_source_skeleton_revision, revision.logical_weights, revision.live,
            };
            foreach (index, value : fields) csv_uint(&files.revisions, value, index + 1 == fields.len)!;
        }
    }
}
