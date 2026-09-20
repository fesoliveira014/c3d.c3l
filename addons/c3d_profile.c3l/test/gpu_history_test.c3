module c3d_profile_gpu_history_test @feat(C3D_PROFILE_GPU);

import c3d::profile @public;

const ulong LARGE_RENDERER_FRAME @private = 9_007_199_254_740_993;

fn RecorderDesc gpu_desc(uint frame_capacity = 2, uint gpu_capacity = 8, uint label_capacity = 128) @private {
    RecorderDesc desc = {
        .frame_capacity = frame_capacity,
        .gpu_scopes_per_frame = gpu_capacity,
        .label_bytes_per_frame = label_capacity,
    };
    $if $feat(C3D_PROFILE_CPU):
        desc.cpu_scopes_per_frame = 8;
        desc.max_depth = 4;
    $endif
    return desc;
}

fn Recorder create_gpu_recorder(uint frame_capacity = 2, uint gpu_capacity = 8, uint label_capacity = 128) @private {
    return profile::create_recorder(mem, gpu_desc(frame_capacity, gpu_capacity, label_capacity))!!;
}

fn String count_gpu_label(uint* count, String label) @private {
    (*count)++;
    return label;
}

fn CaptureBinding open_frame(Recorder* recorder, ulong frame_id) @private {
    return profile::begin_capture_at(recorder, frame_id, 1_000);
}

fn GpuSample gpu_sample(String label, uint parent_index = 0, bool has_parent = false) @private {
    return {
        .label = label,
        .info = {
            .origin = ScopeOrigin.LIBRARY,
            .kind = GpuScopeKind.PASS,
            .pass_ordinal = 3,
        },
        .parent_index = parent_index,
        .has_parent = has_parent,
        .start_ns = 10.0,
        .duration_ns = 20.0,
    };
}

fn void close_frame(Recorder* recorder, CaptureBinding binding, bool aborted = false) @private {
    profile::end_capture(recorder, binding, aborted);
}

fn void assert_invalid_desc(RecorderDesc desc) @private {
    if (catch excuse = profile::create_recorder(mem, desc)) {
        assert(excuse == profile::INVALID_ARGUMENT);
    } else {
        unreachable("expected INVALID_ARGUMENT");
    }
}

fn void assert_not_found(Recorder* recorder, ulong frame_id) @private {
    if (catch excuse = recorder.frame(frame_id)) {
        assert(excuse == profile::NOT_FOUND);
    } else {
        unreachable("expected NOT_FOUND");
    }
}

fn void test_gpu_feature_domain_construction() @test {
    RecorderDesc desc = gpu_desc();
    Recorder recorder = profile::create_recorder(mem, desc)!!;
    assert(recorder.gpu_samples.len == 16);
    $if $feat(C3D_PROFILE_CPU):
        assert(recorder.samples.len == 16);
    $else
        assert(recorder.samples.len == 0 && recorder.stack.len == 0);
    $endif
    profile::destroy_recorder(&recorder);

    desc = gpu_desc();
    desc.frame_capacity = 0;
    assert_invalid_desc(desc);
    desc = gpu_desc();
    desc.label_bytes_per_frame = 0;
    assert_invalid_desc(desc);
    desc = gpu_desc();
    desc.gpu_scopes_per_frame = 0;
    $if $feat(C3D_PROFILE_CPU):
        recorder = profile::create_recorder(mem, desc)!!;
        if (catch excuse = profile::attach_gpu_source(&recorder)) {
            assert(excuse == profile::INVALID_ARGUMENT);
        } else {
            unreachable("expected INVALID_ARGUMENT");
        }
        profile::destroy_recorder(&recorder);
    $else
        assert_invalid_desc(desc);
    $endif
    desc = gpu_desc(uint::max, uint::max, uint::max);
    assert_invalid_desc(desc);
}

