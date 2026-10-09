module c3d::gui;

import c3d::gui::backend;
import c3d::render;
import imgui;

<*
 Display previous-frame counters and completed GPU timings.
 @param [&inout] renderer : "Read before begin_frame resets its counters."
 @return? c3d::gui::backend::memory_panel!
*>
fn void? stats_panel(Renderer* renderer) {
    bool visible = imgui::begin("Stats", null, {});
    defer imgui::end();
    if (!visible) return;
    Stats* stats = &renderer.stats;

    imgui::text("Frame: %.3f ms", (double)stats.frame_ms);
    imgui::text("CPU record: %.3f ms", (double)stats.cpu_record_ms);

    imgui::text("Draws: %u", stats.draws);
    imgui::text("Indirect draws: %u", stats.indirect_draws);
    imgui::text("Post dispatches: %u", stats.post_dispatches);
    imgui::text("Dispatches: %u", stats.dispatches);
    imgui::text("Scene snapshots: %u", stats.scene_snapshots);
    imgui::text("Triangles: %u", stats.triangles);
    imgui::text("Instances: %u", stats.instances);
    uint tested = stats.instances_tested;
    uint visible_instances = stats.instances_visible;
    double visible_percent = tested ? 100.0 * visible_instances / tested : 0;
    imgui::text("Visible instances: %u of %u", visible_instances, tested);
    imgui::text("Visible instances: %.1f%%", visible_percent);
    imgui::text("Cull dispatches: %u", stats.cull_dispatches);
    imgui::text("Cull overflows: %u", stats.cull_overflows);
    imgui::text("Sort dispatches: %u", stats.sort_dispatches);
    imgui::text("Sort overflows: %u", stats.sort_overflows);
    imgui::text("Culled: %u", stats.culled);
    imgui::text("Faded batches: %u", stats.batches_faded);
    imgui::text("Unavailable impostor atlases: %u", stats.impostor_fallbacks);
    if (stats.lod_counts_valid) {
        imgui::text("Completed LOD frame: %llu", stats.lod_frame_index);
        imgui::text("LOD placements tested: %u, fallback groups: %u", stats.lod_instances_tested, stats.lod_fallbacks);
        foreach (uint level, count : stats.lod_visible) {
            imgui::text("LOD %u selected placements: %u", level, stats.lod_selected[level]);
            imgui::text("LOD %u visible placements: %u", level, count);
        }
    }
    foreach (uint level, count : stats.lod_objects_selected) {
        if (count) {
            imgui::text("LOD %u ordinary objects selected: %u", level, count);
            imgui::text("LOD %u ordinary objects visible: %u", level, stats.lod_objects_visible[level]);
        }
    }
    imgui::text("Lights: %u", stats.lights);
    imgui::text("Lights dropped: %u", stats.lights_dropped);
    imgui::text("Decals: %u", stats.decals);
    imgui::text("Decals dropped: %u", stats.decals_dropped);
    imgui::text("Probe rays: %u", stats.probe_rays);
    imgui::text("Probe updates: %u", stats.probe_updates);
    imgui::text("Probe volumes dropped: %u", stats.probe_volumes_dropped);
    imgui::text("Reflection probes dropped: %u", stats.reflection_probes_dropped);
    imgui::text("Reflection probes unavailable: %u", stats.reflection_probes_unavailable);
    imgui::text("Debug lines: %u (dropped %u)", stats.debug_lines, stats.debug_dropped);

    imgui::text("Uploads: %u", stats.uploads);
    imgui::text("Upload bytes: %u", stats.upload_bytes);
    imgui::text("Prepare units: %u", stats.prepare_units);
    imgui::text("Prepare bytes: %llu", (ulong)stats.prepare_bytes);
    imgui::text("Prepare generated texels: %llu", stats.prepare_generated_texels);
    imgui::text("Prepare CPU copied bytes: %llu", stats.prepare_copied_bytes);
    imgui::text("Prepare pipeline calls: %u", stats.prepare_pipelines);
    imgui::text("Prepare cache lookups / hits: %u / %u", stats.prepare_pipeline_lookups, stats.prepare_pipeline_hits);
    imgui::text("Prepare objects: %u", stats.prepare_objects);
    imgui::text("Prepare views / allocations: %u / %u", stats.prepare_views, stats.prepare_allocations);
    imgui::text("Prepare generation ns: %llu", stats.prepare_generation_ns);
    imgui::text("Prepare pipeline driver ns: %llu", stats.prepare_pipeline_ns);
    imgui::text("Prepare elapsed / overrun ns: %llu / %llu", stats.prepare_elapsed_ns, stats.prepare_overrun_ns);
    imgui::text("Prepare restarts: %u", stats.prepare_restarts);
    imgui::text("Dangling references: %u", stats.dangling_refs);
    imgui::text("Trace instances: %u", stats.trace_instances);
    imgui::text("Trace nodes: %u", stats.trace_nodes);
    imgui::text("Trace skipped: %u", stats.trace_skipped);
    imgui::text("Trace build: %.3f ms", (double)stats.trace_build_ms);
    imgui::text("BLAS builds: %u", stats.blas_builds);
    imgui::text("TLAS builds: %u", stats.tlas_builds);
    imgui::text("Path trace samples: %u", stats.path_trace_samples);
    imgui::text("Shader rejections: %u", stats.shader_rejections);
    imgui::text("Textures: %u of %u", stats.textures, stats.texture_capacity);
    imgui::text("Texture views: %u of %u", stats.texture_views, stats.texture_heap_capacity);

    imgui::text("Completed cluster view: %u:%u", stats.cluster_view.index, stats.cluster_view.generation);
    imgui::text("Completed cluster count: %u", stats.cluster_count);
    imgui::text("Completed cluster overflows: %u", stats.cluster_overflows);
    imgui::text("Completed decal overflows: %u", stats.decal_overflows);

    if (renderer.frame_index) {
        render::Frame* previous = &renderer.frames[(renderer.frame_index - 1) % render::FRAMES_IN_FLIGHT];
        imgui::text("Previous slot used: %llu bytes", (ulong)previous.upload.head);
        imgui::text("Previous slot capacity: %llu bytes", (ulong)previous.upload.mapped.bytes.len);
        imgui::text("Overflow allocations: %llu", (ulong)previous.upload.overflow.len());
    }

    $if $feat(C3D_PROFILE_GPU):
        switch (stats.gpu_timing_state) {
            case UNAVAILABLE: imgui::text_unformatted("GPU timings: N/A");
            case PENDING: imgui::text_unformatted("GPU timings: pending");
            case READY:
            case TRUNCATED:
                imgui::text("Completed GPU frame: %llu", stats.gpu_frame_index);
                if (stats.gpu_timing_state == GpuTimingState.TRUNCATED) {
                    imgui::text("Partial GPU timings: %u omitted scopes", stats.gpu_scopes_dropped);
                }
                $foreach $index, $name : Pass::names:
                    if (stats.gpu_pass_valid[$index]) {
                        imgui::text("%s: %.3f ms", (ZString)$name, (double)stats.gpu_pass_ms[$index]);
                    } else {
                        imgui::text("%s: N/A", (ZString)$name);
                    }
                $endforeach
        }
    $else
        imgui::text_unformatted("GPU timings: N/A (profiling excluded)");
    $endif

    c3d::gui::backend::memory_panel(renderer)!;
    c3d::gui::backend::diagnostics_section(renderer);
}
