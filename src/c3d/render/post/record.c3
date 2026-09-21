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
    gpu::PipelineHandle tile_max;
    gpu::PipelineHandle tile_neighbor;
    gpu::PipelineHandle dof_coc;
    gpu::PipelineHandle dof_gather;
    gpu::PipelineHandle dof_composite;
    gpu::PipelineHandle motion_blur;
}

struct LutBinding @private {
    gpu::TextureIndex texture;
    uint              size;
}

<*
 Record the view's display processing into the output rectangle.
 @param [&inout] renderer : "Open frame with its scene view recorded."
 @param [&inout] record : "Its working images change state."
 @param [&inout] output : "Attachment the view writes; transitions to color attachment."
 @param rect : "Output pixels; a zero extent covers the output."
 @return? c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE, c3d::SHADER_NOT_FOUND
 @return? gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? record_display(
    Renderer* renderer,
    ViewRecord* record,
    Target* output,
    PixelRect rect,
) {
    GradeParams* grade = &record.desc.post.grade;
    LutBinding lut = resolve_lut(renderer, grade.lut)!;
    bool bloom_needed = record.desc.post.bloom
        && (record.desc.post.bloom_params.intensity > 0 || render::bloom_preview_requested(renderer, record));
    BloomBinding bloom = bloom_needed ? record_bloom(renderer, record)! : (BloomBinding){};
    if (!record.desc.post.fxaa) {
        close_post_chain(renderer, record)!;
        return record_fused_display(
            renderer: renderer,
            record:   record,
            output:   output,
            rect:     rect,
            grade:    grade,
            lut:      lut,
            bloom:    bloom,
        );
    }

    acquire_post_pipelines(renderer)!;
    open_post_chain(renderer, record)!;
    record_grade(
        renderer: renderer,
        record:   record,
        grade:    grade,
        lut:      lut,
        bloom:    bloom,
    )!;
    renderer.stats.post_dispatches += 1;
    if (fxaa_fragment_eligible(
        working_width:  record.post_a.width,
        working_height: record.post_a.height,
        rect:           rect,
        output_width:   output.width,
        output_height:  output.height,
    )) {
        close_post_chain(renderer, record)!;
        return record_fxaa_fragment(
            renderer: renderer,
            record:   record,
            output:   output,
            rect:     rect,
        );
    }

    acquire_fxaa_fallback_target(renderer, record)!;
    record_fxaa(renderer, record)!;
    close_post_chain(renderer, record)!;
    renderer.stats.post_dispatches += 1;

    return render::composite_target(
        renderer: renderer,
        source:   &record.post_b,
        output:   output,
        rect:     rect,
    );
}

<*
 Whether FXAA can write the output rectangle directly: the working image and the rectangle match in pixels.
 @param rect : "Output rectangle; zero extent means the whole output."
 @pure
*>
fn bool fxaa_fragment_eligible(
    uint working_width,
    uint working_height,
    PixelRect rect,
    uint output_width,
    uint output_height,
) {
    uint rect_width = rect.width ? rect.width : output_width;
    uint rect_height = rect.height ? rect.height : output_height;
    return working_width == rect_width && working_height == rect_height;
}

fn void? record_fxaa_fragment(
    Renderer* renderer,
    ViewRecord* record,
    Target* output,
    PixelRect rect,
) @private {
    record.post_a.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    output.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;

    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, FxaaRoot::size)!;
    *(FxaaRoot*)root.bytes.ptr = {
        .input_texture = record.post_a.view.index,
        .sampler_index = renderer.linear_clamp_sampler,
        .width         = record.post_a.width,
        .height        = record.post_a.height,
    };
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, fxaa_fragment_pipeline_key(output.format))!;

    render::begin_profile_pass(renderer, Pass.COMPOSITE)!;
    render::record_fullscreen_pass(
        renderer:      renderer,
        target:        output,
        pipeline:      pipeline,
        fragment_root: root.address,
        rect:          rect,
        load:          render::output_load_op(output, rect),
    )!;
    render::end_profile_pass(renderer, Pass.COMPOSITE)!;
}

fn PipelineKey fxaa_fragment_pipeline_key(gpu::Format output_format) @private {
    return {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = FXAA_FRAGMENT },
        .color_formats = { [0] = output_format },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
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
    if (record.desc.post.bloom) acquire_bloom_pipelines(renderer)!;
    if (record.desc.post.depth_of_field) acquire_dof_pipelines(renderer)!;
    if (record.desc.post.motion_blur) acquire_motion_blur_pipelines(renderer)!;
    if (!record.hdr_color.texture.is_valid()) return;
    gpu::Format output_format = render::view_output_format(renderer, &record.desc);
    if (record.desc.post.fxaa) {
        acquire_post_pipelines(renderer)!;
        renderer.pipelines.get(&renderer.device, fxaa_fragment_pipeline_key(output_format))!;
        return;
    }
    renderer.pipelines.get(&renderer.device, display_pipeline_key(output_format))!;
}

