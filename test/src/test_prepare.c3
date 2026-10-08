module c3d::test::prepare;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::pool;
import c3d::render @public;
import c3d::shader;
import gpu;
import std::collections::list;

const usz MIB @local = 1 << 20;
const uint TEXTURE_EXTENT @local = 64;

struct PrepareFixture @local {
    AssetStore assets;
    Renderer   renderer;
    ModelId    model;
    TextureId  texture;
    GeometryId first;
    GeometryId second;
    MaterialId material;
}

fn void create_prepare_fixture(PrepareFixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    AssetStore* assets = &fixture.assets;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)TEXTURE_EXTENT * TEXTURE_EXTENT * 4);
        material::TextureDesc desc = material::texture_2d_desc(TEXTURE_EXTENT, TEXTURE_EXTENT, PixelFormat.RGBA8_UNORM);
        fixture.texture = assets.add_texture(desc, pixels, "prepare/texture")!!;
        Geometry box = geometry::box(tmem, 1, 1, 1);
        fixture.first = assets.add_geometry(&box, "prepare/first")!!;
        Geometry wide = geometry::box(tmem, 2, 1, 1);
        fixture.second = assets.add_geometry(&wide, "prepare/second")!!;
    };
    TextureSlot map = {
        .texture = { .kind = TextureRefKind.ASSET, .asset = fixture.texture },
        .sampler = asset::SAMPLER_LINEAR_REPEAT,
    };
    Material textured = material::basic({ .color = { 1, 1, 1, 1 }, .map = map });
    fixture.material = assets.add_material(textured, "prepare/material")!!;
    ModelTemplate template = {
        .nodes  = alloc::new_array(assets.allocator, NodeTemplate, 2),
        .meshes = alloc::new_array(assets.allocator, ModelMesh, 2),
    };
    template.nodes[0] = { .parent = -1, .name = "first".copy(assets.allocator), .visible = true };
    template.nodes[1] = { .parent = -1, .name = "second".copy(assets.allocator), .visible = true };
    template.meshes[0] = { .node = 0, .geometry = fixture.first, .material = fixture.material };
    template.meshes[1] = { .node = 1, .geometry = fixture.second, .material = fixture.material };
    fixture.model = assets.add_model_owned(&template, "prepare/model")!!;

    fixture.renderer = {
        .allocator  = mem,
        .assets     = assets,
        .geometries = alloc::new_array(mem, GpuGeometry, (sz)assets.geometries.items.len),
        .textures   = alloc::new_array(mem, TextureRes, (sz)assets.textures.items.len),
        .materials  = alloc::new_array(mem, MaterialRes, (sz)assets.materials.items.len),
        .prepares   = pool::create_pool{PrepareRecord, PrepareId}(mem, render::PREPARE_CAPACITY),
    };
    fixture.renderer.pending_prepare_marks.init(mem);
}

fn void destroy_prepare_fixture(PrepareFixture* fixture) @local {
    render::free_prepares(&fixture.renderer);
    alloc::free(mem, fixture.renderer.geometries.ptr);
    alloc::free(mem, fixture.renderer.textures.ptr);
    alloc::free(mem, fixture.renderer.materials.ptr);
    asset::destroy_asset_store(&fixture.assets);
}

fn Renderer record_renderer() @local {
    Renderer renderer = {
        .allocator = mem,
        .prepares  = pool::create_pool{PrepareRecord, PrepareId}(mem, render::PREPARE_CAPACITY),
    };
    renderer.pending_prepare_marks.init(mem);
    return renderer;
}

fn Renderer create_shader_renderer(AssetStore* assets) @local {
    return {
        .allocator = mem,
        .assets    = assets,
        .shaders   = alloc::new_array(mem, ShaderRes, (sz)assets.shaders.items.len),
        .pipelines = render::create_pipeline_cache(mem, shader::BUILTIN_REGISTRY),
    };
}

fn void destroy_shader_renderer(Renderer* renderer) @local {
    render::free_shaders(renderer);
    renderer.pipelines.pipelines.free();
    renderer.pipelines.rejected.free();
}

