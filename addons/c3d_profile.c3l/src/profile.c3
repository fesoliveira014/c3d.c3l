module c3d::profile;

$assert !$feat(C3D_PROFILE_INTERNAL) || $feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU)
  : "C3D_PROFILE_INTERNAL requires C3D_PROFILE_CPU or C3D_PROFILE_GPU.";

module c3d::profile @feat(C3D_PROFILE_CPU);

import std::time::clock;

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

<* Fixed storage limits for CPU capture. *>
struct RecorderDesc {
    uint frame_capacity;
    uint cpu_scopes_per_frame;
    uint max_depth;
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

<* Borrowed capture, invalidated when its history slot is reused. *>
struct FrameCaptureView {
    ulong frame_id;
    CaptureState cpu_state;
    bool truncated;
    CpuSample[] cpu;
    uint dropped_cpu_scopes;
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
}

struct ScopeToken @private {
    uint sample_index;
    uint accepted_depth;
    bool recorded;
}

struct CaptureBinding @private {
    Recorder* previous;
}

<* Application-owned bounded CPU capture recorder. *>
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
}

tlocal Recorder* active_recorder @private;

<*
 Run a body within one CPU frame capture.
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

module c3d::profile @feat(!C3D_PROFILE_CPU);

<* Run a body without CPU capture. *>
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

module c3d::profile @feat(C3D_PROFILE_CPU);

fn usz? multiply_size(usz left, usz right) @private {
    if (left && right > (usz)sz::max / left) return INVALID_ARGUMENT~;
    return left * right;
}

fn usz? add_size(usz left, usz right) @private {
    if (right > (usz)sz::max - left) return INVALID_ARGUMENT~;
    return left + right;
}

<*
 Allocate bounded CPU capture storage.
 @return? profile::INVALID_ARGUMENT
*>
fn Recorder? create_recorder(Allocator allocator, RecorderDesc desc) {
    if (!desc.frame_capacity || !desc.cpu_scopes_per_frame || !desc.max_depth || !desc.label_bytes_per_frame) {
        return INVALID_ARGUMENT~;
    }
    if (desc.max_depth > desc.cpu_scopes_per_frame) return INVALID_ARGUMENT~;

    usz frame_count = desc.frame_capacity;
    usz scope_count = multiply_size(frame_count, desc.cpu_scopes_per_frame)!;
    usz label_count = multiply_size(frame_count, desc.label_bytes_per_frame)!;
    usz slot_bytes = multiply_size(frame_count, CaptureSlot::size)!;
    usz sample_bytes = multiply_size(scope_count, CpuSample::size)!;
    usz label_bytes = multiply_size(label_count, char::size)!;
    usz stack_bytes = multiply_size(desc.max_depth, uint::size)!;
    usz allocated_bytes = add_size(slot_bytes, sample_bytes)!;
    allocated_bytes = add_size(allocated_bytes, label_bytes)!;
    allocated_bytes = add_size(allocated_bytes, stack_bytes)!;

    CaptureSlot[] slots = alloc::new_array(allocator, CaptureSlot, (sz)frame_count);
    CpuSample[] samples = alloc::new_array(allocator, CpuSample, (sz)scope_count);
    char[] labels = alloc::new_array(allocator, char, (sz)label_count);
    uint[] stack = alloc::new_array(allocator, uint, (sz)desc.max_depth);
    foreach (index, &slot : slots) {
        sz sample_offset = index * (sz)desc.cpu_scopes_per_frame;
        sz label_offset = index * (sz)desc.label_bytes_per_frame;
        slot.cpu = samples[sample_offset : desc.cpu_scopes_per_frame];
        slot.labels = labels[label_offset : desc.label_bytes_per_frame];
    }

    return {
        .allocator = allocator,
        .desc = desc,
        .slots = slots,
        .samples = samples,
        .labels = labels,
        .stack = stack,
        .allocated_bytes = allocated_bytes,
        .enabled = true,
    };
}

<*
 Release CPU capture storage.
 @param [&inout] recorder : "No capture or scopes remain active."
 @require !recorder.frame_open
 @require recorder.depth == 0
*>
fn void destroy_recorder(Recorder* recorder) {
    alloc::free(recorder.allocator, recorder.stack.ptr);
    alloc::free(recorder.allocator, recorder.labels.ptr);
    alloc::free(recorder.allocator, recorder.samples.ptr);
    alloc::free(recorder.allocator, recorder.slots.ptr);
    *recorder = {};
}
