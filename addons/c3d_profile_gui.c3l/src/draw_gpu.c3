module c3d::gui @feat(C3D_PROFILE_GUI & C3D_PROFILE_GPU);

import c3d::profile;
import imgui;
import std::math;

fn bool first_gpu_group(profile::GpuSample[] samples, sz index) @private {
    profile::GpuSample sample = samples[index];
    foreach (previous : samples[:index]) {
        if (previous.source == sample.source && previous.renderer_frame == sample.renderer_frame) return false;
    }
    return true;
}

fn void draw_gpu_status(profile::FrameCaptureView frame) @private {
    draw_state(frame.gpu_state);
    imgui::text("Omitted scopes: %u", frame.dropped_gpu_scopes);
    imgui::text("Pending: %u / unavailable: %u", frame.pending_gpu_frames, frame.unavailable_gpu_frames);
    imgui::text("Aborted: %u", frame.aborted_gpu_frames);
    if (frame.gpu_truncated) imgui::text_unformatted("Partial counts (truncated)");
    if (frame.gpu_state == profile::CaptureState.PENDING && frame.gpu.len) {
        imgui::text_unformatted("Partial completed prefix");
    }
}

fn void draw_gpu_context(profile::GpuScopeInfo info) @private {
    draw_origin(info.origin);
    switch (info.kind) {
        case APPLICATION: imgui::text_unformatted("Application scope");
        case FRAME: imgui::text_unformatted("Frame scope");
        case VIEW: imgui::text_unformatted("View scope");
        case PASS: imgui::text_unformatted("Pass scope");
        case SHADOW_LAYER: imgui::text_unformatted("Shadow layer scope");
        case COMPUTE_DISPATCH: imgui::text_unformatted("Compute dispatch scope");
    }
    imgui::text("Has view: %s", info.has_view ? "yes" : "no");
    imgui::text(info.has_view ? "View %u:%u" : "View N/A (captured %u:%u)",
      info.view_index, info.view_generation);
    imgui::same_line();
    bool has_pass;
    switch (info.kind) {
        case PASS:
        case SHADOW_LAYER:
        case COMPUTE_DISPATCH: has_pass = true;
        case APPLICATION:
        case FRAME:
        case VIEW:
    }
    imgui::text(has_pass ? "/ pass %u" : "/ pass N/A (captured %u)", info.pass_ordinal);
    imgui::text(info.kind == profile::GpuScopeKind.SHADOW_LAYER ? "Light %u:%u" : "Light N/A (captured %u:%u)",
      info.light_index, info.light_generation);
    imgui::same_line();
    imgui::text("/ kind %u / layer %u", info.light_kind, info.layer_index);
    imgui::text(info.kind == profile::GpuScopeKind.COMPUTE_DISPATCH ? "Shader %u:%u" : "Shader N/A (captured %u:%u)",
      info.shader_index, info.shader_generation);
    imgui::same_line();
    imgui::text("/ revision %u", info.shader_revision);
}

fn void draw_gpu_inspection(profile::GpuSample sample) @private {
    draw_label(sample.label);
    imgui::text("Source %u / renderer frame %llu", sample.source, sample.renderer_frame);
    imgui::text("Inclusive: %.6f ms", sample.duration_ns / NS_PER_MS);
    imgui::text("Producer offset: %.6f ms", sample.start_ns / NS_PER_MS);
    draw_gpu_context(sample.info);
    if (sample.has_parent) {
        imgui::text("Parent event: %u", sample.parent_index);
    } else {
        imgui::text_unformatted("Root scope");
    }
}

fn void draw_gpu_axis(ProfilerPanel* panel, uint source, ulong renderer_frame) @private {
    profile::GpuSample[] samples = panel.snapshot.gpu;
    GpuIntervalSpan span = gpu_interval_span(samples, source, renderer_frame);
    imgui::text("Independent axis: 0 .. %.6f ms (measured scope extent)", span.duration_ns / NS_PER_MS);
    imgui::Vec2 origin = imgui::get_cursor_screen_pos();
    float width = math::max(imgui::get_content_region_avail().x, 1.0f);
    uint maximum_depth;
    foreach (index, sample : samples) {
        if (sample.source != source || sample.renderer_frame != renderer_frame) continue;
        uint depth = panel.depths[index];
        maximum_depth = math::max(maximum_depth, depth);
        imgui::push_id_int((int)index);
        defer imgui::pop_id();
        IntervalInteraction interaction = draw_interval(
            offset_ns: sample.start_ns - span.origin_ns,
            duration_ns: sample.duration_ns,
            span_ns: span.duration_ns,
            depth: depth,
            origin: origin,
            width: width,
            selected: scope_selected(panel, (uint)index, true),
            gpu: true,
            label: sample.label,
        );
        if (interaction.clicked) select_scope(panel, (uint)index, true);
        if (interaction.hovered && imgui::begin_tooltip()) {
            draw_gpu_inspection(sample);
            imgui::end_tooltip();
        }
    }
    imgui::set_cursor_screen_pos(origin);
    imgui::dummy({.x = width, .y = (float)(maximum_depth + 1) * imgui::get_text_line_height_with_spacing()});
}

