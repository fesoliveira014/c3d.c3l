module c3d_profile_feature_test;

import c3d::profile @public;

fn String count_label(uint* count, String label) @private {
    (*count)++;
    return label;
}

fn profile::Recorder* count_recorder(uint* count, profile::Recorder* recorder) @private @feat(C3D_PROFILE_CPU) {
    (*count)++;
    return recorder;
}

fn ulong count_frame_id(uint* count, ulong frame_id) @private @feat(C3D_PROFILE_CPU) {
    (*count)++;
    return frame_id;
}

fn String label_with_recorded_scope(uint* bodies) @private @feat(C3D_PROFILE_CPU) {
    profile::@scope("inner") { (*bodies)++; };
    return "outer";
}

fn String label_latching_depth_overflow(uint* inner_bodies, uint* omitted_bodies) @private @feat(C3D_PROFILE_CPU) {
    profile::@scope("inner") {
        (*inner_bodies)++;
        profile::@scope("too-deep") { (*omitted_bodies)++; };
    };
    return "outer";
}

fn void test_scope_without_capture_skips_label_and_runs_body() @test {
    uint labels;
    uint bodies;
    profile::@scope(count_label(&labels, "outside")) { bodies++; };
    assert(labels == 0 && bodies == 1);
}

fn void test_profiling_arguments_are_discarded_when_all_features_are_off() @test @feat(!C3D_PROFILE_CPU) {
    uint bodies;
    profile::@capture(undefined_recorder, undefined_frame_id) {
        profile::@scope(undefined_label) { bodies++; };
        profile::@internal_scope(undefined_internal_label) { bodies++; };
    };
    assert(bodies == 2);
}

fn void test_cpu_feature_evaluates_application_arguments_once() @test @feat(C3D_PROFILE_CPU) {
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 1,
        .cpu_scopes_per_frame = 4,
        .max_depth = 2,
        .label_bytes_per_frame = 32,
    })!!;
    defer profile::destroy_recorder(&recorder);
    uint recorder_expressions;
    uint id_expressions;
    uint application_labels;
    uint internal_labels;
    uint bodies;

    profile::@capture(count_recorder(&recorder_expressions, &recorder), count_frame_id(&id_expressions, 0)) {
        profile::@scope(count_label(&application_labels, "application")) {
            bodies++;
            profile::@internal_scope(count_label(&internal_labels, "library")) { bodies++; };
        };
    };

    assert(recorder_expressions == 1 && id_expressions == 1);
    assert(application_labels == 1 && bodies == 2);
    profile::FrameCaptureView frame = recorder.frame(0)!!;
    $if $feat(C3D_PROFILE_INTERNAL):
        assert(internal_labels == 1 && frame.cpu.len == 2);
        assert(frame.cpu[0].origin == profile::ScopeOrigin.APPLICATION);
        assert(frame.cpu[1].origin == profile::ScopeOrigin.LIBRARY);
        assert(frame.cpu[1].has_parent && frame.cpu[1].parent_index == 0);
    $else
        assert(internal_labels == 0 && frame.cpu.len == 1);
        assert(frame.cpu[0].origin == profile::ScopeOrigin.APPLICATION);
    $endif
}

fn void test_disabled_capture_skips_labels_and_runs_body() @test @feat(C3D_PROFILE_CPU) {
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 1,
        .cpu_scopes_per_frame = 2,
        .max_depth = 1,
        .label_bytes_per_frame = 16,
    })!!;
    defer profile::destroy_recorder(&recorder);
    recorder.set_enabled(false);
    uint labels;
    uint bodies;
    profile::@capture(&recorder, 0) {
        profile::@scope(count_label(&labels, "disabled")) { bodies++; };
    };
    assert(labels == 0 && bodies == 1);
}

fn void test_truncation_skips_later_labels_but_runs_bodies() @test @feat(C3D_PROFILE_CPU) {
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 1,
        .cpu_scopes_per_frame = 3,
        .max_depth = 3,
        .label_bytes_per_frame = 4,
    })!!;
    defer profile::destroy_recorder(&recorder);
    uint overflow_labels;
    uint later_labels;
    uint bodies;
    profile::@capture(&recorder, 0) {
        profile::@scope("root") {
            profile::@scope(count_label(&overflow_labels, "overflow")) { bodies++; };
            profile::@scope(count_label(&later_labels, "x")) { bodies++; };
        };
    };
    assert(overflow_labels == 1 && later_labels == 0 && bodies == 2);
    profile::FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.dropped_cpu_scopes == 2 && frame.cpu.len == 1);
}

fn void test_label_scope_consuming_last_sample_rechecks_admission() @test @feat(C3D_PROFILE_CPU) {
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 1,
        .cpu_scopes_per_frame = 1,
        .max_depth = 1,
        .label_bytes_per_frame = 32,
    })!!;
    defer profile::destroy_recorder(&recorder);
    uint inner_bodies;
    uint outer_bodies;
    uint later_bodies;
    uint later_labels;

    profile::@capture(&recorder, 0) {
        profile::@scope(label_with_recorded_scope(&inner_bodies)) { outer_bodies++; };
        profile::@scope(count_label(&later_labels, "later")) { later_bodies++; };
    };

    profile::FrameCaptureView frame = recorder.frame(0)!!;
    assert(inner_bodies == 1 && outer_bodies == 1 && later_bodies == 1);
    assert(later_labels == 0);
    assert(frame.cpu.len == 1 && frame.cpu[0].label == "inner");
    assert(frame.truncated && frame.dropped_cpu_scopes == 2);
}

fn void test_label_scope_latching_truncation_keeps_outer_omitted() @test @feat(C3D_PROFILE_CPU) {
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 1,
        .cpu_scopes_per_frame = 2,
        .max_depth = 1,
        .label_bytes_per_frame = 32,
    })!!;
    defer profile::destroy_recorder(&recorder);
    uint inner_bodies;
    uint omitted_bodies;
    uint outer_bodies;
    uint later_bodies;
    uint later_labels;

    profile::@capture(&recorder, 0) {
        profile::@scope(label_latching_depth_overflow(&inner_bodies, &omitted_bodies)) { outer_bodies++; };
        profile::@scope(count_label(&later_labels, "later")) { later_bodies++; };
    };

    profile::FrameCaptureView frame = recorder.frame(0)!!;
    assert(inner_bodies == 1 && omitted_bodies == 1 && outer_bodies == 1 && later_bodies == 1);
    assert(later_labels == 0);
    assert(frame.cpu.len == 1 && frame.cpu[0].label == "inner");
    assert(!frame.cpu[0].self_complete);
    assert(frame.truncated && frame.dropped_cpu_scopes == 3);
}

fn void test_internal_label_scope_rechecks_admission() @test @feat(C3D_PROFILE_CPU & C3D_PROFILE_INTERNAL) {
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 1,
        .cpu_scopes_per_frame = 1,
        .max_depth = 1,
        .label_bytes_per_frame = 32,
    })!!;
    defer profile::destroy_recorder(&recorder);
    uint inner_bodies;
    uint outer_bodies;

    profile::@capture(&recorder, 0) {
        profile::@internal_scope(label_with_recorded_scope(&inner_bodies)) { outer_bodies++; };
    };

    profile::FrameCaptureView frame = recorder.frame(0)!!;
    assert(inner_bodies == 1 && outer_bodies == 1);
    assert(frame.cpu.len == 1 && frame.cpu[0].label == "inner");
    assert(frame.cpu[0].origin == profile::ScopeOrigin.APPLICATION);
    assert(frame.truncated && frame.dropped_cpu_scopes == 1);
}
