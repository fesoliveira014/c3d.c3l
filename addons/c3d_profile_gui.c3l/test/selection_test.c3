module c3d_profile_gui_selection_test @feat(C3D_PROFILE_GUI & (C3D_PROFILE_CPU | C3D_PROFILE_GPU));

import c3d::profile @public;
import c3d::gui @public;

const ulong LARGE_FRAME_ID @private = 9_007_199_254_740_993;

struct CountingAllocator (Allocator) @private {
    uint allocations;
    uint releases;
    void* block;
}

fn void*? CountingAllocator.acquire(
    &self,
    sz size,
    alloc::AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.allocations++;
    self.block = mem.acquire(size, init_type, alignment)!;
    return self.block;
}

fn void*? CountingAllocator.resize(
    &self,
    void* pointer,
    sz new_size,
    sz alignment,
) @dynamic {
    unreachable("panel storage must not resize");
}

fn void CountingAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    assert(pointer == self.block);
    self.releases++;
    mem.release(pointer, aligned);
}

fn RecorderDesc capture_desc(uint frame_capacity = 4) @private {
    RecorderDesc desc = {
        .frame_capacity = frame_capacity,
        .label_bytes_per_frame = 128,
    };
    $if $feat(C3D_PROFILE_CPU):
        desc.cpu_scopes_per_frame = 8;
        desc.max_depth = 4;
    $endif
    $if $feat(C3D_PROFILE_GPU):
        desc.gpu_scopes_per_frame = 8;
    $endif
    return desc;
}

fn CaptureBinding open_capture(Recorder* recorder, ulong frame_id) @private {
    return profile::begin_capture_at(recorder, frame_id, 1_000);
}

fn void close_empty_capture(Recorder* recorder, ulong frame_id) @private {
    CaptureBinding binding = open_capture(recorder, frame_id);
    profile::end_capture(recorder, binding, false);
}

fn void close_replacement_capture(Recorder* recorder, ulong frame_id) @private @feat(C3D_PROFILE_CPU) {
    CaptureBinding binding = open_capture(recorder, frame_id);
    ScopeToken scope = profile::begin_cpu_scope_at(
        recorder: recorder,
        label: "replacement",
        origin: ScopeOrigin.APPLICATION,
        start_ns: 1_000,
    );
    profile::end_cpu_scope_at(recorder, scope, 1_200);
    profile::end_capture(recorder, binding, false);
}

fn GpuSample event(String label, uint revision, double duration) @private @feat(C3D_PROFILE_GPU) {
    return {
        .label = label,
        .info = {
            .origin = ScopeOrigin.LIBRARY,
            .kind = GpuScopeKind.COMPUTE_DISPATCH,
            .shader_index = 2,
            .shader_generation = 3,
            .shader_revision = revision,
        },
        .start_ns = 5.0,
        .duration_ns = duration,
    };
}

fn void test_follow_selects_latest_settled_outcome() @test @feat(C3D_PROFILE_GPU) {
    Recorder recorder = profile::create_recorder(mem, capture_desc())!!;
    defer profile::destroy_recorder(&recorder);
    uint source = profile::attach_gpu_source(&recorder)!!;
    defer profile::detach_gpu_source(&recorder, source);
    ProfilerPanel panel = gui::create_profiler_panel(mem, &recorder)!!;
    defer gui::destroy_profiler_panel(&panel);

    CaptureBinding binding = open_capture(&recorder, 10);
    GpuCaptureToken pending = profile::borrow_gpu_frame(&recorder, source, 1);
    defer profile::cancel_gpu_frame(&recorder, pending);
    profile::end_capture(&recorder, binding, false);
    gui::refresh_panel(&panel);
    assert(!panel.has_snapshot && panel.following);
    close_empty_capture(&recorder, 20);
    binding = open_capture(&recorder, 30);
    GpuCaptureToken canceled = profile::borrow_gpu_frame(&recorder, source, 2);
    profile::end_capture(&recorder, binding, false);
    profile::cancel_gpu_frame(&recorder, canceled);
    binding = open_capture(&recorder, 40);
    GpuCaptureToken completed = profile::borrow_gpu_frame(&recorder, source, 3);
    profile::end_capture(&recorder, binding, false);
    gui::refresh_panel(&panel);
    assert(panel.frame_count == 4 && panel.snapshot.frame_id == 30);
    assert(panel.frame_ids[0] == 10 && panel.frame_ids[1] == 20);
    assert(panel.frame_ids[2] == 30 && panel.frame_ids[3] == 40);
    assert(panel.snapshot.gpu_state == CaptureState.ABORTED);
    GpuSample[1] samples = { event("partial", 7, 20.0) };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: completed,
        samples: samples[..],
        truncated: true,
        dropped_scopes: 2,
    );
    gui::refresh_panel(&panel);
    assert(panel.snapshot.frame_id == 40);
    assert(panel.snapshot.gpu_state == CaptureState.TRUNCATED);
    assert(panel.snapshot.gpu_truncated && panel.snapshot.dropped_gpu_scopes == 2);
}

