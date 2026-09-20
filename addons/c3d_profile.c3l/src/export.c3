module c3d::profile @feat(C3D_PROFILE_CPU | C3D_PROFILE_GPU);

import std::encoding::json;

struct ExportFeatures @private {
    bool cpu;
    bool internal;
    bool gpu @if($feat(C3D_PROFILE_GPU));
}

struct ExportFrame @private {
    ulong frame_id;
    CaptureState cpu_state;
    bool truncated;
    uint dropped_cpu_scopes;
    CpuSample[] cpu;
    CaptureState gpu_state @if($feat(C3D_PROFILE_GPU));
    bool gpu_truncated @if($feat(C3D_PROFILE_GPU));
    uint dropped_gpu_scopes @if($feat(C3D_PROFILE_GPU));
    uint pending_gpu_frames @if($feat(C3D_PROFILE_GPU));
    uint unavailable_gpu_frames @if($feat(C3D_PROFILE_GPU));
    uint aborted_gpu_frames @if($feat(C3D_PROFILE_GPU));
    GpuSample[] gpu @if($feat(C3D_PROFILE_GPU));
}

struct ExportCapture @private {
    String schema;
    uint version;
    ExportFeatures features;
    ExportFrame[] frames;
}

<* Copy a capture snapshot into allocator-owned JSON. *>
fn String capture_json(Allocator allocator, FrameCaptureView frame) {
    ExportFrame[1] frames = {{
        .frame_id = frame.frame_id,
        .cpu_state = frame.cpu_state,
        .truncated = frame.truncated,
        .dropped_cpu_scopes = frame.dropped_cpu_scopes,
        .cpu = frame.cpu,
    }};
    ExportCapture capture = {
        .schema = "c3d.profile",
        .version = 1,
        .features = {
            .cpu = $feat(C3D_PROFILE_CPU),
            .internal = $feat(C3D_PROFILE_INTERNAL),
        },
        .frames = frames[..],
    };
    $if $feat(C3D_PROFILE_GPU):
        capture.features.gpu = true;
        frames[0].gpu_state = frame.gpu_state;
        frames[0].gpu_truncated = frame.gpu_truncated;
        frames[0].dropped_gpu_scopes = frame.dropped_gpu_scopes;
        frames[0].pending_gpu_frames = frame.pending_gpu_frames;
        frames[0].unavailable_gpu_frames = frame.unavailable_gpu_frames;
        frames[0].aborted_gpu_frames = frame.aborted_gpu_frames;
        frames[0].gpu = frame.gpu;
    $endif
    return json::marshal(allocator, capture);
}
