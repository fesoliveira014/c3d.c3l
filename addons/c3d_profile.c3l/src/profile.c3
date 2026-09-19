module c3d::profile;

$assert !$feat(C3D_PROFILE_INTERNAL) || $feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU)
  : "C3D_PROFILE_INTERNAL requires C3D_PROFILE_CPU or C3D_PROFILE_GPU.";

module c3d::profile @feat(C3D_PROFILE_CPU | C3D_PROFILE_GPU);

<* Source of a measured scope. *>
enum ScopeOrigin {
    APPLICATION,
    LIBRARY,
}

<* Availability of one captured domain. *>
enum CaptureState {
    PENDING,
    READY,
    TRUNCATED,
    ABORTED,
    UNAVAILABLE,
}

<* Kind of completed GPU scope. *>
enum GpuScopeKind @feat(C3D_PROFILE_GPU) {
    APPLICATION,
    FRAME,
    VIEW,
    PASS,
    SHADOW_LAYER,
    COMPUTE_DISPATCH,
}

<* Fixed storage limits for capture. *>
struct RecorderDesc {
    uint frame_capacity;
    uint cpu_scopes_per_frame @if($feat(C3D_PROFILE_CPU));
    uint max_depth @if($feat(C3D_PROFILE_CPU));
    uint gpu_scopes_per_frame @if($feat(C3D_PROFILE_GPU));
    uint label_bytes_per_frame;
}

<* Timed CPU scope with explicit self-time completeness. *>
struct CpuSample {
    String label;
    ScopeOrigin origin;
    uint parent_index;
    bool has_parent;
    ulong start_ns;
    ulong duration_ns;
    ulong self_ns;
    bool self_complete;
}

<* Copied identity of one GPU scope. *>
struct GpuScopeInfo @feat(C3D_PROFILE_GPU) {
    ScopeOrigin origin;
    GpuScopeKind kind;
    bool has_view;
    uint view_index;
    uint view_generation;
    uint pass_ordinal;
    uint light_index;
    uint light_generation;
    uint light_kind;
    uint layer_index;
    uint shader_index;
    uint shader_generation;
    uint shader_revision;
}

<* Completed GPU scope with producer identity. *>
struct GpuSample @feat(C3D_PROFILE_GPU) {
    String label;
    uint source;
    ulong renderer_frame;
    GpuScopeInfo info;
    uint parent_index;
    bool has_parent;
    double start_ns;
    double duration_ns;
}

<* Borrowed capture invalidated by slot reuse or GPU publication. *>
struct FrameCaptureView {
    ulong frame_id;
    CaptureState cpu_state;
    bool truncated;
    CpuSample[] cpu;
    uint dropped_cpu_scopes;
    CaptureState gpu_state @if($feat(C3D_PROFILE_GPU));
    bool gpu_truncated @if($feat(C3D_PROFILE_GPU));
    GpuSample[] gpu @if($feat(C3D_PROFILE_GPU));
    uint dropped_gpu_scopes @if($feat(C3D_PROFILE_GPU));
    uint pending_gpu_frames @if($feat(C3D_PROFILE_GPU));
    uint unavailable_gpu_frames @if($feat(C3D_PROFILE_GPU));
    uint aborted_gpu_frames @if($feat(C3D_PROFILE_GPU));
}

struct CaptureSlot @private {
    ulong frame_id;
    CpuSample[] cpu;
    char[] labels;
    uint sample_count;
    uint label_used;
    CaptureState state;
    bool occupied;
    bool truncated;
    uint dropped_cpu_scopes;
    GpuSample[] gpu @if($feat(C3D_PROFILE_GPU));
    uint gpu_sample_count @if($feat(C3D_PROFILE_GPU));
    uint generation @if($feat(C3D_PROFILE_GPU));
    uint pin_count @if($feat(C3D_PROFILE_GPU));
    CaptureState gpu_state @if($feat(C3D_PROFILE_GPU));
    bool gpu_truncated @if($feat(C3D_PROFILE_GPU));
    uint dropped_gpu_scopes @if($feat(C3D_PROFILE_GPU));
    uint pending_gpu_frames @if($feat(C3D_PROFILE_GPU));
    uint completed_gpu_frames @if($feat(C3D_PROFILE_GPU));
    uint unavailable_gpu_frames @if($feat(C3D_PROFILE_GPU));
    uint aborted_gpu_frames @if($feat(C3D_PROFILE_GPU));
}

struct ScopeToken @private {
    uint sample_index;
    uint accepted_depth;
    bool recorded;
}

struct CaptureBinding @private {
    Recorder* previous;
}

struct GpuCaptureToken @private @feat(C3D_PROFILE_GPU) {
    uint slot;
    uint generation;
    uint source;
    ulong renderer_frame;
    bool borrowed;
}

module c3d::profile;

<* Borrowed token for one native GPU scope. *>
struct GpuScopeToken {
    uptr owner;
    ulong recording_serial;
    uint slot;
    uint sample_index;
    bool recorded;
}

module c3d::profile @feat(C3D_PROFILE_CPU | C3D_PROFILE_GPU);

