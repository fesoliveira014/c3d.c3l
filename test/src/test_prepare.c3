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

const usz TEXTURE_EXTENT @local = 64;

struct PrepareFixture @local {
    AssetStore assets;
    Renderer renderer;
    ModelId model;
    TextureId texture;
    GeometryId first;
    GeometryId second;
    MaterialId material;
}

fn void create_prepare_fixture(PrepareFixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    AssetStore* assets = &fixture.assets;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)(TEXTURE_EXTENT * TEXTURE_EXTENT * 4));
        fixture.texture = assets.add_texture(material::texture_2d_desc(TEXTURE_EXTENT, TEXTURE_EXTENT, RGBA8_UNORM), pixels)!!;
        Geometry first = geometry::box(tmem, 1, 1, 1);
        Geometry second = geometry::box(tmem, 2, 1, 1);
        fixture.first = assets.add_geometry(&first)!!;
        fixture.second = assets.add_geometry(&second)!!;
    };
    Material value = material::basic({ .map = material::texture_slot(texture: fixture.texture, sampler: asset::SAMPLER_LINEAR_REPEAT) });
    fixture.material = assets.add_material(value)!!;
    ModelTemplate template = { .nodes = alloc::new_array(mem, NodeTemplate, 2), .meshes = alloc::new_array(mem, ModelMesh, 2) };
    template.nodes[0].parent = -1;
    template.nodes[1].parent = -1;
    template.meshes[0] = { .node = 0, .geometry = fixture.first, .material = fixture.material };
    template.meshes[1] = { .node = 1, .geometry = fixture.second, .material = fixture.material };
    fixture.model = assets.add_model_owned(&template)!!;
    fixture.renderer = {
        .allocator = mem, .assets = assets,
        .geometries = alloc::new_array(mem, GpuGeometry, assets.geometries.items.len),
        .textures = alloc::new_array(mem, TextureRes, assets.textures.items.len),
        .residencies = alloc::new_array(mem, TextureResidency, assets.textures.items.len),
        .samplers = alloc::new_array(mem, SamplerRes, assets.samplers.items.len),
        .materials = alloc::new_array(mem, MaterialRes, assets.materials.items.len),
        .shaders = alloc::new_array(mem, ShaderRes, assets.shaders.items.len),
        .prepares = pool::create_pool{PrepareRecord, PrepareId}(mem, render::PREPARE_CAPACITY),
    };
    fixture.renderer.pending_prepare_installs.init(mem);
    fixture.renderer.pending_prepare_retire.init(mem);
}

fn void destroy_prepare_fixture(PrepareFixture* fixture) @local {
    render::free_prepares(&fixture.renderer);
    alloc::free(mem, fixture.renderer.geometries.ptr);
    alloc::free(mem, fixture.renderer.textures.ptr);
    alloc::free(mem, fixture.renderer.residencies.ptr);
    alloc::free(mem, fixture.renderer.samplers.ptr);
    alloc::free(mem, fixture.renderer.materials.ptr);
    alloc::free(mem, fixture.renderer.shaders.ptr);
    asset::destroy_asset_store(&fixture.assets);
}

fn Renderer create_shader_renderer(AssetStore* assets) @local {
    Renderer renderer = { .allocator = mem, .assets = assets,
        .shaders = alloc::new_array(mem, ShaderRes, assets.shaders.items.len),
        .pipelines = render::create_pipeline_cache(mem, shader::BUILTIN_REGISTRY) };
    renderer.pending_prepare_retire.init(mem);
    return renderer;
}

fn void destroy_shader_renderer(Renderer* renderer) @local {
    render::free_shaders(renderer);
    render::destroy_pipeline_cache(&renderer.device, &renderer.pipelines);
    renderer.pending_prepare_retire.free();
}

fn void test_prepare_dependency_order_and_deduplication() @test {
    PrepareFixture fixture;
    create_prepare_fixture(&fixture);
    defer destroy_prepare_fixture(&fixture);
    PrepareId id = fixture.renderer.begin_prepare_model(fixture.model)!!;
    PrepareUnit[] units = fixture.renderer.prepares.get(id).units;
    uint textures;
    uint geometries;
    uint materials;
    usz texture_index;
    usz material_index;
    foreach (usz index, unit : units) {
        switch (unit.kind) {
            case TEXTURE: textures++; texture_index = index;
            case GEOMETRY: geometries++;
            case MATERIAL: materials++; material_index = index;
            case SAMPLER:
            case TOON_SAMPLER:
            case SHADER:
            case PIPELINES:
            case FINISH:
        }
    }
    assert(textures == 1 && geometries == 2 && materials == 1);
    assert(texture_index < material_index && units[^1].kind == PrepareUnitKind.FINISH);
    assert(units[0].kind == PrepareUnitKind.SAMPLER);
    assert(fixture.renderer.prepare_progress(id).bytes_total > render::MATERIAL_STRIDE);
}

