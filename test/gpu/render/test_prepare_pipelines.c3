module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::render @public;
import c3d::shader;
import gpu;
import gpu::internal @public;
import gpu::internal::vk @public;
import std::math::vector;

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

fn ModelId? pipeline_model(
    Fixture* fixture,
    MaterialId material,
    GeometryId geometry = {},
    bool morphed = false,
) @private {
    Allocator allocator = fixture.assets.allocator;
    NodeTemplate[] nodes = alloc::new_array(allocator, NodeTemplate, 1);
    defer catch alloc::free(allocator, nodes.ptr);
    String name = "pipeline_mesh".copy(allocator);
    defer catch alloc::free(allocator, name.ptr);
    ModelMesh[] meshes = alloc::new_array(allocator, ModelMesh, 1);
    defer catch alloc::free(allocator, meshes.ptr);
    nodes[0] = { .parent = -1, .name = name, .local = c3d::maths::TRANSFORM_IDENTITY, .visible = true };
    meshes[0] = { .node = 0, .geometry = geometry.generation ? geometry : fixture.box, .material = material };
    if (morphed) {
        meshes[0].default_morph_weights = alloc::new_array(allocator, float, 1);
        meshes[0].default_morph_weights[0] = 0.5f;
    }
    defer catch alloc::free(allocator, meshes[0].default_morph_weights.ptr);
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
    PrepareReport blocked = renderer.advance_prepares_within(limits: {
        .staged_bytes = BrdfLutRoot::size - 1,
        .pipelines = 1,
    })!!;
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
    assert(renderer.ambient_occlusion_pipelines.ray_traced.is_valid());
    assert(renderer.ambient_occlusion_pipelines.blur.is_valid());
    assert(renderer.reflection_pipelines.trace.is_valid() && renderer.reflection_pipelines.blur.is_valid());
    assert(renderer.screen_space_gi_pipelines.trace.is_valid());
    assert(renderer.screen_space_gi_pipelines.temporal.is_valid());
    assert(renderer.screen_space_gi_pipelines.filter.is_valid());
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

fn void test_prepare_custom_traced_shadow_pipeline_is_current_before_draw() @test {
    foreach (ray_queries : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        ViewDesc view = render::texture_view_desc(fixture.hdr_target);
        view.ray_tracing.shadows = true;
        render::configure_view(renderer, fixture.view, view)!!;
        c3d::ShaderId shader_id = add_twin_shader(&fixture, true)!!;
        MaterialId material = twin_material(&fixture, shader_id, TWIN_SPHERE_PARAMS)!!;
        ModelId model = pipeline_model(&fixture, material)!!;
        PrepareId prepare = renderer.begin_prepare_model(model)!!;
        uint untraced;
        uint traced;
        foreach (unit : renderer.prepares.get(prepare).units) {
            if (unit.kind != PrepareUnitKind.PIPELINES || unit.pipeline.pass != PreparePipelinePass.FORWARD) continue;
            if (unit.pipeline.key.fragment.flags & shader::SHADER_FLAG_RT_SHADOWS) {
                traced++;
            } else {
                untraced++;
            }
        }
        assert(untraced == 1 && traced == 1);
        complete_pipeline_model(renderer, prepare, 1)!!;
        renderer.end_prepare(prepare)!!;
        DeformedScene scene = create_single_box_scene(
            fixture: &fixture,
            geometry: fixture.box,
            material: material,
            sunlit: false,
        )!!;
        defer c3d::scene::destroy_scene(&scene.scene);
        scene.scene.update_world();
        renderer.begin_frame()!!;
        ulong calls = renderer.pipelines.creations.calls;
        SparsePipelineSnapshot before = sparse_pipeline_snapshot(&renderer.device)!!;
        renderer.render_view(&scene.scene, scene.camera, fixture.view)!!;
        assert(renderer.pipelines.creations.calls == calls);
        assert(sparse_pipeline_snapshot(&renderer.device)!!.available == before.available);
        renderer.finish_view(fixture.view)!!;
        renderer.end_frame()!!;
        render::wait_frames(renderer)!!;
        check_validation(renderer);
    }
}

fn void test_prepare_trace_pose_variants_and_refit_are_current_before_deformed_draw() @test {
    for (uint form = 0; form < 3; form++) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        bool morphed = form != 0;
        GeometryId geometry;
        if (form == 1) {
            @pool() {
                Geometry source = preparation_attribute_geometry(tmem);
                geometry = fixture.assets.add_geometry(&source)!!;
            };
            assert(fixture.assets.geometry(geometry).joints_u16);
        } else {
            geometry = posed_box(&fixture, form == 0, morphed ? (Vec3){ 0.25f, 0, 0 } : (Vec3){})!!;
        }
        ViewDesc view = render::texture_view_desc(fixture.hdr_target);
        view.ray_tracing.shadows = true;
        render::configure_view(renderer, fixture.view, view)!!;
        ModelId model = pipeline_model(
            fixture: &fixture,
            material: fixture.plain,
            geometry: geometry,
            morphed: morphed,
        )!!;
        PrepareId prepare = renderer.begin_prepare_model(model)!!;
        complete_pipeline_model(renderer, prepare, 1)!!;
        assert(renderer.posed_trace.pose_pipeline.is_valid());
        assert(renderer.posed_trace.pose_u16_pipeline.is_valid());
        assert(renderer.posed_trace.refit_pipeline.is_valid());
        renderer.end_prepare(prepare)!!;
        DeformedScene target;
        if (form == 1) {
            target = preparation_asset_scene(
                fixture: &fixture,
                geometry: geometry,
                material: fixture.plain,
                skeleton: preparation_asset_skeleton(&fixture)!!,
            )!!;
        } else {
            target = create_single_box_scene(
                fixture: &fixture,
                geometry: geometry,
                material: fixture.plain,
                sunlit: false,
            )!!;
            if (morphed) {
                Mesh* mesh = target.scene.get(target.mesh, Mesh);
                mesh.morph_weights = alloc::new_array(target.scene.allocator, float, 1);
                mesh.morph_weights[0] = 0.5f;
            } else {
                Node* joint = target.scene.add_node()!!;
                joint.local.position = { 0.15f, 0, 0 };
                Node*[] joints = alloc::new_array(target.scene.allocator, Node*, 1);
                joints[0] = joint;
                target.scene.add(target.mesh, (SkinBinding){ .skeleton = fixture.skeleton, .joints = joints });
            }
        }
        defer c3d::scene::destroy_scene(&target.scene);
        target.scene.update_world();
        renderer.begin_frame()!!;
        SparsePipelineSnapshot before = sparse_pipeline_snapshot(&renderer.device)!!;
        ulong calls = renderer.pipelines.creations.calls;
        renderer.render_view(&target.scene, target.camera, fixture.view)!!;
        assert(renderer.stats.trace_posed_instances == 1 && renderer.stats.trace_poses == 1);
        assert(renderer.stats.trace_refits == 1);
        assert(renderer.pipelines.creations.calls == calls);
        assert(sparse_pipeline_snapshot(&renderer.device)!!.available == before.available);
        renderer.finish_view(fixture.view)!!;
        renderer.end_frame()!!;
        render::wait_frames(renderer)!!;
        check_validation(renderer);
    }
}

