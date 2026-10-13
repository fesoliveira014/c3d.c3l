module c3d::render;

import c3d;
import c3d::render::post;
import c3d::shader;
import gpu;
import std::math;

$assert SsaoRoot::size == 48;
$assert AoBlurRoot::size == 48;
$assert RtAoRoot::size == 48;
$assert AoTemporalRoot::size == 64;

<*
 Fewest rays per texel on the ray-traced AO path.
*>
const uint RT_AO_RAYS_MIN = 1;

<*
 Most rays per texel on the ray-traced AO path.
*>
const uint RT_AO_RAYS_MAX = 16; // 16 rays over a half-resolution 1080p estimate trace 8.3 M rays a frame

<*
 History images per kind; they follow ViewHistory.slot.
*>
const uint AO_HISTORY_SLOTS = 2; // 1080p at half resolution: 2.1 MB of visibility history and 4.1 MB of depth history

const float AO_DEPTH_TOLERANCE @private = 0.05f;   // relative linear depth, TAA's default
const float AO_VELOCITY_THRESHOLD @private = 2;    // full-resolution pixels a frame, TAA's default
const ZString[AO_HISTORY_SLOTS] AO_HISTORY_NAMES @private = { "ao_history_0", "ao_history_1" };
const ZString[AO_HISTORY_SLOTS] AO_DEPTH_NAMES @private = { "ao_depth_0", "ao_depth_1" };

<*
 Half-resolution screen-space AO over half a metre.
*>
const AmbientOcclusionDesc AMBIENT_OCCLUSION_DEFAULT = {
    .kind      = AoKind.SSAO,
    .radius    = 0.5f,
    .intensity = 1,
    .ray_count = 4,
};

<*
 Ambient occlusion source of a view.
*>
enum AoKind {
    NONE,
    SSAO,
    RAY_TRACED,
}

<*
 Ambient occlusion of one view; a zeroed value is NONE.
*>
struct AmbientOcclusionDesc {
    AoKind kind;
    float  radius;
    float  intensity;
    bool   full_resolution;
    uint   ray_count;
    bool   temporal; // accumulates the estimate over frames; keeps history and depth images beside the estimate
}

struct AmbientOcclusionPipelines @private {
    gpu::PipelineHandle ssao;
    gpu::PipelineHandle ray_traced;
    gpu::PipelineHandle temporal;
    gpu::PipelineHandle blur;
}

<*
 Whether the settings can configure a view.
 @param [&in] desc : "Settings to check."
 @pure
*>
fn bool ambient_occlusion_desc_valid(AmbientOcclusionDesc* desc) {
    bool estimate_valid = math::is_finite(desc.radius) && desc.radius > 0
        && math::is_finite(desc.intensity) && desc.intensity >= 0;
    switch (desc.kind) {
        case NONE: return true;
        case SSAO: return estimate_valid;
        case RAY_TRACED:
            return estimate_valid && desc.ray_count >= RT_AO_RAYS_MIN && desc.ray_count <= RT_AO_RAYS_MAX;
    }
}

// Accumulation needs the velocity image and a committed ViewHistory, as screen-space GI does.
fn bool ambient_occlusion_accumulates(ViewDesc* desc) @private {
    return desc.ambient_occlusion.kind != AoKind.NONE && desc.ambient_occlusion.temporal;
}

<*
 Pixel extent of the AO estimate for a working extent.
 @require width > 0 && height > 0
 @pure
*>
fn uint[<2>] ambient_occlusion_extent(uint width, uint height, bool full_resolution) {
    if (full_resolution) return { width, height };
    return { (width + 1) / 2, (height + 1) / 2 };
}

<*
 @require kind != AoKind.NONE
*>
fn void? acquire_ambient_occlusion_pipelines(Renderer* renderer, AoKind kind, bool accumulates) @private {
    switch (kind) {
        case SSAO: acquire_compute_slot(renderer, ComputeSlot.SSAO)!;
        case RAY_TRACED: acquire_compute_slot(renderer, ComputeSlot.RT_AO)!;
        case NONE:
    }
    if (accumulates) acquire_compute_slot(renderer, ComputeSlot.AO_TEMPORAL)!;
    acquire_compute_slot(renderer, ComputeSlot.AO_BLUR)!;
}

fn void destroy_ambient_occlusion_pipelines(gpu::Device* device, AmbientOcclusionPipelines* pipelines) @private {
    if (pipelines.ssao.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.ssao);
    if (pipelines.ray_traced.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.ray_traced);
    if (pipelines.temporal.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.temporal);
    if (pipelines.blur.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.blur);
    *pipelines = {};
}