fn PrepareId add_record(Renderer* renderer, usz[] unit_bytes, ulong sequence) @local {
    PrepareRecord record = {
        .units    = alloc::new_array(mem, PrepareUnit, (sz)unit_bytes.len),
        .sequence = sequence,
        .state    = PrepareState.PENDING,
        .open     = true,
    };
    foreach (index, bytes : unit_bytes) {
        record.units[index] = { .kind = PrepareUnitKind.TEXTURE, .bytes = bytes };
        record.bytes_total += bytes;
    }
    return renderer.prepares.add(record)!!;
}

fn void test_prepare_budget_admits_one_oversized_unit() @test {
    PrepareCheck[4] checks = { { .live = true, .size = 3 * MIB }, { .live = true, .size = 3 * MIB },
        { .live = true, .size = 10 * MIB }, { .live = true, .size = 3 * MIB } };
    PrepareAction[4] actions;
    uint next;
    uint[3] expected_taken = { 2, 1, 1 };
    usz[3] expected_spent = { 6 * MIB, 10 * MIB, 3 * MIB };
    foreach (call, taken : expected_taken) {
        PrepareBudget budget = { .budget = 8 * MIB };
        assert(render::plan_prepare_units(&budget, checks[next..], actions[next..]) == taken);
        next += taken;
        assert(budget.spent == expected_spent[call]);
    }
}

fn void test_prepare_unit_current_before_its_turn_counts_as_done() @test {
    PrepareCheck[3] checks = { { .live = true, .size = 3 * MIB }, { .live = true, .current = true, .size = 3 * MIB },
        { .live = true, .size = 3 * MIB } };
    PrepareAction[3] actions;
    PrepareBudget budget = { .budget = 8 * MIB };

    assert(render::plan_prepare_units(&budget, checks[..], actions[..]) == 3);

    assert(actions[0] == PrepareAction.STAGE && actions[1] == PrepareAction.CURRENT);
    assert(actions[2] == PrepareAction.STAGE && budget.spent == 6 * MIB);
}

fn void test_prepare_budget_uses_the_current_size() @test {
    PrepareCheck[2] checks = { { .live = true, .size = 2 * MIB }, { .live = true, .size = 6 * MIB } };
    PrepareAction[2] actions;
    PrepareBudget first_call = { .budget = 4 * MIB };
    assert(render::plan_prepare_units(&first_call, checks[..], actions[..]) == 1);

    PrepareBudget second_call = { .budget = 4 * MIB };
    assert(render::plan_prepare_units(&second_call, checks[1..], actions[1..]) == 1);
    assert(second_call.spent == 6 * MIB);
}

fn void test_prepare_dead_unit_is_done_without_staging() @test {
    PrepareCheck[2] checks = { { .live = false, .size = 4 * MIB }, { .live = true, .size = 1 * MIB } };
    PrepareAction[2] actions;
    PrepareBudget budget = { .budget = 1 * MIB };

    assert(render::plan_prepare_units(&budget, checks[..], actions[..]) == 2);

    assert(actions[0] == PrepareAction.DEAD && actions[1] == PrepareAction.STAGE);
    assert(budget.spent == 1 * MIB);
}

fn void test_prepare_oversized_unit_runs_after_a_unit_without_bytes() @test {
    PrepareCheck[2] checks = { { .live = true }, { .live = true, .size = 10 * MIB } };
    PrepareAction[2] actions;
    PrepareBudget budget = { .budget = 8 * MIB };

    assert(render::plan_prepare_units(&budget, checks[..], actions[..]) == 2);
    assert(budget.spent == 10 * MIB);
}

fn void test_prepare_units_return_after_an_aborted_frame() @test {
    Renderer renderer = record_renderer();
    defer render::free_prepares(&renderer);
    usz[3] bytes = { 1 * MIB, 2 * MIB, 3 * MIB };
    PrepareId id = add_record(&renderer, bytes[..], 1);
    render::mark_unit_done(&renderer, id, 0);
    renderer.pending_prepare_marks.clear();

    render::mark_unit_done(&renderer, id, 1);
    render::mark_unit_done(&renderer, id, 2);
    PrepareRecord* record = renderer.prepares.get(id);
    assert(record.state == PrepareState.SUBMITTED);
    render::rollback_prepare_marks(&renderer);

    assert(!record.units[1].done && !record.units[2].done && record.units[0].done);
    assert(record.bytes_done == 1 * MIB && record.units_done == 1 && record.next == 1);
    assert(record.state == PrepareState.PENDING && renderer.pending_prepare_marks.len() == 0);
}

