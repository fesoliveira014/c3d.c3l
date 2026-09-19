module c3d_profile_gpu_adapter_test @feat(C3D_PROFILE_GPU);

import c3d::render::profile_gpu @public;
import c3d::profile @public;
import gpu;

fn void test_pairs_preserve_nesting_and_advance_recording_serial() @test {
    GpuProfiler profiler = profile_gpu::allocate_storage(mem, {
        .frame_slots = 1,
        .scopes_per_slot = 2,
        .label_bytes_per_slot = 32,
        .enabled = true,
    })!!;
    defer profile_gpu::release_storage(&profiler);
    profiler.supported = true;
    profile_gpu::start_slot(&profiler, 0, 10);
    ulong serial = profiler.recording_serial;
    GpuScopeInfo info = { .origin = LIBRARY, .kind = PASS, .pass_ordinal = 3 };
    GpuScopeToken parent = profile_gpu::reserve_scope(&profiler, "same", info);
    GpuScopeToken child = profile_gpu::reserve_scope(&profiler, "same", info);
    GpuScopeToken omitted = profile_gpu::reserve_scope(&profiler, "third", info);
    assert(parent.recorded && child.recorded && !omitted.recorded);
    assert(profile_gpu::begin_query(&profiler, parent) == 0 && profile_gpu::end_query(&profiler, parent) == 1);
    assert(profile_gpu::begin_query(&profiler, child) == 2 && profile_gpu::end_query(&profiler, child) == 3);
    assert(profiler.slots[0].depth == 2 && profiler.slots[0].dropped_scopes == 1);
    profile_gpu::close_scope(&profiler, child);
    profile_gpu::close_scope(&profiler, parent);
    profile_gpu::mark_submitted(&profiler);
    profiler.caps = { .queues = { .graphics = true }, .graphics_valid_bits = 8, .period_ns = 2.0f };
    ulong[4] raw = { 250, 10, 252, 5 };
    profiler.slots[0].raw[..] = raw[..];
    CompletedFrame completed = profile_gpu::publish_completed(&profiler, 0)!!;
    assert(completed.available && completed.truncated && completed.renderer_frame == 10);
    assert(completed.samples[0].start_ns == 0.0 && completed.samples[0].duration_ns == 32.0);
    assert(completed.samples[1].start_ns == 4.0 && completed.samples[1].duration_ns == 18.0);
    assert(completed.samples[1].has_parent && completed.samples[1].parent_index == 0);
    assert(completed.samples[1].info.pass_ordinal == 3);
    profile_gpu::start_slot(&profiler, 0, 11);
    assert(profiler.recording_serial != serial && profiler.slots[0].sample_count == 0);
    profile_gpu::cancel_recording(&profiler);
}

fn void test_admission_rechecks_capacity_and_original_recording() @test {
    GpuProfiler profiler = profile_gpu::allocate_storage(mem, {
        .frame_slots = 1,
        .scopes_per_slot = 1,
        .label_bytes_per_slot = 16,
        .enabled = true,
    })!!;
    defer profile_gpu::release_storage(&profiler);
    profiler.supported = true;
    profile_gpu::start_slot(&profiler, 0, 1);
    ulong serial = profiler.recording_serial;
    assert(!profile_gpu::admit_scope(&profiler, APPLICATION, serial));
    assert(profile_gpu::admit_scope(&profiler, LIBRARY, serial));
    GpuScopeToken inner = profile_gpu::reserve_scope(&profiler, "inner", { .origin = LIBRARY });
    profile_gpu::close_scope(&profiler, inner);
    assert(!profile_gpu::admit_scope(&profiler, LIBRARY, serial));
    assert(profiler.slots[0].truncated && profiler.slots[0].dropped_scopes == 1);
    profile_gpu::cancel_recording(&profiler);
    profile_gpu::start_slot(&profiler, 0, 2);
    assert(!profile_gpu::admit_scope(&profiler, LIBRARY, serial));
    profiler.enabled = false;
    assert(!profile_gpu::admit_scope(&profiler, LIBRARY, profiler.recording_serial));
    profiler.enabled = true;
    profiler.supported = false;
    assert(!profile_gpu::admit_scope(&profiler, LIBRARY, profiler.recording_serial));
    profile_gpu::cancel_recording(&profiler);
}

