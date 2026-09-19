module c3d::profile @feat(C3D_PROFILE_CPU);

import std::encoding::json;

struct ExportFeatures @private {
    bool cpu;
    bool internal;
}

struct ExportFrame @private {
    ulong frame_id;
    CaptureState cpu_state;
    bool truncated;
    uint dropped_cpu_scopes;
    CpuSample[] cpu;
}

struct ExportCapture @private {
    String schema;
    uint version;
    ExportFeatures features;
    ExportFrame[] frames;
}

<* Copy a closed capture into allocator-owned JSON. *>
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
            .cpu = true,
            .internal = $feat(C3D_PROFILE_INTERNAL),
        },
        .frames = frames[..],
    };
    return json::marshal(allocator, capture);
}
