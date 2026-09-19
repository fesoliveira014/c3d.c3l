module c3d::test::gpu_summary @feat(C3D_PROFILE_GPU);

import c3d;
import c3d::profile;
import c3d::render @public;
import c3d::render::profile_gpu @public;

fn void test_gpu_summary_sums_pass_instances_without_nested_scopes() @test {
    Renderer renderer;
    profile::GpuSample[8] samples = {
        {
            .info = {
                .kind = PASS,
                .has_view = true,
                .view_index = 1,
                .pass_ordinal = (uint)Pass.FORWARD_OPAQUE.ordinal,
            },
            .duration_ns = 2_000_000,
        },
        {
            .info = {
                .kind = PASS,
                .has_view = true,
                .view_index = 2,
                .pass_ordinal = (uint)Pass.FORWARD_OPAQUE.ordinal,
            },
            .duration_ns = 3_000_000,
        },
        { .info = { .kind = FRAME }, .duration_ns = 20_000_000 },
        { .info = { .kind = VIEW }, .duration_ns = 10_000_000 },
        { .info = { .kind = SHADOW_LAYER }, .duration_ns = 1_000_000 },
        { .info = { .kind = APPLICATION }, .duration_ns = 4_000_000 },
        {
            .info = { .kind = COMPUTE_DISPATCH, .pass_ordinal = (uint)Pass.CUSTOM_COMPUTE.ordinal },
            .duration_ns = 500_000,
        },
        {
            .info = { .kind = COMPUTE_DISPATCH, .pass_ordinal = (uint)Pass.CUSTOM_COMPUTE.ordinal },
            .duration_ns = 750_000,
        },
    };
    ShadowTiming[1] shadows;
    renderer.shadow_timing_results = shadows[..];
    render::publish_gpu_summary(&renderer, { .samples = samples[..], .renderer_frame = 12, .available = true });
    assert(renderer.stats.gpu_frame_index == 12);
    assert(renderer.stats.gpu_timing_state == GpuTimingState.READY);
    assert(renderer.stats.gpu_pass_ms[Pass.FORWARD_OPAQUE.ordinal] == 5);
    assert(renderer.stats.gpu_pass_ms[Pass.CUSTOM_COMPUTE.ordinal] == 1.25f);
    assert(renderer.stats.gpu_pass_valid[Pass.FORWARD_OPAQUE.ordinal]);
    assert(!renderer.stats.gpu_pass_valid[Pass.SHADOW_ATLAS.ordinal]);
    assert(renderer.stats.gpu_pass_ms[Pass.SHADOW_ATLAS.ordinal] == 0);
}

fn void test_gpu_summary_retains_newest_completion_and_partial_state() @test {
    Renderer renderer;
    assert(renderer.stats.gpu_timing_state == GpuTimingState.UNAVAILABLE);
    renderer.stats.gpu_timing_state = GpuTimingState.PENDING;
    render::reset_frame_stats(&renderer.stats);
    assert(renderer.stats.gpu_timing_state == GpuTimingState.PENDING);
    profile::GpuSample[1] samples = {{
        .info = { .kind = PASS, .pass_ordinal = (uint)Pass.FORWARD_OPAQUE.ordinal },
        .duration_ns = 2_000_000,
    }};
    render::publish_gpu_summary(&renderer, {
        .samples = samples[..],
        .renderer_frame = 12,
        .dropped_scopes = 3,
        .truncated = true,
        .available = true,
    });
    samples[0].duration_ns = 9_000_000;
    render::publish_gpu_summary(&renderer, { .samples = samples[..], .renderer_frame = 11, .available = true });
    renderer.stats.draws = 27;
    renderer.stats.dispatches = 8;
    render::reset_frame_stats(&renderer.stats);
    assert(renderer.stats.draws == 0 && renderer.stats.dispatches == 0);
    assert(renderer.stats.gpu_frame_index == 12);
    assert(renderer.stats.gpu_timing_state == GpuTimingState.TRUNCATED);
    assert(renderer.stats.gpu_scopes_dropped == 3);
    assert(renderer.stats.gpu_pass_ms[Pass.FORWARD_OPAQUE.ordinal] == 2);
    assert(renderer.stats.gpu_pass_valid[Pass.FORWARD_OPAQUE.ordinal]);
}