fn void test_prepare_shader_invalid_adoption_keeps_old_handles_and_finishes_record() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    PublishedScene published = create_published_scene(&fixture)!!;
    defer c3d::scene::destroy_scene(&published.target.scene);
    ModelId model = pipeline_model(&fixture, published.material)!!;
    PrepareId initial = renderer.begin_prepare_model(model)!!;
    complete_pipeline_model(renderer, initial, 1)!!;
    renderer.end_prepare(initial)!!;
    uint expected = render_published_frames(&fixture, &published.target, fixture.view)!!;
    check_opaque_color(expected);
    @pool() {
        PipelineKey[] old_keys = renderer.pipelines.keys_of(tmem, published.shader, 1);
        assert(old_keys.len > 0);
        gpu::PipelineHandle[] old_handles = alloc::new_array(tmem, gpu::PipelineHandle, old_keys.len);
        foreach (index, key : old_keys) old_handles[index] = renderer.pipelines.pipelines.get(key)!!;
        published_replace(&fixture, published.shader, broken_fragment: true)!!;
        assert(@catch(renderer.pipelines.replace_shader(
            allocator: tmem,
            device: &renderer.device,
            shader: published.shader,
            old_revision: 1,
            new_revision: 2,
            stages: &fixture.assets.shader(published.shader).desc,
        )) == gpu::SHADER_INVALID);
        assert(renderer.shaders[published.shader.index].rejected_revision == 0);
        ulong copies = renderer.prepare_counters.copied_bytes;
        ulong calls = renderer.prepare_counters.pipelines;
        PrepareId updated = renderer.begin_prepare_model(model)!!;
        complete_pipeline_model(renderer, updated, 0)!!;
        assert(renderer.prepare_progress(updated).state == PrepareState.READY);
        assert(!renderer.prepare_progress(updated).failure);
        assert(renderer.prepare_counters.copied_bytes > copies && renderer.prepare_counters.pipelines > calls);
        assert(renderer.shaders[published.shader.index].revision == 1);
        assert(renderer.shaders[published.shader.index].rejected_revision == 2);
        assert(renderer.pipelines.keys_of(tmem, published.shader, 1).len == old_keys.len);
        assert(renderer.pipelines.keys_of(tmem, published.shader, 2).len == 0);
        foreach (index, key : old_keys) assert(renderer.pipelines.pipelines.get(key)!! == old_handles[index]);
        renderer.end_prepare(updated)!!;
        uint actual = render_published_frames(&fixture, &published.target, fixture.view)!!;
        check_near_pixel(actual, expected);
    };
    check_validation(renderer);
}

