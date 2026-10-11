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
    @row("Images", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.images);
    };
    @row("Light count", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.lights);
    };
    @row("Exposure", views; ViewId view) {
        imgui::text("%.3f", renderer.views.get(view).stats.exposure);
    };
    @row("Accumulated samples", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.accumulated_samples);
    };
    @row("Shadow set", views; ViewId view) {
        imgui::text_unformatted(renderer.views.get(view).stats.shadow_set_shared ? "shared" : "recorded");
    };
    @row("Lights dropped", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.lights_dropped);
    };
    @row("Decals", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.decals);
    };
    @row("Decals dropped", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.decals_dropped);
    };
    @row("Decal overflows", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.decal_overflows);
    };
    @row("Cluster count", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.cluster_count);
    };
    @row("Cluster overflows", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.cluster_overflows);
    };

    @row("Transparency", views; ViewId view) {
        imgui::text_unformatted(@enum_name(TransparencyMode, renderer.views.get(view).desc.transparency.mode));
    };

    @row("Retained group capacity", views; ViewId view) {
        ViewDesc* desc = &renderer.views.get(view).desc;

        if (desc.transparency.mode == LAYERED && desc.shading != PATH_TRACED) {
            imgui::text("%u", desc.transparency.layer_capacity);
        } else {
            imgui::text_unformatted("N/A");
        }
    };

    @row("Layer capture passes", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.transparency.capture_passes);
    };

    @row("Retained shade passes", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.transparency.retained_passes);
    };

    @row("Sorted remainder passes", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.transparency.remainder_passes);
    };

    @row("Layer resolve passes", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.transparency.resolve_passes);
    };

    @row("Filter builds", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.transparency.filter_passes);
    };

    @row("Filter dispatches", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.transparency.filter_dispatches);
    };

    @row("Filtered mip levels", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.transparency.filtered_mips);
    };

    @row("Fallback draws", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.transparency.fallback_draws);
    };

    @row("Overflow dispatches", views; ViewId view) {
        imgui::text("%u", renderer.views.get(view).stats.transparency.overflow_dispatches);
    };

    @row("Completed overflow frame", views; ViewId view) {
        TransparencyStats* stats = &renderer.views.get(view).stats.transparency;

        if (stats.overflow_valid) {
            imgui::text("%llu", stats.overflow_frame_index);
        } else {
            imgui::text_unformatted(stats.overflow_dispatches ? "pending" : "N/A");
        }
    };

    @row("Completed overflow pixels", views; ViewId view) {
        TransparencyStats* stats = &renderer.views.get(view).stats.transparency;

        if (stats.overflow_valid) {
            imgui::text("%u", stats.overflow_pixels);
        } else {
            imgui::text_unformatted("N/A");
        }
    };

    @row("Completed overflow", views; ViewId view) {
        TransparencyStats* stats = &renderer.views.get(view).stats.transparency;

        if (stats.overflow_valid) {
            imgui::text_unformatted(stats.overflow ? "yes" : "no");
        } else {
            imgui::text_unformatted("N/A");
        }
    };

    @row("Transparency bytes", views; ViewId view) {
        imgui::text("%llu", (ulong)renderer.views.get(view).stats.transparency.payload_bytes);
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

fn void transparency_view_summary(TransparencyStats* stats) @private {
    imgui::text("Layer capture passes: %u", stats.capture_passes);
    imgui::text("Retained shade passes: %u", stats.retained_passes);
    imgui::text("Sorted remainder passes: %u", stats.remainder_passes);
    imgui::text("Layer resolve passes: %u", stats.resolve_passes);
    imgui::text("Filter builds: %u", stats.filter_passes);
    imgui::text("Filter dispatches: %u", stats.filter_dispatches);
    imgui::text("Filtered mip levels: %u", stats.filtered_mips);
    imgui::text("Fallback draws: %u", stats.fallback_draws);
    imgui::text("Overflow dispatches: %u", stats.overflow_dispatches);
    imgui::text("Transparency payload: %llu bytes", (ulong)stats.payload_bytes);

    if (stats.overflow_valid) {
        imgui::text("Completed overflow frame: %llu", stats.overflow_frame_index);
        imgui::text("Completed overflow pixels: %u", stats.overflow_pixels);
        imgui::text("Completed overflow: %s", stats.overflow ? "yes" : "no");
    } else {
        ZString readback = stats.overflow_dispatches
          ? "Overflow readback: pending" : "Overflow readback: unavailable";
        imgui::text_unformatted(readback);
    }
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
