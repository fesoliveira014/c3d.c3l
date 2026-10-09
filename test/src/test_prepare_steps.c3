module c3d::test::prepare_steps;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::pool;
import c3d::render @public;
import c3d::shader;
import gpu;

fn Renderer cursor_renderer() @local {
    Renderer renderer = { .allocator = mem,
        .prepares = pool::create_pool{PrepareRecord, PrepareId}(mem, render::PREPARE_CAPACITY) };
    renderer.pending_prepare_installs.init(mem);
    renderer.pending_prepare_retire.init(mem);
    renderer.pending_upload_retire.init(mem);
    return renderer;
}

fn void destroy_cursor_renderer(Renderer* renderer) @local {
    render::free_prepares(renderer);
    renderer.pending_upload_retire.free();
}

fn PrepareId cursor_record(Renderer* renderer, uint units) @local {
    PrepareRecord record = { .units = alloc::new_array(mem, PrepareUnit, units), .open = true,
        .epoch = 1, .state = PrepareState.PENDING };
    PrepareId id = renderer.prepares.add(record)!!;
    render::bind_prepare_record(renderer, id);
    return id;
}

fn void test_strict_axes_stop_without_reinterpreting_depleted_zero() @test {
    PrepareBudget bytes = { .limits = { .staged_bytes = 16 }, .report = { .staged_bytes = 16 } };
    assert(render::prepare_byte_allowance(&bytes) == 0);
    assert(render::prepare_step_stop(&bytes, { .staged_bytes = 1 }, 0) == PrepareStopReason.STAGED_BYTES);
    PrepareBudget texels = { .limits = { .generated_texels = 9 }, .report = { .generated_texels = 9 } };
    assert(render::prepare_step_stop(&texels, { .generated_texels = 1 }, 0) == PrepareStopReason.GENERATED_TEXELS);
    PrepareBudget pipelines = { .limits = { .pipelines = 2 }, .report = { .pipelines = 2 } };
    assert(render::prepare_step_stop(&pipelines, { .pipelines = 1 }, 0) == PrepareStopReason.PIPELINES);
    assert(bytes.report.staged_bytes == 16 && texels.report.generated_texels == 9 && pipelines.report.pipelines == 2);
}

fn void test_zero_axes_are_unbounded_and_each_call_has_fresh_allowance() @test {
    PrepareBudget disabled;
    assert(render::prepare_step_stop(&disabled, { .staged_bytes = usz::max,
        .generated_texels = ulong::max, .pipelines = uint::max }, ulong::max) == PrepareStopReason.NONE);
    PrepareBudget previous = { .limits = { .staged_bytes = 16 }, .report = { .staged_bytes = 16 } };
    PrepareBudget next = { .limits = { .staged_bytes = 16 } };
    assert(render::prepare_byte_allowance(&previous) == 0 && render::prepare_byte_allowance(&next) == 16);
    assert(render::prepare_step_stop(&next, { .staged_bytes = 16 }, 0) == PrepareStopReason.NONE);
}

fn void test_legacy_admits_only_one_oversized_minimum_after_zero_byte_work() @test {
    PrepareBudget budget = { .limits = { .staged_bytes = 1 }, .legacy = true };
    assert(render::prepare_step_stop(&budget, {}, 0) == PrepareStopReason.NONE);
    assert(render::prepare_step_stop(&budget, { .staged_bytes = 16 }, 0) == PrepareStopReason.NONE);
    budget.report.staged_bytes = 16;
    budget.legacy_step = true;
    assert(render::prepare_step_stop(&budget, { .staged_bytes = 16 }, 0) == PrepareStopReason.STAGED_BYTES);
    PrepareBudget zero = { .legacy = true };
    assert(render::prepare_byte_allowance(&zero) == 0);
    assert(render::prepare_step_stop(&zero, { .staged_bytes = 16 }, 0) == PrepareStopReason.NONE);
    zero.report.staged_bytes = 16;
    assert(render::prepare_step_stop(&zero, { .staged_bytes = 16 }, 0) == PrepareStopReason.STAGED_BYTES);
}

