module c3d::gui;

import c3d::gui::backend;
import c3d::render;
import gpu;
import imgui;

const usz DIAGNOSTICS_ROWS @local = 16; // one screen of recent messages; the ring keeps 64

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
    imgui::text("Post dispatches: %u", renderer.stats.post_dispatches);
    imgui::text("Dispatches: %u", renderer.stats.dispatches);
    imgui::text("Triangles: %u", renderer.stats.triangles);
    imgui::text("Instances: %u", renderer.stats.instances);
    imgui::text("Culled: %u", renderer.stats.culled);
    imgui::text("Lights: %u", renderer.stats.lights);
    imgui::text("Lights dropped: %u", renderer.stats.lights_dropped);
    imgui::text("Debug lines: %u", renderer.stats.debug_lines);

    imgui::text("Uploads: %u", renderer.stats.uploads);
    imgui::text("Asset upload bytes: %u", renderer.stats.upload_bytes);
    imgui::text("Dangling references: %u", renderer.stats.dangling_refs);
    imgui::text("Trace instances: %u", renderer.stats.trace_instances);
    imgui::text("Trace nodes: %u", renderer.stats.trace_nodes);
    imgui::text("Trace skipped: %u", renderer.stats.trace_skipped);
    imgui::text("Trace build: %.3f ms", (double)renderer.stats.trace_build_ms);
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
    diagnostics_section(renderer);
}

fn ZString category_name(gpu::DebugMessageCategory category) @local {
    if (category.validation) return "validation";
    if (category.public_contract) return "contract";
    if (category.performance) return "performance";
    if (category.resource_lifetime) return "lifetime";
    if (category.backend) return "backend";
    return "general";
}

fn void diagnostics_section(Renderer* renderer) @local {
    if (!imgui::collapsing_header("Diagnostics", {})) return;

    imgui::text("Validation: %s", renderer.validation ? "on" : "off");
    imgui::text("GPU timings: %s", renderer.timestamps_enabled ? "on" : "off");

    DebugEntry[DIAGNOSTICS_ROWS] entries;
    usz count = renderer.log.recent(entries[..]);
    if (!count) imgui::text_unformatted("No messages");
    @pool() {
        foreach (entry : entries[:count]) {
            imgui::text("%s %s %s#%u %s",
                @enum_name(gpu::DebugMessageSeverity, entry.severity),
                category_name(entry.category),
                @enum_name(gpu::DebugResourceKind, entry.resource_kind),
                entry.resource_index,
                (ZString)&entry.operation);
            if (entry.has_fault) imgui::text("  %s", entry.public_fault.description.zstr_tcopy());
        }
    };
}
