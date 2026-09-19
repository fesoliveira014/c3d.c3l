module c3d_profile_collector_test @feat(C3D_PROFILE_CPU);

import c3d::profile @public;

faultdef TEST_FAILURE @private;

const ulong LARGE_FRAME_ID @private = 9_007_199_254_740_993;

fn RecorderDesc test_desc() @private => {
    .frame_capacity = 2,
    .cpu_scopes_per_frame = 8,
    .max_depth = 4,
    .label_bytes_per_frame = 128,
};

fn Recorder create_test_recorder() @private => profile::create_recorder(mem, test_desc())!!;

fn String counted_label(uint* count, String label) @private {
    (*count)++;
    return label;
}

fn void assert_invalid_desc(RecorderDesc desc) @private {
    if (catch excuse = profile::create_recorder(mem, desc)) {
        assert(excuse == profile::INVALID_ARGUMENT);
    } else {
        unreachable("expected INVALID_ARGUMENT");
    }
}

fn CaptureBinding start_frame(Recorder* recorder, ulong frame_id) @private {
    return profile::begin_capture_at(recorder, frame_id, 1_000);
}

fn ScopeToken start_scope(
    Recorder* recorder,
    String label,
    ScopeOrigin origin,
    ulong relative_ns,
) @private {
    assert(profile::admit_cpu_scope(recorder));
    return profile::begin_cpu_scope_at(
        recorder: recorder,
        label: label,
        origin: origin,
        start_ns: 1_000 + relative_ns,
    );
}

fn void finish_scope(Recorder* recorder, ScopeToken token, ulong relative_ns) @private {
    profile::end_cpu_scope_at(recorder, token, 1_000 + relative_ns);
}

fn void assert_not_found(Recorder* recorder, ulong frame_id) @private {
    if (catch excuse = recorder.frame(frame_id)) {
        assert(excuse == profile::NOT_FOUND);
    } else {
        unreachable("expected NOT_FOUND");
    }
}

fn int return_from_capture(Recorder* recorder, ulong frame_id, bool leave_early) @private {
    profile::@capture(recorder, frame_id) {
        profile::@scope("early") {
            if (leave_early) return 27;
        };
    };
    return 0;
}

fn void? fault_from_capture(Recorder* recorder, ulong frame_id) @private {
    profile::@capture(recorder, frame_id) {
        profile::@scope("fault") { return TEST_FAILURE~; };
    };
}

fn void? fail_in_scope() @private {
    profile::@scope("caught") { return TEST_FAILURE~; };
}

fn void catch_inside_capture(Recorder* recorder, ulong frame_id) @private {
    profile::@capture(recorder, frame_id) {
        if (catch excuse = fail_in_scope()) assert(excuse == TEST_FAILURE);
    };
}

fn void? truncated_fault_from_capture(Recorder* recorder, ulong frame_id) @private {
    profile::@capture(recorder, frame_id) {
        profile::@scope("kept") {
            profile::@scope("omitted") {};
            return TEST_FAILURE~;
        };
    };
}

fn void test_constructor_rejects_invalid_budgets() @test {
    RecorderDesc desc = test_desc();
    desc.frame_capacity = 0;
    assert_invalid_desc(desc);
    desc = test_desc();
    desc.cpu_scopes_per_frame = 0;
    assert_invalid_desc(desc);
    desc = test_desc();
    desc.max_depth = 0;
    assert_invalid_desc(desc);
    desc = test_desc();
    desc.label_bytes_per_frame = 0;
    assert_invalid_desc(desc);
    desc = test_desc();
    desc.max_depth = desc.cpu_scopes_per_frame + 1;
    assert_invalid_desc(desc);
    desc = {
        .frame_capacity = uint::max,
        .cpu_scopes_per_frame = uint::max,
        .max_depth = uint::max,
        .label_bytes_per_frame = uint::max,
    };
    assert_invalid_desc(desc);

    Recorder recorder = create_test_recorder();
    defer profile::destroy_recorder(&recorder);
    usz expected_bytes = (usz)test_desc().frame_capacity * CaptureSlot::size
      + (usz)test_desc().frame_capacity * (usz)test_desc().cpu_scopes_per_frame * CpuSample::size
      + (usz)test_desc().frame_capacity * (usz)test_desc().label_bytes_per_frame
      + (usz)test_desc().max_depth * uint::size;
    assert(recorder.allocated_bytes == expected_bytes);
}

