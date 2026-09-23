module c3d::render;

import c3d;

<*
 Recorded work the renderer times separately.
*>
enum Pass : int {
    UPLOADS,
    CUSTOM_COMPUTE,
    SHADOW_ATLAS,
    LIGHT_CULL,
    ACCELERATION_BUILD,
    DEPTH_PREPASS,
    GBUFFER,
    LIGHTING,
    FORWARD_OPAQUE,
    SKY,
    TRANSMISSION,
    FORWARD_TRANSPARENT,
    DEBUG_LINES,
    VELOCITY,
    POST_CHAIN,
    COMPOSITE,
    CUSTOM_COMPUTE_POST,
}

<*
 Number of pass categories in timing summaries.
*>
const usz PASS_COUNT = Pass::len;

<*
 Timestamps written per timed pass.
*>
const uint TIMESTAMPS_PER_PASS = 2;

<* Availability of the latest completed GPU summary. *>
enum GpuTimingState {
    UNAVAILABLE,
    PENDING,
    READY,
    TRUNCATED,
}

<*
 Current CPU counters and asynchronously completed, frame-tagged GPU timings.
*>
struct Stats {
    uint  draws;
    uint  post_dispatches;
    uint  dispatches;
    uint  triangles;
    uint  instances;
    uint  culled;
    uint  lights;
    uint  lights_dropped;
    ViewId cluster_view;
    uint  cluster_count;
    uint  cluster_overflows;
    uint  debug_lines;
    uint  shadow_layers;
    uint  shadow_requests_dropped;
    ShadowTiming[] shadow_timings;
    uint  environment_prepares;
    uint  uploads;
    uint  upload_bytes;
    uint  material_resolutions;
    uint  pipeline_lookups;
    uint  dangling_refs;
    uint  shader_rejections;
    float frame_ms;
    float cpu_record_ms;
    float[PASS_COUNT] gpu_pass_ms;
    ulong gpu_frame_index @if($feat(C3D_PROFILE_GPU));
    GpuTimingState gpu_timing_state @if($feat(C3D_PROFILE_GPU));
    bool[PASS_COUNT] gpu_pass_valid @if($feat(C3D_PROFILE_GPU));
    uint gpu_scopes_dropped @if($feat(C3D_PROFILE_GPU));
}

<*
 Fixed-layout timestamp offset kept for compatibility; capture uses independent query pairs.
 @require pass_ordinal < PASS_COUNT
 @pure
*>
fn uint pass_timestamp_slot(ulong frame_index, usz pass_ordinal) {
    return (uint)(frame_index % FRAMES_IN_FLIGHT) * (uint)PASS_COUNT * TIMESTAMPS_PER_PASS
      + (uint)pass_ordinal * TIMESTAMPS_PER_PASS;
}

fn void reset_frame_stats(Stats* stats) @private {
    Stats previous = *stats;
    *stats = {};
    stats.gpu_pass_ms = previous.gpu_pass_ms;
    stats.shadow_timings = previous.shadow_timings;
    $if $feat(C3D_PROFILE_GPU):
        stats.gpu_frame_index = previous.gpu_frame_index;
        stats.gpu_timing_state = previous.gpu_timing_state;
        stats.gpu_pass_valid = previous.gpu_pass_valid;
        stats.gpu_scopes_dropped = previous.gpu_scopes_dropped;
    $endif
}
