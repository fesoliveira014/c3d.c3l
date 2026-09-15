module c3d::render::post;

import c3d;
import c3d::render @public;
import c3d::shader;
import gpu;

<*
 Compute pipelines of the display and effect stages, created on first use.
*>
struct PostPipelines {
    gpu::PipelineHandle grade;
    gpu::PipelineHandle fxaa;
    gpu::PipelineHandle bloom_downsample;
    gpu::PipelineHandle bloom_upsample;
}

struct LutBinding @private {
    gpu::TextureIndex texture;
    uint              size;
}

<*
 Record the view's display processing into the frame's window output.
 @param [&inout] renderer : "Open frame with its scene view recorded."
 @param [&inout] record : "Its working images change state."
 @param camera_exposure : "Multiplier of the scene view's camera."
 @return? c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE, c3d::SHADER_NOT_FOUND
 @return? gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? record_display(Renderer* renderer, ViewRecord* record, float camera_exposure) {
    GradeParams* grade = &record.desc.post.grade;
    LutBinding lut = resolve_lut(renderer, grade.lut)!;
    BloomBinding bloom = record.desc.post.bloom ? record_bloom(renderer, record)! : (BloomBinding){};
    if (!record.desc.post.fxaa) {
        close_post_chain(renderer)!;
        return record_fused_display(
            renderer:        renderer,
            grade:           grade,
            lut:             lut,
            bloom:           bloom,
            camera_exposure: camera_exposure,
        );
    }

    ensure_post_pipelines(renderer)!;
    open_post_chain(renderer)!;
    record_grade(
        renderer:        renderer,
        record:          record,
        grade:           grade,
        lut:             lut,
        bloom:           bloom,
        camera_exposure: camera_exposure,
    )!;
    record_fxaa(renderer, record)!;
    close_post_chain(renderer)!;
    renderer.stats.post_dispatches += 2;

    return render::composite_target(renderer, &record.post_b);
}

<*
 Create the pipelines the view's display route needs.
 @param [&inout] renderer : "No open frame required; pipelines persist."
 @param [&in] record : "Selects the route by its FXAA setting."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE
 @return? gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? prepare_display(Renderer* renderer, ViewRecord* record) {
    if (record.desc.post.bloom) ensure_bloom_pipelines(renderer)!;
    if (record.desc.post.fxaa) return ensure_post_pipelines(renderer);
    if (!renderer.swapchain.is_valid()) return;
    renderer.pipelines.get(&renderer.device, display_pipeline_key(renderer.window_target.format))!;
}

<*
 Destroy the compute pipelines.
 @param [&inout] device : "Owner of the pipelines."
 @param [&inout] pipelines : "Cleared."
*>
fn void destroy_post_pipelines(gpu::Device* device, PostPipelines* pipelines) {
    if (pipelines.grade.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.grade);
    if (pipelines.fxaa.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.fxaa);
    if (pipelines.bloom_downsample.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.bloom_downsample);
    if (pipelines.bloom_upsample.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.bloom_upsample);
    *pipelines = {};
}

fn LutBinding? resolve_lut(Renderer* renderer, TextureId lut) @private {
    if (!lut.generation) return {};
    if (!renderer.assets.textures.is_live(lut)) return c3d::INVALID_ID~;

    TextureRes* mirror = render::ensure_texture(renderer, lut)!;
    render::record_pending_copies(renderer, &renderer.commands)!;
    return { .texture = mirror.view.index, .size = mirror.width };
}

fn void? record_fused_display(
    Renderer* renderer,
    GradeParams* grade,
    LutBinding lut,
    BloomBinding bloom,
    float camera_exposure,
) @private {
    renderer.scene_input.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;

    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, DisplayRoot::size)!;
    DisplayRoot* display = (DisplayRoot*)root.bytes.ptr;
    *display = {
        .source_texture = renderer.scene_input.view.index,
        .source_sampler = renderer.linear_clamp_sampler,
    };
    write_grade_gpu(
        gpu_grade:       &display.grade,
        params:          grade,
        camera_exposure: camera_exposure,
        lut_texture:     lut.texture,
        lut_sampler:     renderer.linear_clamp_sampler,
        lut_size:        lut.size,
        bloom_texture:   bloom.texture,
        bloom_sampler:   renderer.linear_clamp_sampler,
        bloom_intensity: bloom.intensity,
    );
    gpu::PipelineHandle pipeline = renderer.pipelines.get(
        &renderer.device, display_pipeline_key(renderer.window_target.format),
    )!;

    render::write_pass_timestamp(
        renderer:    renderer,
        frame_index: renderer.frame_index,
        pass:        Pass.COMPOSITE,
        half:        render::TIMESTAMP_BEGIN,
    )!;
    render::record_fullscreen_pass(
        renderer:      renderer,
        target:        &renderer.window_target,
        pipeline:      pipeline,
        fragment_root: root.address,
    )!;
    render::write_pass_timestamp(
        renderer:    renderer,
        frame_index: renderer.frame_index,
        pass:        Pass.COMPOSITE,
        half:        render::TIMESTAMP_END,
    )!;
    slot.timed[Pass.COMPOSITE.ordinal] = true;
}

