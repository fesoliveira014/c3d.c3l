module c3d::profile @feat(C3D_PROFILE_CPU | C3D_PROFILE_GPU);

<*
 Select recording for the next capture.
 @param [&inout] self : "Current capture keeps its entry selection."
*>
fn void Recorder.set_enabled(&self, bool enabled) {
    self.enabled = enabled;
}

<*
 Borrow a retained closed capture.
 @param [&in] self : "Recorder on its owning thread."
 @return? NOT_FOUND
*>
fn FrameCaptureView? Recorder.frame(&self, ulong frame_id) {
    foreach (&slot : self.slots) {
        if (!slot.occupied || slot.frame_id != frame_id) continue;
        FrameCaptureView frame = {
            .frame_id = slot.frame_id,
            .cpu_state = slot.state,
            .truncated = slot.truncated,
            .cpu = slot.cpu[:slot.sample_count],
            .dropped_cpu_scopes = slot.dropped_cpu_scopes,
        };
        $if $feat(C3D_PROFILE_GPU):
            frame.gpu_state = slot.gpu_state;
            frame.gpu_truncated = slot.gpu_truncated;
            frame.gpu = slot.gpu[:slot.gpu_sample_count];
            frame.dropped_gpu_scopes = slot.dropped_gpu_scopes;
            frame.pending_gpu_frames = slot.pending_gpu_frames;
            frame.unavailable_gpu_frames = slot.unavailable_gpu_frames;
            frame.aborted_gpu_frames = slot.aborted_gpu_frames;
        $endif
        return frame;
    }
    return NOT_FOUND~;
}

fn CaptureSlot* current_slot(Recorder* recorder) @private => &recorder.slots[recorder.active_slot];

fn bool select_capture_slot(Recorder* recorder) @private {
    $if $feat(C3D_PROFILE_GPU):
        for (uint offset = 0; offset < recorder.desc.frame_capacity; offset++) {
            uint slot_index = (recorder.next_slot + offset) % recorder.desc.frame_capacity;
            if (recorder.slots[slot_index].pin_count) continue;
            recorder.active_slot = slot_index;
            recorder.next_slot = (slot_index + 1) % recorder.desc.frame_capacity;
            return true;
        }
        return false;
    $else
        recorder.active_slot = recorder.next_slot;
        recorder.next_slot = (recorder.next_slot + 1) % recorder.desc.frame_capacity;
        return true;
    $endif
}

fn void reset_capture_slot(Recorder* recorder, ulong frame_id) @private {
    CaptureSlot* slot = current_slot(recorder);
    slot.frame_id = frame_id;
    slot.sample_count = 0;
    slot.label_used = 0;
    slot.occupied = false;
    slot.truncated = false;
    slot.dropped_cpu_scopes = 0;
    $if $feat(C3D_PROFILE_CPU):
        slot.state = CaptureState.PENDING;
    $else
        slot.state = CaptureState.UNAVAILABLE;
    $endif
    $if $feat(C3D_PROFILE_GPU):
        slot.generation++;
        slot.gpu_sample_count = 0;
        slot.gpu_state = CaptureState.UNAVAILABLE;
        slot.gpu_truncated = false;
        slot.dropped_gpu_scopes = 0;
        slot.pending_gpu_frames = 0;
        slot.completed_gpu_frames = 0;
        slot.unavailable_gpu_frames = 0;
        slot.aborted_gpu_frames = 0;
    $endif
}

fn void truncate_capture(Recorder* recorder) @private @feat(C3D_PROFILE_CPU) {
    CaptureSlot* slot = current_slot(recorder);
    slot.truncated = true;
    slot.dropped_cpu_scopes++;
    recorder.admitted = false;
    for (uint depth = 0; depth < recorder.depth; depth++) {
        slot.cpu[recorder.stack[depth]].self_complete = false;
    }
}

