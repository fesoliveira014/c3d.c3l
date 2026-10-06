module c3d::render;

import c3d;
import c3d::scene;

<*
 Recorded work the renderer times separately.
*>
enum Pass : int {
    UPLOADS,
    ENVIRONMENT,
    CUSTOM_COMPUTE,
    PROBE_UPDATE,
    INSTANCE_CULL,
    INSTANCE_SORT,
    SHADOW_ATLAS,
    LIGHT_CULL,
    ACCELERATION_BUILD,
    PATH_TRACE,
    SKY_VIEW,
    AERIAL_PERSPECTIVE,
    FOG_SCATTERING,
    FOG_INTEGRATION,
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
    FOG,
    FORWARD_TRANSPARENT,
    SSGI_COLOR_COPY,
    EXPOSURE,
    DEBUG_LINES,
    VELOCITY,
    TEMPORAL_AA,
    POST_CHAIN,
    COMPOSITE,
    CUSTOM_COMPUTE_POST,
    OVERLAY,
}

<*
 Number of pass categories in timing summaries.
*>
const usz PASS_COUNT = Pass::len;

<*
 Environment preparation work timed separately inside Pass.ENVIRONMENT.
*>
enum EnvironmentStage : int (String label) {
    SOURCE { "environment.source" },
    IRRADIANCE { "environment.irradiance" },
    PREFILTER { "environment.prefilter" },
    SHEEN { "environment.sheen" },
    LUTS { "environment.luts" },
    SKY_TRANSMITTANCE { "environment.sky_transmittance" },
    SKY_MULTI_SCATTERING { "environment.sky_multi_scattering" },
    SKY { "environment.sky" },
}

<*
 Number of environment stages in timing summaries.
*>
const usz ENVIRONMENT_STAGE_COUNT = EnvironmentStage::len;

<*
 Frames between the texture readings in Stats.
*>
const uint TEXTURE_STATS_INTERVAL = 16; // a table walk: 0.2 us at 27 entries, 5.4 us at 4,019 on an RTX 4090

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
    uint  sort_dispatches;   // this frame
    uint  sort_overflows;    // this frame: blended ranges drawn unsorted and unculled because they did not fit
    uint  instances_tested;  // the read-back frame, FRAMES_IN_FLIGHT frames late
    uint  instances_visible; // the read-back frame; never above instances_tested
    uint[scene::MAX_LOD_CHOICES] lod_visible;
    uint[scene::MAX_LOD_CHOICES] lod_selected;
    uint[scene::MAX_LOD_CHOICES] lod_objects_selected;
    uint[scene::MAX_LOD_CHOICES] lod_objects_visible;
    uint  lod_instances_tested;
    uint  lod_fallbacks;
    uint  impostor_fallbacks; // current CPU frame: groups whose installed atlas is unavailable
    ulong lod_frame_index;
    bool  lod_counts_valid;
    uint  culled;
    uint  batches_faded;     // this frame: view batches inside the frustum and wholly past their fade band
    uint  lights;
    uint  lights_dropped;
    uint  probe_volumes_dropped; // this frame, per failed acquisition: two views of one scene count a volume twice
    uint  reflection_probes_dropped;     // this frame, per view: past the nearest 16
    uint  reflection_probes_unavailable; // this frame, per view: CPU copy released before this renderer uploaded it
    uint  probe_rays;            // this frame: primary probe rays; shadow rays are not counted
    uint  probe_updates;         // this frame: scene updates of probe volumes
    uint  atmospheres_ignored;   // per resolution: extra, invalid or sunless atmospheres of a scene
    uint  atmospheres_dropped;   // per resolution: atmospheres drawn as absent for want of a mirror slot
    uint  fogs_ignored;          // per view: extra or invalid height fogs the view's layers see
    uint  sky_regenerations;     // this frame: atmosphere lighting marked for regeneration
    ViewId cluster_view;
    uint  cluster_count;
    uint  cluster_overflows;
    uint  debug_lines;
    uint  debug_dropped;         // segments a sink drawn this frame refused; the largest count
    uint  shadow_layers;
    uint  shadow_requests_dropped;
    uint  shadow_sets_recorded;   // this frame: raster views that built a shadow set, empty sets included
    uint  shadow_sets_shared;     // this frame: raster views that bound a set an earlier view recorded
    uint  shadow_lights_unshared; // this frame: lights drawn unshadowed because the bound set lacks them, in views whose shadow camera is not their own
    ShadowTiming[] shadow_timings;
    uint  environment_prepares;
    uint  uploads;
    uint  upload_bytes;
    uint  vertex_history_bytes;  // this frame: previous vertex positions written for temporal views
    uint  prepare_units;
    usz   prepare_bytes;
    uint  material_resolutions;
    uint  pipeline_lookups;
    uint  dangling_refs;
    uint  trace_instances;
    uint  trace_nodes;
    uint  trace_skipped;
    uint  trace_sway_at_rest;    // swaying batches and LOD groups the last preparation traced at rest
    float trace_build_ms;
    uint  blas_builds;
    uint  tlas_builds;
    uint  path_trace_samples;
    uint  shader_rejections;
    uint  textures;              // live table entries at the last reading's frame start; swapchain images count
    uint  texture_capacity;      // the texture table's size
    uint  texture_views;         // live texture views at the last reading's frame start; one heap slot each
    uint  texture_heap_capacity; // the texture heap's size
    float frame_ms;
    float cpu_record_ms;
    float[PASS_COUNT] gpu_pass_ms;
    float[ENVIRONMENT_STAGE_COUNT] gpu_environment_stage_ms; // parts of the ENVIRONMENT pass, not added to it
    ulong gpu_frame_index @if($feat(C3D_PROFILE_GPU));
    GpuTimingState gpu_timing_state @if($feat(C3D_PROFILE_GPU));
    bool[PASS_COUNT] gpu_pass_valid @if($feat(C3D_PROFILE_GPU));
    uint gpu_scopes_dropped @if($feat(C3D_PROFILE_GPU));
}

fn void reset_frame_stats(Stats* stats) @private {
    Stats previous = *stats;
    *stats = {};
    stats.gpu_pass_ms = previous.gpu_pass_ms;
    stats.gpu_environment_stage_ms = previous.gpu_environment_stage_ms;
    stats.shadow_timings = previous.shadow_timings;
    stats.textures = previous.textures;
    stats.texture_capacity = previous.texture_capacity;
    stats.texture_views = previous.texture_views;
    stats.texture_heap_capacity = previous.texture_heap_capacity;
    $if $feat(C3D_PROFILE_GPU):
        stats.gpu_frame_index = previous.gpu_frame_index;
        stats.gpu_timing_state = previous.gpu_timing_state;
        stats.gpu_pass_valid = previous.gpu_pass_valid;
        stats.gpu_scopes_dropped = previous.gpu_scopes_dropped;
    $endif
}
