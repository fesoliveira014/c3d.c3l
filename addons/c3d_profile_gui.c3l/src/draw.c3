module c3d::gui @feat(C3D_PROFILE_GUI & (C3D_PROFILE_CPU | C3D_PROFILE_GPU));

import c3d::profile;
import imgui;
import std::math;

const float PANEL_WIDTH @private = 1040; // Accommodates exact frame identities and both timing columns.
const float PANEL_HEIGHT @private = 780; // Leaves room for history and a selected scope axis.
const float HISTORY_ROWS @private = 7; // Bounds history height while preserving detail space.
const float HISTORY_ROW_LINES @private = 3; // State, omitted count and span per history cell.
const float SPAN_BAR_HEIGHT_FRACTION @private = 0.25f; // Thin bar under the span text.
const float HISTORY_HEIGHT_FRACTION @private = 0.6f; // Reserves detail space in smaller viewports.
const float NS_PER_MS @private = 1_000_000;
const uint CPU_BAR_COLOR @private = 0xffb07b43;
const uint GPU_BAR_COLOR @private = 0xff779f50;
const uint SELECTED_BAR_COLOR @private = 0xff47b4e8;
const uint LABEL_COLOR @private = 0xffffffff;
const uint ID_HALF_BITS @private = 32;

struct IntervalInteraction @private {
    bool clicked;
    bool hovered;
}

fn void push_frame_id(ulong frame_id) @private {
    imgui::push_id_int((int)(uint)(frame_id >> ID_HALF_BITS));
    imgui::push_id_int((int)(uint)frame_id);
}

fn void pop_frame_id() @private {
    imgui::pop_id();
    imgui::pop_id();
}

fn void draw_label(String label) @private {
    imgui::begin_group();
    defer imgui::end_group();
    usz start;
    bool emitted;
    for (usz index = 0; index <= label.len; index++) {
        if (index < label.len && label[index] != 0) continue;
        if (index > start) {
            if (emitted) imgui::same_line_ex(0, 0);
            imgui::text_unformatted_ex((ZString)(label.ptr + start), (ZString)(label.ptr + index));
            emitted = true;
        }
        if (index < label.len) {
            if (emitted) imgui::same_line_ex(0, 0);
            imgui::text_unformatted("[NUL]");
            emitted = true;
        }
        start = index + 1;
    }
    if (!emitted) imgui::text_unformatted("(empty)");
}

fn void draw_bar_label(String label, imgui::Vec2 position) @private {
    usz start;
    for (usz index = 0; index <= label.len; index++) {
        if (index < label.len && label[index] != 0) continue;
        if (index > start) {
            ZString begin = (ZString)(label.ptr + start);
            ZString end = (ZString)(label.ptr + index);
            imgui::draw_list::add_text_ex(
                self_: imgui::get_window_draw_list(),
                pos: position,
                col: LABEL_COLOR,
                text_begin: begin,
                text_end: end,
            );
            position.x += imgui::calc_text_size_ex(
                text: begin,
                text_end: end,
                hide_text_after_double_hash: false,
                wrap_width: -1,
            ).x;
        }
        if (index < label.len) {
            imgui::draw_list::add_text(
                self_: imgui::get_window_draw_list(),
                pos: position,
                col: LABEL_COLOR,
                text_begin: "[NUL]",
            );
            position.x += imgui::calc_text_size("[NUL]").x;
        }
        start = index + 1;
    }
}

fn void draw_state(profile::CaptureState state) @private {
    switch (state) {
        case PENDING: imgui::text_colored({.x = 1, .y = 0.8f, .z = 0.3f, .w = 1}, "Pending");
        case READY: imgui::text_colored({.x = 0.5f, .y = 1, .z = 0.5f, .w = 1}, "Ready");
        case TRUNCATED: imgui::text_colored({.x = 1, .y = 0.7f, .z = 0.3f, .w = 1}, "Truncated");
        case ABORTED: imgui::text_colored({.x = 1, .y = 0.4f, .z = 0.4f, .w = 1}, "Aborted");
        case UNAVAILABLE: imgui::text_disabled("Unavailable");
    }
}

fn void draw_origin(profile::ScopeOrigin origin) @private {
    switch (origin) {
        case APPLICATION: imgui::text_unformatted("Application");
        case LIBRARY: imgui::text_unformatted("Library");
    }
}

fn void draw_cpu_status(profile::FrameCaptureView frame) @private {
    draw_state(frame.cpu_state);
    imgui::text("Omitted scopes: %u", frame.dropped_cpu_scopes);
    if (frame.truncated) imgui::text_unformatted("Partial counts (truncated)");
}