fn void test_atomic_adoption_requires_true_pipeline_count_and_legacy_admits_it() @test {
    PrepareBudget strict = { .limits = { .pipelines = 3 } };
    PrepareStepCost adoption = { .pipelines = 4 };
    assert(render::prepare_step_stop(&strict, adoption, 0) == PrepareStopReason.PIPELINES);
    strict.limits.pipelines = 4;
    assert(render::prepare_step_stop(&strict, adoption, 0) == PrepareStopReason.NONE);
    strict.limits.pipelines = 3;
    strict.legacy = true;
    assert(render::prepare_step_stop(&strict, adoption, 0) == PrepareStopReason.NONE);
}

fn void test_cooperative_deadline_is_checked_between_steps() @test {
    PrepareBudget budget = { .limits = { .time_ns = 100 } };
    assert(render::prepare_step_stop(&budget, {}, 99) == PrepareStopReason.NONE);
    assert(render::prepare_step_stop(&budget, {}, 100) == PrepareStopReason.TIME);
    assert(render::prepare_step_stop(&budget, { .staged_bytes = 16 }, 101) == PrepareStopReason.TIME);
    budget.limits.time_ns = 0;
    assert(render::prepare_step_stop(&budget, {}, ulong::max) == PrepareStopReason.NONE);
}

fn void test_first_checkpoint_survives_multiple_advances_and_commit_sets_new_baseline() @test {
    Renderer renderer = cursor_renderer();
    defer destroy_cursor_renderer(&renderer);
    PrepareId id = cursor_record(&renderer, 1);
    PrepareRecord* record = renderer.prepares.get(id);
    PrepareUnit* unit = &record.units[0];
    unit.kind = PrepareUnitKind.GEOMETRY;
    unit.bytes = 64;
    unit.staged.bytes = 16;
    record.bytes_total = 64;
    renderer.frame_index = 3;
    render::checkpoint_prepare_unit(&renderer, record, unit);
    unit.staged.bytes = 32;
    render::checkpoint_prepare_unit(&renderer, record, unit);
    unit.staged.bytes = 48;
    render::rollback_prepare_cursors(&renderer, record);
    assert(unit.staged.bytes == 16 && record.bytes_done == 16 && !unit.done);
    render::checkpoint_prepare_unit(&renderer, record, unit);
    unit.staged.bytes = 32;
    render::commit_prepare_cursors(record);
    renderer.frame_index++;
    render::checkpoint_prepare_unit(&renderer, record, unit);
    unit.staged.bytes = 64;
    unit.done = true;
    render::rollback_prepare_cursors(&renderer, record);
    assert(unit.staged.bytes == 32 && record.bytes_done == 32 && record.units_done == 0);
}

fn void test_abort_keeps_only_active_chain_and_rolls_finalized_unit_back_for_regeneration() @test {
    Renderer renderer = cursor_renderer();
    defer destroy_cursor_renderer(&renderer);
    PrepareId id = cursor_record(&renderer, 3);
    PrepareRecord* record = renderer.prepares.get(id);
    PrepareUnit* finalized = &record.units[0];
    PrepareUnit* active = &record.units[1];
    finalized.bytes = 64;
    finalized.texels = 16;
    finalized.staged.bytes = 16;
    active.bytes = 64;
    active.texels = 16;
    record.units[2].kind = PrepareUnitKind.SHADER;
    record.bytes_total = 128;
    record.texels_total = 32;
    render::checkpoint_prepare_unit(&renderer, record, finalized);
    finalized.staged.bytes = 64;
    finalized.generated_done = 16;
    finalized.done = true;
    render::checkpoint_prepare_unit(&renderer, record, active);
    active.staged.bytes = 16;
    active.generated_done = 8;
    record.units[2].done = true;
    record.chain = render::create_generated_texture_mips(mem, material::texture_2d_desc(4, 4, RGBA8_UNORM))!!;
    record.chain.pixels[..] = (char)99;
    record.chain_active = true;
    record.chain_unit = 1;
    record.generation_outputs = 3;
    char* retained = record.chain.pixels.ptr;
    render::rollback_prepare_cursors(&renderer, record);
    assert(!finalized.done && finalized.staged.bytes == 16 && finalized.generated_done == 0);
    assert(!active.done && active.staged.bytes == 0 && active.generated_done == 8);
    assert(record.chain_active && record.chain.pixels.ptr == retained && record.chain.pixels[0] == 99);
    assert(record.generation_outputs == 3 && record.texels_done == 8);
    assert(record.units[2].done && record.units_done == 1 && record.bytes_done == 16);
}

