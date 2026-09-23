module c3d::render::post;

import c3d::maths;
import c3d::render @public;
import c3d::shader;
import gpu;
import std::math;

const gpu::Format TAA_DEPTH_FORMAT @private = gpu::Format.R32_FLOAT;
const gpu::Format TAA_VELOCITY_FORMAT @private = gpu::Format.RG16_FLOAT;
const ZString[TAA_HISTORY_SLOTS] TAA_COLOR_NAMES @private = { "taa_color_0", "taa_color_1" };
const ZString[TAA_HISTORY_SLOTS] TAA_DEPTH_NAMES @private = { "taa_depth_0", "taa_depth_1" };
const ZString[TAA_HISTORY_SLOTS] TAA_VELOCITY_NAMES @private = { "taa_velocity_0", "taa_velocity_1" };

<*
 Temporal jitter of a sample index, in NDC for the working extent.
 @require width > 0 && height > 0
 @pure
*>
fn Vec2 taa_jitter(uint sample_index, uint width, uint height) {
    uint point = sample_index % TAA_SAMPLE_COUNT + 1;
    float pixel_x = maths::halton(point, 2) - 0.5f;
    float pixel_y = maths::halton(point, 3) - 0.5f;
    return { 2 * pixel_x / (float)width, -2 * pixel_y / (float)height };
}

fn bool taa_debug_enabled(PostStack* stack) @private {
    return stack.anti_aliasing == AntiAliasing.TAA && stack.taa_params.debug != TaaDebug.NONE;
}

fn void? acquire_taa_images(Renderer* renderer, ViewRecord* record) @private {
    defer catch release_taa_images(&renderer.device, record);
    for (uint slot = 0; slot < TAA_HISTORY_SLOTS; slot++) {
        record.taa_color[slot] = allocate_post_target(
            device:     &renderer.device,
            width:      record.hdr_color.width,
            height:     record.hdr_color.height,
            format:     render::HDR_FORMAT,
            debug_name: TAA_COLOR_NAMES[slot],
        )!;
        record.taa_depth[slot] = allocate_post_target(
            device:     &renderer.device,
            width:      record.hdr_color.width,
            height:     record.hdr_color.height,
            format:     TAA_DEPTH_FORMAT,
            debug_name: TAA_DEPTH_NAMES[slot],
        )!;
        record.taa_velocity[slot] = allocate_post_target(
            device:     &renderer.device,
            width:      record.hdr_color.width,
            height:     record.hdr_color.height,
            format:     TAA_VELOCITY_FORMAT,
            debug_name: TAA_VELOCITY_NAMES[slot],
        )!;
    }
}

fn void? acquire_taa_debug_image(Renderer* renderer, ViewRecord* record) @private {
    record.taa_debug = allocate_post_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     render::HDR_FORMAT,
        debug_name: "taa_debug",
    )!;
}

fn void release_taa_images(gpu::Device* device, ViewRecord* record) @private {
    for (uint slot = 0; slot < TAA_HISTORY_SLOTS; slot++) {
        Target*[3] images = { &record.taa_color[slot], &record.taa_depth[slot], &record.taa_velocity[slot] };
        foreach (image : images) {
            if (image.texture.is_valid()) release_post_target(device, image);
        }
    }
    if (record.taa_debug.texture.is_valid()) release_post_target(device, &record.taa_debug);
}

<*
 Resolve the view's current color against its history into the next history image.
 @param [&inout] renderer : "Open frame with the view's velocity recorded; scene_input moves to the resolve."
 @param [&inout] record : "Its temporal images change state."
 @param jitter : "NDC offset of the view's rendered matrices."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require record.taa_color[0].texture.is_valid(), record.velocity.texture.is_valid()
