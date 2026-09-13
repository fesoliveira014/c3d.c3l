module c3d::render;

import c3d::light;
import c3d::shader;
import gpu;

const uint ENVIRONMENT_LUT_SIZE @private = 256; // Two integrated BRDF terms in a shared 512 KiB image.
const uint ENVIRONMENT_IMAGE_GROUP_SIZE @local = 8; // Mirrors local_size_x/y in environment image stages.

fn void? ensure_environment_lut(Renderer* renderer) @private {
    if (renderer.environment_state.brdf_state != EnvironmentLutState.NONE) return;
    gpu::TextureDesc description = {
        .width = ENVIRONMENT_LUT_SIZE,
        .height = ENVIRONMENT_LUT_SIZE,
        .mip_levels = 1,
        .array_layers = 1,
        .format = gpu::Format.RGBA16_FLOAT,
        .usage = { .sampled, .storage },
        .access = { .graphics },
        .debug_name = "environment_brdf",
    };
    gpu::TextureHandle texture = gpu::create_texture(&renderer.device, &description)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, texture);
    gpu::TextureView view = gpu::create_texture_view(&renderer.device, texture, null)!;
    renderer.environment_state.brdf_texture = texture;
    renderer.environment_state.brdf_view = view;
    renderer.environment_state.brdf_state = EnvironmentLutState.PENDING;
}

fn void? ensure_environment_pipeline(
    Renderer* renderer,
    gpu::PipelineHandle* pipeline,
    ShaderName shader,
) @private {
    if (pipeline.is_valid()) return;
    gpu::ComputePipelineDesc description = {
        .shader = { .spirv = renderer.pipelines.registry.get({ .shader = shader })! },
        .debug_name = "environment_processing",
    };
    *pipeline = gpu::create_compute_pipeline(&renderer.device, &description)!;
}

fn void? record_environment_preparations(Renderer* renderer, gpu::CommandList* commands) @private {
    Frame* slot = recording_frame(renderer, commands);
    foreach (&pending : renderer.environment_state.pending) {
        if (!pending.active) continue;
        if (pending.new_source && !pending.source_recorded) {
            record_environment_source(renderer, commands, pending)!;
            pending.source_recorded = true;
        }
        if (pending.new_lighting && !pending.lighting_recorded) {
            record_environment_lighting(renderer, commands, pending)!;
            pending.lighting_recorded = true;
        }
        if (pending.new_sheen && !pending.sheen_recorded) {
            record_environment_sheen(renderer, commands, pending)!;
            pending.sheen_recorded = true;
        }
    }
    if (renderer.environment_state.sheen_lut_state == EnvironmentLutState.PENDING) {
        record_sheen_lut(renderer, commands)!;
    }
    if (renderer.environment_state.brdf_state != EnvironmentLutState.PENDING) return;
    ensure_environment_pipeline(renderer, &renderer.environment_state.pipelines.brdf, BRDF_LUT)!;
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: renderer.environment_state.brdf_texture,
        before: {},
        after: gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, BrdfLutRoot::size)!;
    *(BrdfLutRoot*)root.bytes.ptr = {
        .output_texture = renderer.environment_state.brdf_view.index,
        .size = ENVIRONMENT_LUT_SIZE,
    };
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.brdf)!;
    gpu::cmd_dispatch(commands, root.address, {
        ENVIRONMENT_LUT_SIZE / ENVIRONMENT_IMAGE_GROUP_SIZE,
        ENVIRONMENT_LUT_SIZE / ENVIRONMENT_IMAGE_GROUP_SIZE, 1,
    })!;
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: renderer.environment_state.brdf_texture,
        before: write.after,
        after: gpu::sampled_at({ .fragment_shader }),
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;
    renderer.environment_state.brdf_state = EnvironmentLutState.RECORDED;
}

fn gpu::TextureView? create_environment_write_view(
    Renderer* renderer,
    gpu::TextureHandle texture,
    uint face,
    uint mip,
) @private {
    gpu::TextureViewDesc description = {
        .base_mip = mip,
        .mip_count = 1,
        .base_layer = face,
        .layer_count = 1,
    };
    gpu::TextureView view = gpu::create_texture_view(&renderer.device, texture, &description)!;
    renderer.environment_state.temporaries.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = view });
    return view;
}

