module c3d::gui;

import c3d;
import c3d::render;
import imgui;

<*
 Side-by-side counters and completed GPU timings of several views.
 @param [&inout] renderer : "Read before begin_frame resets its counters."
 @param views : "Live views, one column each."
 @param labels : "Column headers, one per view."
 @require views.len == labels.len, views.len > 0
*>
fn void view_stats_table(Renderer* renderer, ViewId[] views, ZString[] labels) {
    if (!imgui::begin_table("view_stats", (int)views.len + 1, imgui::TABLE_FLAGS_BORDERS)) return;
    defer imgui::end_table();

    imgui::table_setup_column("", {});
    foreach (label : labels) imgui::table_setup_column(label, {});
    imgui::table_headers_row();

    @row("Shading", views; ViewId view) {
        imgui::text_unformatted(@enum_name(ShadingPath, renderer.views.get(view).desc.shading));
    };
    @row("Lights", views; ViewId view) {
        imgui::text_unformatted(@enum_name(LightSelection, renderer.views.get(view).desc.lights));
    };
    @row("Light count", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.lights);
    };
    @row("Lights dropped", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.lights_dropped);
    };
    @row("Cluster count", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.cluster_count);
    };
    @row("Cluster overflows", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.cluster_overflows);
    };

    $if $feat(C3D_PROFILE_GPU):
        switch (renderer.stats.gpu_timing_state) {
            case UNAVAILABLE: @row("GPU timings", views; ViewId view) { imgui::text_unformatted("N/A"); };
            case PENDING: @row("GPU timings", views; ViewId view) { imgui::text_unformatted("pending"); };
            case READY:
            case TRUNCATED:
                $foreach $index, $name : Pass::names:
                    @row((ZString)$name, views; ViewId view) {
                        ViewStats* stats = &renderer.views.get(view).stats;
                        if (stats.gpu_pass_valid[$index]) {
                            imgui::text("%.3f ms", (double)stats.gpu_pass_ms[$index]);
                        } else {
                            imgui::text_unformatted("N/A");
                        }
                    };
                $endforeach
        }
    $else
        @row("GPU timings", views; ViewId view) { imgui::text_unformatted("N/A (profiling excluded)"); };
    $endif
}

macro @row(ZString label, ViewId[] views; @body(ViewId view)) @local {
    imgui::table_next_row();
    imgui::table_next_column();
    imgui::text_unformatted(label);
    foreach (view : views) {
        imgui::table_next_column();
        @body(view);
    }
}
