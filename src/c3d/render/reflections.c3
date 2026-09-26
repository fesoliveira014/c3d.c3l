module c3d::render;

import c3d;
import c3d::shader;
import gpu;

$assert RtReflectionRoot::size == 48;
$assert RtReflectionBlurRoot::size == 40;

<*
 Roughness above which a pixel keeps the raster environment reflection.
*>
const float RT_REFLECTION_ROUGHNESS_DEFAULT = 0.5f; // above it one ray per pixel reads as grain

struct ReflectionPipelines @private {
    gpu::PipelineHandle trace;
    gpu::PipelineHandle blur;
}

fn void? acquire_reflection_pipelines(Renderer* renderer) @private {
    ReflectionPipelines* pipelines = &renderer.reflection_pipelines;
    acquire_compute_pipeline(renderer, &pipelines.trace, RT_REFLECTIONS, "rt_reflections")!;
    acquire_compute_pipeline(renderer, &pipelines.blur, RT_REFLECTION_BLUR, "rt_reflection_blur")!;
}

fn void destroy_reflection_pipelines(gpu::Device* device, ReflectionPipelines* pipelines) @private {
    if (pipelines.trace.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.trace);
    if (pipelines.blur.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.blur);
    *pipelines = {};
}

fn void? acquire_reflection_images(Renderer* renderer, ViewRecord* record) @private {
    if (!record.desc.ray_tracing.reflections || record.reflection.texture.is_valid()) return;
    if (!record.hdr_color.texture.is_valid()) return;

    defer catch release_reflection_images(&renderer.device, record);
    record.reflection = allocate_storage_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     gpu::Format.RGBA16_FLOAT,
        debug_name: "reflection",
    )!;
    record.reflection_blur = allocate_storage_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     gpu::Format.RGBA16_FLOAT,
        debug_name: "reflection_blur",
    )!;
}

fn void retire_reflection_images(Renderer* renderer, ViewRecord* record) @private {
    if (!record.reflection.texture.is_valid()) return;

    RetireList* retire = last_submitted_retire(renderer);
    retire_storage_target(retire, &record.reflection);
    retire_storage_target(retire, &record.reflection_blur);
}

fn void release_reflection_images(gpu::Device* device, ViewRecord* record) @private {
    if (record.reflection.texture.is_valid()) release_storage_target(device, &record.reflection);
    if (record.reflection_blur.texture.is_valid()) release_storage_target(device, &record.reflection_blur);
}

<*
 @require record.desc.shading == ShadingPath.DEFERRED
 @require record.reflection.texture.is_valid()
*>
fn void? record_reflections(Renderer* renderer, ViewRecord* record, gpu::GpuAddress frame) @private {
    acquire_reflection_pipelines(renderer)!;
    Target* normals = &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS.ordinal];
    Target* specular = &record.gbuffer[GBufferChannel.EMISSIVE_SPECULAR.ordinal];
    record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    normals.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    specular.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.reflection.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan trace_root = slot.upload.take(&renderer.device, RtReflectionRoot::size, STREAM_ALIGNMENT)!;
    *(RtReflectionRoot*)trace_root.bytes.ptr = {
        .frame             = frame,
        .depth             = record.depth.view.index,
        .normal_roughness  = normals.view.index,
        .emissive_specular = specular.view.index,
        .output_texture    = record.reflection.view.index,
        .width             = record.reflection.width,
        .height            = record.reflection.height,
        .max_roughness     = record.desc.ray_tracing.max_reflection_roughness,
        .noise_frame       = temporal_noise_frame(record),
    };

    @profile_pass(renderer, Pass.RT_REFLECTIONS) {
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.reflection_pipelines.trace)!;
        dispatch_over(renderer, trace_root.address, &record.reflection)!;

        record.reflection.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
        record.reflection_blur.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        gpu::MappedGpuSpan blur_root = slot.upload.take(
            &renderer.device, RtReflectionBlurRoot::size, STREAM_ALIGNMENT)!;
        *(RtReflectionBlurRoot*)blur_root.bytes.ptr = {
            .frame            = frame,
            .input_texture    = record.reflection.view.index,
            .depth            = record.depth.view.index,
            .normal_roughness = normals.view.index,
            .output_texture   = record.reflection_blur.view.index,
            .width            = record.reflection_blur.width,
            .height           = record.reflection_blur.height,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.reflection_pipelines.blur)!;
        dispatch_over(renderer, blur_root.address, &record.reflection_blur)!;
    }!;

    record.reflection_blur.transition(&renderer.commands, gpu::sampled_at({ .fragment_shader }))!;
    renderer.stats.post_dispatches += 2;
}