fn void test_gpu_source_identity_is_monotonic_and_exhaustible() @test {
    Recorder recorder = create_gpu_recorder();
    uint source_a = profile::attach_gpu_source(&recorder)!!;
    profile::detach_gpu_source(&recorder, source_a);
    uint source_b = profile::attach_gpu_source(&recorder)!!;
    assert(source_b == source_a + 1 && recorder.live_gpu_sources == 1);
    profile::detach_gpu_source(&recorder, source_b);
    assert(recorder.live_gpu_sources == 0);

    recorder.next_gpu_source = uint::max;
    uint last_source = profile::attach_gpu_source(&recorder)!!;
    assert(last_source == uint::max);
    profile::detach_gpu_source(&recorder, last_source);
    if (catch excuse = profile::attach_gpu_source(&recorder)) {
        assert(excuse == profile::CAPACITY_EXCEEDED);
    } else {
        unreachable("expected CAPACITY_EXCEEDED");
    }
    profile::destroy_recorder(&recorder);
}

fn void test_gpu_token_pins_original_capture() @test {
    Recorder recorder = create_gpu_recorder();
    uint source = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding frame_10 = open_frame(&recorder, 10);
    GpuCaptureToken token = profile::borrow_gpu_frame(&recorder, source, 40);
    close_frame(&recorder, frame_10);
    CaptureState cpu_state = recorder.frame(10)!!.cpu_state;
    CaptureBinding frame_11 = open_frame(&recorder, 11);
    GpuSample[2] samples = {
        gpu_sample("root"),
        gpu_sample("child", 0, true),
    };
    samples[0].start_ns = 5.0;
    samples[0].duration_ns = 100.0;
    samples[1].start_ns = 15.0;
    samples[1].duration_ns = 30.0;
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token,
        samples: samples[..],
        truncated: false,
        dropped_scopes: 0,
    );
    close_frame(&recorder, frame_11);

    FrameCaptureView captured = recorder.frame(10)!!;
    assert(captured.cpu_state == cpu_state);
    assert(captured.gpu_state == CaptureState.READY && captured.gpu.len == 2);
    assert(captured.gpu[0].source == source && captured.gpu[0].renderer_frame == 40);
    assert(captured.gpu[0].start_ns == 5.0 && captured.gpu[1].duration_ns == 30.0);
    assert(captured.pending_gpu_frames == 0 && recorder.pending_gpu_pins == 0);
    assert(recorder.frame(11)!!.gpu.len == 0);
    profile::detach_gpu_source(&recorder, source);
    profile::destroy_recorder(&recorder);
}

fn void test_gpu_borrow_survives_cpu_scope_truncation()
    @test @feat(C3D_PROFILE_CPU & C3D_PROFILE_GPU) {
    RecorderDesc desc = gpu_desc();
    desc.cpu_scopes_per_frame = 1;
    desc.max_depth = 1;
    Recorder recorder = profile::create_recorder(mem, desc)!!;
    uint source = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding binding = open_frame(&recorder, 0);
    assert(profile::admit_cpu_scope(&recorder));
    ScopeToken scope = profile::begin_cpu_scope_at(
        recorder: &recorder,
        label: "cpu",
        origin: ScopeOrigin.APPLICATION,
        start_ns: 1_000,
    );
    profile::end_cpu_scope_at(&recorder, scope, 1_010);
    assert(!profile::admit_cpu_scope(&recorder));
    GpuCaptureToken token = profile::borrow_gpu_frame(&recorder, source, 0);
    assert(token.borrowed);
    close_frame(&recorder, binding);
    GpuSample[1] sample = { gpu_sample("gpu") };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token,
        samples: sample[..],
        truncated: false,
        dropped_scopes: 0,
    );
    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.cpu_state == CaptureState.TRUNCATED);
    assert(frame.gpu_state == CaptureState.READY && frame.gpu.len == 1);
    profile::detach_gpu_source(&recorder, source);
    profile::destroy_recorder(&recorder);
}

