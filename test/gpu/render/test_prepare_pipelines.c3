module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::render @public;
import c3d::shader;
import gpu;
import gpu::internal @public;
import gpu::internal::vk @public;

struct SparsePipelineSnapshot @private {
    uint available;
    uint index;
    uint generation;
}

fn SparsePipelineSnapshot? sparse_pipeline_snapshot(gpu::Device* device) @private {
    gpu::internal::DeviceOperation operation = gpu::internal::begin_device_operation(device)!;
    defer gpu::internal::end_device_operation(&operation);
    operation.state.resource_mutex.lock()!!;
    defer operation.state.resource_mutex.unlock();
    gpu::internal::vk::PipelineTable* table = &operation.state.pipelines;
    uint index = table.free_head ? table.free_head - 1 : table.next_new;
    assert(index < table.slots.len);
    return { .available = table.available_count(), .index = index, .generation = table.slots[index].generation };
}

fn void? check_sparse_pipeline_disposed(gpu::Device* device, SparsePipelineSnapshot before) @private {
    gpu::internal::DeviceOperation operation = gpu::internal::begin_device_operation(device)!;
    defer gpu::internal::end_device_operation(&operation);
    operation.state.resource_mutex.lock()!!;
    defer operation.state.resource_mutex.unlock();
    gpu::internal::vk::PipelineTable* table = &operation.state.pipelines;
    assert(table.available_count() == before.available);
    assert(!table.slots[before.index].used);
    assert(table.slots[before.index].generation != before.generation);
}

fn char[]* sparse_vertex_stage(asset::ShaderDesc* stages, PipelineKey key) @private {
    if (key.vertex.flags & shader::SHADER_FLAG_DEPTH_ONLY) return &stages.vertex.depth;
    if (key.vertex.flags & shader::SHADER_FLAG_INSTANCED) return &stages.vertex.instanced_shaded;
    return &stages.vertex.shaded;
}

fn void test_prepare_shader_replacement_disposes_sparse_fresh_handle_on_failure() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    gpu::Device* device = &fixture.renderer.device;
    @pool() {
        char[] vertex = compile_pulse_stage(&fixture, PULSE_VERTEX, ShaderStage.VERTEX)!!;
        defer alloc::free(fixture.allocator, vertex.ptr);
        char[] fragment = compile_pulse_stage(&fixture, PULSE_FRAGMENT, ShaderStage.FRAGMENT)!!;
        defer alloc::free(fixture.allocator, fragment.ptr);
        asset::ShaderDesc stages = {
            .fragment = fragment,
            .vertex = { .shaded = vertex, .depth = vertex, .instanced_shaded = vertex, .instanced_depth = vertex },
            .param_block_size = PulseBlock::size,
        };
        c3d::ShaderId shader_id = fixture.assets.add_shader(&stages)!!;
        PipelineCache cache = render::create_pipeline_cache(mem, shader::BUILTIN_REGISTRY);
        defer render::destroy_pipeline_cache(device, &cache);
        uint[3] flags = { 0, shader::SHADER_FLAG_DEPTH_ONLY, shader::SHADER_FLAG_INSTANCED };
        foreach (form : flags) {
            PipelineKey key = {
                .vertex = { .shader = MESH, .flags = form },
                .color_formats = { [0] = render::HDR_FORMAT },
                .color_count = 1,
                .depth_format = render::DEPTH_FORMAT,
                .samples = gpu::SampleCount.ONE,
                .polygon = gpu::PolygonMode.FILL,
                .shader = shader_id,
                .shader_revision = 1,
                .custom = { .vertex = true, .fragment = true },
            };
            CustomStageSource source = render::custom_stage_source(&stages, key);
            cache.get(device, key, &source)!!;
        }
        PipelineKey[] ordered = cache.keys_of(tmem, shader_id, 1);
        assert(ordered.len == 3);
        gpu::PipelineHandle[3] old;
        foreach (index, key : ordered) old[index] = cache.pipelines.get(key)!!;
        char[4] invalid_stage;
        asset::ShaderDesc replacement = stages;
        *sparse_vertex_stage(&replacement, ordered[0]) = {};
        *sparse_vertex_stage(&replacement, ordered[2]) = invalid_stage[..];
        SparsePipelineSnapshot before = sparse_pipeline_snapshot(device)!!;

        assert(@catch(cache.replace_shader(
            allocator: tmem,
            device: device,
            shader: shader_id,
            old_revision: 1,
            new_revision: 2,
            stages: &replacement,
        )) == gpu::SHADER_INVALID);
        assert(cache.keys_of(tmem, shader_id, 1).len == 3 && cache.keys_of(tmem, shader_id, 2).len == 0);
        foreach (index, key : ordered) assert(cache.pipelines.get(key)!! == old[index]);
        check_sparse_pipeline_disposed(device, before)!!;
    };
    check_validation(&fixture.renderer);
}

