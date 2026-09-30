module c3d::render;

import c3d::light;
import c3d::shader;
import gpu;

const uint ENVIRONMENT_LUT_SIZE @private = 256; // Two integrated BRDF terms in a shared 512 KiB image.
const uint ENVIRONMENT_IMAGE_GROUP_SIZE @private = 8; // Mirrors local_size_x/y in environment image stages.

fn void? acquire_environment_lut(Renderer* renderer) @private {
    if (renderer.environment_state.brdf_lut.state != EnvironmentLutState.NONE) return;
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
    renderer.environment_state.brdf_lut.texture = texture;
    renderer.environment_state.brdf_lut.view = view;
    renderer.environment_state.brdf_lut.state = EnvironmentLutState.PENDING;
}

fn void? acquire_environment_pipeline(
    Renderer* renderer,
    gpu::PipelineHandle* pipeline,
    ShaderName shader,
) @private {
    return acquire_compute_pipeline(renderer, pipeline, shader, "environment_processing");
}

fn void? record_environment_preparations(Renderer* renderer, gpu::CommandList* commands) @private {
    if (!environment_work_unrecorded(renderer)) return;
    @profile_pass(renderer, Pass.ENVIRONMENT) {
        foreach (&pending : renderer.environment_state.pending) {
            if (pending.write_source && !pending.source_recorded) {
                @profile_stage(renderer, EnvironmentStage.SOURCE) {
                    record_environment_source(renderer, commands, pending)!;
                }!;
                pending.source_recorded = true;
            }
            if (pending.write_lighting && !pending.lighting_recorded) {
                @profile_stage(renderer, EnvironmentStage.PREFILTER) {
                    record_environment_prefilter(renderer, commands, pending)!;
                }!;
                @profile_stage(renderer, EnvironmentStage.IRRADIANCE) {
                    record_environment_irradiance(renderer, commands, pending)!;
                }!;
                pending.lighting_recorded = true;
            }
            if (pending.write_sheen && !pending.sheen_recorded) {
                @profile_stage(renderer, EnvironmentStage.SHEEN) {
                    record_environment_sheen(renderer, commands, pending)!;
                }!;
                pending.sheen_recorded = true;
            }
        }
        if (environment_luts_unrecorded(renderer)) {
            @profile_stage(renderer, EnvironmentStage.LUTS) {
                record_environment_luts(renderer, commands)!;
            }!;
        }
    }!;
}

fn bool environment_work_unrecorded(Renderer* renderer) @local {
    if (environment_luts_unrecorded(renderer)) return true;
    foreach (&pending : renderer.environment_state.pending) {
        if (pending.write_source && !pending.source_recorded) return true;
        if (pending.write_lighting && !pending.lighting_recorded) return true;
        if (pending.write_sheen && !pending.sheen_recorded) return true;
    }
    return false;
}

fn bool environment_luts_unrecorded(Renderer* renderer) @local {
    return renderer.environment_state.sheen_lut.state == EnvironmentLutState.PENDING
      || renderer.environment_state.brdf_lut.state == EnvironmentLutState.PENDING;
}

fn void? record_environment_luts(Renderer* renderer, gpu::CommandList* commands) @local {
    if (renderer.environment_state.sheen_lut.state == EnvironmentLutState.PENDING) {
        record_sheen_lut(renderer, commands)!;
    }
    if (renderer.environment_state.brdf_lut.state != EnvironmentLutState.PENDING) return;
    acquire_environment_pipeline(renderer, &renderer.environment_state.pipelines.brdf, BRDF_LUT)!;
    record_environment_lut(
        renderer: renderer,
        commands: commands,
        pipeline: renderer.environment_state.pipelines.brdf,
        lut: &renderer.environment_state.brdf_lut,
        size: ENVIRONMENT_LUT_SIZE,
    )!;
}

fn void? record_environment_lut(
    Renderer* renderer,
    gpu::CommandList* commands,
    gpu::PipelineHandle pipeline,
    EnvironmentLut* lut,
    uint size,
) @private {
    Frame* slot = recording_frame(renderer, commands);
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: lut.texture,
        before: {},
        after: gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, BrdfLutRoot::size)!;
    *(BrdfLutRoot*)root.bytes.ptr = {
        .output_texture = lut.view.index,
        .size = size,
    };
    gpu::cmd_bind_pipeline(commands, pipeline)!;
    gpu::cmd_dispatch(commands, root.address, {
        size / ENVIRONMENT_IMAGE_GROUP_SIZE,
        size / ENVIRONMENT_IMAGE_GROUP_SIZE, 1,
    })!;
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: lut.texture,
        before: write.after,
        after: gpu::sampled_at({ .fragment_shader }),
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;
    lut.state = EnvironmentLutState.RECORDED;
}

