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

fn void test_prepare_axes_stop_independently_and_zero_is_unbounded() @test {
    PrepareBudget bytes = { .limits = { .staged_bytes = 16 }, .report = { .staged_bytes = 16 } };
    PrepareBudget fresh = { .limits = { .staged_bytes = 16 } };
    assert(render::prepare_byte_allowance(&bytes) == 0 && render::prepare_byte_allowance(&fresh) == 16);
    assert(render::prepare_step_stop(&bytes, { .staged_bytes = 1 }, 0) == PrepareStopReason.STAGED_BYTES);
    assert(render::prepare_step_stop(&fresh, { .staged_bytes = 16 }, 0) == PrepareStopReason.NONE);
    PrepareBudget texels = { .limits = { .generated_texels = 9 }, .report = { .generated_texels = 9 } };
    assert(render::prepare_step_stop(&texels, { .generated_texels = 1 }, 0) == PrepareStopReason.GENERATED_TEXELS);
    PrepareBudget pipelines = { .limits = { .pipelines = 3 } };
    assert(render::prepare_step_stop(&pipelines, { .pipelines = 4 }, 0) == PrepareStopReason.PIPELINES);
    pipelines.limits.pipelines = 4;
    assert(render::prepare_step_stop(&pipelines, { .pipelines = 4 }, 0) == PrepareStopReason.NONE);
    PrepareBudget deadline = { .limits = { .time_ns = 100 } };
    assert(render::prepare_step_stop(&deadline, {}, 99) == PrepareStopReason.NONE);
    assert(render::prepare_step_stop(&deadline, { .staged_bytes = 16 }, 100) == PrepareStopReason.TIME);
    PrepareBudget unbounded;
    assert(render::prepare_step_stop(&unbounded, { .staged_bytes = usz::max,
        .generated_texels = ulong::max, .pipelines = uint::max }, ulong::max) == PrepareStopReason.NONE);
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

fn void test_shader_first_use_adopts_an_owned_copy_in_one_step() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        AssetStore assets = asset::create_asset_store(&tracker, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&assets);
        char[4] fragment = { 1, 2, 3, 4 };
        asset::ShaderDesc desc = { .fragment = fragment[..] };
        ShaderId shader = assets.add_shader(&desc)!!;
        Renderer renderer = { .allocator = &tracker, .assets = &assets,
            .shaders = alloc::new_array(&tracker, ShaderRes, assets.shaders.items.len),
            .pipelines = render::create_pipeline_cache(&tracker, shader::BUILTIN_REGISTRY) };
        renderer.pending_prepare_retire.init(&tracker);
        defer renderer.pending_prepare_retire.free();
        defer render::destroy_pipeline_cache(&renderer.device, &renderer.pipelines);
        defer render::free_shaders(&renderer);
        PrepareUnit unit = { .kind = PrepareUnitKind.SHADER, .shader = shader, .revision = 1 };
        PrepareReport report;
        assert(render::prepare_shader_cost(&renderer, &unit).pipelines == 0);
        assert(render::run_prepare_shader_step(&renderer, &unit, &report)!!);
        assert(report.pipelines == 0 && report.copied_bytes == fragment.len);
        assert(renderer.shaders[shader.index].desc.fragment.ptr != assets.shader(shader).desc.fragment.ptr);
        assert(renderer.shaders[shader.index].desc.fragment == fragment[..]);
    }
    assert(!tracker.has_leaks());
}
