module c3d::render;

import c3d::shader;
import gpu;

fn void? ensure_sheen_lut(Renderer* renderer) @private {
    if (renderer.environment_state.sheen_lut.state != EnvironmentLutState.NONE) return;

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
    renderer.environment_state.sheen_lut.texture = texture;
    renderer.environment_state.sheen_lut.view = view;
    renderer.environment_state.sheen_sampler = sampler_index;
    renderer.environment_state.sheen_lut.state = EnvironmentLutState.PENDING;
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
    record_environment_lut(
        renderer: renderer,
        commands: commands,
        pipeline: renderer.environment_state.pipelines.sheen_lut,
        lut: &renderer.environment_state.sheen_lut,
        size: shader::SHEEN_LUT_SIZE,
    )!;
}

fn void? record_environment_sheen(
    Renderer* renderer,
    gpu::CommandList* commands,
    PendingEnvironment* pending,
) @private {
    ensure_environment_pipeline(renderer, &renderer.environment_state.pipelines.sheen_prefilter, SHEEN_PREFILTER)!;
    EnvironmentRes* result = &pending.result;
    record_cube_prefilter(
        renderer: renderer,
        commands: commands,
        pipeline: renderer.environment_state.pipelines.sheen_prefilter,
        source_view: result.source_view,
        output: result.sheen_cube,
        base_size: result.description.settings.specular_size,
    )!;
}
