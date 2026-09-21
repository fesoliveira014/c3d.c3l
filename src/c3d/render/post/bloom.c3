module c3d::render::post;

import c3d;
import c3d::render @public;
import c3d::shader;
import gpu;

<*
 Level-0 image of a recorded bloom chain and its mix factor; zero without bloom.
*>
struct BloomBinding {
    gpu::TextureIndex texture;
    float             intensity;
}

<*
 Record the view's bloom chain from the scene input and return its level-0 binding.
 @param [&inout] renderer : "Open frame; the chain reads scene_input."
 @param [&inout] record : "Bloom images change state; bloom_levels images exist."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require record.bloom_levels > 0
*>
fn BloomBinding? record_bloom(Renderer* renderer, ViewRecord* record) {
    acquire_bloom_pipelines(renderer)!;
    open_post_chain(renderer, record)!;
    BloomParams* params = &record.desc.post.bloom_params;
    uint levels = record.bloom_levels;

    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.bloom_downsample)!;
    Target* input = record.scene_input;
    for (uint level = 0; level < levels; level++) {
        Target* output = &record.bloom[level];
        input.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
        output.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        record_bloom_dispatch(
            renderer:  renderer,
            input:     input,
            output:    output,
            prefilter: level == 0,
            params:    params,
        )!;
        input = output;
    }

    if (levels > 1) gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.bloom_upsample)!;
    for (uint level = levels - 1; level > 0; level--) {
        Target* coarse = &record.bloom[level];
        Target* fine = &record.bloom[level - 1];
        coarse.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
        fine.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read, .write }))!;
        record_bloom_dispatch(
            renderer:  renderer,
            input:     coarse,
            output:    fine,
            prefilter: false,
            params:    params,
        )!;
    }

    record.bloom[0].transition(&renderer.commands, gpu::sampled_at({ .compute, .fragment_shader }))!;
    record.bloom_recorded = true;
    renderer.stats.post_dispatches += 2 * levels - 1;
    return { .texture = record.bloom[0].view.index, .intensity = params.intensity };
}

fn void? acquire_bloom_pipelines(Renderer* renderer) @private {
    render::acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.bloom_downsample,
        shader:     ShaderName.BLOOM_DOWNSAMPLE,
        debug_name: "post_bloom_downsample",
    )!;
    render::acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.bloom_upsample,
        shader:     ShaderName.BLOOM_UPSAMPLE,
        debug_name: "post_bloom_upsample",
    )!;
}

fn void? record_bloom_dispatch(
    Renderer* renderer,
    Target* input,
    Target* output,
    bool prefilter,
    BloomParams* params,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, BloomRoot::size)!;
    *(BloomRoot*)root.bytes.ptr = {
        .input_texture  = input.view.index,
        .sampler_index  = renderer.linear_clamp_sampler,
        .output_texture = output.view.index,
        .width          = output.width,
        .height         = output.height,
        .prefilter      = prefilter ? 1 : 0,
        .threshold      = params.threshold,
        .knee           = params.knee,
        .input_texel    = { 1.0f / (float)input.width, 1.0f / (float)input.height },
    };
    return dispatch_over(renderer, root.address, output);
}