fn CaptureBinding begin_capture_at(Recorder* recorder, ulong frame_id, ulong origin_ns) @private {
    CaptureBinding binding = { .previous = active_recorder };
    recorder.frame_open = true;
    recorder.has_last_frame_id = true;
    recorder.last_frame_id = frame_id;
    recorder.recording = recorder.enabled;
    recorder.origin_ns = origin_ns;
    recorder.depth = 0;
    active_recorder = recorder;

    if (!recorder.recording) return binding;
    if (!select_capture_slot(recorder)) {
        recorder.recording = false;
        $if $feat(C3D_PROFILE_GPU):
            recorder.dropped_frames++;
        $endif
        return binding;
    }
    recorder.admitted = true;
    reset_capture_slot(recorder, frame_id);
    return binding;
}

fn void reduce_gpu_state(CaptureSlot* slot) @private @feat(C3D_PROFILE_GPU) {
    if (slot.pending_gpu_frames) {
        slot.gpu_state = CaptureState.PENDING;
    } else if (slot.aborted_gpu_frames) {
        slot.gpu_state = CaptureState.ABORTED;
    } else if (slot.gpu_truncated) {
        slot.gpu_state = CaptureState.TRUNCATED;
    } else if (slot.unavailable_gpu_frames || !slot.completed_gpu_frames) {
        slot.gpu_state = CaptureState.UNAVAILABLE;
    } else {
        slot.gpu_state = CaptureState.READY;
    }
}

fn void end_capture(Recorder* recorder, CaptureBinding binding, bool aborted) @private {
    if (recorder.recording) {
        CaptureSlot* slot = current_slot(recorder);
        $if $feat(C3D_PROFILE_CPU):
            slot.state = aborted
                ? CaptureState.ABORTED
                : slot.truncated ? CaptureState.TRUNCATED : CaptureState.READY;
        $endif
        $if $feat(C3D_PROFILE_GPU):
            reduce_gpu_state(slot);
        $endif
        slot.occupied = true;
    }
    recorder.frame_open = false;
    recorder.recording = false;
    recorder.admitted = false;
    active_recorder = binding.previous;
}

fn bool admit_cpu_scope(Recorder* recorder) @private @feat(C3D_PROFILE_CPU) {
    if (!recorder || !recorder.recording) return false;
    CaptureSlot* slot = current_slot(recorder);
    if (!recorder.admitted) {
        slot.dropped_cpu_scopes++;
        return false;
    }
    if (slot.sample_count == recorder.desc.cpu_scopes_per_frame || recorder.depth == recorder.desc.max_depth) {
        truncate_capture(recorder);
        return false;
    }
    return true;
}

fn ScopeToken begin_cpu_scope_at(
    Recorder* recorder,
    String label,
    ScopeOrigin origin,
    ulong start_ns,
) @private @feat(C3D_PROFILE_CPU) {
    CaptureSlot* slot = current_slot(recorder);
    if (label.len > (sz)(recorder.desc.label_bytes_per_frame - slot.label_used)) {
        truncate_capture(recorder);
        return {};
    }
    uint sample_index = slot.sample_count++;
    uint label_offset = slot.label_used;
    if (label.len) mem::copy(&slot.labels[label_offset], label.ptr, label.len);
    slot.label_used += (uint)label.len;
    CpuSample* sample = &slot.cpu[sample_index];
    *sample = {
        .label = (String)slot.labels[label_offset : label.len],
        .origin = origin,
        .parent_index = recorder.depth ? recorder.stack[recorder.depth - 1] : 0,
        .has_parent = recorder.depth > 0,
        .start_ns = start_ns - recorder.origin_ns,
        .self_complete = true,
    };
    recorder.stack[recorder.depth] = sample_index;
    recorder.depth++;
    return { .sample_index = sample_index, .accepted_depth = recorder.depth, .recorded = true };
}

fn void end_cpu_scope_at(Recorder* recorder, ScopeToken token, ulong end_ns) @private @feat(C3D_PROFILE_CPU) {
    if (!token.recorded) return;
    CaptureSlot* slot = current_slot(recorder);
    CpuSample* sample = &slot.cpu[token.sample_index];
    sample.duration_ns = end_ns - recorder.origin_ns - sample.start_ns;
    sample.self_ns = sample.duration_ns - sample.self_ns;
    recorder.depth--;
    if (recorder.depth) slot.cpu[recorder.stack[recorder.depth - 1]].self_ns += sample.duration_ns;
}