fn void? acquire_ao_images(Renderer* renderer, ViewRecord* record) @private {
    AmbientOcclusionDesc* desc = &record.desc.ambient_occlusion;
    if (desc.kind == AoKind.NONE || !record.hdr_color.texture.is_valid()) return;

    if (!record.ao.texture.is_valid()) acquire_ao_estimate_images(renderer, record)!;
    if (desc.temporal && !record.ao_history[0].texture.is_valid()) acquire_ao_history_images(renderer, record)!;
}

fn void? acquire_ao_estimate_images(Renderer* renderer, ViewRecord* record) @private {
    defer catch release_ao_estimate_images(&renderer.device, record);
    uint width = record.hdr_color.width;
    uint height = record.hdr_color.height;
    uint[<2>] extent = ambient_occlusion_extent(width, height, record.desc.ambient_occlusion.full_resolution);
    record.ao_raw = allocate_storage_target(
        device:     &renderer.device,
        width:      extent.x,
        height:     extent.y,
        format:     gpu::Format.R8_UNORM,
        debug_name: "ao_raw",
    )!;
    record.ao = allocate_storage_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     gpu::Format.R8_UNORM,
        debug_name: "ao",
    )!;
}

fn void? acquire_ao_history_images(Renderer* renderer, ViewRecord* record) @private {
    defer catch release_ao_history_images(&renderer.device, record);
    uint[<2>] extent = ambient_occlusion_extent(
        record.hdr_color.width,
        record.hdr_color.height,
        record.desc.ambient_occlusion.full_resolution,
    );
    for (uint slot = 0; slot < AO_HISTORY_SLOTS; slot++) {
        record.ao_history[slot] = allocate_storage_target(
            device:     &renderer.device,
            width:      extent.x,
            height:     extent.y,
            format:     gpu::Format.R16_FLOAT,
            debug_name: AO_HISTORY_NAMES[slot],
        )!;
        record.ao_depth[slot] = allocate_storage_target(
            device:     &renderer.device,
            width:      extent.x,
            height:     extent.y,
            format:     gpu::Format.R32_FLOAT,
            debug_name: AO_DEPTH_NAMES[slot],
        )!;
    }
}

fn void release_ao_estimate_images(gpu::Device* device, ViewRecord* record) @private {
    if (record.ao_raw.texture.is_valid()) release_storage_target(device, &record.ao_raw);
    if (record.ao.texture.is_valid()) release_storage_target(device, &record.ao);
}

fn void release_ao_history_images(gpu::Device* device, ViewRecord* record) @private {
    foreach (&image : record.ao_history) {
        if (image.texture.is_valid()) release_storage_target(device, image);
    }
    foreach (&image : record.ao_depth) {
        if (image.texture.is_valid()) release_storage_target(device, image);
    }
}

fn uint temporal_noise_frame(ViewRecord* record, bool accumulates) @private {
    bool rotates = accumulates || record.desc.post.anti_aliasing == AntiAliasing.TAA;
    return rotates ? record.history.sample_index : 0;
}

fn Target*? record_ambient_occlusion_history(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    bool history_valid,
) @local {
    uint previous = record.history.slot;
    uint next = (previous + 1) % AO_HISTORY_SLOTS;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::TextureState compute_read = gpu::sampled_at({ .compute });
    gpu::TextureState compute_write = gpu::storage_at({ .compute }, { .write });

    record.velocity.transition(&renderer.commands, compute_read)!;
    record.ao_history[previous].transition(&renderer.commands, compute_read)!;
    record.ao_depth[previous].transition(&renderer.commands, compute_read)!;
    record.ao_history[next].transition(&renderer.commands, compute_write)!;
    record.ao_depth[next].transition(&renderer.commands, compute_write)!;

    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, AoTemporalRoot::size, STREAM_ALIGNMENT)!;
    *(AoTemporalRoot*)root.bytes.ptr = {
        .frame              = frame,
        .raw                = record.ao_raw.view.index,
        .history            = record.ao_history[previous].view.index,
        .previous_depth     = record.ao_depth[previous].view.index,
        .depth              = record.depth.view.index,
        .velocity           = record.velocity.view.index,
        .output_texture     = record.ao_history[next].view.index,
        .output_depth       = record.ao_depth[next].view.index,
        .sampler_index      = renderer.linear_clamp_sampler,
        .width              = record.ao_raw.width,
        .height             = record.ao_raw.height,
        .depth_tolerance    = AO_DEPTH_TOLERANCE,
        .velocity_threshold = AO_VELOCITY_THRESHOLD,
        .flags              = history_valid ? shader::AO_TEMPORAL_FLAG_HISTORY_VALID : 0,
    };

    gpu::cmd_bind_pipeline(&renderer.commands, renderer.ambient_occlusion_pipelines.temporal)!;
    dispatch_over(renderer, root.address, &record.ao_history[next])!;

    return &record.ao_history[next];
}

