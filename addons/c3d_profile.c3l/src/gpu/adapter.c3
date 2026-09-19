module c3d::render::profile_gpu @private @feat(C3D_PROFILE_GPU);

import c3d::profile @public;
import gpu;

const uint DEFAULT_SCOPES_PER_SLOT = 2048; // Bounds each slot to 4096 queries and 416 KiB of scope/raw/decoded storage.
const uint DEFAULT_LABEL_BYTES_PER_SLOT = 65536; // 64 KiB of copied labels per in-flight recording.
const uint QUERIES_PER_SCOPE = 2;

struct GpuProfilerDesc {
    uint frame_slots;
    uint scopes_per_slot;
    uint label_bytes_per_slot;
    bool enabled;
}

struct ScopeRecord {
    String label;
    GpuScopeInfo info;
    uint parent_index;
    bool has_parent;
}

struct QuerySlot {
    ScopeRecord[] records;
    GpuSample[] decoded;
    ulong[] raw;
    char[] labels;
    GpuCaptureToken capture;
    ulong renderer_frame;
    uint sample_count;
    uint label_used;
    uint depth;
    uint top;
    uint dropped_scopes;
    bool truncated;
    bool pending;
}

struct CompletedFrame {
    GpuSample[] samples;
    ulong renderer_frame;
    uint dropped_scopes;
    bool truncated;
    bool available;
}

struct GpuProfiler {
    Allocator allocator;
    GpuProfilerDesc desc;
    Recorder* recorder;
    gpu::TimestampPoolHandle pool;
    gpu::TimestampCaps caps;
    QuerySlot[] slots;
    ScopeRecord[] records;
    GpuSample[] decoded;
    ulong[] raw;
    char[] labels;
    usz allocated_bytes;
    ulong recording_serial;
    uint current_slot;
    uint source;
    bool supported;
    bool enabled;
    bool recording;
}

fn GpuProfilerDesc? resolve_desc(GpuProfilerDesc desc) {
    if (!desc.frame_slots) return profile::INVALID_ARGUMENT~;
    if (!desc.scopes_per_slot) desc.scopes_per_slot = DEFAULT_SCOPES_PER_SLOT;
    if (!desc.label_bytes_per_slot) desc.label_bytes_per_slot = DEFAULT_LABEL_BYTES_PER_SLOT;

    usz scopes = profile::multiply_size(desc.frame_slots, desc.scopes_per_slot)!;
    if (scopes > uint::max / QUERIES_PER_SCOPE) return profile::INVALID_ARGUMENT~;
    (void)storage_bytes(desc)!;

    return desc;
}

fn usz? storage_bytes(GpuProfilerDesc desc) {
    usz scopes = profile::multiply_size(desc.frame_slots, desc.scopes_per_slot)!;
    usz queries = profile::multiply_size(scopes, QUERIES_PER_SCOPE)!;
    usz labels = profile::multiply_size(desc.frame_slots, desc.label_bytes_per_slot)!;
    usz bytes = profile::multiply_size(desc.frame_slots, QuerySlot::size)!;
    bytes = profile::add_size(bytes, profile::multiply_size(scopes, ScopeRecord::size)!)!;
    bytes = profile::add_size(bytes, profile::multiply_size(scopes, GpuSample::size)!)!;
    bytes = profile::add_size(bytes, profile::multiply_size(queries, ulong::size)!)!;
    return profile::add_size(bytes, labels);
}

