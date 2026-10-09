module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::pool;
import gpu;
import std::collections::list;
import std::math;
import std::time;
import std::time::clock;

<* Pool of open model preparations. *>
alias PreparePool = Pool{PrepareRecord, PrepareId};

<* Default staged-byte allowance of the legacy preparation call. *>
const usz PREPARE_FRAME_BUDGET_BYTES = 1 << 20; // one MiB per call; divisible uploads stop at legal bands

<* Open preparations admitted by one renderer. *>
const uint PREPARE_CAPACITY = 4; // fixed record count; each owns its structural units and one mip chain

const usz PREPARE_SPAN_BYTES @private = 64 << 10; // bounded CPU-copy/packing spans permit cooperative deadline checks
const uint PREPARE_GENERATION_ROWS @private = 16; // one output band; a wide row may exceed the cooperative target

<* Publication and completion state of a model preparation. *>
enum PrepareState {
    PENDING,
    SUBMITTED,
    READY,
    FAILED,
}

<* Work currently reached by a preparation. *>
enum PreparePhase {
    DEPENDENCIES,
    GENERATION,
    UPLOAD,
    PIPELINES,
    FINISH,
    COMPLETE,
}

<* Axis that prevented the next preparation step. *>
enum PrepareStopReason {
    NONE,
    STAGED_BYTES,
    GENERATED_TEXELS,
    PIPELINES,
    TIME,
}

<* Per-call limits; each zero axis is unbounded. *>
struct PrepareLimits {
    usz staged_bytes;
    ulong generated_texels;
    uint pipelines;
    ulong time_ns;
}

<* Work required by one indivisible preparation step. *>
struct PrepareStepCost {
    usz staged_bytes;
    ulong generated_texels;
    uint pipelines;
}

<* Actual work and the next blocked step of one advance. *>
struct PrepareReport {
    usz staged_bytes;
    ulong generated_texels;
    ulong copied_bytes;
    uint pipelines;
    uint objects;
    uint views;
    uint allocations;
    uint pipeline_lookups;
    uint pipeline_hits;
    uint pipeline_keys;
    uint restarts;
    ulong generation_ns;
    ulong pipeline_ns;
    ulong elapsed_ns;
    ulong overrun_ns;
    PrepareStopReason reason;
    PrepareStepCost required;
}

<* Per-renderer work accumulated across preparation calls and aborted frames. *>
struct PrepareCounters {
    ulong staged_bytes;
    ulong generated_texels;
    ulong copied_bytes;
    ulong pipelines;
    ulong objects;
    ulong views;
    ulong allocations;
    ulong pipeline_lookups;
    ulong pipeline_hits;
    ulong pipeline_keys;
    ulong restarts;
    ulong generation_ns;
    ulong pipeline_ns;
    ulong elapsed_ns;
    ulong overrun_ns;
}

<* Fixed totals and current progress of a preparation. *>
struct PrepareProgress {
    PrepareState state;
    PreparePhase phase;
    usz bytes_total;
    usz bytes_done;
    ulong texels_total;
    ulong texels_done;
    uint units_total;
    uint units_done;
    uint restarts;
    fault failure;
}

enum PrepareUnitKind @private {
    TEXTURE,
    GEOMETRY,
    SAMPLER,
    TOON_SAMPLER,
    SHADER,
    MATERIAL,
    PIPELINES,
    FINISH,
}

struct PrepareCursor @private {
    usz bytes;
    uint mip;
    uint layer;
    uint slice;
    uint row;
}

struct PrepareCheckpoint @private {
    PrepareCursor staged;
    bool done;
    bool initialized;
    gpu::TextureState texture_state;
    ulong epoch;
    ulong frame;
    bool active;
}

struct PrepareUnit @private {
    PrepareUnitKind kind;
    PrepareId owner;
    uint index;
    uint creation_next;
    ulong generated_done;
    TextureId texture;
    GeometryId geometry;
    MaterialId material;
    SamplerId sampler;
    ShaderId shader;
    uint revision;
    usz bytes;
    ulong texels;
    bool full_reader;
    bool morphed;
    bool done;
    bool initialized;
    bool installed;
    bool force_restart;
    bool abandoned_candidate;
    PrepareCursor staged;
    PrepareCheckpoint checkpoint;
    TextureRes texture_candidate;
    TextureResidency residency_candidate;
    uint texture_base;
    GpuGeometry geometry_candidate;
    MaterialRes material_candidate;
    PreparePipelineUnit pipeline;
    PrepareShaderUnit shader_job;
    gpu::CompletionPoint last_submission;
    uint last_submission_slot;
    bool referenced_this_frame;
}

