module c3d::test::render;

import c3d::render;
import c3d::shader;
import gpu;
import std::io;

fn gpu::DebugMessage diagnostic(ZString operation, ZString backend_text) @local {
    return {
        .severity             = gpu::DebugMessageSeverity.ERROR,
        .category             = { .validation = true },
        .operation            = operation,
        .has_fault            = true,
        .public_fault         = gpu::INVALID_HANDLE,
        .resource             = {
            .kind       = gpu::DebugResourceKind.TEXTURE,
            .index      = 7,
            .debug_name = "hdr_color",
        },
        .backend_text         = backend_text,
        .validation_id_number = 1234,
    };
}

fn String entry_text(render::DebugEntry* entry) @local {
    return ((ZString)&entry.text[0]).str_view();
}

fn void test_growth_keeps_capacity_when_demand_fits() @test {
    assert(render::grown_capacity(32, 0) == 32);
    assert(render::grown_capacity(32, 31) == 32);
    assert(render::grown_capacity(32, 32) == 32);
}

fn void test_growth_doubles_until_demand_fits() @test {
    assert(render::grown_capacity(32, 33) == 64);
    assert(render::grown_capacity(32, 64) == 64);
    assert(render::grown_capacity(32, 65) == 128);
    assert(render::grown_capacity(32, 100) == 128);
}

fn void test_growth_from_smallest_capacity_terminates() @test {
    assert(render::grown_capacity(1, 1000) == 1024);
}

fn void test_debug_entry_copies_message_fields() @test {
    render::DebugLog log;
    gpu::DebugMessage message = diagnostic("cmd_texture_barrier", "layout mismatch");
    log.record(&message);

    render::DebugEntry[1] recent;
    assert(log.recent(recent[..]) == 1);
    render::DebugEntry* entry = &recent[0];
    assert(entry.severity == gpu::DebugMessageSeverity.ERROR);
    assert(entry.category.validation);
    assert(entry.resource_kind == gpu::DebugResourceKind.TEXTURE);
    assert(entry.resource_index == 7);
    assert(entry.validation_id_number == 1234);
    assert(entry.has_fault);
    assert(entry.public_fault == gpu::INVALID_HANDLE);
    assert(((ZString)&entry.operation[0]).str_view() == "cmd_texture_barrier");
    assert(entry_text(entry) == "layout mismatch");
}

fn void test_debug_text_is_truncated_and_terminated() @test {
    char[render::DEBUG_TEXT_BYTES * 2] long_text;
    for (usz index = 0; index < long_text.len - 1; index++) long_text[index] = 'x';
    long_text[long_text.len - 1] = 0;

    render::DebugLog log;
    gpu::DebugMessage message = diagnostic("submit", (ZString)&long_text[0]);
    log.record(&message);

    render::DebugEntry[1] recent;
    assert(log.recent(recent[..]) == 1);
    assert(entry_text(&recent[0]).len == render::DEBUG_TEXT_BYTES - 1);
}

fn void test_debug_text_of_a_null_string_is_empty() @test {
    render::DebugLog log;
    gpu::DebugMessage message = diagnostic("submit", null);
    message.invariant = null;
    log.record(&message);

    render::DebugEntry[1] recent;
    assert(log.recent(recent[..]) == 1);
    assert(entry_text(&recent[0]).len == 0);
}

fn void test_debug_log_recent_before_first_wrap() @test {
    render::DebugLog log;
    @pool() {
        for (usz index = 0; index < 3; index++) {
            gpu::DebugMessage message = diagnostic("submit", string::tformat("%d", index).zstr_tcopy());
            log.record(&message);
        }
    };

    render::DebugEntry[render::DEBUG_LOG_ENTRIES] recent;
    assert(log.recent(recent[..]) == 3);
    assert(entry_text(&recent[0]) == "0");
    assert(entry_text(&recent[2]) == "2");
}