fn Recorder create_adapter_recorder() @private {
    RecorderDesc desc = {
        .frame_capacity = 2,
        .gpu_scopes_per_frame = 4,
        .label_bytes_per_frame = 32,
    };
    $if $feat(C3D_PROFILE_CPU):
        desc.cpu_scopes_per_frame = 4;
        desc.max_depth = 2;
    $endif
    return profile::create_recorder(mem, desc)!!;
}

fn void test_copied_metadata_and_failed_decode_keep_original_capture_pending() @test {
    Recorder recorder = create_adapter_recorder();
    defer profile::destroy_recorder(&recorder);
    GpuProfiler profiler = profile_gpu::allocate_storage(mem, {
        .frame_slots = 1,
        .scopes_per_slot = 2,
        .label_bytes_per_slot = 16,
        .enabled = true,
    })!!;
    defer profile_gpu::release_storage(&profiler);
    profiler.supported = true;
    profiler.recorder = &recorder;
    profiler.source = profile::attach_gpu_source(&recorder)!!;
    defer profile::detach_gpu_source(&recorder, profiler.source);
    CaptureBinding binding = profile::begin_capture_at(&recorder, 1, 0);
    profile_gpu::start_slot(&profiler, 0, 42);
    char[5] label = { 'p', 'a', 's', 's', 'A' };
    GpuScopeInfo info = { .origin = APPLICATION, .kind = APPLICATION, .shader_revision = 7 };
    GpuScopeToken token = profile_gpu::reserve_scope(&profiler, (String)label[..], info);
    label[4] = 'B';
    info.shader_revision = 8;
    assert(profile_gpu::scope_is_current(&profiler, token));
    GpuScopeToken wrong = token;
    wrong.owner = 0;
    assert(!profile_gpu::scope_is_current(&profiler, wrong));
    wrong = token;
    wrong.recording_serial++;
    assert(!profile_gpu::scope_is_current(&profiler, wrong));
    profile_gpu::close_scope(&profiler, token);
    assert(!profile_gpu::scope_is_current(&profiler, token));
    profile_gpu::mark_submitted(&profiler);
    profile::end_capture(&recorder, binding, false);
    profile_gpu::cancel_recording(&profiler);
    assert(profiler.slots[0].pending && recorder.pending_gpu_pins == 1);
    profiler.slots[0].raw[0] = 10;
    profiler.slots[0].raw[1] = 20;
    assert(@catch(profile_gpu::publish_completed(&profiler, 0)) == gpu::UNSUPPORTED_FEATURE);
    assert(profiler.slots[0].pending && recorder.pending_gpu_pins == 1);
    assert(recorder.frame(1)!!.gpu.len == 0);
    profiler.caps = { .queues = { .graphics = true }, .graphics_valid_bits = 8, .period_ns = 2.0f };
    CompletedFrame completed = profile_gpu::publish_completed(&profiler, 0)!!;
    assert(completed.samples[0].label == "passA" && completed.samples[0].info.shader_revision == 7);
    assert(recorder.pending_gpu_pins == 0 && recorder.frame(1)!!.gpu_state == READY);
    profile_gpu::abandon_pending(&profiler);
    profile_gpu::abandon_pending(&profiler);
    assert(recorder.pending_gpu_pins == 0);
}

