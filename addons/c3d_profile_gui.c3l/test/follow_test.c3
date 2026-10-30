module c3d_profile_gui_follow_test @feat(C3D_PROFILE_GUI & C3D_PROFILE_CPU);

import c3d::profile @public;
import c3d::gui @public;
import imgui;

const uint FOLLOWED_FRAMES @private = 10;
const ulong FIRST_FRAME_ID @private = 100;
const ulong ORIGIN_NS @private = 1_000;
const uint CPU_TABLE_STACK_DEPTH @private = 5; // Panel, tab bar, tab item, "cpu" and the table.

fn RecorderDesc follow_desc() @private {
    RecorderDesc desc = {
        .frame_capacity = 4,
        .label_bytes_per_frame = 128,
        .cpu_scopes_per_frame = 8,
        .max_depth = 4,
    };
    return desc;
}

fn void record_scope(
    Recorder* recorder,
    String label,
    ulong start_ns,
    ulong end_ns,
) @private {
    ScopeToken scope = profile::begin_cpu_scope_at(
        recorder: recorder,
        label: label,
        origin: ScopeOrigin.APPLICATION,
        start_ns: start_ns,
    );
    profile::end_cpu_scope_at(recorder, scope, end_ns);
}

fn void record_frame(Recorder* recorder, ulong frame_id, bool post_first) @private {
    CaptureBinding binding = profile::begin_capture_at(recorder, frame_id, ORIGIN_NS);
    if (post_first) record_scope(recorder, "post", 1_000, 1_100);
    ScopeToken render = profile::begin_cpu_scope_at(
        recorder: recorder,
        label: "render",
        origin: ScopeOrigin.APPLICATION,
        start_ns: 1_200,
    );
    record_scope(recorder, "draw", 1_210, 1_300);
    record_scope(recorder, "draw", 1_310, 1_400);
    profile::end_cpu_scope_at(recorder, render, 1_500);
    if (!post_first) record_scope(recorder, "post", 1_500, 1_600);
    profile::end_capture(recorder, binding, false);
}

fn imgui::Context create_headless_context() @private {
    imgui::Context context = imgui::create_context((imgui::FontAtlas)null);
    assert(context != null);
    imgui::set_current_context(context);
    imgui::io_set_ini_filename(null);
    imgui::io_set_display_size(1200, 1000);
    imgui::io_set_delta_time(1.0f / 60);
    assert(imgui::fonts_build(imgui::io_get_fonts()));
    return context;
}

fn sz scope_index(ProfilerPanel* panel, String label, uint occurrence = 0) @private {
    uint seen;
    foreach (index, sample : panel.snapshot.cpu) {
        if (sample.label != label) continue;
        if (seen++ == occurrence) return index;
    }
    unreachable("Recorded scope missing from the snapshot.");
}

fn imgui::Id open_cpu_table_stack(ProfilerPanel* panel) @private {
    assert(imgui::begin("Profiler", null, {}));
    imgui::push_id_ptr(panel);
    // ImGui pushes the ids of the tab bar and the selected tab itself.
    imgui::internal::push_override_id(imgui::get_id("details"));
    imgui::internal::push_override_id(imgui::get_id("CPU"));
    imgui::push_id("cpu");
    imgui::Id table_id = imgui::get_id("cpu_events");
    imgui::internal::push_override_id(table_id);
    return table_id;
}

fn void close_cpu_table_stack() @private {
    for (uint depth = 0; depth < CPU_TABLE_STACK_DEPTH; depth++) imgui::pop_id();
    imgui::end();
}

fn void open_scope(ProfilerPanel* panel, sz index) @private {
    ScopePath path = gui::push_cpu_scope_path(panel.snapshot.cpu, index);
    defer gui::pop_scope_path(path);
    assert(path.visible);
    imgui::storage::set_int(imgui::get_state_storage(), imgui::get_id("##event"), 1);
}

fn bool scope_open(ProfilerPanel* panel, sz index) @private {
    ScopePath path = gui::push_cpu_scope_path(panel.snapshot.cpu, index);
    defer gui::pop_scope_path(path);
    return path.visible && imgui::tree_node_get_open(imgui::get_id("##event"));
}

fn void test_followed_panel_keeps_its_tables_and_open_scopes() @test {
    Recorder recorder = profile::create_recorder(mem, follow_desc())!!;
    defer profile::destroy_recorder(&recorder);
    ProfilerPanel panel = gui::create_profiler_panel(mem, &recorder)!!;
    defer gui::destroy_profiler_panel(&panel);
    imgui::Context context = create_headless_context();
    defer imgui::destroy_context(context);

    imgui::internal::Table first_table;
    for (uint step = 0; step < FOLLOWED_FRAMES; step++) {
        record_frame(&recorder, FIRST_FRAME_ID + step, step % 2 == 1);
        imgui::new_frame();
        gui::profiler_panel(&panel);
        assert(panel.following && panel.snapshot.frame_id == FIRST_FRAME_ID + step);

        imgui::Id table_id = open_cpu_table_stack(&panel);
        imgui::internal::Table table = imgui::internal::table_find_by_id(table_id);
        assert(table != null);
        sz render = scope_index(&panel, "render");
        sz first_draw = scope_index(&panel, "draw", 0);
        sz second_draw = scope_index(&panel, "draw", 1);
        if (step == 0) {
            first_table = table;
            open_scope(&panel, render);
            open_scope(&panel, second_draw);
        } else {
            assert(table == first_table);
            assert(scope_open(&panel, render));
            assert(scope_open(&panel, second_draw));
            assert(!scope_open(&panel, first_draw));
        }
        close_cpu_table_stack();
        imgui::render();
    }
}