fn ModelId? pipeline_model(Fixture* fixture, MaterialId material) @private {
    Allocator allocator = fixture.assets.allocator;
    NodeTemplate[] nodes = alloc::new_array(allocator, NodeTemplate, 1);
    defer catch alloc::free(allocator, nodes.ptr);
    String name = "pipeline_mesh".copy(allocator);
    defer catch alloc::free(allocator, name.ptr);
    ModelMesh[] meshes = alloc::new_array(allocator, ModelMesh, 1);
    defer catch alloc::free(allocator, meshes.ptr);
    nodes[0] = { .parent = -1, .name = name, .local = c3d::maths::TRANSFORM_IDENTITY, .visible = true };
    meshes[0] = { .node = 0, .geometry = fixture.box, .material = material };
    ModelTemplate template = { .nodes = nodes, .meshes = meshes };
    return fixture.assets.add_model_owned(&template, "pipeline_model");
}

fn void? complete_pipeline_model(Renderer* renderer, PrepareId prepare, uint pipeline_limit) @private {
    PrepareProgress progress = renderer.prepare_progress(prepare);
    uint calls = progress.units_total + render::FRAMES_IN_FLIGHT + 1;
    while (calls-- && progress.state != PrepareState.READY) {
        renderer.begin_frame()!;
        defer catch render::abort_frame(renderer);
        PrepareReport report = renderer.advance_prepares_within({ .pipelines = pipeline_limit })!;
        if (pipeline_limit) assert(report.pipelines <= pipeline_limit);
        renderer.end_frame()!;
        render::wait_frames(renderer)!;
        progress = renderer.prepare_progress(prepare);
        assert(progress.state != PrepareState.FAILED);
    }
    assert(progress.state == PrepareState.READY);
}

fn void test_prepare_pipeline_creations_obey_each_call_and_warm_keys_are_hits() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ModelId model = pipeline_model(&fixture, fixture.plain)!!;
    PrepareId first = renderer.begin_prepare_model(model)!!;
    ulong before = renderer.prepare_counters.pipelines;
    complete_pipeline_model(renderer, first, 1)!!;
    assert(renderer.prepare_counters.pipelines > before);
    renderer.end_prepare(first)!!;

    PrepareId warm = renderer.begin_prepare_model(model)!!;
    renderer.begin_frame()!!;
    PrepareReport report = renderer.advance_prepares_within({ .pipelines = 1 })!!;
    assert(report.pipelines == 0 && report.pipeline_hits > 0);
    assert(report.staged_bytes == 0 && report.pipeline_ns == 0 && report.reason == PrepareStopReason.NONE);
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;
    assert(renderer.prepare_progress(warm).state == PrepareState.READY);
    renderer.end_prepare(warm)!!;
    check_validation(renderer);
}