fn void test_nested_scopes_compute_inclusive_and_self_time() @test {
    Recorder recorder = create_test_recorder();
    defer profile::destroy_recorder(&recorder);
    CaptureBinding binding = start_frame(&recorder, 0);
    ScopeToken parent = start_scope(
        recorder: &recorder,
        label: "parent",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    ScopeToken child = start_scope(
        recorder: &recorder,
        label: "child",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 10,
    );
    ScopeToken grandchild = start_scope(
        recorder: &recorder,
        label: "grandchild",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 20,
    );
    finish_scope(&recorder, grandchild, 40);
    finish_scope(&recorder, child, 70);
    ScopeToken sibling = start_scope(
        recorder: &recorder,
        label: "sibling",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 80,
    );
    finish_scope(&recorder, sibling, 90);
    finish_scope(&recorder, parent, 100);
    profile::end_capture(&recorder, binding, false);

    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.cpu.len == 4 && frame.cpu_state == CaptureState.READY);
    assert(frame.cpu[0].duration_ns == 100 && frame.cpu[0].self_ns == 30);
    assert(frame.cpu[1].duration_ns == 60 && frame.cpu[1].self_ns == 40);
    assert(frame.cpu[2].duration_ns == 20 && frame.cpu[2].self_ns == 20);
    assert(frame.cpu[3].duration_ns == 10 && frame.cpu[3].self_ns == 10);
    assert(!frame.cpu[0].has_parent && frame.cpu[0].parent_index == 0);
    assert(frame.cpu[1].has_parent && frame.cpu[1].parent_index == 0);
    assert(frame.cpu[2].has_parent && frame.cpu[2].parent_index == 1);
    assert(frame.cpu[3].has_parent && frame.cpu[3].parent_index == 0);
    foreach (sample : frame.cpu) assert(sample.self_complete);
}

fn void test_repeated_labels_and_origins_remain_distinct() @test {
    Recorder recorder = create_test_recorder();
    defer profile::destroy_recorder(&recorder);
    CaptureBinding binding = start_frame(&recorder, 0);
    ScopeToken root = start_scope(
        recorder: &recorder,
        label: "work",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    ScopeToken first = start_scope(
        recorder: &recorder,
        label: "work",
        origin: ScopeOrigin.LIBRARY,
        relative_ns: 10,
    );
    finish_scope(&recorder, first, 40);
    ScopeToken second = start_scope(
        recorder: &recorder,
        label: "work",
        origin: ScopeOrigin.LIBRARY,
        relative_ns: 50,
    );
    finish_scope(&recorder, second, 70);
    finish_scope(&recorder, root, 100);
    ScopeToken separate = start_scope(
        recorder: &recorder,
        label: "work",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 110,
    );
    finish_scope(&recorder, separate, 120);
    profile::end_capture(&recorder, binding, false);

    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.cpu.len == 4 && frame.cpu[0].self_ns == 50);
    uint application_count;
    uint library_count;
    ulong application_sum;
    ulong library_sum;
    foreach (sample : frame.cpu) {
        assert(sample.label == "work");
        if (sample.origin == ScopeOrigin.APPLICATION) {
            application_count++;
            application_sum += sample.duration_ns;
        } else {
            library_count++;
            library_sum += sample.duration_ns;
        }
    }
    assert(application_count == 2 && application_sum == 110);
    assert(library_count == 2 && library_sum == 50);
}