fn void draw_span(
    bool available,
    double duration_ns,
    double maximum_ns,
    bool pending,
) @private {
    if (!available) {
        imgui::text_unformatted("N/A");
        return;
    }
    imgui::text("%.6f ms measured scope span", duration_ns / NS_PER_MS);
    if (pending) imgui::text_unformatted("Partial completed prefix");
    float fraction = maximum_ns > 0 ? (float)(duration_ns / maximum_ns) : 0;
    imgui::progress_bar(fraction, {.x = -1, .y = imgui::get_text_line_height() * SPAN_BAR_HEIGHT_FRACTION}, "");
}

fn void draw_history(ProfilerPanel* panel) @private {
    bool newest = imgui::button("Newest history entry");
    double cpu_maximum @if($feat(C3D_PROFILE_CPU));
    double gpu_maximum @if($feat(C3D_PROFILE_GPU));
    profile::FrameCaptureView[] history = panel.history[:panel.frame_count];
    foreach (index, frame_id : panel.frame_ids[:panel.frame_count]) {
        history[index] = panel.recorder.frame(frame_id)!!;
        profile::FrameCaptureView frame = history[index];
        $if $feat(C3D_PROFILE_CPU):
            cpu_maximum = math::max(cpu_maximum, cpu_interval_span(frame.cpu).duration_ns);
        $endif
        $if $feat(C3D_PROFILE_GPU):
            foreach (sample_index, sample : frame.gpu) {
                if (!first_gpu_group(frame.gpu, sample_index)) continue;
                gpu_maximum = math::max(gpu_maximum,
                  gpu_interval_span(frame.gpu, sample.source, sample.renderer_frame).duration_ns);
            }
        $endif
    }
    float history_height = math::min(imgui::get_text_line_height_with_spacing() * HISTORY_ROWS * HISTORY_ROW_LINES,
      math::max(imgui::get_content_region_avail().y * HISTORY_HEIGHT_FRACTION, 1.0f));
    if (!imgui::begin_table_ex(
        str_id: "history",
        columns: 3,
        flags: {.row_bg = true, .resizable = true, .scroll_y = true},
        outer_size: {.x = 0, .y = history_height},
        inner_width: 0,
    )) return;
    defer imgui::end_table();
    imgui::table_setup_column("Application frame", {});
    imgui::table_setup_column("CPU", {});
    imgui::table_setup_column("GPU (each source / renderer frame)", {});
    imgui::table_setup_scroll_freeze(0, 1);
    imgui::table_headers_row();
    foreach (index, frame_id : panel.frame_ids[:panel.frame_count]) {
        imgui::table_next_row();
        push_frame_id(frame_id);
        defer pop_frame_id();
        (void)imgui::table_next_column();
        if (imgui::selectable_ex(
            label: "##frame",
            selected: panel.has_snapshot && panel.snapshot.frame_id == frame_id,
            flags: {},
            size: {.x = imgui::get_font_size(), .y = imgui::get_text_line_height()},
        )) select_frame(panel, frame_id)!!;
        imgui::same_line();
        imgui::text("%llu", frame_id);
        if (imgui::is_item_clicked()) select_frame(panel, frame_id)!!;
        if (newest && (usz)index + 1 == panel.frame_count) imgui::set_scroll_here_y(1);
        profile::FrameCaptureView frame = history[index];
        (void)imgui::table_next_column();
        draw_cpu_status(frame);
        $if $feat(C3D_PROFILE_CPU):
            CpuIntervalSpan cpu_span = cpu_interval_span(frame.cpu);
            draw_span(
                available: cpu_span.available,
                duration_ns: cpu_span.duration_ns,
                maximum_ns: cpu_maximum,
                pending: frame.cpu_state == profile::CaptureState.PENDING,
            );
        $else
            imgui::text_unformatted("Not compiled / N/A");
        $endif
        (void)imgui::table_next_column();
        $if $feat(C3D_PROFILE_GPU):
            draw_gpu_status(frame);
            if (!frame.gpu.len) imgui::text_unformatted("N/A");
            foreach (sample_index, sample : frame.gpu) {
                if (!first_gpu_group(frame.gpu, sample_index)) continue;
                imgui::text("Source %u / frame %llu", sample.source, sample.renderer_frame);
                GpuIntervalSpan span = gpu_interval_span(frame.gpu, sample.source, sample.renderer_frame);
                draw_span(
                    available: span.available,
                    duration_ns: span.duration_ns,
                    maximum_ns: gpu_maximum,
                    pending: frame.gpu_state == profile::CaptureState.PENDING,
                );
            }
        $else
            imgui::text_unformatted("Not compiled / N/A");
        $endif
    }
}