fn void test_pending_selection_remains_frozen() @test @feat(C3D_PROFILE_GPU) {
    Recorder recorder = profile::create_recorder(mem, capture_desc(3))!!;
    defer profile::destroy_recorder(&recorder);
    uint source = profile::attach_gpu_source(&recorder)!!;
    defer profile::detach_gpu_source(&recorder, source);
    ProfilerPanel panel = gui::create_profiler_panel(mem, &recorder)!!;
    defer gui::destroy_profiler_panel(&panel);
    CaptureBinding binding = open_capture(&recorder, 10);
    GpuCaptureToken first = profile::borrow_gpu_frame(&recorder, source, 11);
    GpuCaptureToken second = profile::borrow_gpu_frame(&recorder, source, 12);
    profile::end_capture(&recorder, binding, false);
    GpuSample[1] early = { event("early", 7, 20.0) };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: first,
        samples: early[..],
        truncated: false,
        dropped_scopes: 0,
    );
    gui::select_frame(&panel, 10)!!;
    assert(!panel.following && panel.snapshot.gpu.len == 1);
    gui::select_scope(&panel, 0, true);
    gui::resume_panel(&panel);
    assert(panel.following && !panel.has_snapshot && !panel.has_selected_scope);
    gui::select_frame(&panel, 10)!!;
    gui::select_scope(&panel, 0, true);
    assert(panel.snapshot.pending_gpu_frames == 1 && recorder.pending_gpu_pins == 1);
    char[FrameCaptureView::size] frozen_metadata;
    char[GpuSample::size] frozen_sample;
    char[128] frozen_labels;
    mem::copy(&frozen_metadata, &panel.snapshot, FrameCaptureView::size);
    mem::copy(&frozen_sample, panel.snapshot.gpu.ptr, GpuSample::size);
    frozen_labels[..] = panel.labels[..];
    GpuSample[1] late = { event("late", 8, 30.0) };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: second,
        samples: late[..],
        truncated: false,
        dropped_scopes: 0,
    );
    gui::refresh_panel(&panel);
    assert(mem::equals((char*)&frozen_metadata, (char*)&panel.snapshot, FrameCaptureView::size));
    assert(mem::equals((char*)&frozen_sample, (char*)panel.snapshot.gpu.ptr, GpuSample::size));
    assert(frozen_labels[..] == panel.labels);
    assert(panel.snapshot.gpu_state == CaptureState.PENDING);
    assert(panel.snapshot.pending_gpu_frames == 1 && panel.snapshot.gpu.len == 1);
    assert(panel.snapshot.gpu[0].info.shader_revision == 7);
    assert(panel.snapshot.gpu[0].label == "early");
    assert(panel.snapshot.gpu[0].duration_ns == 20.0);
    assert(panel.has_selected_scope && panel.selected_scope == 0 && panel.selected_gpu);
    assert(recorder.frame(10)!!.gpu_state == CaptureState.READY);
    assert(recorder.frame(10)!!.gpu.len == 2 && recorder.pending_gpu_pins == 0);
    gui::select_frame(&panel, 10)!!;
    assert(panel.snapshot.gpu_state == CaptureState.READY);
    assert(!panel.has_selected_scope);
    assert(panel.snapshot.pending_gpu_frames == 0 && panel.snapshot.gpu.len == 2);
    assert(panel.snapshot.gpu[1].label == "late");
    assert(panel.snapshot.gpu[1].info.shader_revision == 8);
}