fn void test_debug_log_wraps_and_reports_recent_oldest_first() @test {
    render::DebugLog log;
    usz total = render::DEBUG_LOG_ENTRIES + 3;
    @pool() {
        for (usz index = 0; index < total; index++) {
            gpu::DebugMessage message = diagnostic("submit", string::tformat("%d", index).zstr_tcopy());
            log.record(&message);
        }
    };

    render::DebugEntry[render::DEBUG_LOG_ENTRIES] recent;
    assert(log.recent(recent[..]) == render::DEBUG_LOG_ENTRIES);
    assert(entry_text(&recent[0]) == "3");
    assert(entry_text(&recent[render::DEBUG_LOG_ENTRIES - 1]) == "66");
}

fn void test_debug_log_recent_is_limited_by_the_destination() @test {
    render::DebugLog log;
    @pool() {
        for (usz index = 0; index < 10; index++) {
            gpu::DebugMessage message = diagnostic("submit", string::tformat("%d", index).zstr_tcopy());
            log.record(&message);
        }
    };

    render::DebugEntry[2] recent;
    assert(log.recent(recent[..]) == 2);
    assert(entry_text(&recent[0]) == "8");
    assert(entry_text(&recent[1]) == "9");
}

fn void test_timestamp_slots_do_not_overlap_between_frames() @test {
    bool[render::FRAMES_IN_FLIGHT * render::PASS_COUNT * render::TIMESTAMPS_PER_PASS] claimed;
    for (ulong frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) {
        for (usz pass = 0; pass < render::PASS_COUNT; pass++) {
            uint first = render::pass_timestamp_slot(frame, pass);
            for (uint half = 0; half < render::TIMESTAMPS_PER_PASS; half++) {
                assert(!claimed[first + half]);
                claimed[first + half] = true;
            }
        }
    }
    foreach (slot : claimed) assert(slot);
}

fn void test_routine_faults_are_still_recorded_in_the_log() @test {
    render::DebugLog log;
    gpu::DebugMessage message = diagnostic("present", "swapchain is out of date");
    message.public_fault = gpu::SWAPCHAIN_OUT_OF_DATE;
    log.record(&message);

    render::DebugEntry[1] recent;
    assert(log.recent(recent[..]) == 1);
    assert(recent[0].public_fault == gpu::SWAPCHAIN_OUT_OF_DATE);
}

fn void test_flipped_viewport_covers_the_area_upside_down() @test {
    gpu::Viewport viewport = render::flipped_viewport(1280, 720);
    assert(viewport.x == 0.0f);
    assert(viewport.y == 720.0f);
    assert(viewport.width == 1280.0f);
    assert(viewport.height == -720.0f);
    assert(viewport.min_depth == 0.0f);
    assert(viewport.max_depth == 1.0f);
}

fn render::PipelineKey gradient_key() @local {
    return {
        .vertex        = { .shader = shader::ShaderName.FULLSCREEN },
        .fragment      = { .shader = shader::ShaderName.GRADIENT },
        .color_formats = { [0] = gpu::Format.RGBA16_FLOAT },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
}

fn void test_pipeline_keys_with_equal_fields_match() @test {
    render::PipelineKey first = gradient_key();
    render::PipelineKey second = gradient_key();
    assert(first.equals(second));
    assert(first.hash() == second.hash());
}

fn void test_pipeline_key_differs_by_any_field() @test {
    render::PipelineKey base = gradient_key();

    render::PipelineKey other_fragment = gradient_key();
    other_fragment.fragment = { .shader = shader::ShaderName.COMPOSITE };
    assert(!base.equals(other_fragment));

    render::PipelineKey other_format = gradient_key();
    other_format.color_formats[0] = gpu::Format.BGRA8_UNORM;
    assert(!base.equals(other_format));

    render::PipelineKey more_targets = gradient_key();
    more_targets.color_count = 2;
    assert(!base.equals(more_targets));

    render::PipelineKey with_depth = gradient_key();
    with_depth.depth_format = gpu::Format.D32_FLOAT;
    assert(!base.equals(with_depth));
}