<* Application-owned bounded capture recorder. *>
struct Recorder {
    Allocator allocator;
    RecorderDesc desc;
    CaptureSlot[] slots;
    CpuSample[] samples;
    char[] labels;
    uint[] stack;
    usz allocated_bytes;
    ulong origin_ns;
    ulong last_frame_id;
    uint next_slot;
    uint active_slot;
    uint depth;
    bool has_last_frame_id;
    bool frame_open;
    bool recording;
    bool enabled;
    bool admitted;
    GpuSample[] gpu_samples @if($feat(C3D_PROFILE_GPU));
    ulong dropped_frames @if($feat(C3D_PROFILE_GPU));
    ulong live_gpu_sources @if($feat(C3D_PROFILE_GPU));
    uint next_gpu_source @if($feat(C3D_PROFILE_GPU));
    uint pending_gpu_pins @if($feat(C3D_PROFILE_GPU));
    bool gpu_source_exhausted @if($feat(C3D_PROFILE_GPU));
}

tlocal Recorder* active_recorder @private;

module c3d::profile @feat(C3D_PROFILE_CPU);
import std::time::clock;

<*
 Run a body within one frame capture.
 @param [&inout] recorder : "Stable application-owned recorder."
 @require !recorder.frame_open
 @require !recorder.has_last_frame_id || frame_id > recorder.last_frame_id
*>
macro void @capture(Recorder* recorder, ulong frame_id; @body()) {
    ulong origin_ns = recorder.enabled ? (ulong)clock::now() : 0;
    CaptureBinding binding = begin_capture_at(recorder, frame_id, origin_ns);
    bool capture_ended;
    defer {
        if (!capture_ended) end_capture(recorder, binding, false);
    }
    defer catch {
        end_capture(recorder, binding, true);
        capture_ended = true;
    }
    @body();
}

<* Run a body within an application CPU scope. *>
macro void @scope(#label; @body()) {
    Recorder* recorder = active_recorder;
    if (admit_cpu_scope(recorder)) {
        String scope_label = #label;
        if (admit_cpu_scope(recorder)) {
            ScopeToken token = begin_cpu_scope_at(
                recorder: recorder,
                label: scope_label,
                origin: ScopeOrigin.APPLICATION,
                start_ns: (ulong)clock::now(),
            );
            defer if (token.recorded) end_cpu_scope_at(recorder, token, (ulong)clock::now());
            @body();
        } else {
            @body();
        }
    } else {
        @body();
    }
}

macro void @internal_scope(#label; @body()) @private @feat(C3D_PROFILE_INTERNAL) {
    Recorder* recorder = active_recorder;
    if (admit_cpu_scope(recorder)) {
        String scope_label = #label;
        if (admit_cpu_scope(recorder)) {
            ScopeToken token = begin_cpu_scope_at(
                recorder: recorder,
                label: scope_label,
                origin: ScopeOrigin.LIBRARY,
                start_ns: (ulong)clock::now(),
            );
            defer if (token.recorded) end_cpu_scope_at(recorder, token, (ulong)clock::now());
            @body();
        } else {
            @body();
        }
    } else {
        @body();
    }
}

macro void @internal_scope(#label; @body()) @private @feat(!C3D_PROFILE_INTERNAL) {
    @body();
}

module c3d::profile @feat(C3D_PROFILE_GPU & !C3D_PROFILE_CPU);

<*
 Run a body within one GPU-only frame capture.
 @param [&inout] recorder : "Stable application-owned recorder."
 @require !recorder.frame_open
 @require !recorder.has_last_frame_id || frame_id > recorder.last_frame_id
*>
macro void @capture(Recorder* recorder, ulong frame_id; @body()) {
    CaptureBinding binding = begin_capture_at(recorder, frame_id, 0);
    bool capture_ended;
    defer {
        if (!capture_ended) end_capture(recorder, binding, false);
    }
    defer catch {
        end_capture(recorder, binding, true);
        capture_ended = true;
    }
    @body();
}

<* Run a body without CPU scope capture. *>
macro void @scope(#label; @body()) {
    @body();
}

macro void @internal_scope(#label; @body()) @private {
    @body();
}

module c3d::profile @feat(!C3D_PROFILE_CPU & !C3D_PROFILE_GPU);

<* Run a body without capture. *>
macro void @capture(#recorder, #frame_id; @body()) {
    @body();
}

<* Run a body without CPU scope capture. *>
macro void @scope(#label; @body()) {
    @body();
}

macro void @internal_scope(#label; @body()) @private {
    @body();
}

module c3d::profile @feat(C3D_PROFILE_CPU | C3D_PROFILE_GPU);

fn usz? multiply_size(usz left, usz right) @private {
    if (left && right > (usz)sz::max / left) return INVALID_ARGUMENT~;
    return left * right;
}

fn usz? add_size(usz left, usz right) @private {
    if (right > (usz)sz::max - left) return INVALID_ARGUMENT~;
    return left + right;
}

<* Allocate bounded capture storage.
 @return? profile::INVALID_ARGUMENT