fn void test_all_pinned_slots_drop_application_frames() @test {
    Recorder recorder = create_gpu_recorder(1);
    uint source = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding binding = open_frame(&recorder, 0);
    GpuCaptureToken token = profile::borrow_gpu_frame(&recorder, source, 0);
    close_frame(&recorder, binding);

    uint labels;
    uint bodies;
    for (ulong frame_id = 1; frame_id <= 2; frame_id++) {
        profile::@capture(&recorder, frame_id) {
            profile::@scope(count_gpu_label(&labels, "dropped")) { bodies++; };
        };
        assert_not_found(&recorder, frame_id);
    }
    assert(labels == 0 && bodies == 2);
    assert(recorder.dropped_frames == 2 && recorder.frame(0)!!.gpu_state == CaptureState.PENDING);
    GpuSample[1] sample = { gpu_sample("frame") };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token,
        samples: sample[..],
        truncated: false,
        dropped_scopes: 0,
    );
    binding = open_frame(&recorder, 3);
    close_frame(&recorder, binding);
    assert_not_found(&recorder, 0);
    assert(recorder.frame(3)!!.gpu_state == CaptureState.UNAVAILABLE);
    profile::detach_gpu_source(&recorder, source);
    profile::destroy_recorder(&recorder);
}

fn void test_multiple_gpu_producers_remap_parent_prefixes() @test {
    Recorder recorder = create_gpu_recorder();
    uint source_a = profile::attach_gpu_source(&recorder)!!;
    uint source_b = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding binding = open_frame(&recorder, 0);
    GpuCaptureToken token_a = profile::borrow_gpu_frame(&recorder, source_a, 7);
    GpuCaptureToken token_b = profile::borrow_gpu_frame(&recorder, source_b, 2);
    close_frame(&recorder, binding);
    GpuSample[2] samples = { gpu_sample("root"), gpu_sample("child", 0, true) };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token_b,
        samples: samples[..],
        truncated: false,
        dropped_scopes: 0,
    );
    FrameCaptureView pending = recorder.frame(0)!!;
    assert(pending.gpu_state == CaptureState.PENDING && pending.gpu.len == 2);
    assert(pending.gpu[1].parent_index == 0 && pending.gpu[0].source == source_b);
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token_a,
        samples: samples[..],
        truncated: false,
        dropped_scopes: 0,
    );
    FrameCaptureView ready = recorder.frame(0)!!;
    assert(ready.gpu_state == CaptureState.READY && ready.gpu.len == 4);
    assert(ready.gpu[3].parent_index == 2 && ready.gpu[2].source == source_a);
    profile::detach_gpu_source(&recorder, source_b);
    profile::detach_gpu_source(&recorder, source_a);
    profile::destroy_recorder(&recorder);
}

fn void test_gpu_cancel_preserves_other_completed_samples() @test {
    Recorder recorder = create_gpu_recorder();
    uint source_a = profile::attach_gpu_source(&recorder)!!;
    uint source_b = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding binding = open_frame(&recorder, 0);
    GpuCaptureToken canceled = profile::borrow_gpu_frame(&recorder, source_a, 0);
    GpuCaptureToken completed = profile::borrow_gpu_frame(&recorder, source_b, 1);
    close_frame(&recorder, binding);
    profile::cancel_gpu_frame(&recorder, canceled);
    GpuSample[1] sample = { gpu_sample("complete") };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: completed,
        samples: sample[..],
        truncated: false,
        dropped_scopes: 0,
    );
    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.gpu_state == CaptureState.ABORTED && frame.gpu.len == 1);
    assert(frame.aborted_gpu_frames == 1 && frame.pending_gpu_frames == 0);
    assert(frame.cpu_state != CaptureState.ABORTED);
    profile::detach_gpu_source(&recorder, source_b);
    profile::detach_gpu_source(&recorder, source_a);
    profile::destroy_recorder(&recorder);
}