*>
fn void? record_taa(Renderer* renderer, ViewRecord* record, Vec2 jitter) {
    acquire_taa_pipeline(renderer)!;
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    uint previous = record.history.slot;
    uint next = (previous + 1) % TAA_HISTORY_SLOTS;
    bool debug = taa_debug_enabled(&record.desc.post);
    TaaParams* params = &record.desc.post.taa_params;
    Target* input = record.scene_input;

    render::begin_profile_pass(renderer, Pass.TEMPORAL_AA)!;
    gpu::TextureState sampled = gpu::sampled_at({ .compute });
    gpu::TextureState history_read = gpu::storage_at({ .compute }, { .read });
    gpu::TextureState written = gpu::storage_at({ .compute }, { .write });
    input.transition(&renderer.commands, sampled)!;
    record.depth.transition(&renderer.commands, sampled)!;
    record.velocity.transition(&renderer.commands, sampled)!;
    record.taa_color[previous].transition(&renderer.commands, sampled)!;
    record.taa_depth[previous].transition(&renderer.commands, history_read)!;
    record.taa_velocity[previous].transition(&renderer.commands, history_read)!;
    record.taa_color[next].transition(&renderer.commands, written)!;
    record.taa_depth[next].transition(&renderer.commands, written)!;
    record.taa_velocity[next].transition(&renderer.commands, written)!;
    if (debug) record.taa_debug.transition(&renderer.commands, written)!;

    uint width = record.taa_color[next].width;
    uint height = record.taa_color[next].height;
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, TaaRoot::size)!;
    *(TaaRoot*)root.bytes.ptr = {
        .color_texture      = input.view.index,
        .depth_texture      = record.depth.view.index,
        .velocity_texture   = record.velocity.view.index,
        .history_color      = record.taa_color[previous].view.index,
        .history_depth      = record.taa_depth[previous].view.index,
        .history_velocity   = record.taa_velocity[previous].view.index,
        .output_color       = record.taa_color[next].view.index,
        .output_depth       = record.taa_depth[next].view.index,
        .output_velocity    = record.taa_velocity[next].view.index,
        .debug_texture      = debug ? record.taa_debug.view.index : (gpu::TextureIndex)0,
        .sampler_index      = renderer.linear_clamp_sampler,
        .width              = width,
        .height             = height,
        .history_valid      = record.history.valid ? 1 : 0,
        .orthographic       = record.projection_terms.orthographic ? 1 : 0,
        .debug              = (uint)params.debug.ordinal,
        .texel              = { 1.0f / (float)width, 1.0f / (float)height },
        .jitter_uv          = jitter_uv(jitter),
        .current_weight     = params.current_weight,
        .clip_gamma         = params.clip_gamma,
        .depth_tolerance    = params.depth_tolerance,
        .velocity_threshold = params.velocity_threshold,
        .proj_22            = record.projection_terms.m22,
        .proj_23            = record.projection_terms.m23,
    };
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.taa_resolve)!;
    dispatch_over(renderer, root.address, &record.taa_color[next])!;
    render::end_profile_pass(renderer, Pass.TEMPORAL_AA)!;
    renderer.stats.post_dispatches += 1;
    record.scene_input = debug ? &record.taa_debug : &record.taa_color[next];
}

fn void? acquire_taa_pipeline(Renderer* renderer) @private {
    render::acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.taa_resolve,
        shader:     ShaderName.TAA_RESOLVE,
        debug_name: "post_taa_resolve",
    )!;
}

<*
 Copy a TAA view's scene image out of its history before a write.
 @param [&inout] renderer : "Open frame."
 @param [&inout] record : "Its scene_input moves to a copy in hdr_color."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? detach_scene_input(Renderer* renderer, ViewRecord* record) {
    bool history;
    foreach (&image : record.taa_color) history |= record.scene_input == image;
    if (!history) return;
    render::composite_target(
        renderer: renderer,
        source:   record.scene_input,
        output:   &record.hdr_color,
        rect:     {},
    )!;
    record.scene_input = &record.hdr_color;
}