struct PrepareRecord @private {
    PrepareId id;
    ModelId model;
    uint model_revision;
    PrepareUnit[] units;
    uint next;
    ulong sequence;
    ulong epoch;
    PrepareState state;
    PreparePhase phase;
    fault failure;
    usz bytes_total;
    usz bytes_done;
    ulong texels_total;
    ulong texels_done;
    uint units_done;
    uint restarts;
    SceneReads scene_reads;
    TextureMipChain chain;
    uint chain_unit;
    uint generation_mip;
    uint generation_layer;
    uint generation_row;
    ulong generation_outputs;
    bool chain_active;
    gpu::CompletionPoint last_submission;
    bool pending_gpu;
    bool open;
}

struct PrepareBudget @private {
    PrepareLimits limits;
    PrepareReport report;
    std::time::Clock started;
    bool legacy;
    bool legacy_step;
}

struct PrepareInstall @private {
    PrepareId record;
    uint unit;
    ulong epoch;
    PrepareUnitKind kind;
    TextureRes old_texture;
    TextureRes new_texture;
    TextureResidency old_residency;
    TextureResidency new_residency;
    GpuGeometry old_geometry;
    GpuGeometry new_geometry;
    MaterialRes old_material;
    MaterialRes new_material;
    PathTracer old_path_tracer;
    PathTracer new_path_tracer;
    gpu::CompletionPoint last_submission;
    uint last_submission_slot;
}

<*
 Open a model preparation with synchronous structural enumeration.
 @return? c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
*>
fn PrepareId? Renderer.begin_prepare_model(&self, ModelId model) {
    ModelAsset* source = self.assets.models.try_get(model)!;
    if (!self.prepares.free_count) return c3d::CAPACITY_EXCEEDED~;
    PrepareRecord record = {
        .model = model,
        .model_revision = source.header.revision,
        .last_submission = self.last_submission,
        .sequence = ++self.next_prepare_sequence,
        .epoch = 1,
        .state = PrepareState.PENDING,
        .open = true,
    };
    enumerate_prepare_record(self, &record);
    PrepareId id = self.prepares.add(record)!;
    bind_prepare_record(self, id);
    return id;
}

<*
 Advance preparation within four independent per-call limits.
 @return? c3d::INVALID_ARGUMENT, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::UNSUPPORTED_FEATURE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::INVALID_RESOURCE_STATE, gpu::RESOURCE_IN_USE, gpu::DEVICE_BUSY
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::WAIT_TIMEOUT
 @require self.frame_open
*>
fn PrepareReport? Renderer.advance_prepares_within(&self, PrepareLimits limits) {
    return advance_prepare_engine(self, limits, false);
}

<*
 Advance preparation under the legacy staged-byte allowance.
 @param budget_bytes : "One oversized minimum step may progress before bytes stage."
 @return? c3d::INVALID_ARGUMENT, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::UNSUPPORTED_FEATURE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::INVALID_RESOURCE_STATE, gpu::RESOURCE_IN_USE, gpu::DEVICE_BUSY
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::WAIT_TIMEOUT
 @require self.frame_open
*>
fn void? Renderer.advance_prepares(&self, usz budget_bytes = PREPARE_FRAME_BUDGET_BYTES) {
    advance_prepare_engine(self, { .staged_bytes = budget_bytes }, true)!;
}

<*
 Inspect progress and detect a removed model.
 @return "FAILED with INVALID_ID for a stale request or removed model."
*>
fn PrepareProgress Renderer.prepare_progress(&self, PrepareId id) {
    PrepareRecord*? record = self.prepares.try_get(id);
    if (catch record) return { .state = PrepareState.FAILED, .failure = c3d::INVALID_ID };
    check_prepare_model(self, record);
    promote_prepare_record(self, record);
    return {
        .state = record.state,
        .phase = record.phase,
        .bytes_total = record.bytes_total,
        .bytes_done = record.bytes_done,
        .texels_total = record.texels_total,
        .texels_done = record.texels_done,
        .units_total = (uint)record.units.len,
        .units_done = record.units_done,
        .restarts = record.restarts,
        .failure = record.failure,
    };
}

<*
 Abandon a preparation without unloading its published mirrors.
 @return? c3d::INVALID_ID
 @require !self.frame_open