fn void? record_grade(
    Renderer* renderer,
    ViewRecord* record,
    GradeParams* grade,
    LutBinding lut,
    BloomBinding bloom,
    float camera_exposure,
) @private {
    renderer.scene_input.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.post_a.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;

    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, GradeRoot::size)!;
    GradeRoot* grade_root = (GradeRoot*)root.bytes.ptr;
    *grade_root = {
        .input_texture  = renderer.scene_input.view.index,
        .sampler_index  = renderer.linear_clamp_sampler,
        .output_texture = record.post_a.view.index,
        .width          = record.post_a.width,
        .height         = record.post_a.height,
    };
    write_grade_gpu(
        gpu_grade:       &grade_root.grade,
        params:          grade,
        camera_exposure: camera_exposure,
        lut_texture:     lut.texture,
        lut_sampler:     renderer.linear_clamp_sampler,
        lut_size:        lut.size,
        bloom_texture:   bloom.texture,
        bloom_sampler:   renderer.linear_clamp_sampler,
        bloom_intensity: bloom.intensity,
    );
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.grade)!;
    dispatch_over(renderer, root.address, &record.post_a)!;
}

fn void? record_fxaa(Renderer* renderer, ViewRecord* record) @private {
    record.post_a.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.post_b.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;

    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, FxaaRoot::size)!;
    *(FxaaRoot*)root.bytes.ptr = {
        .input_texture  = record.post_a.view.index,
        .sampler_index  = renderer.linear_clamp_sampler,
        .output_texture = record.post_b.view.index,
        .width          = record.post_b.width,
        .height         = record.post_b.height,
    };
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.fxaa)!;
    dispatch_over(renderer, root.address, &record.post_b)!;
}

fn void? dispatch_over(Renderer* renderer, gpu::GpuAddress root, Target* target) @private {
    uint groups_x = (target.width + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
    uint groups_y = (target.height + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
    return gpu::cmd_dispatch(&renderer.commands, root, { groups_x, groups_y, 1 });
}

fn PipelineKey display_pipeline_key(gpu::Format output_format) @private {
    return {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = DISPLAY },
        .color_formats = { [0] = output_format },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
}

fn void? ensure_post_pipelines(Renderer* renderer) @private {
    ensure_compute_pipeline(renderer, &renderer.post_pipelines.grade, ShaderName.GRADE, "post_grade")!;
    ensure_compute_pipeline(renderer, &renderer.post_pipelines.fxaa, ShaderName.FXAA, "post_fxaa")!;
}

fn void? ensure_compute_pipeline(
    Renderer* renderer,
    gpu::PipelineHandle* pipeline,
    ShaderName shader,
    ZString debug_name,
) @private {
    if (pipeline.is_valid()) return;

    gpu::ComputePipelineDesc description = {
        .shader     = { .spirv = renderer.pipelines.registry.get({ .shader = shader })! },
        .debug_name = debug_name,
    };
    *pipeline = gpu::create_compute_pipeline(&renderer.device, &description)!;
}

fn void? open_post_chain(Renderer* renderer) @private {
    if (renderer.post_chain_open) return;

    render::write_pass_timestamp(
        renderer:    renderer,
        frame_index: renderer.frame_index,
        pass:        Pass.POST_CHAIN,
        half:        render::TIMESTAMP_BEGIN,
    )!;
    renderer.post_chain_open = true;
}

fn void? close_post_chain(Renderer* renderer) @private {
    if (!renderer.post_chain_open) return reset_post_timing(renderer);

    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    render::write_pass_timestamp(
        renderer:    renderer,
        frame_index: renderer.frame_index,
        pass:        Pass.POST_CHAIN,
        half:        render::TIMESTAMP_END,
    )!;
    slot.timed[Pass.POST_CHAIN.ordinal] = true;
    renderer.post_chain_open = false;
}

fn void? reset_post_timing(Renderer* renderer) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    if (!slot.timed[Pass.POST_CHAIN.ordinal]) return;

    if (renderer.timestamps_enabled) {
        gpu::cmd_reset_timestamps(
            commands: &renderer.commands,
            pool:     renderer.timestamps,
            first:    render::pass_timestamp_slot(renderer.frame_index, Pass.POST_CHAIN.ordinal),
            count:    render::TIMESTAMPS_PER_PASS,
        )!;
    }
    slot.timed[Pass.POST_CHAIN.ordinal] = false;
}
