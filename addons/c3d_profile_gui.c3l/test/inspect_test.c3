module c3d_profile_gui_inspect_test @feat(C3D_PROFILE_GUI & (C3D_PROFILE_CPU | C3D_PROFILE_GPU));

import c3d::profile @public;
import c3d::gui @public;

const ulong LARGE_RENDERER_FRAME @private = 9_007_199_254_740_993;

fn GpuSample inspection_gpu_sample(String label) @private @feat(C3D_PROFILE_GPU) {
    return {
        .label = label,
        .source = 7,
        .renderer_frame = LARGE_RENDERER_FRAME,
        .info = {
            .origin = ScopeOrigin.LIBRARY,
            .kind = GpuScopeKind.PASS,
            .has_view = true,
            .view_index = 11,
            .view_generation = 13,
            .pass_ordinal = 17,
            .light_index = 19,
            .light_generation = 23,
            .light_kind = 29,
            .layer_index = 31,
            .shader_index = 37,
            .shader_generation = 41,
            .shader_revision = 43,
        },
        .start_ns = 100.0,
        .duration_ns = 20.0,
    };
}

fn void test_cpu_aggregation_preserves_origin_and_incomplete_self() @test @feat(C3D_PROFILE_CPU) {
    char[4] copied_work = { 'w', 'o', 'r', 'k' };
    char[4] original_copied_work = copied_work;
    CpuSample[6] samples = {
        {
            .label = "work",
            .origin = ScopeOrigin.APPLICATION,
            .duration_ns = 100,
            .self_ns = 70,
            .self_complete = true,
        },
        {
            .label = "child",
            .origin = ScopeOrigin.APPLICATION,
            .duration_ns = 30,
            .self_ns = 30,
            .self_complete = true,
        },
        {
            .label = "work",
            .origin = ScopeOrigin.APPLICATION,
            .duration_ns = 50,
            .self_ns = 40,
        },
        {
            .label = "work",
            .origin = ScopeOrigin.LIBRARY,
            .duration_ns = 25,
            .self_ns = 25,
            .self_complete = true,
        },
        {
            .label = (String)copied_work[..],
            .origin = ScopeOrigin.APPLICATION,
            .duration_ns = 10,
            .self_ns = 10,
            .self_complete = true,
        },
        {
            .label = "work##x",
            .origin = ScopeOrigin.APPLICATION,
            .duration_ns = 5,
            .self_ns = 5,
            .self_complete = true,
        },
    };
    CpuSample[6] original_samples = samples;
    ScopeAggregate[6] rows;

    usz row_count = gui::aggregate_cpu(samples[..], rows[..]);

    assert(row_count == 4);
    assert(rows[0].sample_index == 0 && rows[0].call_count == 3);
    assert(rows[0].inclusive_ns == 160.0 && rows[0].self_ns == 120.0);
    assert(!rows[0].self_complete);
    assert(rows[1].sample_index == 1 && rows[1].call_count == 1);
    assert(rows[1].inclusive_ns == 30.0 && rows[1].self_ns == 30.0);
    assert(rows[1].self_complete);
    assert(rows[2].sample_index == 3 && rows[2].call_count == 1);
    assert(rows[2].inclusive_ns == 25.0 && rows[2].self_ns == 25.0);
    assert(rows[2].self_complete);
    assert(rows[3].sample_index == 5 && rows[3].call_count == 1);
    assert(rows[3].inclusive_ns == 5.0 && rows[3].self_ns == 5.0);
    assert(rows[3].self_complete);
    assert(mem::equals((char*)&original_samples, (char*)&samples, CpuSample[6]::size));
    assert(original_copied_work == copied_work);
}

fn void test_gpu_aggregation_preserves_context() @test @feat(C3D_PROFILE_GPU) {
    GpuSample base = inspection_gpu_sample("dispatch");
    GpuSample[18] samples;
    samples[0] = base;
    samples[1] = base;
    samples[1].parent_index = 999;
    samples[1].has_parent = true;
    samples[1].start_ns = 900.0;
    samples[1].duration_ns = 30.0;
    for (usz i = 2; i < samples.len; i++) samples[i] = base;
    samples[2].source++;
    samples[3].renderer_frame++;
    samples[4].info.origin = ScopeOrigin.APPLICATION;
    samples[5].info.kind = GpuScopeKind.COMPUTE_DISPATCH;
    samples[6].info.has_view = false;
    samples[7].info.view_index++;
    samples[8].info.view_generation++;
    samples[9].info.pass_ordinal++;
    samples[10].info.light_index++;
    samples[11].info.light_generation++;
    samples[12].info.light_kind++;
    samples[13].info.layer_index++;
    samples[14].info.shader_index++;
    samples[15].info.shader_generation++;
    samples[16].info.shader_revision++;
    samples[17].label = "dispatch##detail";
    GpuSample[18] original_samples = samples;
    ScopeAggregate[18] rows;

    usz row_count = gui::aggregate_gpu(samples[..], rows[..]);

    assert(row_count == 17);
    assert(rows[0].sample_index == 0 && rows[0].call_count == 2);
    assert(rows[0].inclusive_ns == 50.0);
    assert(rows[0].self_ns == 0.0 && !rows[0].self_complete);
    for (usz i = 1; i < row_count; i++) {
        assert(rows[i].sample_index == i + 1);
        assert(rows[i].call_count == 1 && rows[i].inclusive_ns == 20.0);
        assert(rows[i].self_ns == 0.0 && !rows[i].self_complete);
    }
    assert(samples[0].renderer_frame == LARGE_RENDERER_FRAME);
    assert(samples[3].renderer_frame == LARGE_RENDERER_FRAME + 1);
    assert(mem::equals((char*)&original_samples, (char*)&samples, GpuSample[18]::size));
}