fn void test_sample_exhaustion_stays_latched() @test {
    RecorderDesc desc = test_desc();
    desc.cpu_scopes_per_frame = 2;
    desc.max_depth = 2;
    Recorder recorder = profile::create_recorder(mem, desc)!!;
    defer profile::destroy_recorder(&recorder);
    CaptureBinding binding = start_frame(&recorder, 0);
    ScopeToken parent = start_scope(
        recorder: &recorder,
        label: "parent",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    ScopeToken child = start_scope(
        recorder: &recorder,
        label: "child",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 10,
    );
    finish_scope(&recorder, child, 20);
    assert(!profile::admit_cpu_scope(&recorder));
    finish_scope(&recorder, parent, 100);
    assert(!profile::admit_cpu_scope(&recorder));
    profile::end_capture(&recorder, binding, false);

    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.cpu.len == 2 && frame.dropped_cpu_scopes == 2);
    assert(frame.cpu_state == CaptureState.TRUNCATED && frame.truncated);
    assert(frame.cpu[0].duration_ns == 100 && frame.cpu[0].self_ns == 90 && !frame.cpu[0].self_complete);
    assert(frame.cpu[1].duration_ns == 10 && frame.cpu[1].self_ns == 10 && frame.cpu[1].self_complete);
    binding = start_frame(&recorder, 1);
    ScopeToken next = start_scope(
        recorder: &recorder,
        label: "next",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    finish_scope(&recorder, next, 1);
    profile::end_capture(&recorder, binding, false);
    assert(recorder.frame(1)!!.cpu_state == CaptureState.READY);
}

fn void test_depth_exhaustion_stays_latched() @test {
    RecorderDesc desc = test_desc();
    desc.max_depth = 2;
    Recorder recorder = profile::create_recorder(mem, desc)!!;
    defer profile::destroy_recorder(&recorder);
    CaptureBinding binding = start_frame(&recorder, 0);
    ScopeToken parent = start_scope(
        recorder: &recorder,
        label: "parent",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    ScopeToken child = start_scope(
        recorder: &recorder,
        label: "child",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 10,
    );
    assert(!profile::admit_cpu_scope(&recorder));
    finish_scope(&recorder, child, 30);
    assert(!profile::admit_cpu_scope(&recorder));
    finish_scope(&recorder, parent, 100);
    profile::end_capture(&recorder, binding, false);
    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.cpu.len == 2 && frame.dropped_cpu_scopes == 2);
    assert(frame.cpu[0].duration_ns == 100 && !frame.cpu[0].self_complete);
    assert(frame.cpu[1].duration_ns == 20 && !frame.cpu[1].self_complete);
    binding = start_frame(&recorder, 1);
    ScopeToken next = start_scope(
        recorder: &recorder,
        label: "next",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    finish_scope(&recorder, next, 1);
    profile::end_capture(&recorder, binding, false);
    assert(recorder.frame(1)!!.cpu_state == CaptureState.READY);
}

fn void test_label_overflow_is_atomic_and_sticky() @test {
    RecorderDesc desc = test_desc();
    desc.label_bytes_per_frame = 6;
    Recorder recorder = profile::create_recorder(mem, desc)!!;
    CaptureBinding binding = start_frame(&recorder, 0);
    ScopeToken root = start_scope(
        recorder: &recorder,
        label: "root",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    assert(profile::admit_cpu_scope(&recorder));
    ScopeToken skipped = profile::begin_cpu_scope_at(
        recorder: &recorder,
        label: "long",
        origin: ScopeOrigin.APPLICATION,
        start_ns: 1_010,
    );
    profile::end_cpu_scope_at(&recorder, skipped, 1_020);
    assert(!profile::admit_cpu_scope(&recorder));
    finish_scope(&recorder, root, 100);
    profile::end_capture(&recorder, binding, false);
    FrameCaptureView overflow = recorder.frame(0)!!;
    assert(overflow.cpu.len == 1 && overflow.cpu[0].label == "root");
    assert(overflow.dropped_cpu_scopes == 2 && !overflow.cpu[0].self_complete);

    profile::destroy_recorder(&recorder);
    desc.label_bytes_per_frame = 4;
    recorder = profile::create_recorder(mem, desc)!!;
    defer profile::destroy_recorder(&recorder);
    String copied = "root".copy(mem);
    defer alloc::free(mem, copied.ptr);
    binding = start_frame(&recorder, 0);
    ScopeToken exact = start_scope(
        recorder: &recorder,
        label: copied,
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    copied[0] = 'b';
    finish_scope(&recorder, exact, 10);
    ScopeToken empty = start_scope(
        recorder: &recorder,
        label: "",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 20,
    );
    finish_scope(&recorder, empty, 30);
    profile::end_capture(&recorder, binding, false);
    FrameCaptureView exact_frame = recorder.frame(0)!!;
    assert(exact_frame.cpu.len == 2);
    assert(exact_frame.cpu[0].label == "root" && exact_frame.cpu[1].label == "");
}

fn void test_history_retains_closed_frames_and_evicts_oldest() @test {
    Recorder recorder = create_test_recorder();
    defer profile::destroy_recorder(&recorder);
    CaptureBinding binding = start_frame(&recorder, 0);
    ScopeToken token = start_scope(
        recorder: &recorder,
        label: "zero",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    finish_scope(&recorder, token, 1);
    assert_not_found(&recorder, 0);
    profile::end_capture(&recorder, binding, false);
    assert_not_found(&recorder, 9);
    binding = start_frame(&recorder, 1);
    token = start_scope(
        recorder: &recorder,
        label: "one",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    finish_scope(&recorder, token, 1);
    profile::end_capture(&recorder, binding, false);
    assert(recorder.frame(0)!!.cpu[0].label == "zero");
    binding = start_frame(&recorder, 2);
    token = start_scope(
        recorder: &recorder,
        label: "two",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    finish_scope(&recorder, token, 1);
    profile::end_capture(&recorder, binding, false);
    assert_not_found(&recorder, 0);
    assert(recorder.frame(1)!!.cpu[0].label == "one");
    assert(recorder.frame(2)!!.cpu[0].label == "two");
}

fn void test_enable_selection_is_latched_at_capture_entry() @test {
    Recorder recorder = create_test_recorder();
    defer profile::destroy_recorder(&recorder);
    profile::@capture(&recorder, 0) {
        profile::@scope("before") {};
        recorder.set_enabled(false);
        profile::@scope("after") {};
    };
    assert(recorder.frame(0)!!.cpu.len == 2);
    uint labels;
    profile::@capture(&recorder, 1) {
        recorder.set_enabled(true);
        profile::@scope(counted_label(&labels, "disabled")) {};
    };
    assert(labels == 0);
    assert_not_found(&recorder, 1);
    assert(recorder.frame(0)!!.cpu.len == 2);
    profile::@capture(&recorder, 2) { profile::@scope("enabled") {}; };
    assert(recorder.frame(2)!!.cpu.len == 1);
}

fn void test_nested_capture_bindings_restore_outer_recorder() @test {
    Recorder outer = create_test_recorder();
    defer profile::destroy_recorder(&outer);
    Recorder inner = create_test_recorder();
    defer profile::destroy_recorder(&inner);
    profile::@capture(&outer, 0) {
        profile::@scope("outer") {
            profile::@capture(&inner, 0) { profile::@scope("inner") {}; };
            profile::@scope("after-inner") {};
        };
    };
    FrameCaptureView outer_frame = outer.frame(0)!!;
    FrameCaptureView inner_frame = inner.frame(0)!!;
    assert(outer_frame.cpu.len == 2 && inner_frame.cpu.len == 1);
    assert(outer_frame.cpu[1].has_parent && outer_frame.cpu[1].parent_index == 0);

    inner.set_enabled(false);
    uint labels;
    profile::@capture(&outer, 1) {
        profile::@scope("outer-disabled-inner") {
            profile::@capture(&inner, 1) { profile::@scope(counted_label(&labels, "masked")) {}; };
            profile::@scope("after-disabled-inner") {};
        };
    };
    assert(labels == 0 && outer.frame(1)!!.cpu.len == 2);
    assert_not_found(&inner, 1);
    profile::@scope(counted_label(&labels, "outside")) {};
    assert(labels == 0);
}

fn void test_early_return_and_faults_close_capture_and_restore_binding() @test {
    Recorder outer = create_test_recorder();
    defer profile::destroy_recorder(&outer);
    RecorderDesc inner_desc = test_desc();
    inner_desc.frame_capacity = 4;
    Recorder inner = profile::create_recorder(mem, inner_desc)!!;
    defer profile::destroy_recorder(&inner);
    RecorderDesc desc = test_desc();
    desc.cpu_scopes_per_frame = 1;
    desc.max_depth = 1;
    Recorder truncated = profile::create_recorder(mem, desc)!!;
    defer profile::destroy_recorder(&truncated);
    profile::@capture(&outer, 0) {
        assert(return_from_capture(&inner, 0, true) == 27);
        profile::@scope("outer-after-return") {};
        if (catch excuse = fault_from_capture(&inner, 1)) {
            assert(excuse == TEST_FAILURE);
        } else {
            unreachable("expected TEST_FAILURE");
        }
        profile::@scope("outer-after-fault") {};
        catch_inside_capture(&inner, 2);
        profile::@scope("outer-after-caught") {};
        if (catch excuse = truncated_fault_from_capture(&truncated, 0)) {
            assert(excuse == TEST_FAILURE);
        } else {
            unreachable("expected TEST_FAILURE");
        }
        profile::@scope("outer-after-truncated-fault") {};
    };

    FrameCaptureView outer_frame = outer.frame(0)!!;
    assert(outer_frame.cpu.len == 4);
    assert(outer_frame.cpu[0].label == "outer-after-return");
    assert(outer_frame.cpu[1].label == "outer-after-fault");
    assert(outer_frame.cpu[2].label == "outer-after-caught");
    assert(outer_frame.cpu[3].label == "outer-after-truncated-fault");
    foreach (sample : outer_frame.cpu) assert(!sample.has_parent);
    assert(inner.frame(0)!!.cpu_state == CaptureState.READY);
    assert(inner.frame(1)!!.cpu_state == CaptureState.ABORTED);
    assert(inner.frame(2)!!.cpu_state == CaptureState.READY);
    FrameCaptureView truncated_frame = truncated.frame(0)!!;
    assert(truncated_frame.cpu_state == CaptureState.ABORTED);
    assert(truncated_frame.truncated && truncated_frame.dropped_cpu_scopes == 1);
    profile::@capture(&inner, 3) {};
    assert(inner.frame(3)!!.cpu_state == CaptureState.READY);
    profile::@capture(&truncated, 1) {};
    assert(truncated.frame(1)!!.cpu_state == CaptureState.READY);
}

fn void test_empty_capture_is_available_only_when_enabled() @test {
    Recorder recorder = create_test_recorder();
    defer profile::destroy_recorder(&recorder);
    profile::@capture(&recorder, 0) {};
    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.cpu_state == CaptureState.READY && frame.cpu.len == 0);
    assert(!frame.truncated && frame.dropped_cpu_scopes == 0);
    recorder.set_enabled(false);
    profile::@capture(&recorder, 1) {};
    assert_not_found(&recorder, 1);
}

fn void test_export_is_exact_deterministic_and_owned() @test {
    Recorder recorder = create_test_recorder();
    CaptureBinding binding = profile::begin_capture_at(&recorder, LARGE_FRAME_ID, 1_000);
    ScopeToken parent = start_scope(
        recorder: &recorder,
        label: "parent",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    ScopeToken child = start_scope(
        recorder: &recorder,
        label: "child",
        origin: ScopeOrigin.LIBRARY,
        relative_ns: 10,
    );
    finish_scope(&recorder, child, 70);
    finish_scope(&recorder, parent, 100);
    profile::end_capture(&recorder, binding, false);
    String encoded = profile::capture_json(mem, recorder.frame(LARGE_FRAME_ID)!!);
    defer alloc::free(mem, encoded.ptr);
    String second = profile::capture_json(mem, recorder.frame(LARGE_FRAME_ID)!!);
    defer alloc::free(mem, second.ptr);
    assert(encoded == second);
    $if $feat(C3D_PROFILE_INTERNAL):
        String expected = "{\"schema\":\"c3d.profile\",\"version\":1,\"features\":{\"cpu\":true,\"internal\":true},\"frames\":[{\"frame_id\":9007199254740993,\"cpu_state\":\"READY\",\"truncated\":false,\"dropped_cpu_scopes\":0,\"cpu\":[{\"label\":\"parent\",\"origin\":\"APPLICATION\",\"parent_index\":0,\"has_parent\":false,\"start_ns\":0,\"duration_ns\":100,\"self_ns\":40,\"self_complete\":true},{\"label\":\"child\",\"origin\":\"LIBRARY\",\"parent_index\":0,\"has_parent\":true,\"start_ns\":10,\"duration_ns\":60,\"self_ns\":60,\"self_complete\":true}]}]}";
    $else
        String expected = "{\"schema\":\"c3d.profile\",\"version\":1,\"features\":{\"cpu\":true,\"internal\":false},\"frames\":[{\"frame_id\":9007199254740993,\"cpu_state\":\"READY\",\"truncated\":false,\"dropped_cpu_scopes\":0,\"cpu\":[{\"label\":\"parent\",\"origin\":\"APPLICATION\",\"parent_index\":0,\"has_parent\":false,\"start_ns\":0,\"duration_ns\":100,\"self_ns\":40,\"self_complete\":true},{\"label\":\"child\",\"origin\":\"LIBRARY\",\"parent_index\":0,\"has_parent\":true,\"start_ns\":10,\"duration_ns\":60,\"self_ns\":60,\"self_complete\":true}]}]}";
    $endif
    $if $feat(C3D_PROFILE_GPU):
        assert(encoded.contains("\"features\":{\"cpu\":true,\"internal\":"));
        assert(encoded.contains("\"gpu\":true"));
        assert(encoded.contains("\"gpu_state\":\"UNAVAILABLE\""));
        assert(encoded.contains("\"gpu\":[]"));
    $else
        assert(encoded == expected);
    $endif
    binding = profile::begin_capture_at(&recorder, LARGE_FRAME_ID + 1, 1_000);
    ScopeToken escaped = start_scope(
        recorder: &recorder,
        label: "quote\" slash\\ line\n tab\t café",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    finish_scope(&recorder, escaped, 1);
    profile::end_capture(&recorder, binding, false);
    FrameCaptureView escaped_frame = recorder.frame(LARGE_FRAME_ID + 1)!!;
    assert(escaped_frame.cpu[0].start_ns == 0 && escaped_frame.cpu[0].duration_ns == 1);
    String escaped_json = profile::capture_json(mem, escaped_frame);
    defer alloc::free(mem, escaped_json.ptr);
    assert(escaped_json.contains("quote\\\" slash\\\\ line\\n tab\\t café"));
    profile::destroy_recorder(&recorder);
    assert(encoded.contains("9007199254740993") && encoded.contains("parent"));
}

fn void test_export_preserves_truncation_abort_and_empty_state() @test {
    RecorderDesc desc = test_desc();
    desc.cpu_scopes_per_frame = 1;
    desc.max_depth = 1;
    Recorder recorder = profile::create_recorder(mem, desc)!!;
    defer profile::destroy_recorder(&recorder);
    CaptureBinding binding = start_frame(&recorder, 0);
    ScopeToken kept = start_scope(
        recorder: &recorder,
        label: "kept",
        origin: ScopeOrigin.APPLICATION,
        relative_ns: 0,
    );
    assert(!profile::admit_cpu_scope(&recorder));
    finish_scope(&recorder, kept, 10);
    profile::end_capture(&recorder, binding, false);
    String truncated = profile::capture_json(mem, recorder.frame(0)!!);
    defer alloc::free(mem, truncated.ptr);
    assert(truncated.contains("\"cpu_state\":\"TRUNCATED\""));
    assert(truncated.contains("\"dropped_cpu_scopes\":1"));
    assert(truncated.contains("\"self_complete\":false"));
    if (catch excuse = truncated_fault_from_capture(&recorder, 1)) assert(excuse == TEST_FAILURE);
    String aborted = profile::capture_json(mem, recorder.frame(1)!!);
    defer alloc::free(mem, aborted.ptr);
    assert(aborted.contains("\"cpu_state\":\"ABORTED\""));
    assert(aborted.contains("\"truncated\":true"));
    assert(aborted.contains("\"dropped_cpu_scopes\":1"));
    profile::@capture(&recorder, 2) {};
    String empty = profile::capture_json(mem, recorder.frame(2)!!);
    defer alloc::free(mem, empty.ptr);
    assert(empty.contains("\"cpu_state\":\"READY\""));
    assert(empty.contains("\"cpu\":[]"));
}