<*
 @require record.ao.texture.is_valid() && record.desc.ambient_occlusion.kind != AoKind.NONE
 @require !ambient_occlusion_accumulates(&record.desc) || record.velocity.texture.is_valid()
*>
fn void? record_ambient_occlusion(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    bool history_valid,
) @private {
    AmbientOcclusionDesc* ambient_occlusion = &record.desc.ambient_occlusion;
    bool accumulates = ambient_occlusion_accumulates(&record.desc);
    acquire_ambient_occlusion_pipelines(renderer, ambient_occlusion.kind, accumulates)!;
    bool deferred = record.desc.shading == ShadingPath.DEFERRED;
    Target* normals = &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS.ordinal];
    record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    if (deferred) normals.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.ao_raw.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::TextureIndex normals_index = deferred ? normals.view.index : (gpu::TextureIndex)0;
    gpu::PipelineHandle estimate;
    gpu::MappedGpuSpan estimate_root;
    switch (ambient_occlusion.kind) {
        case SSAO:
            estimate = renderer.ambient_occlusion_pipelines.ssao;
            estimate_root = slot.upload.take(&renderer.device, SsaoRoot::size, STREAM_ALIGNMENT)!;
            *(SsaoRoot*)estimate_root.bytes.ptr = {
                .frame          = frame,
                .depth          = record.depth.view.index,
                .normals        = normals_index,
                .output_texture = record.ao_raw.view.index,
                .width          = record.ao_raw.width,
                .height         = record.ao_raw.height,
                .radius         = ambient_occlusion.radius,
                .intensity      = ambient_occlusion.intensity,
                .noise_frame    = temporal_noise_frame(record, accumulates),
            };
        case RAY_TRACED:
            estimate = renderer.ambient_occlusion_pipelines.ray_traced;
            estimate_root = slot.upload.take(&renderer.device, RtAoRoot::size, STREAM_ALIGNMENT)!;
            *(RtAoRoot*)estimate_root.bytes.ptr = {
                .frame          = frame,
                .depth          = record.depth.view.index,
                .normals        = normals_index,
                .output_texture = record.ao_raw.view.index,
                .width          = record.ao_raw.width,
                .height         = record.ao_raw.height,
                .radius         = ambient_occlusion.radius,
                .intensity      = ambient_occlusion.intensity,
                .noise_frame    = temporal_noise_frame(record, accumulates),
                .ray_count      = ambient_occlusion.ray_count,
            };
        case NONE:
    }

    @profile_pass(renderer, Pass.AMBIENT_OCCLUSION) {
        gpu::cmd_bind_pipeline(&renderer.commands, estimate)!;
        dispatch_over(renderer, estimate_root.address, &record.ao_raw)!;

        record.ao_raw.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
        Target* blur_input = &record.ao_raw;
        if (accumulates) {
            blur_input = record_ambient_occlusion_history(
                renderer:      renderer,
                record:        record,
                frame:         frame,
                history_valid: history_valid,
            )!;
            blur_input.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
        }

        record.ao.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        gpu::MappedGpuSpan blur_root = slot.upload.take(&renderer.device, AoBlurRoot::size, STREAM_ALIGNMENT)!;
        *(AoBlurRoot*)blur_root.bytes.ptr = {
            .frame          = frame,
            .input_texture  = blur_input.view.index,
            .depth          = record.depth.view.index,
            .output_texture = record.ao.view.index,
            .width          = record.ao.width,
            .height         = record.ao.height,
            .input_width    = blur_input.width,
            .input_height   = blur_input.height,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.ambient_occlusion_pipelines.blur)!;
        dispatch_over(renderer, blur_root.address, &record.ao)!;
    }!;

    record.ao.transition(&renderer.commands, gpu::sampled_at({ .fragment_shader }))!;
    renderer.stats.post_dispatches += accumulates ? 3 : 2;
}