*>
fn Recorder? create_recorder(Allocator allocator, RecorderDesc desc) {
    if (!desc.frame_capacity || !desc.label_bytes_per_frame) return INVALID_ARGUMENT~;
    $if $feat(C3D_PROFILE_CPU):
        if (!desc.cpu_scopes_per_frame || !desc.max_depth) return INVALID_ARGUMENT~;
        if (desc.max_depth > desc.cpu_scopes_per_frame) return INVALID_ARGUMENT~;
    $endif
    $if $feat(C3D_PROFILE_GPU) && !$feat(C3D_PROFILE_CPU):
        if (!desc.gpu_scopes_per_frame) return INVALID_ARGUMENT~;
    $endif

    usz frame_count = desc.frame_capacity;
    usz label_count = multiply_size(frame_count, desc.label_bytes_per_frame)!;
    usz slot_bytes = multiply_size(frame_count, CaptureSlot::size)!;
    usz label_bytes = multiply_size(label_count, char::size)!;
    usz allocated_bytes = add_size(slot_bytes, label_bytes)!;
    usz cpu_scope_count;
    usz gpu_scope_count;
    $if $feat(C3D_PROFILE_CPU):
        cpu_scope_count = multiply_size(frame_count, desc.cpu_scopes_per_frame)!;
        allocated_bytes = add_size(allocated_bytes, multiply_size(cpu_scope_count, CpuSample::size)!)!;
        allocated_bytes = add_size(allocated_bytes, multiply_size(desc.max_depth, uint::size)!)!;
    $endif
    $if $feat(C3D_PROFILE_GPU):
        gpu_scope_count = multiply_size(frame_count, desc.gpu_scopes_per_frame)!;
        allocated_bytes = add_size(allocated_bytes, multiply_size(gpu_scope_count, GpuSample::size)!)!;
    $endif

    CaptureSlot[] slots = alloc::new_array(allocator, CaptureSlot, (sz)frame_count);
    char[] labels = alloc::new_array(allocator, char, (sz)label_count);
    CpuSample[] samples;
    uint[] stack;
    $if $feat(C3D_PROFILE_CPU):
        samples = alloc::new_array(allocator, CpuSample, (sz)cpu_scope_count);
        stack = alloc::new_array(allocator, uint, (sz)desc.max_depth);
    $endif
    GpuSample[] gpu_samples @if($feat(C3D_PROFILE_GPU));
    $if $feat(C3D_PROFILE_GPU):
        if (gpu_scope_count) gpu_samples = alloc::new_array(allocator, GpuSample, (sz)gpu_scope_count);
    $endif
    foreach (index, &slot : slots) {
        sz label_offset = index * (sz)desc.label_bytes_per_frame;
        slot.labels = labels[label_offset : desc.label_bytes_per_frame];
        $if $feat(C3D_PROFILE_CPU):
            sz sample_offset = index * (sz)desc.cpu_scopes_per_frame;
            slot.cpu = samples[sample_offset : desc.cpu_scopes_per_frame];
        $endif
        $if $feat(C3D_PROFILE_GPU):
            sz gpu_offset = index * (sz)desc.gpu_scopes_per_frame;
            slot.gpu = gpu_samples[gpu_offset : desc.gpu_scopes_per_frame];
        $endif
    }
    Recorder recorder = {
        .allocator = allocator,
        .desc = desc,
        .slots = slots,
        .samples = samples,
        .labels = labels,
        .stack = stack,
        .allocated_bytes = allocated_bytes,
        .enabled = true,
    };
    $if $feat(C3D_PROFILE_GPU):
        recorder.gpu_samples = gpu_samples;
    $endif
    return recorder;
}

fn void release_recorder_storage(Recorder* recorder) @private {
    $if $feat(C3D_PROFILE_GPU):
        if (recorder.gpu_samples.ptr) alloc::free(recorder.allocator, recorder.gpu_samples.ptr);
    $endif
    $if $feat(C3D_PROFILE_CPU):
        alloc::free(recorder.allocator, recorder.stack.ptr);
        alloc::free(recorder.allocator, recorder.samples.ptr);
    $endif
    alloc::free(recorder.allocator, recorder.labels.ptr);
    alloc::free(recorder.allocator, recorder.slots.ptr);
    *recorder = {};
}

<* Release capture storage.
 @param [&inout] recorder : "No capture, source, or pin remains active."
 @require !recorder.frame_open
 @require recorder.depth == 0
 @require recorder.live_gpu_sources == 0
 @require recorder.pending_gpu_pins == 0
*>
fn void destroy_recorder(Recorder* recorder) @feat(C3D_PROFILE_GPU) {
    release_recorder_storage(recorder);
}

<* Release CPU capture storage.
 @param [&inout] recorder : "No capture or scope remains active."
 @require !recorder.frame_open
 @require recorder.depth == 0
*>
fn void destroy_recorder(Recorder* recorder) @feat(C3D_PROFILE_CPU & !C3D_PROFILE_GPU) {
    release_recorder_storage(recorder);
}