fn GpuProfiler? allocate_storage(Allocator allocator, GpuProfilerDesc desc) {
    desc = resolve_desc(desc)!;

    GpuProfiler profiler = { .allocator = allocator, .desc = desc, .enabled = desc.enabled };
    profiler.allocated_bytes = storage_bytes(desc)!;
    sz scopes = (sz)desc.frame_slots * desc.scopes_per_slot;

    profiler.slots = alloc::new_array(allocator, QuerySlot, desc.frame_slots);
    profiler.records = alloc::new_array(allocator, ScopeRecord, scopes);
    profiler.decoded = alloc::new_array(allocator, GpuSample, scopes);
    profiler.raw = alloc::new_array(allocator, ulong, scopes * QUERIES_PER_SCOPE);
    profiler.labels = alloc::new_array(allocator, char, (sz)desc.frame_slots * desc.label_bytes_per_slot);

    foreach (index, &slot : profiler.slots) {
        sz offset = index * desc.scopes_per_slot;
        slot.records = profiler.records[offset : desc.scopes_per_slot];
        slot.decoded = profiler.decoded[offset : desc.scopes_per_slot];
        slot.raw = profiler.raw[offset * QUERIES_PER_SCOPE : desc.scopes_per_slot * QUERIES_PER_SCOPE];
        slot.labels = profiler.labels[index * desc.label_bytes_per_slot : desc.label_bytes_per_slot];
    }

    return profiler;
}

fn void release_storage(GpuProfiler* profiler) {
    if (profiler.labels.ptr) alloc::free(profiler.allocator, profiler.labels.ptr);
    if (profiler.raw.ptr) alloc::free(profiler.allocator, profiler.raw.ptr);
    if (profiler.decoded.ptr) alloc::free(profiler.allocator, profiler.decoded.ptr);
    if (profiler.records.ptr) alloc::free(profiler.allocator, profiler.records.ptr);
    if (profiler.slots.ptr) alloc::free(profiler.allocator, profiler.slots.ptr);

    *profiler = {};
}

fn GpuProfiler? create_gpu_profiler(
    Allocator allocator,
    gpu::Device* device,
    Recorder* recorder,
    GpuProfilerDesc desc,
) {
    desc = resolve_desc(desc)!;

    gpu::DeviceCaps caps = gpu::get_device_caps(device)!;
    GpuProfiler profiler = {
        .allocator = allocator,
        .desc = desc,
        .enabled = desc.enabled,
        .supported = caps.timestamps.queues.graphics,
        .caps = caps.timestamps,
    };

    if (desc.enabled && profiler.supported) {
        profiler = allocate_storage(allocator, desc)!;
        profiler.supported = true;
        profiler.caps = caps.timestamps;
    }
    defer catch release_storage(&profiler);

    profiler.recorder = recorder;
    if (recorder) profiler.source = profile::attach_gpu_source(recorder)!;
    defer catch if (recorder) profile::detach_gpu_source(recorder, profiler.source);

    if (profiler.slots.len) {
        gpu::TimestampPoolDesc pool_desc = {
            .capacity = desc.frame_slots * desc.scopes_per_slot * QUERIES_PER_SCOPE,
            .debug_name = "profile_timestamps",
        };
        profiler.pool = gpu::create_timestamp_pool(device, &pool_desc)!;
    }

    return profiler;
}

<* @require !profiler.recording
   @require slot_index < profiler.slots.len
   @require !profiler.slots[slot_index].pending *>
fn void start_slot(GpuProfiler* profiler, uint slot_index, ulong renderer_frame) {
    profiler.current_slot = slot_index;
    profiler.recording_serial++;
    profiler.recording = true;

    QuerySlot* slot = &profiler.slots[slot_index];
    slot.sample_count = 0;
    slot.label_used = 0;
    slot.depth = 0;
    slot.top = 0;
    slot.dropped_scopes = 0;
    slot.truncated = false;
    slot.renderer_frame = renderer_frame;
    slot.capture = {};

    if (profiler.recorder) {
        slot.capture = profile::borrow_gpu_frame(profiler.recorder, profiler.source, renderer_frame);
    }
}

<* @require !profiler.recording
   @require slot_index < profiler.desc.frame_slots
   @require !profiler.slots.len || !profiler.slots[slot_index].pending *>
fn void? begin_recording(
    GpuProfiler* profiler,
    gpu::CommandList* commands,
    uint slot_index,
    ulong renderer_frame,
) {
    if (!profiler.enabled || !profiler.supported) {
        if (profiler.recorder) profile::unavailable_gpu_frame(profiler.recorder, profiler.source, renderer_frame);
        return;
    }

    gpu::cmd_reset_timestamps(
        commands: commands,
        pool: profiler.pool,
        first: slot_index * profiler.desc.scopes_per_slot * QUERIES_PER_SCOPE,
        count: profiler.desc.scopes_per_slot * QUERIES_PER_SCOPE,
    )!;

    start_slot(profiler, slot_index, renderer_frame);
}

