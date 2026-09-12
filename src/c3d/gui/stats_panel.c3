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
    imgui::text("Triangles: %u", renderer.stats.triangles);
    imgui::text("Culled: %u", renderer.stats.culled);
    imgui::text("Lights: %u", renderer.stats.lights);
    imgui::text("Lights dropped: %u", renderer.stats.lights_dropped);

    imgui::text("Uploads: %u", renderer.stats.uploads);
    imgui::text("Asset upload bytes: %u", renderer.stats.upload_bytes);
    imgui::text("Dangling references: %u", renderer.stats.dangling_refs);

    if (renderer.frame_index) {
        render::Frame* previous = &renderer.frames[(renderer.frame_index - 1) % render::FRAMES_IN_FLIGHT];
        imgui::text("Previous slot used: %llu bytes", (ulong)previous.upload.head);
        imgui::text("Previous slot capacity: %llu bytes", (ulong)previous.upload.mapped.bytes.len);
        imgui::text("Overflow allocations: %llu", (ulong)previous.upload.overflow.len());
    }

    if (renderer.timestamps_enabled) {
        imgui::text("Completed GPU opaque: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.FORWARD_OPAQUE.ordinal]);
        imgui::text("Completed GPU transparent: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.FORWARD_TRANSPARENT.ordinal]);
        imgui::text("Completed GPU composite: %.3f ms",
            (double)renderer.stats.gpu_pass_ms[Pass.COMPOSITE.ordinal]);
    } else {
        imgui::text_unformatted("GPU timings disabled");
    }

    return c3d::gui::backend::memory_panel(renderer);
}