fn void test_prepare_shader_adoption_counts_eligible_keys_and_survives_abort() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    c3d::ShaderId shader_id = add_pulse_shader(&fixture)!!;
    PulseBlock still = { .color = { 1, 1, 1, 1 } };
    MaterialId material = fixture.assets.add_material(material::custom(shader_id, material::@as_bytes(still)))!!;
    ModelId model = pipeline_model(&fixture, material)!!;
    PrepareId initial = renderer.begin_prepare_model(model)!!;
    complete_pipeline_model(renderer, initial, 1)!!;
    renderer.end_prepare(initial)!!;
    DeformedScene scene = create_single_box_scene(
        fixture: &fixture,
        geometry: fixture.box,
        material: material,
        sunlit: false,
    )!!;
    defer c3d::scene::destroy_scene(&scene.scene);
    uint expected = render_published_frames(&fixture, &scene, fixture.view)!!;

    uint eligible;
    @pool() {
        PipelineKey[] keys = renderer.pipelines.keys_of(tmem, shader_id, 1);
        assert(keys.len > 0);
        PipelineKey instanced;
        bool found;
        foreach (key : keys) {
            if (!key.custom.fragment || !key.custom.vertex) continue;
            instanced = key;
            instanced.vertex.flags = shader::SHADER_FLAG_INSTANCED;
            found = true;
            break;
        }
        assert(found);
        asset::ShaderDesc* old = &fixture.assets.shader(shader_id).desc;
        CustomStageSource stages = render::custom_stage_source(old, instanced);
        renderer.pipelines.get(&renderer.device, instanced, &stages)!!;
        asset::ShaderDesc replacement = *old;
        replacement.vertex.instanced_shaded = {};
        replacement.vertex.instanced_depth = {};
        replacement.vertex.instanced_velocity = {};
        fixture.assets.replace_shader(shader_id, &replacement)!!;
        keys = renderer.pipelines.keys_of(tmem, shader_id, 1);
        asset::ShaderDesc* current = &fixture.assets.shader(shader_id).desc;
        foreach (key : keys) if (render::key_stages_present(key, current)) eligible++;
        assert(eligible > 1 && keys.len > eligible);
    };
    PrepareId updated = renderer.begin_prepare_model(model)!!;
    renderer.begin_frame()!!;
    PrepareReport blocked = renderer.advance_prepares_within({ .pipelines = eligible - 1 })!!;
    assert(blocked.reason == PrepareStopReason.PIPELINES && blocked.required.pipelines == eligible);
    assert(blocked.pipelines == 0 && blocked.copied_bytes > 0 && blocked.pipeline_keys >= eligible);
    assert(renderer.shaders[shader_id.index].revision == 1);
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;

    renderer.begin_frame()!!;
    PrepareReport adopted = renderer.advance_prepares_within({ .pipelines = eligible })!!;
    assert(adopted.pipelines == eligible && adopted.copied_bytes == 0 && adopted.pipeline_keys >= eligible);
    assert(renderer.shaders[shader_id.index].revision == 2);
    render::abort_frame(renderer);
    assert(renderer.shaders[shader_id.index].revision == 2);
    @pool() {
        assert(renderer.pipelines.keys_of(tmem, shader_id, 1).len == 0);
        assert(renderer.pipelines.keys_of(tmem, shader_id, 2).len == eligible);
    };
    complete_pipeline_model(renderer, updated, 1)!!;
    renderer.end_prepare(updated)!!;
    uint actual = render_published_frames(&fixture, &scene, fixture.view)!!;
    check_near_pixel(actual, expected);
    check_validation(renderer);
}

fn void test_prepare_sheen_root_is_billed_and_pipeline_survives_abort() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.sheen_color = { 0.7f, 0.3f, 0.1f };
    params.sheen_roughness = 0.5f;
    MaterialId material = fixture.assets.add_material(material::physical(params))!!;
    ModelId model = pipeline_model(&fixture, material)!!;
    PrepareId prepare = renderer.begin_prepare_model(model)!!;

    renderer.begin_frame()!!;
    PrepareReport blocked = renderer.advance_prepares_within({ .staged_bytes = BrdfLutRoot::size - 1, .pipelines = 1 })!!;
    assert(blocked.reason == PrepareStopReason.STAGED_BYTES && blocked.required.staged_bytes == BrdfLutRoot::size);
    assert(blocked.staged_bytes == 0 && blocked.pipelines == 1);
    assert(renderer.environment_state.sheen_lut.state == EnvironmentLutState.NONE);
    gpu::PipelineHandle pipeline = renderer.environment_state.pipelines.sheen_lut;
    assert(pipeline.is_valid());
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;

    renderer.begin_frame()!!;
    PrepareReport lut = renderer.advance_prepares_within({ .staged_bytes = BrdfLutRoot::size, .pipelines = 1 })!!;
    assert(lut.staged_bytes == BrdfLutRoot::size && lut.pipelines == 0);
    assert(renderer.environment_state.sheen_lut.state == EnvironmentLutState.RECORDED);
    render::abort_frame(renderer);
    assert(renderer.environment_state.sheen_lut.state == EnvironmentLutState.NONE);
    assert(renderer.environment_state.pipelines.sheen_lut == pipeline);
    complete_pipeline_model(renderer, prepare, 1)!!;
    assert(renderer.environment_state.sheen_lut.state == EnvironmentLutState.READY);
    assert(renderer.environment_state.pipelines.sheen_lut == pipeline);
    renderer.end_prepare(prepare)!!;
    check_validation(renderer);
}