fn void test_aborted_recording_restores_ring_checkpoint_even_without_ordinary_queues() @test {
    Renderer renderer = cursor_renderer();
    defer destroy_cursor_renderer(&renderer);
    renderer.frames[0].upload.head = 32;
    renderer.frames[0].upload.demand = 48;
    render::checkpoint_prepare_uploads(&renderer);
    renderer.frames[0].upload.head = 96;
    renderer.frames[0].upload.demand = 112;
    render::checkpoint_prepare_uploads(&renderer);
    renderer.frames[0].upload.head = 160;
    renderer.frames[0].upload.demand = 176;
    render::discard_uploads(&renderer);
    assert(renderer.frames[0].upload.head == 32 && renderer.frames[0].upload.demand == 48);
    assert(!renderer.prepare_upload_checkpoint.active);
}

fn void test_shader_cpu_spans_are_owned_separate_and_first_use_has_zero_adoption_keys() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        AssetStore assets = asset::create_asset_store(&tracker, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&assets);
        char[] fragment = alloc::new_array(&tracker, char, (sz)(2 * render::PREPARE_SPAN_BYTES + 17));
        defer alloc::free(&tracker, fragment.ptr);
        foreach (index, &value : fragment) *value = (char)(index % 251);
        asset::ShaderDesc desc = { .fragment = fragment };
        ShaderId shader = assets.add_shader(&desc)!!;
        Renderer renderer = { .allocator = &tracker, .assets = &assets,
            .shaders = alloc::new_array(&tracker, ShaderRes, assets.shaders.items.len),
            .pipelines = render::create_pipeline_cache(&tracker, shader::BUILTIN_REGISTRY) };
        renderer.pending_prepare_retire.init(&tracker);
        defer renderer.pending_prepare_retire.free();
        defer render::destroy_pipeline_cache(&renderer.device, &renderer.pipelines);
        defer render::free_shaders(&renderer);
        PrepareUnit unit = { .kind = PrepareUnitKind.SHADER, .shader = shader, .revision = 1 };
        defer render::free_prepare_shader_unit(&renderer, &unit);
        PrepareBudget budget;
        PrepareReport report;
        usz[3] expected = { render::PREPARE_SPAN_BYTES, render::PREPARE_SPAN_BYTES, 17 };
        foreach (bytes : expected) {
            assert(render::prepare_shader_cost(&renderer, &unit, &budget)!!.pipelines == 0);
            ulong before = report.copied_bytes;
            assert(!render::run_prepare_shader_step(&renderer, &unit, &report)!!);
            assert(report.copied_bytes - before == bytes && report.staged_bytes == 0 && report.pipelines == 0);
        }
        assert(render::prepare_shader_cost(&renderer, &unit, &budget)!!.pipelines == 0);
        assert(render::run_prepare_shader_step(&renderer, &unit, &report)!!);
        assert(renderer.shaders[shader.index].desc.fragment.ptr != assets.shader(shader).desc.fragment.ptr);
        assert(renderer.shaders[shader.index].desc.fragment.len == fragment.len);
        foreach (index, value : fragment) assert(renderer.shaders[shader.index].desc.fragment[index] == value);
        assert(report.staged_bytes == 0 && report.pipelines == 0 && report.copied_bytes == fragment.len);
    }
    assert(!tracker.has_leaks());
}