fn void test_prepare_units_stay_done_when_the_frame_staged_nothing() @test {
    Renderer renderer = record_renderer();
    defer render::free_prepares(&renderer);
    usz[2] bytes = { 0, 0 };
    PrepareId id = add_record(&renderer, bytes[..], 1);
    PrepareRecord* record = renderer.prepares.get(id);
    record.units[0].kind = PrepareUnitKind.PIPELINES;
    record.units[1].kind = PrepareUnitKind.FINISH;

    render::mark_unit_done(&renderer, id, 0);
    render::mark_unit_done(&renderer, id, 1);
    render::discard_uploads(&renderer);

    assert(record.units[0].done && record.units[1].done);
    assert(record.state == PrepareState.SUBMITTED && renderer.pending_prepare_marks.len() == 0);
}

fn void test_prepare_readiness_waits_two_frames() @test {
    Renderer renderer = record_renderer();
    defer render::free_prepares(&renderer);
    usz[1] bytes = { 1 * MIB };
    PrepareId id = add_record(&renderer, bytes[..], 1);
    renderer.frame_index = 5;
    render::mark_unit_done(&renderer, id, 0);

    renderer.frame_index = 6;
    render::promote_ready_prepares(&renderer);
    assert(renderer.prepare_progress(id).state == PrepareState.SUBMITTED);
    renderer.frame_index = 7;
    render::promote_ready_prepares(&renderer);
    assert(renderer.prepare_progress(id).state == PrepareState.READY);
}

fn void test_prepare_records_advance_in_begin_order() @test {
    Renderer renderer = record_renderer();
    defer render::free_prepares(&renderer);
    usz[1] bytes = { 1 * MIB };
    PrepareId first = add_record(&renderer, bytes[..], 1);
    PrepareId second = add_record(&renderer, bytes[..], 2);
    PrepareId third = add_record(&renderer, bytes[..], 3);
    renderer.end_prepare(first)!!;
    PrepareId fourth = add_record(&renderer, bytes[..], 4);
    assert(fourth.index == first.index);
    PrepareId failed = add_record(&renderer, bytes[..], 5);
    renderer.prepares.get(failed).state = PrepareState.FAILED;

    PrepareId[render::PREPARE_CAPACITY] order;
    assert(render::prepare_order(&renderer, order[..]) == 3);

    assert(c3d::same_id(order[0], second) && c3d::same_id(order[1], third) && c3d::same_id(order[2], fourth));
}

fn void test_prepare_units_follow_dependency_order() @test {
    PrepareFixture fixture;
    create_prepare_fixture(&fixture);
    defer destroy_prepare_fixture(&fixture);

    PrepareId id = fixture.renderer.begin_prepare_model(fixture.model)!!;

    PrepareUnit[] units = fixture.renderer.prepares.get(id).units;
    PrepareUnitKind[7] expected = { TEXTURE, GEOMETRY, MATERIAL, PIPELINES, GEOMETRY, PIPELINES, FINISH };
    assert(units.len == expected.len);
    foreach (index, kind : expected) assert(units[index].kind == kind);
    assert(c3d::same_id(units[1].geometry, fixture.first) && c3d::same_id(units[4].geometry, fixture.second));
}

fn void test_prepare_bytes_total_leaves_out_current_units() @test {
    PrepareFixture fixture;
    create_prepare_fixture(&fixture);
    defer destroy_prepare_fixture(&fixture);
    AssetStore* assets = &fixture.assets;
    fixture.renderer.geometries[fixture.first.index] = {
        .asset    = fixture.first,
        .revision = assets.geometry(fixture.first).header.revision,
    };

    PrepareId id = fixture.renderer.begin_prepare_model(fixture.model)!!;

    PrepareProgress progress = fixture.renderer.prepare_progress(id);
    assert(progress.units_total == 6);
    usz texture_bytes = render::prepare_texture_bytes(&fixture.renderer, fixture.texture);
    usz geometry_bytes = render::geometry_layout(&assets.geometry(fixture.second).data).total_bytes;
    assert(progress.bytes_total == texture_bytes + geometry_bytes + render::MATERIAL_STRIDE);
    assert(progress.bytes_done == 0 && progress.state == PrepareState.PENDING);
}