fn void test_interval_span_preserves_clock_groups() @test {
    $if $feat(C3D_PROFILE_CPU):
        CpuSample[3] samples = {
            { .start_ns = 10, .duration_ns = 100 },
            { .parent_index = 0, .has_parent = true, .start_ns = 20, .duration_ns = 30 },
            { .start_ns = 151, .duration_ns = 20 },
        };
        uint[3] depths;
        gui::cpu_scope_depths(samples[..], depths[..]);
        assert(depths[0] == 0 && depths[1] == 1 && depths[2] == 0);
        CpuIntervalSpan span = gui::cpu_interval_span(samples[..]);
        assert(span.available && span.origin_ns == 10 && span.duration_ns == 161.0);

        CpuSample[3] large_samples = samples;
        foreach (&sample : large_samples) sample.start_ns += LARGE_RENDERER_FRAME;
        span = gui::cpu_interval_span(large_samples[..]);
        assert(span.available && span.origin_ns == LARGE_RENDERER_FRAME + 10);
        assert(span.duration_ns == 161.0);
        span = gui::cpu_interval_span({});
        assert(!span.available);
        CpuSample[1] zero = {{ .start_ns = LARGE_RENDERER_FRAME, .duration_ns = 0 }};
        span = gui::cpu_interval_span(zero[..]);
        assert(span.available && span.duration_ns == 0.0);
    $endif
    $if $feat(C3D_PROFILE_GPU):
        GpuSample[5] gpu_samples = {
            { .source = 3, .renderer_frame = LARGE_RENDERER_FRAME, .start_ns = 100.0, .duration_ns = 20.0 },
            {
                .source = 3,
                .renderer_frame = LARGE_RENDERER_FRAME,
                .parent_index = 0,
                .has_parent = true,
                .start_ns = 101.0,
                .duration_ns = 10.0,
            },
            {
                .source = 3,
                .renderer_frame = LARGE_RENDERER_FRAME,
                .parent_index = 0,
                .has_parent = true,
                .start_ns = 102.0,
                .duration_ns = 10.0,
            },
            { .source = 3, .renderer_frame = LARGE_RENDERER_FRAME + 1, .start_ns = 9_000.0, .duration_ns = 30.0 },
            { .source = 4, .renderer_frame = LARGE_RENDERER_FRAME, .start_ns = 20_000.0, .duration_ns = 40.0 },
        };
        uint[5] gpu_depths;
        gui::gpu_scope_depths(gpu_samples[..], gpu_depths[..]);
        assert(gpu_depths[0] == 0 && gpu_depths[1] == 1 && gpu_depths[2] == 1);
        assert(gpu_depths[3] == 0 && gpu_depths[4] == 0);
        GpuIntervalSpan first = gui::gpu_interval_span(gpu_samples[..], 3, LARGE_RENDERER_FRAME);
        GpuIntervalSpan second = gui::gpu_interval_span(gpu_samples[..], 3, LARGE_RENDERER_FRAME + 1);
        GpuIntervalSpan third = gui::gpu_interval_span(gpu_samples[..], 4, LARGE_RENDERER_FRAME);
        assert(first.available && first.origin_ns == 100.0 && first.duration_ns == 20.0);
        assert(second.available && second.origin_ns == 9_000.0 && second.duration_ns == 30.0);
        assert(third.available && third.origin_ns == 20_000.0 && third.duration_ns == 40.0);
        GpuIntervalSpan absent = gui::gpu_interval_span(gpu_samples[..], 5, LARGE_RENDERER_FRAME);
        assert(!absent.available);
        GpuSample[1] gpu_zero = {{ .source = 6, .renderer_frame = 2, .start_ns = 500.0 }};
        GpuIntervalSpan measured_zero = gui::gpu_interval_span(gpu_zero[..], 6, 2);
        assert(measured_zero.available && measured_zero.duration_ns == 0.0);
    $endif
}