fn void select_scope(ProfilerPanel* panel, uint index, bool gpu) @private {
    pause_panel(panel);
    panel.has_selected_scope = true;
    panel.selected_scope = index;
    panel.selected_gpu = gpu;
}

fn bool scope_selected(ProfilerPanel* panel, uint index, bool gpu) @private {
    return panel.has_selected_scope && panel.selected_scope == index && panel.selected_gpu == gpu;
}

fn void draw_cpu_inspection(profile::CpuSample sample) @private @feat(C3D_PROFILE_CPU) {
    draw_label(sample.label);
    draw_origin(sample.origin);
    imgui::text("Inclusive: %.6f ms", (double)sample.duration_ns / NS_PER_MS);
    imgui::text("Self: %.6f ms", (double)sample.self_ns / NS_PER_MS);
    imgui::text_unformatted(sample.self_complete ? "Self complete" : "Self upper bound (incomplete)");
    imgui::text("Capture offset: %llu ns", sample.start_ns);
    if (sample.has_parent) {
        imgui::text("Parent event: %u", sample.parent_index);
    } else {
        imgui::text_unformatted("Root scope");
    }
}

fn IntervalInteraction draw_interval(
    double offset_ns,
    double duration_ns,
    double span_ns,
    uint depth,
    imgui::Vec2 origin,
    float width,
    bool selected,
    bool gpu,
    String label,
) @private {
    float row_height = imgui::get_text_line_height_with_spacing();
    float left = span_ns > 0 ? (float)(offset_ns / span_ns) * width : 0;
    left = math::min(left, width - 1);
    float right = span_ns > 0 ? (float)((offset_ns + duration_ns) / span_ns) * width : 0;
    imgui::Vec2 minimum = {.x = origin.x + left, .y = origin.y + (float)depth * row_height};
    imgui::Vec2 maximum = {
        .x = math::min(origin.x + width, minimum.x + math::max(right - left, 1.0f)),
        .y = minimum.y + imgui::get_text_line_height(),
    };
    imgui::set_cursor_screen_pos(minimum);
    bool clicked = imgui::invisible_button("interval", {.x = math::max(maximum.x - minimum.x, 1.0f),
      .y = row_height}, {});
    bool hovered = imgui::is_item_hovered({});
    imgui::draw_list::add_rect_filled(
        self_: imgui::get_window_draw_list(),
        p_min: minimum,
        p_max: maximum,
        col: selected ? SELECTED_BAR_COLOR : (gpu ? GPU_BAR_COLOR : CPU_BAR_COLOR),
    );
    imgui::push_clip_rect(minimum, maximum, true);
    draw_bar_label(label, minimum);
    imgui::pop_clip_rect();
    return {.clicked = clicked, .hovered = hovered};
}

fn void draw_cpu_axis(ProfilerPanel* panel) @private @feat(C3D_PROFILE_CPU) {
    profile::CpuSample[] samples = panel.snapshot.cpu;
    CpuIntervalSpan span = cpu_interval_span(samples);
    if (!span.available) {
        imgui::text_unformatted("CPU measured scope span: N/A");
        return;
    }
    imgui::text("CPU axis: 0 .. %.6f ms (measured scope extent)", span.duration_ns / NS_PER_MS);
    cpu_scope_depths(samples, panel.depths);
    imgui::Vec2 origin = imgui::get_cursor_screen_pos();
    float width = math::max(imgui::get_content_region_avail().x, 1.0f);
    uint maximum_depth;
    foreach (index, sample : samples) {
        uint depth = panel.depths[index];
        maximum_depth = math::max(maximum_depth, depth);
        imgui::push_id_int((int)index);
        defer imgui::pop_id();
        IntervalInteraction interaction = draw_interval(
            offset_ns: (double)(sample.start_ns - span.origin_ns),
            duration_ns: (double)sample.duration_ns,
            span_ns: span.duration_ns,
            depth: depth,
            origin: origin,
            width: width,
            selected: scope_selected(panel, (uint)index, false),
            gpu: false,
            label: sample.label,
        );
        if (interaction.clicked) select_scope(panel, (uint)index, false);
        if (interaction.hovered && imgui::begin_tooltip()) {
            draw_cpu_inspection(sample);
            imgui::end_tooltip();
        }
    }
    imgui::set_cursor_screen_pos(origin);
    imgui::dummy({.x = width, .y = (float)(maximum_depth + 1) * imgui::get_text_line_height_with_spacing()});
}