fn void test_prepare_capacity_and_release() @test {
    PrepareFixture fixture;
    create_prepare_fixture(&fixture);
    defer destroy_prepare_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;

    PrepareId first = renderer.begin_prepare_model(fixture.model)!!;
    for (uint index = 1; index < render::PREPARE_CAPACITY; index++) renderer.begin_prepare_model(fixture.model)!!;
    assert(@catch(renderer.begin_prepare_model(fixture.model)) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(renderer.begin_prepare_model({})) == c3d::INVALID_ID);

    renderer.end_prepare(first)!!;
    renderer.begin_prepare_model(fixture.model)!!;
}

fn void test_released_prepare_id_is_stale() @test {
    PrepareFixture fixture;
    create_prepare_fixture(&fixture);
    defer destroy_prepare_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    PrepareId old = renderer.begin_prepare_model(fixture.model)!!;

    renderer.end_prepare(old)!!;

    PrepareProgress stale = renderer.prepare_progress(old);
    assert(stale.state == PrepareState.FAILED && stale.failure == c3d::INVALID_ID);
    assert(@catch(renderer.end_prepare(old)) == c3d::INVALID_ID);
    PrepareProgress unrequested = renderer.prepare_progress({});
    assert(unrequested.state == PrepareState.FAILED && unrequested.failure == c3d::INVALID_ID);
}

fn void test_prepare_texture_bytes_match_the_mip_chain() @test {
    material::TextureDesc[3] descs = {
        material::texture_2d_desc(64, 64, PixelFormat.RGBA8_UNORM),
        material::texture_2d_desc(64, 64, PixelFormat.RGBA8_SRGB),
        material::texture_2d_desc(300, 200, PixelFormat.RGBA8_UNORM),
    };
    foreach (desc : descs) {
        @pool() {
            char[] pixels = alloc::new_array(tmem, char, (sz)desc.width * desc.height * 4);
            TextureAsset record = { .desc = desc, .source_kind = MIP_ZERO, .pixels = pixels };
            TextureMipChain chain = render::create_texture_mips(tmem, desc, pixels)!!;
            assert(render::prepare_source_bytes(&record) == chain.pixels.len);
        };
    }
}

fn void test_scene_reads_follow_the_published_shader_revision() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    char[4] fragment = { 1, 2, 3, 4 };
    asset::ShaderDesc reader = { .fragment = fragment[..], .scene_reads = { .depth } };
    asset::ShaderDesc flat = { .fragment = fragment[..] };
    ShaderId shader = assets.add_shader(&reader)!!;
    Material custom = material::custom(shader);
    Material basic = material::basic();
    Renderer renderer = create_shader_renderer(&assets);
    defer destroy_shader_renderer(&renderer);
    assert(render::custom_scene_reads(&renderer, &custom)!! == (SceneReads){ .depth });

    assets.replace_shader(shader, &flat)!!;
    assert(render::pipeline_rejected(&renderer, shader, gpu::SHADER_INVALID));
    assert(render::custom_scene_reads(&renderer, &custom)!! == (SceneReads){ .depth });

    assets.replace_shader(shader, &flat)!!;
    assert(render::custom_scene_reads(&renderer, &custom)!! == (SceneReads){});
    assert(render::custom_scene_reads(&renderer, &basic)!! == (SceneReads){});

    assets.remove_shader(shader);
    assert(render::custom_scene_reads(&renderer, &custom)!! == (SceneReads){});
}