fn bool admit_scope(GpuProfiler* profiler, ScopeOrigin origin, ulong expected_serial) {
    if (!profiler.enabled || !profiler.supported || !profiler.recording) return false;
    if (profiler.recording_serial != expected_serial) return false;

    QuerySlot* slot = &profiler.slots[profiler.current_slot];
    if (origin == APPLICATION && !slot.capture.borrowed) return false;
    if (slot.truncated || slot.sample_count == slot.records.len) {
        slot.truncated = true;
        slot.dropped_scopes++;
        return false;
    }

    return true;
}

fn GpuScopeToken reserve_scope(GpuProfiler* profiler, String label, GpuScopeInfo info) {
    if (!admit_scope(profiler, info.origin, profiler.recording_serial)) return {};

    QuerySlot* slot = &profiler.slots[profiler.current_slot];
    if (label.len > slot.labels.len - slot.label_used) {
        slot.truncated = true;
        slot.dropped_scopes++;
        return {};
    }

    uint sample_index = slot.sample_count++;
    ScopeRecord* record = &slot.records[sample_index];
    *record = {
        .label = (String)slot.labels[slot.label_used : label.len],
        .info = info,
        .parent_index = slot.top,
        .has_parent = slot.depth > 0,
    };
    if (label.len) mem::copy(&slot.labels[slot.label_used], label.ptr, label.len);
    slot.label_used += (uint)label.len;
    slot.top = sample_index;
    slot.depth++;

    return {
        .owner = (uptr)profiler,
        .recording_serial = profiler.recording_serial,
        .slot = profiler.current_slot,
        .sample_index = sample_index,
        .recorded = true,
    };
}

fn uint begin_query(GpuProfiler* profiler, GpuScopeToken token) {
    return (token.slot * profiler.desc.scopes_per_slot + token.sample_index) * QUERIES_PER_SCOPE;
}

fn uint end_query(GpuProfiler* profiler, GpuScopeToken token) {
    return begin_query(profiler, token) + 1;
}

fn bool scope_is_current(GpuProfiler* profiler, GpuScopeToken token) {
    if (!token.recorded) return true;
    if (token.owner != (uptr)profiler || !profiler.recording) return false;
    if (token.recording_serial != profiler.recording_serial || token.slot != profiler.current_slot) return false;

    QuerySlot* slot = &profiler.slots[token.slot];
    return slot.depth > 0 && slot.top == token.sample_index;
}

<* @require scope_is_current(profiler, token) *>
fn void close_scope(GpuProfiler* profiler, GpuScopeToken token) {
    if (!token.recorded) return;

    QuerySlot* slot = &profiler.slots[token.slot];
    slot.top = slot.records[token.sample_index].parent_index;
    slot.depth--;
}

fn GpuScopeToken? begin_scope(
    GpuProfiler* profiler,
    gpu::CommandList* commands,
    String label,
    GpuScopeInfo info,
) {
    GpuScopeToken token = reserve_scope(profiler, label, info);
    if (!token.recorded) return token;

    gpu::cmd_write_timestamp(
        commands: commands,
        pool: profiler.pool,
        index: begin_query(profiler, token),
        stage: { .all = true },
    )!;

    return token;
}

<* @require scope_is_current(profiler, token) *>
fn void? end_scope(GpuProfiler* profiler, gpu::CommandList* commands, GpuScopeToken token) {
    if (!token.recorded) return;

    gpu::cmd_write_timestamp(
        commands: commands,
        pool: profiler.pool,
        index: end_query(profiler, token),
        stage: { .all = true },
    )!;

    close_scope(profiler, token);
}

<* @require !profiler.recording || profiler.slots[profiler.current_slot].depth == 0 *>
fn void mark_submitted(GpuProfiler* profiler) {
    if (!profiler.recording) return;

    profiler.slots[profiler.current_slot].pending = true;
    profiler.recording = false;
}