fn bool cpu_row_visible(profile::CpuSample[] samples, sz index) @private @feat(C3D_PROFILE_CPU) {
    while (samples[index].has_parent) {
        index = samples[index].parent_index;
        imgui::push_id_int((int)index);
        bool open = imgui::tree_node_get_open(imgui::get_id("##event"));
        imgui::pop_id();
        if (!open) return false;
    }
    return true;
}

fn void draw_cpu_tree(ProfilerPanel* panel) @private @feat(C3D_PROFILE_CPU) {
    profile::CpuSample[] samples = panel.snapshot.cpu;
    if (!imgui::begin_table("cpu_events", 4, {.resizable = true, .row_bg = true})) return;
    defer imgui::end_table();
    imgui::table_setup_column("Scope", {});
    imgui::table_setup_column("Origin", {});
    imgui::table_setup_column("Inclusive ms", {});
    imgui::table_setup_column("Self ms / completeness", {});
    imgui::table_headers_row();
    foreach (index, sample : samples) {
        if (!cpu_row_visible(samples, index)) continue;
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
            .selected = scope_selected(panel, (uint)index, false),
        });
        if (imgui::is_item_clicked()) select_scope(panel, (uint)index, false);
        imgui::same_line();
        draw_label(sample.label);
        if (imgui::is_item_clicked()) select_scope(panel, (uint)index, false);
        if (imgui::is_item_hovered({}) && imgui::begin_tooltip()) {
            draw_cpu_inspection(sample);
            imgui::end_tooltip();
        }
        if (indent > 0) imgui::unindent_ex(indent);
        (void)imgui::table_next_column();
        draw_origin(sample.origin);
        (void)imgui::table_next_column();
        imgui::text("%.6f", (double)sample.duration_ns / NS_PER_MS);
        (void)imgui::table_next_column();
        imgui::text("%.6f", (double)sample.self_ns / NS_PER_MS);
        imgui::text_unformatted(sample.self_complete ? "Complete" : "Upper bound");
    }
}

fn void draw_cpu_summary(ProfilerPanel* panel) @private @feat(C3D_PROFILE_CPU) {
    usz count = aggregate_cpu(panel.snapshot.cpu, panel.aggregates);
    if (!imgui::begin_table("cpu_summary", 5, {.row_bg = true, .resizable = true})) return;
    defer imgui::end_table();
    imgui::table_setup_column("Label", {});
    imgui::table_setup_column("Origin", {});
    imgui::table_setup_column("Calls", {});
    imgui::table_setup_column("Inclusive sum ms", {});
    imgui::table_setup_column("Self sum ms", {});
    imgui::table_headers_row();
    foreach (row : panel.aggregates[:count]) {
        profile::CpuSample sample = panel.snapshot.cpu[row.sample_index];
        imgui::table_next_row();
        (void)imgui::table_next_column();
        draw_label(sample.label);
        (void)imgui::table_next_column();
        draw_origin(sample.origin);
        (void)imgui::table_next_column();
        imgui::text("%u", row.call_count);
        (void)imgui::table_next_column();
        imgui::text("%.6f", row.inclusive_ns / NS_PER_MS);
        (void)imgui::table_next_column();
        imgui::text("%.6f", row.self_ns / NS_PER_MS);
        imgui::text_unformatted(row.self_complete ? "Complete" : "Upper bound");
    }
}

<*
 Draw live history and owned profiler details in the active frame.
 @param [&inout] panel : "Panel on its recorder's owning thread."
 @require imgui::get_current_context() != null