<*
 Destroy the compute pipelines.
 @param [&inout] device : "Owner of the pipelines."
 @param [&inout] pipelines : "Cleared."
*>
fn void destroy_post_pipelines(gpu::Device* device, PostPipelines* pipelines) {
    gpu::PipelineHandle*[10] handles = {
        &pipelines.grade, &pipelines.fxaa, &pipelines.bloom_downsample, &pipelines.bloom_upsample,
        &pipelines.tile_max, &pipelines.tile_neighbor, &pipelines.dof_coc, &pipelines.dof_gather,
        &pipelines.dof_composite, &pipelines.motion_blur,
    };
    foreach (handle : handles) {
        if (handle.is_valid()) (void)gpu::destroy_pipeline(device, *handle);
    }
    *pipelines = {};
}

fn LutBinding? resolve_lut(Renderer* renderer, TextureId lut) @private {
    if (!lut.generation) return {};
    if (!renderer.assets.textures.is_live(lut)) return c3d::INVALID_ID~;

    TextureRes* mirror = render::resolve_texture(renderer, lut)!;
    render::record_pending_copies(renderer, &renderer.commands)!;
    return { .texture = mirror.view.index, .size = mirror.width };
}

fn void? record_fused_display(
    Renderer* renderer,
    ViewRecord* record,
    Target* output,
    PixelRect rect,
    GradeParams* grade,
    LutBinding lut,
    BloomBinding bloom,
) @private {
    record.scene_input.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    output.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;

    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, DisplayRoot::size)!;
    DisplayRoot* display = (DisplayRoot*)root.bytes.ptr;
    *display = {
        .source_texture = record.scene_input.view.index,
        .source_sampler = renderer.linear_clamp_sampler,
    };
    write_grade_gpu(
        gpu_grade:       &display.grade,
        params:          grade,
        camera_exposure: record.exposure,
        lut_texture:     lut.texture,
        lut_sampler:     renderer.linear_clamp_sampler,
        lut_size:        lut.size,
        bloom_texture:   bloom.texture,
        bloom_sampler:   renderer.linear_clamp_sampler,
        bloom_intensity: bloom.intensity,
    );
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, display_pipeline_key(output.format))!;

    render::begin_profile_pass(renderer, Pass.COMPOSITE)!;
    render::record_fullscreen_pass(
        renderer:      renderer,
        target:        output,
        pipeline:      pipeline,
        fragment_root: root.address,
        rect:          rect,
        load:          render::output_load_op(output, rect),
    )!;
    render::end_profile_pass(renderer, Pass.COMPOSITE)!;
}

fn void? record_grade(
    Renderer* renderer,
    ViewRecord* record,
    GradeParams* grade,
    LutBinding lut,
    BloomBinding bloom,
) @private {
    record.scene_input.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.post_a.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;

    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, GradeRoot::size)!;
    GradeRoot* grade_root = (GradeRoot*)root.bytes.ptr;
    *grade_root = {
        .input_texture  = record.scene_input.view.index,
        .sampler_index  = renderer.linear_clamp_sampler,
        .output_texture = record.post_a.view.index,
        .width          = record.post_a.width,
        .height         = record.post_a.height,
    };
    write_grade_gpu(
        gpu_grade:       &grade_root.grade,
        params:          grade,
        camera_exposure: record.exposure,
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
    return dispatch_extent(renderer, root, target.width, target.height);
}

fn void? dispatch_extent(Renderer* renderer, gpu::GpuAddress root, uint width, uint height) @private {
    uint groups_x = (width + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
    uint groups_y = (height + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
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

fn void? acquire_post_pipelines(Renderer* renderer) @private {
    render::acquire_compute_pipeline(renderer, &renderer.post_pipelines.grade, ShaderName.GRADE, "post_grade")!;
    render::acquire_compute_pipeline(renderer, &renderer.post_pipelines.fxaa, ShaderName.FXAA, "post_fxaa")!;
}

fn void? open_post_chain(Renderer* renderer, ViewRecord* record) @private {
    if (record.post_chain_open) return;

    render::begin_profile_pass(renderer, Pass.POST_CHAIN)!;
    record.post_chain_open = true;
}

fn void? close_post_chain(Renderer* renderer, ViewRecord* record) @private {
    if (!record.post_chain_open) return;

    render::end_profile_pass(renderer, Pass.POST_CHAIN)!;
    record.post_chain_open = false;
}