fn void test_snapshot_survives_eviction_and_failed_reselection() @test @feat(C3D_PROFILE_CPU) {
    Recorder recorder = profile::create_recorder(mem, capture_desc(2))!!;
    defer profile::destroy_recorder(&recorder);
    ProfilerPanel panel = gui::create_profiler_panel(mem, &recorder)!!;
    defer gui::destroy_profiler_panel(&panel);
    char[4] label = { 'w', 'o', 'r', 'k' };
    CaptureBinding binding = open_capture(&recorder, 10);
    ScopeToken parent = profile::begin_cpu_scope_at(
        recorder: &recorder,
        label: (String)label[..],
        origin: ScopeOrigin.APPLICATION,
        start_ns: 1_000,
    );
    ScopeToken child = profile::begin_cpu_scope_at(
        recorder: &recorder,
        label: "child",
        origin: ScopeOrigin.APPLICATION,
        start_ns: 1_010,
    );
    profile::end_cpu_scope_at(&recorder, child, 1_040);
    profile::end_cpu_scope_at(&recorder, parent, 1_100);
    profile::end_capture(&recorder, binding, false);
    gui::refresh_panel(&panel);
    gui::select_scope(&panel, 1, false);
    assert(!panel.following);
    char[128] frozen_labels;
    frozen_labels[..] = panel.labels[..];
    label[0] = 'x';
    close_replacement_capture(&recorder, 20);
    close_replacement_capture(&recorder, 30);
    gui::refresh_panel(&panel);
    assert(panel.snapshot.frame_id == 10 && panel.snapshot.cpu.len == 2);
    assert(panel.snapshot.cpu[0].label == "work");
    assert(panel.snapshot.cpu[0].duration_ns == 100 && panel.snapshot.cpu[0].self_ns == 70);
    assert(panel.snapshot.cpu[1].label == "child");
    assert(panel.snapshot.cpu[1].has_parent && panel.snapshot.cpu[1].parent_index == 0);
    if (catch excuse = gui::select_frame(&panel, 10)) {
        assert(excuse == profile::NOT_FOUND);
    } else {
        unreachable("expected NOT_FOUND");
    }
    assert(!panel.following && panel.snapshot.frame_id == 10 && recorder.enabled);
    assert(frozen_labels[..] == panel.labels);
    assert(panel.has_selected_scope && panel.selected_scope == 1 && !panel.selected_gpu);
    assert(panel.snapshot.cpu[0].duration_ns == 100 && panel.snapshot.cpu[1].duration_ns == 30);
    gui::resume_panel(&panel);
    assert(panel.snapshot.frame_id == 30 && panel.snapshot.cpu.len == 1);
    assert(!panel.has_selected_scope);
    assert(panel.snapshot.cpu[0].label == "replacement" && panel.snapshot.cpu[0].duration_ns == 200);
    assert(recorder.enabled);
}

fn void test_cpu_follow_skips_active_capture() @test @feat(C3D_PROFILE_CPU) {
    RecorderDesc desc = capture_desc(3);
    $if $feat(C3D_PROFILE_GPU):
        desc.gpu_scopes_per_frame = 0;
    $endif
    Recorder recorder = profile::create_recorder(mem, desc)!!;
    defer profile::destroy_recorder(&recorder);
    ProfilerPanel panel = gui::create_profiler_panel(mem, &recorder)!!;
    defer gui::destroy_profiler_panel(&panel);
    close_replacement_capture(&recorder, LARGE_FRAME_ID);
    close_replacement_capture(&recorder, LARGE_FRAME_ID + 7);
    CaptureBinding binding = open_capture(&recorder, LARGE_FRAME_ID + 12);
    gui::refresh_panel(&panel);
    assert(panel.frame_count == 2 && panel.snapshot.frame_id == LARGE_FRAME_ID + 7);
    gui::pause_panel(&panel);
    assert(!panel.following && panel.snapshot.cpu[0].duration_ns == 200);
    profile::end_capture(&recorder, binding, false);
    recorder.set_enabled(false);
    gui::refresh_panel(&panel);
    assert(panel.frame_count == 3 && panel.snapshot.frame_id == LARGE_FRAME_ID + 7);
    gui::resume_panel(&panel);
    assert(panel.following && panel.snapshot.frame_id == LARGE_FRAME_ID + 12 && !recorder.enabled);
}

