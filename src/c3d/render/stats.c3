module c3d::render;

import c3d;

<*
 Recorded work the renderer times separately.
*>
enum Pass : int {
    UPLOADS,
    CUSTOM_COMPUTE,
    PROBE_UPDATE,
    INSTANCE_CULL,
    SHADOW_ATLAS,
    LIGHT_CULL,
    ACCELERATION_BUILD,
    PATH_TRACE,
    DEPTH_PREPASS,
    GBUFFER,
    AMBIENT_OCCLUSION,
    SCREEN_SPACE_GI,
    RT_REFLECTIONS,
    LIGHTING,
    FORWARD_OPAQUE,
    SKY,
    SCENE_SNAPSHOT,
    SCENE_READ,
    FORWARD_TRANSPARENT,
    SSGI_COLOR_COPY,
    DEBUG_LINES,
    VELOCITY,
    TEMPORAL_AA,
    POST_CHAIN,
    COMPOSITE,
    CUSTOM_COMPUTE_POST,
}

<*
 Number of pass categories in timing summaries.
*>
const usz PASS_COUNT = Pass::len;

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
    uint  indirect_draws;
    uint  post_dispatches;
    uint  scene_snapshots;   // this frame: one per snapshot image copied
    uint  dispatches;
    uint  triangles;
    uint  instances;
    uint  cull_dispatches;   // this frame
    uint  cull_overflows;    // this frame: ranges drawn unculled because the arena was full
    uint  instances_tested;  // the read-back frame, FRAMES_IN_FLIGHT frames late
    uint  instances_visible; // the read-back frame; never above instances_tested
    uint  culled;
    uint  lights;
    uint  lights_dropped;
    uint  probe_volumes_dropped; // this frame, per failed acquisition: two views of one scene count a volume twice
    uint  probe_rays;            // this frame: primary probe rays; shadow rays are not counted
    uint  probe_updates;         // this frame: scene updates of probe volumes
    ViewId cluster_view;
    uint  cluster_count;
    uint  cluster_overflows;
    uint  debug_lines;
    uint  debug_dropped;         // segments a sink drawn this frame refused; the largest count
    uint  shadow_layers;
    uint  shadow_requests_dropped;
    ShadowTiming[] shadow_timings;
    uint  environment_prepares;
    uint  uploads;
    uint  upload_bytes;
    uint  prepare_units;
    usz   prepare_bytes;
    uint  material_resolutions;
    uint  pipeline_lookups;
    uint  dangling_refs;
    uint  trace_instances;
    uint  trace_nodes;
    uint  trace_skipped;
    float trace_build_ms;
    uint  blas_builds;
    uint  tlas_builds;
    uint  path_trace_samples;
    uint  shader_rejections;
    float frame_ms;
    float cpu_record_ms;
    float[PASS_COUNT] gpu_pass_ms;
    ulong gpu_frame_index @if($feat(C3D_PROFILE_GPU));
    GpuTimingState gpu_timing_state @if($feat(C3D_PROFILE_GPU));
    bool[PASS_COUNT] gpu_pass_valid @if($feat(C3D_PROFILE_GPU));
    uint gpu_scopes_dropped @if($feat(C3D_PROFILE_GPU));
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