fn void? record_environment_source(
    Renderer* renderer,
    gpu::CommandList* commands,
    PendingEnvironment* pending,
) @local {
    acquire_environment_pipeline(renderer, &renderer.environment_state.pipelines.source, ENVIRONMENT_SOURCE)!;
    EnvironmentRes* result = &pending.result;
    Frame* slot = recording_frame(renderer, commands);
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: result.source_cube,
        before: pending.new_source ? (gpu::TextureState){} : renderer.sampled_state,
        after: gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.source)!;
    for (uint face = 0; face < shader::ENVIRONMENT_FACE_COUNT; face++) {
        gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, EnvironmentSourceRoot::size)!;
        *(EnvironmentSourceRoot*)root.bytes.ptr = {
            .source_texture = pending.input_texture,
            .sampler_index = renderer.environment_state.source_sampler,
            .output_texture = result.source_faces[face].index,
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
        after: renderer.sampled_state,
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;
}

fn void? record_environment_prefilter(
    Renderer* renderer,
    gpu::CommandList* commands,
    PendingEnvironment* pending,
) @local {
    acquire_environment_pipeline(renderer, &renderer.environment_state.pipelines.prefilter, ENVIRONMENT_PREFILTER)!;
    EnvironmentRes* result = &pending.result;
    record_cube_prefilter(
        renderer: renderer,
        commands: commands,
        pipeline: renderer.environment_state.pipelines.prefilter,
        source_view: result.source_view,
        output: result.specular_cube,
        faces: result.specular_faces[..],
        previous: pending.new_lighting ? (gpu::TextureState){} : renderer.sampled_state,
        base_size: result.specular_size,
    )!;
}

fn void? record_environment_irradiance(
    Renderer* renderer,
    gpu::CommandList* commands,
    PendingEnvironment* pending,
) @local {
    acquire_environment_pipeline(renderer, &renderer.environment_state.pipelines.project, IRRADIANCE_PROJECT)!;
    acquire_environment_pipeline(renderer, &renderer.environment_state.pipelines.reduce, IRRADIANCE_REDUCE)!;
    EnvironmentRes* result = &pending.result;
    Frame* slot = recording_frame(renderer, commands);
    // Orders the rewrite of the SH and partials after their earlier readers on this queue.
    gpu::Barrier earlier_reads = { .before = renderer.consumer_stages, .after = { .compute } };
    gpu::cmd_barrier(commands, &earlier_reads)!;
    gpu::MappedGpuSpan project = slot.upload.take(&renderer.device, IrradianceProjectRoot::size)!;
    *(IrradianceProjectRoot*)project.bytes.ptr = {
        .source_cube = result.source_view.index,
        .sampler_index = renderer.environment_state.sampler,
        .source_size = result.source_size,
        .partial_count = shader::ENVIRONMENT_SH_GROUPS,
        .partials = result.partials_address,
    };
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.project)!;
    gpu::cmd_dispatch(commands, project.address, { shader::ENVIRONMENT_SH_GROUPS, 1, 1 })!;
    gpu::Barrier partials_ready = { .before = { .compute }, .after = { .compute } };
    gpu::cmd_barrier(commands, &partials_ready)!;
    gpu::MappedGpuSpan reduce = slot.upload.take(&renderer.device, IrradianceReduceRoot::size)!;
    *(IrradianceReduceRoot*)reduce.bytes.ptr = {
        .partials = result.partials_address,
        .output_coefficients = result.irradiance_address,
        .partial_count = shader::ENVIRONMENT_SH_GROUPS,
    };
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.reduce)!;
    gpu::cmd_dispatch(commands, reduce.address, { 1, 1, 1 })!;
    gpu::Barrier irradiance_ready = { .before = { .compute }, .after = { .fragment_shader } };
    gpu::cmd_barrier(commands, &irradiance_ready)!;
}

fn void? record_cube_prefilter(
    Renderer* renderer,
    gpu::CommandList* commands,
    gpu::PipelineHandle pipeline,
    gpu::TextureView source_view,
    gpu::TextureHandle output,
    gpu::TextureView[] faces,
    gpu::TextureState previous,
    uint base_size,
) @private {
    Frame* slot = recording_frame(renderer, commands);
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: output,
        before: previous,
        after: gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::cmd_bind_pipeline(commands, pipeline)!;
    for (uint mip = 0; mip < shader::ENVIRONMENT_SPECULAR_MIPS; mip++) {
        uint size = base_size >> mip;
        for (uint face = 0; face < shader::ENVIRONMENT_FACE_COUNT; face++) {
            gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, EnvironmentPrefilterRoot::size)!;
            *(EnvironmentPrefilterRoot*)root.bytes.ptr = {
                .source_cube = source_view.index,
                .sampler_index = renderer.environment_state.sampler,
                .output_texture = faces[mip * shader::ENVIRONMENT_FACE_COUNT + face].index,
                .face = face,
                .size = size,
                .roughness = (float)mip / (float)(shader::ENVIRONMENT_SPECULAR_MIPS - 1),
            };
            uint groups = (size + ENVIRONMENT_IMAGE_GROUP_SIZE - 1) / ENVIRONMENT_IMAGE_GROUP_SIZE;
            gpu::cmd_dispatch(commands, root.address, { groups, groups, 1 })!;
        }
    }
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: output,
        before: write.after,
        after: renderer.sampled_state,
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;
}

fn Frame* recording_frame(Renderer* renderer, gpu::CommandList* commands) @private {
    uint index = commands == &renderer.commands ? renderer.recording_slot
      : (uint)(renderer.frame_index % FRAMES_IN_FLIGHT);
    return &renderer.frames[index];
}