fn void? decode_slot(QuerySlot* slot, gpu::TimestampCaps* caps, uint source) {
    foreach (index, record : slot.records[:slot.sample_count]) {
        ulong begin = slot.raw[index * QUERIES_PER_SCOPE];
        ulong end = slot.raw[index * QUERIES_PER_SCOPE + 1];
        slot.decoded[index] = {
            .label = record.label,
            .source = source,
            .renderer_frame = slot.renderer_frame,
            .info = record.info,
            .parent_index = record.parent_index,
            .has_parent = record.has_parent,
            .start_ns = gpu::timestamp_delta_ns(
                caps: caps,
                queue: gpu::QueueKind.GRAPHICS,
                begin: slot.raw[0],
                end: begin,
            )!,
            .duration_ns = gpu::timestamp_delta_ns(
                caps: caps,
                queue: gpu::QueueKind.GRAPHICS,
                begin: begin,
                end: end,
            )!,
        };
    }
}

<* @require slot_index < profiler.slots.len
   @require profiler.slots[slot_index].pending *>
fn CompletedFrame? publish_completed(GpuProfiler* profiler, uint slot_index) {
    QuerySlot* slot = &profiler.slots[slot_index];
    decode_slot(slot, &profiler.caps, profiler.source)!;

    GpuSample[] samples = slot.decoded[:slot.sample_count];
    if (slot.capture.borrowed) {
        profile::publish_gpu_frame(
            recorder: profiler.recorder,
            token: slot.capture,
            samples: samples,
            truncated: slot.truncated,
            dropped_scopes: slot.dropped_scopes,
        );
        slot.capture = {};
    }
    slot.pending = false;

    return {
        .samples = samples,
        .renderer_frame = slot.renderer_frame,
        .dropped_scopes = slot.dropped_scopes,
        .truncated = slot.truncated,
        .available = true,
    };
}

<* @require slot_index < profiler.desc.frame_slots *>
fn CompletedFrame? collect_completed(gpu::Device* device, GpuProfiler* profiler, uint slot_index) {
    if (!profiler.slots.len || !profiler.slots[slot_index].pending) return {};

    QuerySlot* slot = &profiler.slots[slot_index];
    if (slot.sample_count) {
        gpu::read_timestamps(
            device: device,
            pool: profiler.pool,
            first: slot_index * profiler.desc.scopes_per_slot * QUERIES_PER_SCOPE,
            count: slot.sample_count * QUERIES_PER_SCOPE,
            out: slot.raw[:slot.sample_count * QUERIES_PER_SCOPE],
        )!;
    }

    return publish_completed(profiler, slot_index);
}

fn void cancel_recording(GpuProfiler* profiler) {
    if (!profiler.recording) return;

    QuerySlot* slot = &profiler.slots[profiler.current_slot];
    if (slot.capture.borrowed) {
        profile::cancel_gpu_frame(profiler.recorder, slot.capture);
        slot.capture = {};
    }

    slot.depth = 0;
    profiler.recording = false;
}

fn void abandon_pending(GpuProfiler* profiler) {
    cancel_recording(profiler);

    foreach (&slot : profiler.slots) {
        if (!slot.pending) continue;
        if (slot.capture.borrowed) {
            profile::cancel_gpu_frame(profiler.recorder, slot.capture);
            slot.capture = {};
        }
        slot.pending = false;
    }
}

fn bool has_pending(GpuProfiler* profiler) {
    foreach (slot : profiler.slots) if (slot.pending) return true;
    return false;
}

<* @require !profiler.recording && !has_pending(profiler) *>
fn void? destroy_gpu_profiler(gpu::Device* device, GpuProfiler* profiler) {
    if (profiler.pool.is_valid()) {
        if (catch excuse = gpu::destroy_timestamp_pool(device, profiler.pool)) {
            if (excuse != gpu::DEVICE_LOST) return excuse~;

            if (profiler.recorder) profile::detach_gpu_source(profiler.recorder, profiler.source);
            release_storage(profiler);

            return excuse~;
        }
    }

    if (profiler.recorder) profile::detach_gpu_source(profiler.recorder, profiler.source);
    release_storage(profiler);
}
