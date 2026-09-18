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
    imgui::text("Culled: %u", renderer.stats.culled);
    imgui::text("Lights: %u", renderer.stats.lights);
    imgui::text("Lights dropped: %u", renderer.stats.lights_dropped);
    imgui::text("Debug lines: %u", renderer.stats.debug_lines);

    imgui::text("Uploads: %u", renderer.stats.uploads);
    imgui::text("Asset upload bytes: %u", renderer.stats.upload_bytes);
    imgui::text("Dangling references: %u", renderer.stats.dangling_refs);
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

    if (renderer.timestamps_enabled) {
        imgui::text("Completed GPU custom compute: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.CUSTOM_COMPUTE.ordinal]);
        imgui::text("Completed GPU light cull: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.LIGHT_CULL.ordinal]);
        imgui::text("Completed GPU opaque: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.FORWARD_OPAQUE.ordinal]);
        imgui::text("Completed GPU transmission: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.TRANSMISSION.ordinal]);
        imgui::text("Completed GPU transparent: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.FORWARD_TRANSPARENT.ordinal]);
        imgui::text("Completed GPU debug lines: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.DEBUG_LINES.ordinal]);
        imgui::text("Completed GPU velocity: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.VELOCITY.ordinal]);
        imgui::text("Completed GPU post chain: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.POST_CHAIN.ordinal]);
        imgui::text("Completed GPU composite: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.COMPOSITE.ordinal]);
        imgui::text("Completed GPU custom compute (post): %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.CUSTOM_COMPUTE_POST.ordinal]);
    } else {
        imgui::text_unformatted("GPU timings disabled");
    }

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
