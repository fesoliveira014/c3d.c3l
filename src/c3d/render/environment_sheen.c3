module c3d::render;

import c3d::shader;
import gpu;

const uint SHEEN_IMAGE_GROUP_SIZE @local = 8; // Mirrors both sheen compute image workgroups.

fn void? ensure_sheen_lut(Renderer* renderer) @private {
    if (renderer.environment_state.sheen_lut_state != EnvironmentLutState.NONE) return;

    gpu::TextureDesc description = {
        .width = shader::SHEEN_LUT_SIZE,
        .height = shader::SHEEN_LUT_SIZE,
        .mip_levels = 1,
        .array_layers = 1,
        .format = gpu::Format.RGBA16_FLOAT,
        .usage = { .sampled, .storage },
        .access = { .graphics },
        .debug_name = "sheen_albedo",
    };
    gpu::TextureHandle texture = gpu::create_texture(&renderer.device, &description)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, texture);
    gpu::TextureView view = gpu::create_texture_view(&renderer.device, texture, null)!;
    defer catch (void)gpu::destroy_texture_view(&renderer.device, view);
    gpu::SamplerDesc sampler = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .mip_filter = gpu::Filter.NEAREST,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
        .min_lod = 0,
        .max_lod = 0,
        .debug_name = "sheen_albedo",
    };
    gpu::SamplerIndex sampler_index = gpu::intern_sampler(&renderer.device, &sampler)!;
    renderer.environment_state.sheen_lut_texture = texture;
    renderer.environment_state.sheen_lut_view = view;
    renderer.environment_state.sheen_sampler = sampler_index;
    renderer.environment_state.sheen_lut_state = EnvironmentLutState.PENDING;
}

fn void release_sheen_lut(Renderer* renderer) @private {
    (void)gpu::destroy_texture_view(&renderer.device, renderer.environment_state.sheen_lut_view);
    (void)gpu::destroy_texture(&renderer.device, renderer.environment_state.sheen_lut_texture);
    renderer.environment_state.sheen_lut_texture = {};
    renderer.environment_state.sheen_lut_view = {};
    renderer.environment_state.sheen_lut_state = EnvironmentLutState.NONE;
}

fn void? create_environment_sheen(Renderer* renderer, EnvironmentRes* result) @private {
    gpu::TextureDesc description = {
        .width = result.description.settings.specular_size,
        .height = result.description.settings.specular_size,
        .mip_levels = shader::ENVIRONMENT_SPECULAR_MIPS,
        .array_layers = shader::ENVIRONMENT_FACE_COUNT,
        .cube_compatible = true,
        .format = gpu::Format.RGBA16_FLOAT,
        .usage = { .sampled, .storage },
        .access = { .graphics },
        .debug_name = "environment_sheen",
    };
    gpu::TextureHandle texture = gpu::create_texture(&renderer.device, &description)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, texture);
    gpu::TextureViewDesc view_desc = { .cube = true };
    gpu::TextureView view = gpu::create_texture_view(&renderer.device, texture, &view_desc)!;
    result.sheen_cube = texture;
    result.sheen_view = view;
}

fn void release_environment_sheen(gpu::Device* device, EnvironmentRes* result) @private {
    if (result.sheen_view.is_valid()) (void)gpu::destroy_texture_view(device, result.sheen_view);
    if (result.sheen_cube.is_valid()) (void)gpu::destroy_texture(device, result.sheen_cube);
}

fn void retire_environment_sheen(RetireList* retire, EnvironmentRes* result) @private {
    if (!result.sheen_cube.is_valid()) return;
    retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = result.sheen_view });
    retire.push({ .kind = RetiredKind.TEXTURE, .texture = result.sheen_cube });
}

fn void? record_sheen_lut(Renderer* renderer, gpu::CommandList* commands) @private {
    ensure_environment_pipeline(renderer, &renderer.environment_state.pipelines.sheen_lut, SHEEN_LUT)!;
    Frame* slot = recording_frame(renderer, commands);
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: renderer.environment_state.sheen_lut_texture,
        before: {},
        after: gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, BrdfLutRoot::size)!;
    *(BrdfLutRoot*)root.bytes.ptr = {
        .output_texture = renderer.environment_state.sheen_lut_view.index,
        .size = shader::SHEEN_LUT_SIZE,
    };
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.sheen_lut)!;
    gpu::cmd_dispatch(commands, root.address, {
        shader::SHEEN_LUT_SIZE / SHEEN_IMAGE_GROUP_SIZE,
        shader::SHEEN_LUT_SIZE / SHEEN_IMAGE_GROUP_SIZE, 1,
    })!;
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: renderer.environment_state.sheen_lut_texture,
        before: write.after,
        after: gpu::sampled_at({ .fragment_shader }),
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;
    renderer.environment_state.sheen_lut_state = EnvironmentLutState.RECORDED;
}

fn void? record_environment_sheen(
    Renderer* renderer,
    gpu::CommandList* commands,
    PendingEnvironment* pending,
) @private {
    ensure_environment_pipeline(renderer, &renderer.environment_state.pipelines.sheen_prefilter, SHEEN_PREFILTER)!;
    EnvironmentRes* result = &pending.result;
    Frame* slot = recording_frame(renderer, commands);
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: result.sheen_cube,
        before: {},
        after: gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.sheen_prefilter)!;
    for (uint mip = 0; mip < shader::ENVIRONMENT_SPECULAR_MIPS; mip++) {
        uint size = result.description.settings.specular_size >> mip;
        for (uint face = 0; face < shader::ENVIRONMENT_FACE_COUNT; face++) {
            gpu::TextureView view = create_environment_write_view(
                renderer: renderer,
                texture: result.sheen_cube,
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
            uint groups = (size + SHEEN_IMAGE_GROUP_SIZE - 1) / SHEEN_IMAGE_GROUP_SIZE;
            gpu::cmd_dispatch(commands, root.address, { groups, groups, 1 })!;
        }
    }
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: result.sheen_cube,
        before: write.after,
        after: gpu::sampled_at({ .fragment_shader }),
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;
}