fn void test_snapshot_preserves_domain_outcomes() @test @feat(C3D_PROFILE_CPU & C3D_PROFILE_GPU) {
    RecorderDesc desc = capture_desc(1);
    desc.max_depth = 1;
    Recorder recorder = profile::create_recorder(mem, desc)!!;
    defer profile::destroy_recorder(&recorder);
    ProfilerPanel panel = gui::create_profiler_panel(mem, &recorder)!!;
    defer gui::destroy_profiler_panel(&panel);
    uint previous_source = profile::attach_gpu_source(&recorder)!!;
    profile::detach_gpu_source(&recorder, previous_source);
    uint source = profile::attach_gpu_source(&recorder)!!;
    CaptureBinding binding = open_capture(&recorder, LARGE_FRAME_ID);
    ScopeToken parent = profile::begin_cpu_scope_at(
        recorder: &recorder,
        label: "cpu",
        origin: ScopeOrigin.LIBRARY,
        start_ns: 1_010,
    );
    for (uint i = 0; i < 3; i++) assert(!profile::admit_cpu_scope(&recorder));
    profile::end_cpu_scope_at(&recorder, parent, 1_110);
    GpuCaptureToken completed = profile::borrow_gpu_frame(&recorder, source, LARGE_FRAME_ID + 1);
    GpuCaptureToken canceled = profile::borrow_gpu_frame(&recorder, source, 2);
    GpuCaptureToken pending_first = profile::borrow_gpu_frame(&recorder, source, 3);
    GpuCaptureToken pending_second = profile::borrow_gpu_frame(&recorder, source, 4);
    profile::unavailable_gpu_frame(&recorder, source, 5);
    profile::end_capture(&recorder, binding, true);
    GpuSample[3] samples = {
        {
            .label = "gpu",
            .info = {
                .origin = ScopeOrigin.LIBRARY,
                .kind = GpuScopeKind.SHADOW_LAYER,
                .has_view = true,
                .view_index = 11,
                .view_generation = 12,
                .pass_ordinal = 13,
                .light_index = 14,
                .light_generation = 15,
                .light_kind = 16,
                .layer_index = 17,
                .shader_index = 18,
                .shader_generation = 19,
                .shader_revision = 20,
            },
            .start_ns = 23.5,
            .duration_ns = 29.5,
        },
        {
            .label = "child",
            .info = { .origin = ScopeOrigin.APPLICATION, .kind = GpuScopeKind.APPLICATION },
            .parent_index = 0,
            .has_parent = true,
            .start_ns = 25.5,
            .duration_ns = 5.5,
        },
        {
            .label = "nested",
            .info = { .origin = ScopeOrigin.APPLICATION, .kind = GpuScopeKind.APPLICATION },
            .parent_index = 1,
            .has_parent = true,
            .start_ns = 26.0,
            .duration_ns = 1.0,
        },
    };
    profile::publish_gpu_frame(
        recorder: &recorder,
        token: completed,
        samples: samples[..],
        truncated: true,
        dropped_scopes: 4,
    );
    profile::cancel_gpu_frame(&recorder, canceled);
    gui::copy_snapshot(&panel, recorder.frame(LARGE_FRAME_ID)!!);
    gui::pause_panel(&panel);
    profile::cancel_gpu_frame(&recorder, pending_first);
    profile::cancel_gpu_frame(&recorder, pending_second);
    profile::detach_gpu_source(&recorder, source);
    close_replacement_capture(&recorder, LARGE_FRAME_ID + 10);
    gui::refresh_panel(&panel);

    FrameCaptureView snapshot = panel.snapshot;
    assert(snapshot.frame_id == LARGE_FRAME_ID && snapshot.cpu_state == CaptureState.ABORTED);
    assert(snapshot.truncated && snapshot.dropped_cpu_scopes == 3 && snapshot.cpu.len == 1);
    CpuSample cpu = snapshot.cpu[0];
    assert(cpu.label == "cpu" && cpu.origin == ScopeOrigin.LIBRARY);
    assert(cpu.start_ns == 10 && cpu.duration_ns == 100 && cpu.self_ns == 100 && !cpu.self_complete);
    assert(!cpu.has_parent && cpu.parent_index == 0);
    assert(snapshot.gpu_state == CaptureState.PENDING && snapshot.gpu_truncated);
    assert(snapshot.dropped_gpu_scopes == 4 && snapshot.pending_gpu_frames == 2);
    assert(snapshot.unavailable_gpu_frames == 1 && snapshot.aborted_gpu_frames == 1 && snapshot.gpu.len == 3);
    GpuSample gpu = snapshot.gpu[0];
    assert(gpu.label == "gpu" && gpu.source == source && gpu.renderer_frame == LARGE_FRAME_ID + 1);
    assert(!gpu.has_parent && gpu.parent_index == 0 && gpu.start_ns == 23.5 && gpu.duration_ns == 29.5);
    assert(gpu.info.origin == ScopeOrigin.LIBRARY && gpu.info.kind == GpuScopeKind.SHADOW_LAYER);
    assert(gpu.info.has_view && gpu.info.view_index == 11 && gpu.info.view_generation == 12);
    assert(gpu.info.pass_ordinal == 13 && gpu.info.light_index == 14 && gpu.info.light_generation == 15);
    assert(gpu.info.light_kind == 16 && gpu.info.layer_index == 17);
    assert(gpu.info.shader_index == 18 && gpu.info.shader_generation == 19 && gpu.info.shader_revision == 20);
    assert(snapshot.gpu[1].label == "child" && snapshot.gpu[1].has_parent && snapshot.gpu[1].parent_index == 0);
    assert(snapshot.gpu[1].start_ns == 25.5 && snapshot.gpu[1].duration_ns == 5.5);
    assert(snapshot.gpu[2].label == "nested" && snapshot.gpu[2].has_parent && snapshot.gpu[2].parent_index == 1);
    assert(recorder.pending_gpu_pins == 0 && recorder.enabled);

    close_empty_capture(&recorder, LARGE_FRAME_ID + 20);
    gui::select_frame(&panel, LARGE_FRAME_ID + 20)!!;
    assert(panel.snapshot.cpu.len == 0 && panel.snapshot.gpu.len == 0);
    assert(panel.snapshot.cpu_state == CaptureState.READY && panel.snapshot.gpu_state == CaptureState.UNAVAILABLE);
    assert(!panel.snapshot.truncated && !panel.snapshot.gpu_truncated);
    assert(panel.snapshot.dropped_cpu_scopes == 0 && panel.snapshot.dropped_gpu_scopes == 0);
    assert(panel.snapshot.pending_gpu_frames == 0 && panel.snapshot.unavailable_gpu_frames == 0);
    assert(panel.snapshot.aborted_gpu_frames == 0);
}