fn void test_prepare_sbt_writes_split_and_abort_restores_private_candidate() @test {
    Fixture fixture;
    create_fixture(
        allocator: mem,
        fixture: &fixture,
        ray_queries: true,
        ray_tracing_pipelines: true,
    )!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    renderer.upload_geometry(fixture.box)!!;
    renderer.upload_material(fixture.plain)!!;
    render::wait_frames(renderer)!!;
    ViewDesc view = render::texture_view_desc(fixture.hdr_target);
    view.shading = ShadingPath.PATH_TRACED;
    render::configure_view(renderer, fixture.view, view)!!;
    ModelId model = pipeline_model(&fixture, fixture.plain)!!;
    PrepareId prepare = renderer.begin_prepare_model(model)!!;
    uint calls = renderer.prepare_progress(prepare).units_total + 1;
    bool partial;
    while (calls-- && !partial) {
        renderer.begin_frame()!!;
        PrepareReport report = renderer.advance_prepares_within({ .staged_bytes = 1, .pipelines = 1 })!!;
        assert(report.staged_bytes <= 1 && report.pipelines <= 1);
        partial = renderer.path_tracer.pipeline.is_valid() && !renderer.path_tracer.sbt.is_valid() && report.staged_bytes == 1;
        renderer.end_frame()!!;
        render::wait_frames(renderer)!!;
    }
    assert(partial);
    gpu::PipelineHandle pipeline = renderer.path_tracer.pipeline;
    PrepareRecord* record = renderer.prepares.get(prepare);
    PrepareBudget setup;
    uint expected_creations;
    foreach (index, &unit : record.units) {
        if (index <= record.next || unit.kind != PrepareUnitKind.PIPELINES) continue;
        if (unit.pipeline.kind != PreparePipelineKind.CACHE && unit.pipeline.kind != PreparePipelineKind.COMPUTE) continue;
        PrepareStepCost cost = render::prepare_pipeline_cost(renderer, unit, &setup)!!;
        expected_creations += cost.pipelines;
        assert(render::run_prepare_pipeline_step(renderer, unit, &setup.report)!!);
    }
    assert(expected_creations > 0 && setup.report.pipelines == expected_creations);
    renderer.begin_frame()!!;
    PrepareReport final = renderer.advance_prepares_within({ .pipelines = 1 })!!;
    assert(final.staged_bytes > 0 && final.pipelines == 0 && renderer.path_tracer.sbt.is_valid());
    gpu::GpuSpan prepared = gpu::get_allocation_span(&renderer.device, renderer.path_tracer.sbt)!!;
    gpu::MappedGpuSpan prepared_bytes = gpu::mapped_gpu_span(&renderer.device, prepared)!!;
    char[] expected = (char[])((String)prepared_bytes.bytes).copy(mem);
    defer free(expected.ptr);
    render::abort_frame(renderer);
    assert(!renderer.path_tracer.sbt.is_valid() && renderer.path_tracer.pipeline == pipeline);
    complete_pipeline_model(renderer, prepare, 1)!!;
    assert(renderer.path_tracer.sbt.is_valid() && renderer.path_tracer.pipeline == pipeline);
    gpu::GpuSpan retried = gpu::get_allocation_span(&renderer.device, renderer.path_tracer.sbt)!!;
    gpu::MappedGpuSpan retried_bytes = gpu::mapped_gpu_span(&renderer.device, retried)!!;
    assert(retried_bytes.bytes == expected);
    renderer.end_prepare(prepare)!!;
    check_validation(renderer);
}

