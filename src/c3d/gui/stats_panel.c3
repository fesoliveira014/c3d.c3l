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

    imgui::text("Frame: %.3f ms", (double)renderer.stats.frame_ms);
    imgui::text("CPU record: %.3f ms", (double)renderer.stats.cpu_record_ms);

    imgui::text("Draws: %u", renderer.stats.draws);
    imgui::text("Indirect draws: %u", renderer.stats.indirect_draws);
    imgui::text("Post dispatches: %u", renderer.stats.post_dispatches);
    imgui::text("Dispatches: %u", renderer.stats.dispatches);
    imgui::text("Scene snapshots: %u", renderer.stats.scene_snapshots);
    imgui::text("Triangles: %u", renderer.stats.triangles);
    imgui::text("Instances: %u", renderer.stats.instances);
    uint tested = renderer.stats.instances_tested;
    uint visible_instances = renderer.stats.instances_visible;
    double visible_percent = tested ? 100.0 * visible_instances / tested : 0;
    imgui::text("Visible instances: %u of %u (%.1f%%)", visible_instances, tested, visible_percent);
    imgui::text("Cull dispatches: %u", renderer.stats.cull_dispatches);
    imgui::text("Cull overflows: %u", renderer.stats.cull_overflows);
    imgui::text("Sort dispatches: %u", renderer.stats.sort_dispatches);
    imgui::text("Sort overflows: %u", renderer.stats.sort_overflows);
    imgui::text("Culled: %u", renderer.stats.culled);
    imgui::text("Faded batches: %u", renderer.stats.batches_faded);
    imgui::text("Unavailable impostor atlases: %u", renderer.stats.impostor_fallbacks);
    if (renderer.stats.lod_counts_valid) {
        imgui::text("Completed LOD frame: %llu", renderer.stats.lod_frame_index);
        imgui::text("LOD placements tested: %u, fallback groups: %u", renderer.stats.lod_instances_tested, renderer.stats.lod_fallbacks);
        foreach (uint level, count : renderer.stats.lod_visible) {
            imgui::text(
                "LOD %u placements: %u selected, %u visible",
                level,
                renderer.stats.lod_selected[level],
                count,
            );
        }
    }
    foreach (uint level, count : renderer.stats.lod_objects_selected) {
        if (count) imgui::text(
            "LOD %u ordinary objects, current CPU frame: %u selected, %u visible",
            level,
            count,
            renderer.stats.lod_objects_visible[level],
        );
    }
    imgui::text("Lights: %u", renderer.stats.lights);
    imgui::text("Lights dropped: %u", renderer.stats.lights_dropped);
    imgui::text("Probe rays: %u", renderer.stats.probe_rays);
    imgui::text("Probe updates: %u", renderer.stats.probe_updates);
    imgui::text("Probe volumes dropped: %u", renderer.stats.probe_volumes_dropped);
    imgui::text("Reflection probes dropped: %u", renderer.stats.reflection_probes_dropped);
    imgui::text("Reflection probes unavailable: %u", renderer.stats.reflection_probes_unavailable);
    imgui::text("Debug lines: %u (dropped %u)", renderer.stats.debug_lines, renderer.stats.debug_dropped);

    imgui::text("Uploads: %u", renderer.stats.uploads);
    imgui::text("Upload bytes: %u", renderer.stats.upload_bytes);
    imgui::text("Prepare units: %u", renderer.stats.prepare_units);
    imgui::text("Prepare bytes: %llu", (ulong)renderer.stats.prepare_bytes);
    imgui::text("Dangling references: %u", renderer.stats.dangling_refs);
    imgui::text("Trace instances: %u", renderer.stats.trace_instances);
    imgui::text("Trace nodes: %u", renderer.stats.trace_nodes);
    imgui::text("Trace skipped: %u", renderer.stats.trace_skipped);
    imgui::text("Trace build: %.3f ms", (double)renderer.stats.trace_build_ms);
    imgui::text("BLAS builds: %u", renderer.stats.blas_builds);
    imgui::text("TLAS builds: %u", renderer.stats.tlas_builds);
    imgui::text("Path trace samples: %u", renderer.stats.path_trace_samples);
    imgui::text("Shader rejections: %u", renderer.stats.shader_rejections);

    imgui::text("Completed cluster view: %u:%u",
        renderer.stats.cluster_view.index, renderer.stats.cluster_view.generation);
    imgui::text("Completed cluster count: %u", renderer.stats.cluster_count);
    imgui::text("Completed cluster overflows: %u", renderer.stats.cluster_overflows);

    if (renderer.frame_index) {
        render::Frame* previous = &renderer.frames[(renderer.frame_index - 1) % render::FRAMES_IN_FLIGHT];
        imgui::text("Previous slot used: %llu bytes", (ulong)previous.upload.head);
        imgui::text("Previous slot capacity: %llu bytes", (ulong)previous.upload.mapped.bytes.len);
        imgui::text("Overflow allocations: %llu", (ulong)previous.upload.overflow.len());
    }

    $if $feat(C3D_PROFILE_GPU):
        Stats* stats = &renderer.stats;
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
