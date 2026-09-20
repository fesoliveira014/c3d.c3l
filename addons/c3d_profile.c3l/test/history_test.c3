module c3d_profile_history_test @feat(C3D_PROFILE_CPU | C3D_PROFILE_GPU);

import c3d::profile @public;

const ulong LARGE_FRAME_ID @private = 9_007_199_254_740_993;
const ulong ACTIVE_FRAME_ID @private = 9_007_199_254_741_005;
const ulong HISTORY_SENTINEL @private = ulong::max;

fn RecorderDesc cpu_history_desc() @private @feat(C3D_PROFILE_CPU) => {
    .frame_capacity = 2,
    .cpu_scopes_per_frame = 1,
    .max_depth = 1,
    .label_bytes_per_frame = 1,
};

fn RecorderDesc gpu_history_desc() @private @feat(C3D_PROFILE_GPU) {
    RecorderDesc desc = {
        .frame_capacity = 3,
        .gpu_scopes_per_frame = 1,
        .label_bytes_per_frame = 1,
    };
    $if $feat(C3D_PROFILE_CPU):
        desc.cpu_scopes_per_frame = 1;
        desc.max_depth = 1;
    $endif
    return desc;
}

fn CaptureBinding open_history_frame(Recorder* recorder, ulong frame_id) @private {
    return profile::begin_capture_at(recorder, frame_id, 0);
}

fn void close_history_frame(Recorder* recorder, CaptureBinding binding) @private {
    profile::end_capture(recorder, binding, false);
}

fn void test_history_lists_closed_sparse_ids() @test @feat(C3D_PROFILE_CPU) {
    Recorder recorder = profile::create_recorder(mem, cpu_history_desc())!!;
    defer profile::destroy_recorder(&recorder);
    ulong[3] frame_ids = { HISTORY_SENTINEL, HISTORY_SENTINEL, HISTORY_SENTINEL };

    assert(recorder.frame_ids(frame_ids[..]) == 0);
    assert(frame_ids[0] == HISTORY_SENTINEL && frame_ids[1] == HISTORY_SENTINEL);
    assert(frame_ids[2] == HISTORY_SENTINEL);

    CaptureBinding binding = open_history_frame(&recorder, 0);
    close_history_frame(&recorder, binding);
    binding = open_history_frame(&recorder, LARGE_FRAME_ID);
    close_history_frame(&recorder, binding);
    binding = open_history_frame(&recorder, ACTIVE_FRAME_ID);

    assert(recorder.frame_ids(frame_ids[..]) == 1);
    assert(frame_ids[0] == LARGE_FRAME_ID && frame_ids[1] == HISTORY_SENTINEL);
    assert(frame_ids[2] == HISTORY_SENTINEL);

    close_history_frame(&recorder, binding);
    assert(recorder.frame_ids(frame_ids[..]) == 2);
    assert(frame_ids[0] == LARGE_FRAME_ID && frame_ids[1] == ACTIVE_FRAME_ID);
    assert(frame_ids[2] == HISTORY_SENTINEL);

    recorder.set_enabled(false);
    binding = open_history_frame(&recorder, ACTIVE_FRAME_ID + 1);
    close_history_frame(&recorder, binding);
    assert(recorder.frame_ids(frame_ids[..]) == 2);
    assert(frame_ids[0] == LARGE_FRAME_ID && frame_ids[1] == ACTIVE_FRAME_ID);
    assert(frame_ids[2] == HISTORY_SENTINEL);
}

fn void test_history_orders_pinned_slots() @test @feat(C3D_PROFILE_GPU) {
    Recorder recorder = profile::create_recorder(mem, gpu_history_desc())!!;
    defer profile::destroy_recorder(&recorder);
    uint source = profile::attach_gpu_source(&recorder)!!;
    defer profile::detach_gpu_source(&recorder, source);
    CaptureBinding binding = open_history_frame(&recorder, 10);
    GpuCaptureToken pending = profile::borrow_gpu_frame(&recorder, source, 10);
    defer profile::cancel_gpu_frame(&recorder, pending);
    close_history_frame(&recorder, binding);
    binding = open_history_frame(&recorder, 20);
    close_history_frame(&recorder, binding);
    binding = open_history_frame(&recorder, 30);
    close_history_frame(&recorder, binding);
    binding = open_history_frame(&recorder, 40);
    close_history_frame(&recorder, binding);
    ulong[3] frame_ids;

    assert(recorder.frame_ids(frame_ids[..]) == 3);
    assert(frame_ids[0] == 10 && frame_ids[1] == 30 && frame_ids[2] == 40);
}

fn void test_history_omits_dropped_admissions() @test @feat(C3D_PROFILE_GPU) {
    RecorderDesc desc = gpu_history_desc();
    desc.frame_capacity = 2;
    Recorder recorder = profile::create_recorder(mem, desc)!!;
    defer profile::destroy_recorder(&recorder);
    uint source = profile::attach_gpu_source(&recorder)!!;
    defer profile::detach_gpu_source(&recorder, source);
    CaptureBinding binding = open_history_frame(&recorder, 10);
    GpuCaptureToken frame_10 = profile::borrow_gpu_frame(&recorder, source, 10);
    defer profile::cancel_gpu_frame(&recorder, frame_10);
    close_history_frame(&recorder, binding);
    binding = open_history_frame(&recorder, 20);
    GpuCaptureToken frame_20 = profile::borrow_gpu_frame(&recorder, source, 20);
    defer profile::cancel_gpu_frame(&recorder, frame_20);
    close_history_frame(&recorder, binding);
    ulong[2] frame_ids;
    uint bodies;

    profile::@capture(&recorder, 30) {
        bodies++;
        assert(recorder.frame_ids(frame_ids[..]) == 2);
        assert(frame_ids[0] == 10 && frame_ids[1] == 20);
    };

    assert(bodies == 1 && recorder.dropped_frames == 1);
    assert(recorder.frame_ids(frame_ids[..]) == 2);
    assert(frame_ids[0] == 10 && frame_ids[1] == 20);
    if (catch excuse = recorder.frame(30)) {
        assert(excuse == profile::NOT_FOUND);
    } else {
        unreachable("expected NOT_FOUND");
    }
}