fn void test_prepare_effect_rich_view_enumerates_each_pipeline_once() @test {
    Fixture fixture;
    create_fixture(allocator: mem, fixture: &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ViewDesc view = render::texture_view_desc(fixture.ldr_target);
    view.color = OutputMode.DISPLAY_LDR;
    view.shading = ShadingPath.DEFERRED;
    view.lights = LightSelection.CLUSTERED;
    view.ray_tracing.shadows = true;
    view.ray_tracing.reflections = true;
    view.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
    view.ambient_occlusion.kind = AoKind.RAY_TRACED;
    view.screen_space_gi = render::SCREEN_SPACE_GI_DEFAULT;
    view.screen_space_gi.enabled = true;
    view.post.bloom = true;
    view.post.depth_of_field = true;
    view.post.motion_blur = true;
    view.post.anti_aliasing = AntiAliasing.TAA;
    view.post.auto_exposure = true;
    render::configure_view(renderer, fixture.view, view)!!;
    MaterialId material = fixture.assets.add_material(material::standard())!!;
    ModelId model = pipeline_model(&fixture, material)!!;
    PrepareId prepare = renderer.begin_prepare_model(model)!!;
    complete_pipeline_model(renderer, prepare, 1)!!;
    assert(renderer.cluster_pipeline.is_valid());
    assert(renderer.ambient_occlusion_pipelines.ray_traced.is_valid() && renderer.ambient_occlusion_pipelines.blur.is_valid());
    assert(renderer.reflection_pipelines.trace.is_valid() && renderer.reflection_pipelines.blur.is_valid());
    assert(renderer.screen_space_gi_pipelines.trace.is_valid());
    assert(renderer.screen_space_gi_pipelines.temporal.is_valid() && renderer.screen_space_gi_pipelines.filter.is_valid());
    assert(renderer.post_pipelines.bloom_downsample.is_valid() && renderer.post_pipelines.bloom_upsample.is_valid());
    assert(renderer.post_pipelines.dof_coc.is_valid() && renderer.post_pipelines.dof_gather.is_valid());
    assert(renderer.post_pipelines.dof_composite.is_valid() && renderer.post_pipelines.motion_blur.is_valid());
    assert(renderer.post_pipelines.tile_max.is_valid() && renderer.post_pipelines.tile_neighbor.is_valid());
    assert(renderer.post_pipelines.taa_resolve.is_valid());
    assert(renderer.post_pipelines.exposure_histogram.is_valid() && renderer.post_pipelines.exposure_adapt.is_valid());
    renderer.end_prepare(prepare)!!;
    PrepareId warm = renderer.begin_prepare_model(model)!!;
    renderer.begin_frame()!!;
    PrepareReport report = renderer.advance_prepares_within({ .pipelines = 1 })!!;
    assert(report.pipelines == 0 && report.pipeline_hits > 0 && report.staged_bytes == 0);
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;
    renderer.end_prepare(warm)!!;
    check_validation(renderer);
}

fn void test_prepare_normal_draw_shader_adoption_supersedes_copied_job() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    c3d::ShaderId shader_id = add_pulse_shader(&fixture)!!;
    PulseBlock still = { .color = { 1, 1, 1, 1 } };
    MaterialId material = fixture.assets.add_material(material::custom(shader_id, material::@as_bytes(still)))!!;
    ModelId model = pipeline_model(&fixture, material)!!;
    PrepareId initial = renderer.begin_prepare_model(model)!!;
    complete_pipeline_model(renderer, initial, 1)!!;
    renderer.end_prepare(initial)!!;
    DeformedScene scene = create_single_box_scene(
        fixture: &fixture,
        geometry: fixture.box,
        material: material,
        sunlit: false,
    )!!;
    defer c3d::scene::destroy_scene(&scene.scene);
    uint expected = render_published_frames(&fixture, &scene, fixture.view)!!;
    @pool() {
        asset::ShaderDesc replacement = fixture.assets.shader(shader_id).desc;
        fixture.assets.replace_shader(shader_id, &replacement)!!;
    };
    PrepareId prepare = renderer.begin_prepare_model(model)!!;
    renderer.begin_frame()!!;
    PrepareReport blocked = renderer.advance_prepares_within({ .pipelines = 1 })!!;
    assert(blocked.reason == PrepareStopReason.PIPELINES && blocked.required.pipelines > 1);
    assert(blocked.copied_bytes > 0 && blocked.pipelines == 0);
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;

    renderer.begin_frame()!!;
    scene.scene.update_world();
    renderer.render_view(&scene.scene, scene.camera, fixture.view)!!;
    assert(renderer.shaders[shader_id.index].revision == 2);
    render::abort_frame(renderer);
    assert(renderer.shaders[shader_id.index].revision == 2);
    ulong calls = renderer.pipelines.creations.calls;
    complete_pipeline_model(renderer, prepare, 1)!!;
    assert(renderer.pipelines.creations.calls == calls);
    renderer.end_prepare(prepare)!!;
    uint actual = render_published_frames(&fixture, &scene, fixture.view)!!;
    check_near_pixel(actual, expected);
    check_validation(renderer);
}