fn void test_shadow_summary_copies_repeated_layers_with_original_views() @test {
    Renderer renderer;
    renderer.gpu_profile.has_view = true;
    renderer.gpu_profile.current_view = { .index = 4, .generation = 8 };
    profile::GpuScopeInfo first = render::profile_view_info(&renderer, profile::GpuScopeKind.SHADOW_LAYER);
    first.light_index = 2;
    first.light_generation = 3;
    first.light_kind = (uint)LightKind.POINT.ordinal;
    first.layer_index = 1;
    renderer.gpu_profile.current_view.generation = 9;
    profile::GpuScopeInfo second = first;
    second.view_generation = renderer.gpu_profile.current_view.generation;
    profile::GpuSample[2] samples = {
        { .info = first, .duration_ns = 1_000_000 },
        { .info = second, .duration_ns = 2_000_000 },
    };
    ShadowTiming[2] shadows;
    renderer.shadow_timing_results = shadows[..];
    render::publish_gpu_summary(&renderer, { .samples = samples[..], .renderer_frame = 12, .available = true });
    samples = {};
    renderer.gpu_profile.current_view = {};
    assert(renderer.stats.shadow_timings.len == 2);
    assert(shadows[0].view.index == 4 && shadows[0].view.generation == 8);
    assert(shadows[1].view.index == 4 && shadows[1].view.generation == 9);
    foreach (shadow : shadows) {
        assert(shadow.light.index == 2 && shadow.light.generation == 3);
        assert(shadow.kind == LightKind.POINT && shadow.layer_index == 1);
    }
    assert(shadows[0].gpu_ms == 1 && shadows[1].gpu_ms == 2);
}

fn void test_gpu_wrappers_skip_unavailable_labels() @test {
    Renderer renderer;
    renderer.frame_open = true;
    uint evaluations;
    profile::GpuScopeToken disabled = render::@gpu_begin(&renderer, evaluated_label(&evaluations))!!;
    render::@gpu_end(&renderer, disabled)!!;
    renderer.gpu_profile.adapter.enabled = true;
    profile::GpuScopeToken unsupported = render::@gpu_begin(&renderer, evaluated_label(&evaluations))!!;
    render::@gpu_end(&renderer, unsupported)!!;
    assert(!disabled.recorded && !unsupported.recorded && evaluations == 0);
    $if !$feat(C3D_PROFILE_CPU):
        profile::@scope(missing_cpu_label()) { evaluations++; };
        assert(evaluations == 1);
    $endif
}

fn String evaluated_label(uint* evaluations) @private {
    (*evaluations)++;
    return "application";
}

fn void test_gpu_labels_recheck_recording_and_capacity_after_evaluation() @test {
    profile_gpu::ScopeRecord[1] records;
    profile_gpu::QuerySlot[1] slots = {{
        .records = records[..],
        .capture = { .borrowed = true },
    }};
    Renderer renderer;
    renderer.frame_open = true;
    renderer.gpu_profile.adapter.enabled = true;
    renderer.gpu_profile.adapter.supported = true;
    renderer.gpu_profile.adapter.recording = true;
    renderer.gpu_profile.adapter.recording_serial = 7;
    renderer.gpu_profile.adapter.slots = slots[..];
    uint evaluations;
    profile::GpuScopeToken changed = render::@gpu_begin(&renderer, invalidate_recording(&renderer, &evaluations))!!;
    assert(!changed.recorded && evaluations == 1 && slots[0].sample_count == 0);
    renderer.gpu_profile.adapter.recording = true;
    slots[0].sample_count = 1;
    profile::GpuScopeToken full = render::@gpu_begin(&renderer, evaluated_label(&evaluations))!!;
    assert(!full.recorded && evaluations == 1);
    assert(slots[0].truncated && slots[0].dropped_scopes == 1);
}

fn String invalidate_recording(Renderer* renderer, uint* evaluations) @private {
    (*evaluations)++;
    renderer.gpu_profile.adapter.recording_serial++;
    return "expired";
}