fn void test_snapshot_fits_full_recorder_budgets() @test {
    RecorderDesc desc = capture_desc(2);
    desc.label_bytes_per_frame = 0;
    $if $feat(C3D_PROFILE_CPU):
        desc.cpu_scopes_per_frame = 2;
        desc.max_depth = 2;
        desc.label_bytes_per_frame += 8;
    $endif
    $if $feat(C3D_PROFILE_GPU):
        desc.gpu_scopes_per_frame = 3;
        desc.label_bytes_per_frame += 6;
    $endif
    Recorder recorder = profile::create_recorder(mem, desc)!!;
    defer profile::destroy_recorder(&recorder);
    CountingAllocator counter;
    {
        ProfilerPanel panel = gui::create_profiler_panel(&counter, &recorder)!!;
        defer gui::destroy_profiler_panel(&panel);
        assert(counter.allocations == 1 && counter.releases == 0);
        assert(panel.following && !panel.has_snapshot && panel.frame_count == 0);
        assert(panel.storage.len == gui::panel_storage_size(desc)!!);
        assert((uptr)panel.frame_ids.ptr % ulong::alignment == 0);
        assert((uptr)panel.cpu.ptr % CpuSample::alignment == 0);
        assert((uptr)panel.depths.ptr % uint::alignment == 0);
        assert((uptr)panel.aggregates.ptr % ScopeAggregate::alignment == 0);
        CaptureBinding binding = open_capture(&recorder, LARGE_FRAME_ID);
        $if $feat(C3D_PROFILE_CPU):
            for (uint i = 0; i < desc.cpu_scopes_per_frame; i++) {
                ScopeToken scope = profile::begin_cpu_scope_at(
                    recorder: &recorder,
                    label: "same",
                    origin: ScopeOrigin.APPLICATION,
                    start_ns: 1_000,
                );
                profile::end_cpu_scope_at(&recorder, scope, 1_010);
            }
        $endif
        $if $feat(C3D_PROFILE_GPU):
            assert((uptr)panel.gpu.ptr % GpuSample::alignment == 0);
            uint source = profile::attach_gpu_source(&recorder)!!;
            defer profile::detach_gpu_source(&recorder, source);
            GpuCaptureToken token = profile::borrow_gpu_frame(&recorder, source, 7);
            GpuSample[3] samples = { event("x\0y", 1, 2.0), event("x\0y", 2, 3.0), event("", 3, 4.0) };
            profile::publish_gpu_frame(
                recorder: &recorder,
                token: token,
                samples: samples[..],
                truncated: false,
                dropped_scopes: 0,
            );
        $endif
        profile::end_capture(&recorder, binding, false);
        for (uint i = 0; i < 5; i++) {
            gui::resume_panel(&panel);
            gui::select_frame(&panel, LARGE_FRAME_ID)!!;
            gui::refresh_panel(&panel);
        }
        assert(!panel.snapshot.truncated && counter.allocations == 1 && counter.releases == 0);
        $if $feat(C3D_PROFILE_CPU):
            assert(panel.snapshot.cpu.len == desc.cpu_scopes_per_frame);
            foreach (sample : panel.snapshot.cpu) {
                assert(sample.label == "same" && sample.duration_ns == 10);
                assert((uptr)sample.label.ptr >= (uptr)panel.labels.ptr);
                assert((uptr)sample.label.ptr + sample.label.len <= (uptr)panel.labels.ptr + panel.labels.len);
            }
        $else
            assert(panel.cpu.len == 0 && panel.snapshot.cpu.len == 0);
        $endif
        $if $feat(C3D_PROFILE_GPU):
            assert(panel.snapshot.gpu.len == desc.gpu_scopes_per_frame && !panel.snapshot.gpu_truncated);
            assert(panel.snapshot.gpu[0].label == "x\0y" && panel.snapshot.gpu[1].label == "x\0y");
            assert(panel.snapshot.gpu[2].label.len == 0);
            foreach (sample : panel.snapshot.gpu) {
                assert((uptr)sample.label.ptr >= (uptr)panel.labels.ptr);
                assert((uptr)sample.label.ptr + sample.label.len <= (uptr)panel.labels.ptr + panel.labels.len);
            }
        $endif
    }
    assert(counter.allocations == 1 && counter.releases == 1);
}