fn void test_prepare_rejected_builtin_key_fails_only_its_record() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ModelId bad_model = pipeline_model(&fixture, fixture.plain)!!;
    PrepareId rejected = renderer.begin_prepare_model(bad_model)!!;
    PipelineKey key;
    bool selected;
    foreach (unit : renderer.prepares.get(rejected).units) {
        if (unit.kind != PrepareUnitKind.PIPELINES || unit.pipeline.kind != PreparePipelineKind.CACHE) continue;
        if (unit.pipeline.pass != PreparePipelinePass.FORWARD || unit.pipeline.key.shader.generation) continue;
        key = unit.pipeline.key;
        selected = true;
        break;
    }
    assert(selected && !renderer.pipelines.pipelines.has_key(key));
    renderer.pipelines.rejected.set(key, true);
    MaterialId standard = fixture.assets.add_material(c3d::material::standard())!!;
    ModelTemplate template = {
        .nodes = alloc::new_array(fixture.assets.allocator, NodeTemplate, 1),
        .meshes = alloc::new_array(fixture.assets.allocator, ModelMesh, 1),
    };
    template.nodes[0] = { .parent = -1, .local = c3d::maths::TRANSFORM_IDENTITY, .visible = true };
    template.meshes[0] = { .node = 0, .geometry = fixture.box, .material = standard };
    ModelId good_model = fixture.assets.add_model_owned(&template)!!;
    PrepareId good = renderer.begin_prepare_model(good_model)!!;
    renderer.begin_frame()!!;
    renderer.advance_prepares_within({})!!;
    PrepareProgress failed = renderer.prepare_progress(rejected);
    assert(failed.state == PrepareState.FAILED && failed.failure == render::PIPELINE_REJECTED);
    assert(renderer.prepare_progress(good).state != PrepareState.FAILED);
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;
    complete_pipeline_model(renderer, good, 1)!!;
    renderer.begin_frame()!!;
    PrepareReport no_work = renderer.advance_prepares_within({})!!;
    assert(no_work.pipelines == 0 && no_work.staged_bytes == 0);
    renderer.end_frame()!!;
    renderer.end_prepare(rejected)!!;
    renderer.end_prepare(good)!!;
    check_validation(renderer);
}