fn void test_prepare_totals_include_current_geometry_with_released_source() @test {
    PrepareFixture fixture;
    create_prepare_fixture(&fixture);
    defer destroy_prepare_fixture(&fixture);
    GeometryAsset* source = fixture.assets.geometry(fixture.first);
    GeometryLayout layout = render::geometry_layout_from_width(&source.data, source.joints_u16);
    fixture.renderer.geometries[fixture.first.index] = { .asset = fixture.first, .revision = source.header.revision, .layout = layout };
    fixture.assets.release_geometry_cpu(fixture.first);
    PrepareId id = fixture.renderer.begin_prepare_model(fixture.model)!!;
    bool found;
    foreach (unit : fixture.renderer.prepares.get(id).units) {
        if (unit.kind == PrepareUnitKind.GEOMETRY && c3d::same_id(unit.geometry, fixture.first)) {
            assert(unit.bytes == layout.total_bytes);
            found = true;
        }
    }
    assert(found);
}

fn void test_prepare_totals_change_only_when_restart_reenumerates() @test {
    PrepareFixture fixture;
    create_prepare_fixture(&fixture);
    defer destroy_prepare_fixture(&fixture);
    PrepareId id = fixture.renderer.begin_prepare_model(fixture.model)!!;
    PrepareRecord* record = fixture.renderer.prepares.get(id);
    usz original = record.bytes_total;
    fixture.assets.mark_material_dirty(fixture.material);
    assert(record.bytes_total == original && render::prepare_dependencies_changed(&fixture.renderer, record));
    PrepareReport report;
    render::restart_prepare_record(&fixture.renderer, record, &report);
    assert(record.bytes_total == original && record.units_done == 0 && record.bytes_done == 0);
    assert(record.restarts == 1 && report.restarts == 1);
}

fn void test_prepare_capacity_release_and_stale_generation() @test {
    PrepareFixture fixture;
    create_prepare_fixture(&fixture);
    defer destroy_prepare_fixture(&fixture);
    PrepareId first = fixture.renderer.begin_prepare_model(fixture.model)!!;
    for (uint index = 1; index < render::PREPARE_CAPACITY; index++) fixture.renderer.begin_prepare_model(fixture.model)!!;
    assert(@catch(fixture.renderer.begin_prepare_model(fixture.model)) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(fixture.renderer.begin_prepare_model({})) == c3d::INVALID_ID);
    fixture.renderer.end_prepare(first)!!;
    PrepareId reused = fixture.renderer.begin_prepare_model(fixture.model)!!;
    assert(reused.index == first.index && reused.generation != first.generation);
    assert(fixture.renderer.prepare_progress(first).failure == c3d::INVALID_ID);
    assert(@catch(fixture.renderer.end_prepare(first)) == c3d::INVALID_ID);
}

fn void test_removed_model_fails_even_after_units_are_logically_done() @test {
    PrepareFixture fixture;
    create_prepare_fixture(&fixture);
    defer destroy_prepare_fixture(&fixture);
    PrepareId id = fixture.renderer.begin_prepare_model(fixture.model)!!;
    PrepareRecord* record = fixture.renderer.prepares.get(id);
    foreach (&unit : record.units) unit.done = true;
    render::refresh_prepare_progress(record);
    assert(record.state == PrepareState.READY);
    fixture.assets.remove_model(fixture.model);
    assert(fixture.renderer.prepare_progress(id).state == PrepareState.FAILED);
    assert(fixture.renderer.prepare_progress(id).failure == c3d::INVALID_ID);
}

fn void test_prepare_records_follow_begin_order_after_slot_reuse() @test {
    PrepareFixture fixture;
    create_prepare_fixture(&fixture);
    defer destroy_prepare_fixture(&fixture);
    PrepareId first = fixture.renderer.begin_prepare_model(fixture.model)!!;
    PrepareId second = fixture.renderer.begin_prepare_model(fixture.model)!!;
    fixture.renderer.end_prepare(first)!!;
    PrepareId third = fixture.renderer.begin_prepare_model(fixture.model)!!;
    PrepareId[render::PREPARE_CAPACITY] order;
    assert(render::prepare_order(&fixture.renderer, order[..]) == 2);
    assert(c3d::same_id(order[0], second) && c3d::same_id(order[1], third));
}

fn void test_prepare_texture_totals_match_existing_whole_mips() @test {
    material::TextureDesc desc = material::texture_2d_desc(37, 19, RGBA8_SRGB);
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, 37 * 19 * 4);
        TextureAsset source = { .desc = desc, .source_kind = MIP_ZERO, .pixels = pixels };
        TextureMipChain reference = render::create_texture_mips(tmem, desc, pixels)!!;
        assert(render::prepare_source_bytes(&source) == reference.pixels.len);
    };
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