*>
fn void profiler_panel(ProfilerPanel* panel) {
    refresh_panel(panel);
    imgui::Viewport* viewport = imgui::get_main_viewport();
    if (viewport.work_size.x <= 0 || viewport.work_size.y <= 0) return;
    imgui::Vec2 initial_size = {
        .x = math::min(PANEL_WIDTH, viewport.work_size.x),
        .y = math::min(PANEL_HEIGHT, viewport.work_size.y),
    };
    imgui::set_next_window_size(initial_size, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_pos({
        .x = viewport.work_pos.x + (viewport.work_size.x - initial_size.x) * 0.5f,
        .y = viewport.work_pos.y + (viewport.work_size.y - initial_size.y) * 0.5f,
    }, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size_constraints(
        size_min: {},
        size_max: viewport.work_size,
        custom_callback: null,
        custom_callback_data: null,
    );
    bool visible = imgui::begin("Profiler", null, {});
    defer imgui::end();
    imgui::Vec2 position = imgui::get_window_pos();
    imgui::Vec2 size = imgui::get_window_size();
    imgui::Vec2 fitted_position = {
        .x = math::clamp(position.x, viewport.work_pos.x,
          viewport.work_pos.x + math::max(viewport.work_size.x - size.x, 0.0f)),
        .y = math::clamp(position.y, viewport.work_pos.y,
          viewport.work_pos.y + math::max(viewport.work_size.y - size.y, 0.0f)),
    };
    if (fitted_position.x != position.x || fitted_position.y != position.y) {
        imgui::set_window_pos(fitted_position, imgui::COND_ALWAYS);
    }
    if (!visible) return;
    imgui::push_id_ptr(panel);
    defer imgui::pop_id();
    if (panel.following) {
        imgui::text_unformatted("Live");
        imgui::same_line();
        imgui::begin_disabled(!panel.has_snapshot);
        if (imgui::button("Pause")) pause_panel(panel);
        imgui::end_disabled();
    } else {
        imgui::text_unformatted("Frozen snapshot (counters reflect selection time)");
        if (imgui::button("Resume")) resume_panel(panel);
        imgui::same_line();
        if (imgui::button("Reselect source frame")) {
            if (catch excuse = select_frame(panel, panel.snapshot.frame_id)) {
                panel.source_evicted = true;
            }
        }
    }
    imgui::text_unformatted(panel.recorder.enabled ? "Collection enabled" : "Collection disabled");
    imgui::text("Compiled domains: CPU %s / GPU %s",
      $feat(C3D_PROFILE_CPU) ? "yes" : "no", $feat(C3D_PROFILE_GPU) ? "yes" : "no");
    imgui::same_line();
    imgui::text("/ INTERNAL %s", $feat(C3D_PROFILE_INTERNAL) ? "yes" : "no");
    $if $feat(C3D_PROFILE_GPU):
        imgui::text("Recorder dropped frames: %llu", panel.recorder.dropped_frames);
    $else
        imgui::text_unformatted("Recorder dropped frames: 0");
    $endif
    if (panel.has_snapshot) imgui::text("Application frame: %llu", panel.snapshot.frame_id);
    if (panel.source_evicted) imgui::text_unformatted("Source frame was evicted; frozen snapshot preserved");
    draw_history(panel);
    if (!panel.has_snapshot) {
        imgui::text_unformatted("No settled capture. Select any retained pending frame to inspect it.");
        return;
    }
    imgui::text_unformatted("Axes fit recorded scope extents; clocks are independent.");
    if (!imgui::begin_tab_bar("details", {})) return;
    defer imgui::end_tab_bar();
    if (imgui::begin_tab_item("CPU", null, {})) {
        defer imgui::end_tab_item();
        push_frame_id(panel.snapshot.frame_id);
        defer pop_frame_id();
        imgui::push_id("cpu");
        defer imgui::pop_id();
        draw_cpu_status(panel.snapshot);
        $if $feat(C3D_PROFILE_CPU):
            draw_cpu_axis(panel);
            draw_cpu_tree(panel);
            if (panel.has_selected_scope && !panel.selected_gpu) {
                imgui::separator_text("Selected CPU event");
                draw_cpu_inspection(panel.snapshot.cpu[panel.selected_scope]);
            }
        $else
            imgui::text_unformatted("CPU not compiled / N/A");
        $endif
    }
    if (imgui::begin_tab_item("GPU", null, {})) {
        defer imgui::end_tab_item();
        push_frame_id(panel.snapshot.frame_id);
        defer pop_frame_id();
        $if $feat(C3D_PROFILE_GPU):
            draw_gpu_detail(panel);
        $else
            imgui::text_unformatted("GPU not compiled / N/A");
        $endif
    }
    if (imgui::begin_tab_item("Summary", null, {})) {
        defer imgui::end_tab_item();
        push_frame_id(panel.snapshot.frame_id);
        defer pop_frame_id();
        imgui::text_unformatted("Selected snapshot only. Inclusive sums may overlap.");
        imgui::separator_text("CPU");
        draw_cpu_status(panel.snapshot);
        $if $feat(C3D_PROFILE_CPU):
            draw_cpu_summary(panel);
        $else
            imgui::text_unformatted("CPU not compiled / N/A");
        $endif
        imgui::separator_text("GPU");
        $if $feat(C3D_PROFILE_GPU):
            draw_gpu_status(panel.snapshot);
            draw_gpu_summary(panel);
        $else
            imgui::text_unformatted("GPU not compiled / N/A");
        $endif
    }
}