*>
fn void? Renderer.end_prepare(&self, PrepareId id) {
    PrepareRecord* record = self.prepares.try_get(id)!;
    release_prepare_record(self, record);
    *record = {};
    self.prepares.remove(id);
}

fn ulong prepare_add(ulong first, ulong second) @private {
    return first > ulong::max - second ? ulong::max : first + second;
}

fn usz prepare_byte_allowance(PrepareBudget* budget) @private {
    bool bounded = budget.legacy || budget.limits.staged_bytes != 0;
    if (!bounded) return PREPARE_SPAN_BYTES;
    if (budget.report.staged_bytes >= budget.limits.staged_bytes) return 0;
    return math::min(budget.limits.staged_bytes - budget.report.staged_bytes, PREPARE_SPAN_BYTES);
}

fn PrepareStopReason prepare_step_stop(PrepareBudget* budget, PrepareStepCost cost, ulong elapsed_ns) @private {
    if (budget.limits.time_ns && elapsed_ns >= budget.limits.time_ns) return PrepareStopReason.TIME;
    bool bytes_bounded = budget.legacy || budget.limits.staged_bytes != 0;
    if (bytes_bounded && (cost.staged_bytes > budget.limits.staged_bytes
      || budget.report.staged_bytes > budget.limits.staged_bytes - cost.staged_bytes)) {
        if (!budget.legacy || budget.report.staged_bytes || budget.legacy_step) return PrepareStopReason.STAGED_BYTES;
    }
    if (budget.limits.generated_texels && (cost.generated_texels > budget.limits.generated_texels
      || budget.report.generated_texels > budget.limits.generated_texels - cost.generated_texels)) return PrepareStopReason.GENERATED_TEXELS;
    if (!budget.legacy && budget.limits.pipelines && (cost.pipelines > budget.limits.pipelines
      || budget.report.pipelines > budget.limits.pipelines - cost.pipelines)) return PrepareStopReason.PIPELINES;
    return PrepareStopReason.NONE;
}

fn void account_prepare_report(Renderer* renderer, PrepareReport report) @private {
    renderer.stats.prepare_bytes += report.staged_bytes;
    renderer.stats.prepare_generated_texels += report.generated_texels;
    renderer.stats.prepare_copied_bytes += report.copied_bytes;
    renderer.stats.prepare_pipelines += report.pipelines;
    renderer.stats.prepare_objects += report.objects;
    renderer.stats.prepare_views += report.views;
    renderer.stats.prepare_allocations += report.allocations;
    renderer.stats.prepare_pipeline_lookups += report.pipeline_lookups;
    renderer.stats.prepare_pipeline_hits += report.pipeline_hits;
    renderer.stats.prepare_pipeline_keys += report.pipeline_keys;
    renderer.stats.prepare_restarts += report.restarts;
    renderer.stats.prepare_generation_ns += report.generation_ns;
    renderer.stats.prepare_pipeline_ns += report.pipeline_ns;
    renderer.stats.prepare_elapsed_ns += report.elapsed_ns;
    renderer.stats.prepare_overrun_ns += report.overrun_ns;
    PrepareCounters* totals = &renderer.prepare_counters;
    totals.staged_bytes = prepare_add(totals.staged_bytes, report.staged_bytes);
    totals.generated_texels = prepare_add(totals.generated_texels, report.generated_texels);
    totals.copied_bytes = prepare_add(totals.copied_bytes, report.copied_bytes);
    totals.pipelines = prepare_add(totals.pipelines, report.pipelines);
    totals.objects = prepare_add(totals.objects, report.objects);
    totals.views = prepare_add(totals.views, report.views);
    totals.allocations = prepare_add(totals.allocations, report.allocations);
    totals.pipeline_lookups = prepare_add(totals.pipeline_lookups, report.pipeline_lookups);
    totals.pipeline_hits = prepare_add(totals.pipeline_hits, report.pipeline_hits);
    totals.pipeline_keys = prepare_add(totals.pipeline_keys, report.pipeline_keys);
    totals.restarts = prepare_add(totals.restarts, report.restarts);
    totals.generation_ns = prepare_add(totals.generation_ns, report.generation_ns);
    totals.pipeline_ns = prepare_add(totals.pipeline_ns, report.pipeline_ns);
    totals.elapsed_ns = prepare_add(totals.elapsed_ns, report.elapsed_ns);
    totals.overrun_ns = prepare_add(totals.overrun_ns, report.overrun_ns);
}