fn void test_label_capacity_preserves_accepted_ends_and_abandon_releases_pins() @test {
    Recorder recorder = create_adapter_recorder();
    defer profile::destroy_recorder(&recorder);
    GpuProfiler profiler = profile_gpu::allocate_storage(mem, {
        .frame_slots = 1,
        .scopes_per_slot = 3,
        .label_bytes_per_slot = 4,
        .enabled = true,
    })!!;
    defer profile_gpu::release_storage(&profiler);
    profiler.supported = true;
    profiler.recorder = &recorder;
    profiler.source = profile::attach_gpu_source(&recorder)!!;
    defer profile::detach_gpu_source(&recorder, profiler.source);
    CaptureBinding binding = profile::begin_capture_at(&recorder, 1, 0);
    profile_gpu::start_slot(&profiler, 0, 1);
    GpuScopeInfo info = { .origin = APPLICATION };
    GpuScopeToken parent = profile_gpu::reserve_scope(&profiler, "root", info);
    GpuScopeToken skipped = profile_gpu::reserve_scope(&profiler, "full", info);
    assert(parent.recorded && !skipped.recorded);
    assert(!profile_gpu::admit_scope(&profiler, APPLICATION, profiler.recording_serial));
    assert(profiler.slots[0].depth == 1 && profiler.slots[0].dropped_scopes == 2);
    profile_gpu::close_scope(&profiler, skipped);
    profile_gpu::close_scope(&profiler, parent);
    profile_gpu::mark_submitted(&profiler);
    profile::end_capture(&recorder, binding, false);
    profile_gpu::abandon_pending(&profiler);
    profile_gpu::abandon_pending(&profiler);
    assert(!profiler.slots[0].pending && recorder.pending_gpu_pins == 0);
    assert(recorder.frame(1)!!.gpu_state == ABORTED);
    binding = profile::begin_capture_at(&recorder, 2, 0);
    profile_gpu::start_slot(&profiler, 0, 2);
    profile_gpu::cancel_recording(&profiler);
    profile_gpu::cancel_recording(&profiler);
    profile::end_capture(&recorder, binding, false);
    assert(recorder.pending_gpu_pins == 0 && recorder.frame(2)!!.gpu_state == ABORTED);
}

fn void test_query_budget_validation_precedes_allocation() @test {
    assert(@catch(profile_gpu::resolve_desc({})) == profile::INVALID_ARGUMENT);
    assert(@catch(profile_gpu::resolve_desc({
        .frame_slots = uint::max,
        .scopes_per_slot = 2,
    })) == profile::INVALID_ARGUMENT);
    GpuProfilerDesc desc = profile_gpu::resolve_desc({ .frame_slots = 2 })!!;
    assert(desc.scopes_per_slot == 2048 && desc.label_bytes_per_slot == 65536);
}

fn String consume_last_scope(GpuProfiler* profiler, uint* labels) @private {
    (*labels)++;
    GpuScopeToken inner = profile_gpu::reserve_scope(profiler, "inner", { .origin = LIBRARY });
    profile_gpu::close_scope(profiler, inner);
    return "outer";
}

fn void test_reentrant_label_cannot_reserve_consumed_capacity() @test {
    GpuProfiler profiler = profile_gpu::allocate_storage(mem, {
        .frame_slots = 1,
        .scopes_per_slot = 1,
        .label_bytes_per_slot = 32,
        .enabled = true,
    })!!;
    defer profile_gpu::release_storage(&profiler);
    profiler.supported = true;
    profile_gpu::start_slot(&profiler, 0, 1);
    ulong serial = profiler.recording_serial;
    uint labels;
    GpuScopeToken outer;
    if (profile_gpu::admit_scope(&profiler, LIBRARY, serial)) {
        String label = consume_last_scope(&profiler, &labels);
        if (profile_gpu::admit_scope(&profiler, LIBRARY, serial)) {
            outer = profile_gpu::reserve_scope(&profiler, label, { .origin = LIBRARY });
        }
    }
    if (profile_gpu::admit_scope(&profiler, LIBRARY, serial)) labels++;
    assert(labels == 1 && !outer.recorded);
    assert(profiler.slots[0].sample_count == 1 && profiler.slots[0].depth == 0);
    assert(profiler.slots[0].records[0].label == "inner");
    assert(profiler.slots[0].dropped_scopes == 2);
    profile_gpu::cancel_recording(&profiler);
}