fn void test_submitted_gpu_work_survives_cpu_abort() @test {
    Recorder recorder = create_gpu_recorder();
    uint source = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding binding = open_frame(&recorder, 0);
    GpuCaptureToken token = profile::borrow_gpu_frame(&recorder, source, 0);
    close_frame(&recorder, binding, true);
    GpuSample[1] sample = { gpu_sample("submitted") };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token,
        samples: sample[..],
        truncated: false,
        dropped_scopes: 0,
    );
    FrameCaptureView frame = recorder.frame(0)!!;
    $if $feat(C3D_PROFILE_CPU):
        assert(frame.cpu_state == CaptureState.ABORTED);
    $else
        assert(frame.cpu_state == CaptureState.UNAVAILABLE);
    $endif
    assert(frame.gpu_state == CaptureState.READY && frame.gpu.len == 1);
    profile::detach_gpu_source(&recorder, source);
    profile::destroy_recorder(&recorder);
}

fn void test_runtime_toggle_keeps_pending_publication() @test {
    Recorder recorder = create_gpu_recorder();
    uint source = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding binding = open_frame(&recorder, 0);
    GpuCaptureToken token = profile::borrow_gpu_frame(&recorder, source, 0);
    recorder.set_enabled(false);
    close_frame(&recorder, binding);
    binding = open_frame(&recorder, 1);
    close_frame(&recorder, binding);
    assert_not_found(&recorder, 1);
    GpuSample[1] sample = { gpu_sample("pending") };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token,
        samples: sample[..],
        truncated: false,
        dropped_scopes: 0,
    );
    assert(recorder.frame(0)!!.gpu.len == 1);
    recorder.set_enabled(true);
    binding = open_frame(&recorder, 2);
    close_frame(&recorder, binding);
    assert(recorder.frame(2)!!.gpu_state == CaptureState.UNAVAILABLE);
    profile::detach_gpu_source(&recorder, source);
    profile::destroy_recorder(&recorder);
}

fn void test_gpu_capacity_keeps_valid_parent_prefix() @test {
    Recorder recorder = create_gpu_recorder(1, 2, 128);
    uint source_a = profile::attach_gpu_source(&recorder)!!;
    uint source_b = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding binding = open_frame(&recorder, 0);
    GpuCaptureToken token_a = profile::borrow_gpu_frame(&recorder, source_a, 0);
    GpuCaptureToken token_b = profile::borrow_gpu_frame(&recorder, source_b, 1);
    close_frame(&recorder, binding);
    FrameCaptureView gpu_only = recorder.frame(0)!!;
    $if !$feat(C3D_PROFILE_CPU):
        assert(gpu_only.cpu_state == CaptureState.UNAVAILABLE && gpu_only.cpu.len == 0);
    $endif
    GpuSample[3] nested = {
        gpu_sample("root"),
        gpu_sample("child", 0, true),
        gpu_sample("grandchild", 1, true),
    };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token_a,
        samples: nested[..],
        truncated: false,
        dropped_scopes: 0,
    );
    GpuSample[1] later = { gpu_sample("later") };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token_b,
        samples: later[..],
        truncated: false,
        dropped_scopes: 0,
    );
    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.gpu.len == 2 && frame.gpu[1].parent_index == 0);
    assert(frame.gpu_state == CaptureState.TRUNCATED && frame.gpu_truncated);
    assert(frame.dropped_gpu_scopes == 2);
    $if $feat(C3D_PROFILE_CPU):
        assert(frame.cpu_state == CaptureState.READY && !frame.truncated);
    $endif
    profile::detach_gpu_source(&recorder, source_b);
    profile::detach_gpu_source(&recorder, source_a);
    profile::destroy_recorder(&recorder);

    recorder = create_gpu_recorder(1, 3, 4);
    source_a = profile::attach_gpu_source(&recorder)!!;
    binding = open_frame(&recorder, 0);
    token_a = profile::borrow_gpu_frame(&recorder, source_a, 0);
    close_frame(&recorder, binding);
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token_a,
        samples: nested[..],
        truncated: false,
        dropped_scopes: 0,
    );
    frame = recorder.frame(0)!!;
    assert(frame.gpu.len == 1 && frame.gpu[0].label == "root");
    assert(frame.dropped_gpu_scopes == 2 && frame.gpu_truncated);
    profile::detach_gpu_source(&recorder, source_a);
    profile::destroy_recorder(&recorder);
}

