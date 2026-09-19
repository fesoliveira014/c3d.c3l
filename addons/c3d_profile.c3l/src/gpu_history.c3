module c3d::profile @feat(C3D_PROFILE_GPU);

fn uint? attach_gpu_source(Recorder* recorder) @private {
    if (!recorder.desc.gpu_scopes_per_frame) return INVALID_ARGUMENT~;
    if (recorder.gpu_source_exhausted) return CAPACITY_EXCEEDED~;
    uint source = recorder.next_gpu_source;
    if (source == uint::max) {
        recorder.gpu_source_exhausted = true;
    } else {
        recorder.next_gpu_source++;
    }
    recorder.live_gpu_sources++;
    return source;
}

fn void detach_gpu_source(Recorder* recorder, uint source) @private {
    (void)source;
    recorder.live_gpu_sources--;
}

fn GpuCaptureToken borrow_gpu_frame(Recorder* recorder, uint source, ulong renderer_frame) @private {
    if (!recorder.frame_open || !recorder.recording) return {};
    CaptureSlot* slot = current_slot(recorder);
    slot.pin_count++;
    slot.pending_gpu_frames++;
    slot.gpu_state = CaptureState.PENDING;
    recorder.pending_gpu_pins++;
    return {
        .slot = recorder.active_slot,
        .generation = slot.generation,
        .source = source,
        .renderer_frame = renderer_frame,
        .borrowed = true,
    };
}

fn void release_gpu_pin(Recorder* recorder, CaptureSlot* slot) @private {
    slot.pin_count--;
    slot.pending_gpu_frames--;
    recorder.pending_gpu_pins--;
    reduce_gpu_state(slot);
}

fn bool copy_gpu_label(CaptureSlot* slot, GpuSample* target, String label) @private {
    if (label.len > (sz)(slot.labels.len - slot.label_used)) return false;
    uint label_offset = slot.label_used;
    if (label.len) mem::copy(&slot.labels[label_offset], label.ptr, label.len);
    slot.label_used += (uint)label.len;
    target.label = (String)slot.labels[label_offset : label.len];
    return true;
}

<* @require !token.borrowed || token.slot < recorder.slots.len
 @require !token.borrowed || recorder.slots[token.slot].generation == token.generation
*>
fn void publish_gpu_frame(
    Recorder* recorder,
    GpuCaptureToken token,
    GpuSample[] samples,
    bool truncated,
    uint dropped_scopes,
) @private {
    if (!token.borrowed) return;
    CaptureSlot* slot = &recorder.slots[token.slot];
    uint destination_offset = slot.gpu_sample_count;
    uint accepted;
    if (!slot.gpu_truncated) {
        foreach (&incoming : samples) {
            if (slot.gpu_sample_count == slot.gpu.len) break;
            GpuSample* target = &slot.gpu[slot.gpu_sample_count];
            *target = *incoming;
            if (!copy_gpu_label(slot, target, incoming.label)) break;
            target.source = token.source;
            target.renderer_frame = token.renderer_frame;
            if (target.has_parent) target.parent_index += destination_offset;
            slot.gpu_sample_count++;
            accepted++;
        }
    }
    uint omitted = (uint)samples.len - accepted;
    slot.dropped_gpu_scopes += omitted + dropped_scopes;
    if (truncated || dropped_scopes || omitted) slot.gpu_truncated = true;
    slot.completed_gpu_frames++;
    release_gpu_pin(recorder, slot);
}

<* @require !token.borrowed || token.slot < recorder.slots.len
 @require !token.borrowed || recorder.slots[token.slot].generation == token.generation
*>
fn void cancel_gpu_frame(Recorder* recorder, GpuCaptureToken token) @private {
    if (!token.borrowed) return;
    CaptureSlot* slot = &recorder.slots[token.slot];
    slot.aborted_gpu_frames++;
    release_gpu_pin(recorder, slot);
}

fn void unavailable_gpu_frame(Recorder* recorder, uint source, ulong renderer_frame) @private {
    (void)source;
    (void)renderer_frame;
    if (!recorder.frame_open || !recorder.recording) return;
    CaptureSlot* slot = current_slot(recorder);
    slot.unavailable_gpu_frames++;
    reduce_gpu_state(slot);
}