fn bool gpu_row_visible(profile::GpuSample[] samples, sz index) @private {
    while (samples[index].has_parent) {
        index = samples[index].parent_index;
        imgui::push_id_int((int)index);
        bool open = imgui::tree_node_get_open(imgui::get_id("##event"));
        imgui::pop_id();
        if (!open) return false;
    }
    return true;
}

fn void draw_gpu_tree(ProfilerPanel* panel, uint source, ulong renderer_frame) @private {
    profile::GpuSample[] samples = panel.snapshot.gpu;
    if (!imgui::begin_table("gpu_events", 3, {.resizable = true, .row_bg = true})) return;
    defer imgui::end_table();
    imgui::table_setup_column("Scope", {});
    imgui::table_setup_column("Inclusive ms", {});
    imgui::table_setup_column("Origin / context", {});
    imgui::table_headers_row();
    foreach (index, sample : samples) {
        if (sample.source != source || sample.renderer_frame != renderer_frame) continue;
        if (!gpu_row_visible(samples, index)) continue;
        bool has_children;
        foreach (child : samples) {
            if (child.has_parent && child.parent_index == index) has_children = true;
        }
        imgui::push_id_int((int)index);
        defer imgui::pop_id();
        imgui::table_next_row();
        (void)imgui::table_next_column();
        float indent = (float)panel.depths[index] * imgui::get_tree_node_to_label_spacing();
        if (indent > 0) imgui::indent_ex(indent);
        (void)imgui::tree_node_ex("##event", {
            .no_tree_push_on_open = true,
            .leaf = !has_children,
            .open_on_arrow = true,
            .selected = scope_selected(panel, (uint)index, true),
        });
        if (imgui::is_item_clicked()) select_scope(panel, (uint)index, true);
        imgui::same_line();
        draw_label(sample.label);
        if (imgui::is_item_clicked()) select_scope(panel, (uint)index, true);
        if (imgui::is_item_hovered({}) && imgui::begin_tooltip()) {
            draw_gpu_inspection(sample);
            imgui::end_tooltip();
        }
        if (indent > 0) imgui::unindent_ex(indent);
        (void)imgui::table_next_column();
        imgui::text("%.6f", sample.duration_ns / NS_PER_MS);
        (void)imgui::table_next_column();
        draw_gpu_context(sample.info);
    }
}

fn void draw_gpu_detail(ProfilerPanel* panel) @private {
    imgui::push_id("gpu");
    defer imgui::pop_id();
    draw_gpu_status(panel.snapshot);
    profile::GpuSample[] samples = panel.snapshot.gpu;
    if (!samples.len) imgui::text_unformatted("GPU measured scope spans: N/A");
    gpu_scope_depths(samples, panel.depths);
    foreach (index, sample : samples) {
        if (!first_gpu_group(samples, index)) continue;
        imgui::push_id_int((int)sample.source);
        push_frame_id(sample.renderer_frame);
        defer {
            pop_frame_id();
            imgui::pop_id();
        }
        imgui::separator();
        imgui::text("Source %u / renderer frame %llu", sample.source, sample.renderer_frame);
        draw_gpu_axis(panel, sample.source, sample.renderer_frame);
        draw_gpu_tree(panel, sample.source, sample.renderer_frame);
    }
    if (panel.has_selected_scope && panel.selected_gpu) {
        imgui::separator_text("Selected GPU event");
        draw_gpu_inspection(samples[panel.selected_scope]);
    }
}

fn void draw_gpu_summary(ProfilerPanel* panel) @private {
    usz count = aggregate_gpu(panel.snapshot.gpu, panel.aggregates);
    if (!imgui::begin_table("gpu_summary", 5, {.row_bg = true, .resizable = true})) return;
    defer imgui::end_table();
    imgui::table_setup_column("Label", {});
    imgui::table_setup_column("Source / renderer frame", {});
    imgui::table_setup_column("Origin / context", {});
    imgui::table_setup_column("Calls", {});
    imgui::table_setup_column("Inclusive sum ms", {});
    imgui::table_headers_row();
    foreach (row : panel.aggregates[:count]) {
        profile::GpuSample sample = panel.snapshot.gpu[row.sample_index];
        imgui::table_next_row();
        (void)imgui::table_next_column();
        draw_label(sample.label);
        (void)imgui::table_next_column();
        imgui::text("%u / %llu", sample.source, sample.renderer_frame);
        (void)imgui::table_next_column();
        draw_gpu_context(sample.info);
        (void)imgui::table_next_column();
        imgui::text("%u", row.call_count);
        (void)imgui::table_next_column();
        imgui::text("%.6f", row.inclusive_ns / NS_PER_MS);
    }
}
