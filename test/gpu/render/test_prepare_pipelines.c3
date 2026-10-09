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