fn void test_storage_arithmetic_rejects_unaddressable_spans() @test {
    assert(gui::panel_multiply_size(0, usz::max)!! == 0);
    assert(gui::panel_add_size((usz)sz::max, 0)!! == (usz)sz::max);
    assert(gui::panel_align_size(16, 8)!! == 16);
    assert(gui::panel_align_size(17, 8)!! == 24);
    if (catch excuse = gui::panel_multiply_size(usz::max, 2)) {
        assert(excuse == gui::PROFILE_STORAGE_OVERFLOW);
    } else {
        unreachable("expected storage overflow");
    }
    if (catch excuse = gui::panel_multiply_size((usz)sz::max, 2)) {
        assert(excuse == gui::PROFILE_STORAGE_OVERFLOW);
    } else {
        unreachable("expected storage overflow");
    }
    if (catch excuse = gui::panel_add_size(usz::max, 1)) {
        assert(excuse == gui::PROFILE_STORAGE_OVERFLOW);
    } else {
        unreachable("expected storage overflow");
    }
    if (catch excuse = gui::panel_add_size((usz)sz::max, 1)) {
        assert(excuse == gui::PROFILE_STORAGE_OVERFLOW);
    } else {
        unreachable("expected storage overflow");
    }
    if (catch excuse = gui::panel_align_size(usz::max, 8)) {
        assert(excuse == gui::PROFILE_STORAGE_OVERFLOW);
    } else {
        unreachable("expected storage overflow");
    }
    if (catch excuse = gui::panel_align_size((usz)sz::max, 8)) {
        assert(excuse == gui::PROFILE_STORAGE_OVERFLOW);
    } else {
        unreachable("expected storage overflow");
    }
}