fn void test_gpu_labels_partial_state_and_export_ownership() @test {
    Recorder recorder = create_gpu_recorder(1, 2, 64);
    uint completed_source = profile::attach_gpu_source(&recorder)!!;
    uint canceled_source = profile::attach_gpu_source(&recorder)!!;
    uint unavailable_source = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding binding = open_frame(&recorder, 5);
    GpuCaptureToken completed = profile::borrow_gpu_frame(&recorder, completed_source, LARGE_RENDERER_FRAME);
    GpuCaptureToken canceled = profile::borrow_gpu_frame(&recorder, canceled_source, 6);
    profile::unavailable_gpu_frame(&recorder, unavailable_source, 7);
    close_frame(&recorder, binding);
    String mutable_label = "mutable".copy(mem);
    GpuSample[2] samples = { gpu_sample(mutable_label), gpu_sample("second") };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: completed,
        samples: samples[..],
        truncated: true,
        dropped_scopes: 3,
    );
    mutable_label[0] = 'x';
    alloc::free(mem, mutable_label.ptr);
    profile::cancel_gpu_frame(&recorder, canceled);
    FrameCaptureView frame = recorder.frame(5)!!;
    assert(frame.gpu[0].label == "mutable");
    assert(frame.gpu_state == CaptureState.ABORTED && frame.gpu_truncated);
    assert(frame.unavailable_gpu_frames == 1 && frame.aborted_gpu_frames == 1);
    assert(frame.dropped_gpu_scopes == 3);
    String first = profile::capture_json(mem, frame);
    String second = profile::capture_json(mem, frame);
    assert(first == second);
    assert(first.contains("\"gpu_state\":\"ABORTED\""));
    assert(first.contains("9007199254740993"));
    assert(first.contains("\"label\":\"mutable\""));
    assert(!first.contains("duration_ns\":0"));
    profile::detach_gpu_source(&recorder, unavailable_source);
    profile::detach_gpu_source(&recorder, canceled_source);
    profile::detach_gpu_source(&recorder, completed_source);
    profile::destroy_recorder(&recorder);
    assert(first.contains("mutable") && first.contains("ABORTED"));
    alloc::free(mem, second.ptr);
    alloc::free(mem, first.ptr);
}

fn void test_gpu_export_pending_then_completed_is_snapshot_owned() @test {
    Recorder recorder = create_gpu_recorder();
    uint source_a = profile::attach_gpu_source(&recorder)!!;
    uint source_b = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding binding = open_frame(&recorder, 0);
    GpuCaptureToken token_a = profile::borrow_gpu_frame(&recorder, source_a, 0);
    GpuCaptureToken token_b = profile::borrow_gpu_frame(&recorder, source_b, 1);
    close_frame(&recorder, binding);
    GpuSample[1] sample = { gpu_sample("first") };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token_a,
        samples: sample[..],
        truncated: false,
        dropped_scopes: 0,
    );
    String pending = profile::capture_json(mem, recorder.frame(0)!!);
    sample[0] = gpu_sample("second");
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: token_b,
        samples: sample[..],
        truncated: false,
        dropped_scopes: 0,
    );
    String ready = profile::capture_json(mem, recorder.frame(0)!!);
    assert(pending.contains("\"gpu_state\":\"PENDING\"") && pending.contains("first"));
    assert(!pending.contains("second"));
    assert(ready.contains("\"gpu_state\":\"READY\"") && ready.contains("second"));
    profile::detach_gpu_source(&recorder, source_b);
    profile::detach_gpu_source(&recorder, source_a);
    profile::destroy_recorder(&recorder);
    assert(pending.contains("PENDING") && !pending.contains("second"));
    alloc::free(mem, ready.ptr);
    alloc::free(mem, pending.ptr);
}