fn void? record_environment_source(
    Renderer* renderer,
    gpu::CommandList* commands,
    PendingEnvironment* pending,
) @local {
    ensure_environment_pipeline(renderer, &renderer.environment_state.pipelines.source, ENVIRONMENT_SOURCE)!;
    EnvironmentRes* result = &pending.result;
    Frame* slot = recording_frame(renderer, commands);
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: result.source_cube,
        before: {},
        after: gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.source)!;
    for (uint face = 0; face < shader::ENVIRONMENT_FACE_COUNT; face++) {
        gpu::TextureView view = create_environment_write_view(
            renderer: renderer,
            texture: result.source_cube,
            face: face,
            mip: 0,
        )!;
        gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, EnvironmentSourceRoot::size)!;
        *(EnvironmentSourceRoot*)root.bytes.ptr = {
            .source_texture = pending.input_texture,
            .sampler_index = renderer.environment_state.source_sampler,
            .output_texture = view.index,
            .face = face,
            .size = result.source_size,
            .source_kind = result.description.kind == SOLID
              ? shader::ENVIRONMENT_SOURCE_SOLID : shader::ENVIRONMENT_SOURCE_EQUIRECTANGULAR,
            .solid_color = { result.description.solid_color.x, result.description.solid_color.y,
              result.description.solid_color.z, 1 },
        };
        uint groups = (result.source_size + ENVIRONMENT_IMAGE_GROUP_SIZE - 1) / ENVIRONMENT_IMAGE_GROUP_SIZE;
        gpu::cmd_dispatch(commands, root.address, { groups, groups, 1 })!;
    }
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: result.source_cube,
        before: write.after,
        after: gpu::sampled_at({ .compute, .fragment_shader }),
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;
}

fn void? record_environment_lighting(
    Renderer* renderer,
    gpu::CommandList* commands,
    PendingEnvironment* pending,
) @local {
    ensure_environment_pipeline(renderer, &renderer.environment_state.pipelines.prefilter, ENVIRONMENT_PREFILTER)!;
    ensure_environment_pipeline(renderer, &renderer.environment_state.pipelines.project, IRRADIANCE_PROJECT)!;
    ensure_environment_pipeline(renderer, &renderer.environment_state.pipelines.reduce, IRRADIANCE_REDUCE)!;
    EnvironmentRes* result = &pending.result;
    Frame* slot = recording_frame(renderer, commands);
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: result.specular_cube,
        before: {},
        after: gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.prefilter)!;
    for (uint mip = 0; mip < shader::ENVIRONMENT_SPECULAR_MIPS; mip++) {
        uint size = result.description.settings.specular_size >> mip;
        for (uint face = 0; face < shader::ENVIRONMENT_FACE_COUNT; face++) {
            gpu::TextureView view = create_environment_write_view(
                renderer: renderer,
                texture: result.specular_cube,
                face: face,
                mip: mip,
            )!;
            gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, EnvironmentPrefilterRoot::size)!;
            *(EnvironmentPrefilterRoot*)root.bytes.ptr = {
                .source_cube = result.source_view.index,
                .sampler_index = renderer.environment_state.sampler,
                .output_texture = view.index,
                .face = face,
                .size = size,
                .roughness = (float)mip / (float)(shader::ENVIRONMENT_SPECULAR_MIPS - 1),
            };
            uint groups = (size + ENVIRONMENT_IMAGE_GROUP_SIZE - 1) / ENVIRONMENT_IMAGE_GROUP_SIZE;
            gpu::cmd_dispatch(commands, root.address, { groups, groups, 1 })!;
        }
    }
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: result.specular_cube,
        before: write.after,
        after: gpu::sampled_at({ .fragment_shader }),
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;

    gpu::AllocationDesc scratch_desc = {
        .size = IrradianceGpu::size * shader::ENVIRONMENT_SH_GROUPS,
        .alignment = STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access = { .graphics },
        .debug_name = "environment_irradiance_partials",
    };
    gpu::GpuAllocation scratch = gpu::allocate_memory(&renderer.device, &scratch_desc)!;
    renderer.environment_state.temporaries.push({ .kind = RetiredKind.ALLOCATION, .allocation = scratch });
    gpu::GpuAddress partials = gpu::get_span_address(
        &renderer.device, gpu::get_allocation_span(&renderer.device, scratch)!,
    )!;
    gpu::MappedGpuSpan project = slot.upload.take(&renderer.device, IrradianceProjectRoot::size)!;
    *(IrradianceProjectRoot*)project.bytes.ptr = {
        .source_cube = result.source_view.index,
        .sampler_index = renderer.environment_state.sampler,
        .source_size = result.source_size,
        .partial_count = shader::ENVIRONMENT_SH_GROUPS,
        .partials = partials,
    };
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.project)!;
    gpu::cmd_dispatch(commands, project.address, { shader::ENVIRONMENT_SH_GROUPS, 1, 1 })!;
    gpu::Barrier partials_ready = { .before = { .compute }, .after = { .compute } };
    gpu::cmd_barrier(commands, &partials_ready)!;
    gpu::MappedGpuSpan reduce = slot.upload.take(&renderer.device, IrradianceReduceRoot::size)!;
    *(IrradianceReduceRoot*)reduce.bytes.ptr = {
        .partials = partials,
        .output_coefficients = result.irradiance_address,
        .partial_count = shader::ENVIRONMENT_SH_GROUPS,
    };
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.reduce)!;
    gpu::cmd_dispatch(commands, reduce.address, { 1, 1, 1 })!;
    gpu::Barrier irradiance_ready = { .before = { .compute }, .after = { .fragment_shader } };
    gpu::cmd_barrier(commands, &irradiance_ready)!;
}

fn Frame* recording_frame(Renderer* renderer, gpu::CommandList* commands) @private {
    uint index = commands == &renderer.commands ? renderer.recording_slot
      : (uint)(renderer.frame_index % FRAMES_IN_FLIGHT);
    return &renderer.frames[index];
}