fn void test_published_shader_copy_follows_accepted_revisions() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    char[4] first = { 1, 1, 1, 1 };
    char[4] second = { 2, 2, 2, 2 };
    asset::ShaderDesc first_desc = { .fragment = first[..], .vertex = { .shaded = first[..], .depth = first[..] } };
    asset::ShaderDesc second_desc = { .fragment = second[..], .gbuffer = second[..], .param_block_size = 16 };
    ShaderId shader = assets.add_shader(&first_desc)!!;
    Renderer renderer = create_shader_renderer(&assets);
    defer destroy_shader_renderer(&renderer);

    ShaderRes* published = render::resolve_shader(&renderer, shader)!!;
    assert(published.revision == 1 && published.desc.vertex.depth[0] == 1);
    assert(published.desc.fragment.ptr != assets.shader(shader).desc.fragment.ptr);

    assets.replace_shader(shader, &second_desc)!!;
    published = render::resolve_shader(&renderer, shader)!!;
    assert(published.revision == 2 && published.desc.fragment[0] == 2 && published.desc.gbuffer.len == 4);
    assert(published.desc.vertex.depth.len == 0 && published.desc.param_block_size == 16);

    assets.shader(shader).desc.fragment[0] = 9;
    assert(render::resolve_shader(&renderer, shader)!!.desc.fragment[0] == 2);

    assets.remove_shader(shader);
    render::sweep_shaders(&renderer);
    assert(!renderer.shaders[shader.index].asset.generation);
    assert(renderer.shaders[shader.index].desc.fragment.len == 0);
}

fn void test_rejected_replacement_keeps_the_published_stages() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    char[4] first = { 1, 1, 1, 1 };
    char[4] second = { 2, 2, 2, 2 };
    asset::ShaderDesc first_desc = {
        .fragment = first[..],
        .gbuffer  = first[..],
        .vertex   = { .shaded = first[..], .depth = first[..], .velocity = first[..] },
    };
    asset::ShaderDesc second_desc = {
        .fragment = second[..],
        .vertex   = {
            .shaded           = second[..],
            .depth            = second[..],
            .instanced_shaded = second[..],
            .instanced_depth  = second[..],
        },
    };
    ShaderId shader = assets.add_shader(&first_desc)!!;
    Material custom = material::custom(shader);
    Renderer renderer = create_shader_renderer(&assets);
    defer destroy_shader_renderer(&renderer);
    ShaderRes* published = render::resolve_shader(&renderer, shader)!!;
    assets.replace_shader(shader, &second_desc)!!;
    assert(render::pipeline_rejected(&renderer, shader, gpu::SHADER_INVALID));

    assert(render::custom_gbuffer_stage(&renderer, &custom)!!);
    assert(render::custom_velocity_stage(&renderer, &custom, false)!!);

    PipelineKey forward = { .vertex = { .shader = MESH }, .custom = { .vertex = true, .fragment = true } };
    CustomStageSource source = render::published_key_stages(published, &forward)!!;
    assert(forward.shader_revision == 1 && c3d::same_id(forward.shader, shader));
    assert(source.vertex[0] == 1 && source.fragment[0] == 1);

    PipelineKey caster = {
        .vertex = { .shader = MESH, .flags = shader::SHADER_FLAG_DEPTH_ONLY },
        .custom = { .vertex = true },
    };
    assert(render::published_key_stages(published, &caster)!!.vertex[0] == 1);

    PipelineKey instanced = {
        .vertex = { .shader = MESH, .flags = shader::SHADER_FLAG_INSTANCED },
        .custom = { .vertex = true, .fragment = true },
    };
    assert(@catch(render::published_key_stages(published, &instanced)) == render::PIPELINE_REJECTED);
    assert(renderer.stats.shader_rejections == 1);
}

fn void test_custom_references_accept_only_live_standard_materials() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    MaterialId layer = assets.add_material(material::standard())!!;
    MaterialId toon = assets.add_material(material::toon())!!;
    MaterialId physical = assets.add_material(material::physical())!!;
    MaterialId removed = assets.add_material(material::standard())!!;
    assets.remove_material(removed);
    Material layered = material::custom({ .index = 1, .generation = 1 }, references: { [0] = layer, [2] = layer });
    render::check_custom_references(&assets, &layered.custom)!!;

    MaterialId self_reference = assets.add_material(layered)!!;
    MaterialId[4] rejected = { toon, physical, removed, self_reference };
    foreach (reference : rejected) {
        layered.custom.references[1] = reference;
        assert(@catch(render::check_custom_references(&assets, &layered.custom)) == c3d::INVALID_ARGUMENT);
    }
}
