module c3d::render;

import c3d;
import c3d::material;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

$assert RtReflectionRoot::size == 72;
$assert RtReflectionUpsampleRoot::size == 56;
$assert RtReflectionBlurRoot::size == 40;
$assert RtReflectionTemporalRoot::size == 72;

<*
 Roughness above which a pixel keeps the raster environment reflection.
*>
const float RT_REFLECTION_ROUGHNESS_DEFAULT = 0.5f; // above it one ray per pixel reads as grain

<*
 Most reflection rays a view casts per traced pixel.
*>
const uint RT_REFLECTION_RAYS_MAX = 4; // each ray is one more trace and hit shading per traced pixel

<*
 Format of the thin reflection G-buffer: octahedral normal, roughness, specular weight.
*>
const gpu::Format REFLECTION_SURFACE_FORMAT = gpu::Format.RGBA16_FLOAT; // 8 B per pixel of the view's working extent

<*
 History images per kind; they follow ViewHistory.slot.
*>
const uint REFLECTION_HISTORY_SLOTS = 2; // 1080p: 33.2 MB of radiance history and 16.6 MB of depth history

const ZString[REFLECTION_HISTORY_SLOTS] REFLECTION_HISTORY_NAMES @private = {
    "reflection_history_0", "reflection_history_1",
};
const ZString[REFLECTION_HISTORY_SLOTS] REFLECTION_DEPTH_NAMES @private = {
    "reflection_depth_0", "reflection_depth_1",
};

const uint RT_REFLECTION_HALF_PHASES @private = 4; // the size of RT_REFLECTION_HALF_OFFSETS in rt_reflection.glsl
const uint RT_REFLECTION_HALF_SHIFT @private = 1; // the half-resolution trace takes one pixel of each 2 x 2 block

<*
 Extent a view traces reflection rays at.
*>
enum ReflectionResolution : char {
    FULL,
    HALF, // one pixel of each 2 x 2 block, rebuilt to the full extent by a bilateral filter
}

enum ReflectionPrepass @private {
    OFF,     // the pass binds no thin target
    MASKED,  // the thin target is bound with every channel write masked
    WRITTEN, // the draw writes the thin target
}

struct ReflectionLights @private {
    gpu::GpuAddress address;
    gpu::GpuAddress spatial;
    uint            count;
}

struct ReflectionPipelines @private {
    gpu::PipelineHandle trace;
    gpu::PipelineHandle upsample;
    gpu::PipelineHandle temporal;
    gpu::PipelineHandle blur;
}

<*
 Pack the lights a reflection hit sees, with no frustum test.
 @param allocator : "Owns the returned array."
 @param [&in] scene : "Current world transforms and valid light descriptions."
 @param view_layers : "Camera visibility mask."
 @param [&inout] counts : "Overwritten with this list's counts."
 @param [in] atmosphere : "Null or a zero entity attenuates no light."
 @param altitude : "Metres above world y = 0 the sun is seen from."
 @param origin : "Absolute origin the packed positions are relative to."
 @param pre_exposure : "Multiplies every packed intensity."
 @require capacity > 0
*>
fn LightGpu[] extract_reflection_lights(
    Allocator allocator,
    Scene* scene,
    uint view_layers,
    uint capacity,
    LightCounts* counts,
    AtmosphereSelection* atmosphere,
    float altitude,
    Vec3 origin,
    float pre_exposure = 1,
) {
    // Atlas layers are fitted to the camera, so every shadowing light traces at a hit.
    return extract_lights(
        allocator:     allocator,
        scene:         scene,
        frustum:       null,
        view_layers:   view_layers,
        capacity:      capacity,
        counts:        counts,
        atmosphere:    atmosphere,
        altitude:      altitude,
        trace_shadows: true,
        origin:        origin,
        pre_exposure:  pre_exposure,
    ).lights;
}

fn ReflectionLights? upload_reflection_lights(
    Renderer* renderer,
    Scene* scene,
    uint view_layers,
    AtmosphereSelection* atmosphere,
    float altitude,
    float pre_exposure,
) @private {
    LightCounts counts;
    LightGpu[] lights = extract_reflection_lights(
        allocator:    tmem,
        scene:        scene,
        view_layers:  view_layers,
        capacity:     renderer.max_lights,
        counts:       &counts,
        atmosphere:   atmosphere,
        altitude:     altitude,
        origin:       renderer.frame_origin,
        pre_exposure: pre_exposure,
    );
    return {
        .address = upload_lights(renderer, lights)!,
        .spatial = upload_light_spatial(renderer, lights)!,
        .count = (uint)lights.len,
    };
}

fn void? acquire_reflection_pipelines(Renderer* renderer, bool half_resolution, bool accumulates) @private {
    acquire_compute_slot(renderer, ComputeSlot.REFLECTION)!;
    if (half_resolution) acquire_compute_slot(renderer, ComputeSlot.REFLECTION_UPSAMPLE)!;
    if (accumulates) acquire_compute_slot(renderer, ComputeSlot.REFLECTION_TEMPORAL)!;
    acquire_compute_slot(renderer, ComputeSlot.REFLECTION_BLUR)!;
}

fn void destroy_reflection_pipelines(gpu::Device* device, ReflectionPipelines* pipelines) @private {
    if (pipelines.trace.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.trace);
    if (pipelines.upsample.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.upsample);
    if (pipelines.temporal.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.temporal);
    if (pipelines.blur.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.blur);
    *pipelines = {};
}

fn bool reflection_half_resolution(ViewDesc* desc) @private {
    return desc.ray_tracing.reflections && desc.ray_tracing.reflection_resolution == ReflectionResolution.HALF;
}

// Accumulation needs the velocity image and a committed ViewHistory, as screen-space GI does.
fn bool reflection_accumulates(ViewDesc* desc) @private {
    return desc.ray_tracing.reflections && desc.ray_tracing.reflection_history;
}

fn bool forward_reflection_eligible(MeshCandidate* candidate, Material* material) @private {
    return !candidate.impostor && !candidate.billboards && gbuffer_encodable(material);
}

fn ShaderVariant reflection_prepass_fragment(Material* material) @private {
    ShaderVariant fragment = gbuffer_fragment(material);
    fragment.flags = shader::SHADER_FLAG_REFLECTION_PREPASS;
    return fragment;
}

fn void? acquire_reflection_images(Renderer* renderer, ViewRecord* record) @private {
    if (!record.desc.ray_tracing.reflections || !record.hdr_color.texture.is_valid()) return;

    if (!record.reflection.texture.is_valid()) acquire_reflection_full_images(renderer, record)!;
    if (reflection_half_resolution(&record.desc) && !record.reflection_half.texture.is_valid()) {
        record.reflection_half = allocate_storage_target(
            device:     &renderer.device,
            width:      (record.hdr_color.width + 1) >> RT_REFLECTION_HALF_SHIFT,
            height:     (record.hdr_color.height + 1) >> RT_REFLECTION_HALF_SHIFT,
            format:     gpu::Format.RGBA16_FLOAT,
            debug_name: "reflection_half",
        )!;
    }
    if (reflection_accumulates(&record.desc) && !record.reflection_history[0].texture.is_valid()) {
        acquire_reflection_history_images(renderer, record)!;
    }
}

fn void? acquire_reflection_full_images(Renderer* renderer, ViewRecord* record) @private {
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

fn void? acquire_reflection_history_images(Renderer* renderer, ViewRecord* record) @private {
    defer catch release_reflection_history_images(&renderer.device, record);
    for (uint slot = 0; slot < REFLECTION_HISTORY_SLOTS; slot++) {
        record.reflection_history[slot] = allocate_storage_target(
            device:     &renderer.device,
            width:      record.hdr_color.width,
            height:     record.hdr_color.height,
            format:     gpu::Format.RGBA16_FLOAT,
            debug_name: REFLECTION_HISTORY_NAMES[slot],
        )!;
        record.reflection_depth[slot] = allocate_storage_target(
            device:     &renderer.device,
            width:      record.hdr_color.width,
            height:     record.hdr_color.height,
            format:     gpu::Format.R32_FLOAT,
            debug_name: REFLECTION_DEPTH_NAMES[slot],
        )!;
    }
}

fn void? acquire_reflection_gbuffer(Renderer* renderer, ViewRecord* record) @private {
    if (!record.desc.ray_tracing.reflections || record.desc.shading != ShadingPath.FORWARD) return;
    if (record.reflection_gbuffer.texture.is_valid() || !record.hdr_color.texture.is_valid()) return;

    record.reflection_gbuffer = allocate_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     REFLECTION_SURFACE_FORMAT,
        usage:      { .color_attach, .sampled },
        debug_name: "reflection_gbuffer",
    )!;
}

fn void release_reflection_images(gpu::Device* device, ViewRecord* record) @private {
    if (record.reflection.texture.is_valid()) release_storage_target(device, &record.reflection);
    if (record.reflection_blur.texture.is_valid()) release_storage_target(device, &record.reflection_blur);
    if (record.reflection_half.texture.is_valid()) release_storage_target(device, &record.reflection_half);
}

fn void release_reflection_history_images(gpu::Device* device, ViewRecord* record) @private {
    foreach (&image : record.reflection_history) {
        if (image.texture.is_valid()) release_storage_target(device, image);
    }
    foreach (&image : record.reflection_depth) {
        if (image.texture.is_valid()) release_storage_target(device, image);
    }
}

fn Target*? record_reflection_history(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    Target* normals,
    Target* specular,
    bool history_valid,
) @local {
    uint previous = record.history.slot;
    uint next = (previous + 1) % REFLECTION_HISTORY_SLOTS;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::TextureState compute_read = gpu::sampled_at({ .compute });
    gpu::TextureState compute_write = gpu::storage_at({ .compute }, { .write });
    float pre_exposure = record.pre_exposure.factor;
    float pre_exposure_ratio = history_valid ? pre_exposure / record.reflection_history_pre_exposure[previous] : 1;
    record.reflection_history_pre_exposure[next] = pre_exposure;

    record.velocity.transition(&renderer.commands, compute_read)!;
    record.reflection_history[previous].transition(&renderer.commands, compute_read)!;
    record.reflection_depth[previous].transition(&renderer.commands, compute_read)!;
    record.reflection_history[next].transition(&renderer.commands, compute_write)!;
    record.reflection_depth[next].transition(&renderer.commands, compute_write)!;

    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, RtReflectionTemporalRoot::size, STREAM_ALIGNMENT)!;
    *(RtReflectionTemporalRoot*)root.bytes.ptr = {
        .frame              = frame,
        .current            = record.reflection.view.index,
        .history            = record.reflection_history[previous].view.index,
        .previous_depth     = record.reflection_depth[previous].view.index,
        .depth              = record.depth.view.index,
        .velocity           = record.velocity.view.index,
        .normal_roughness   = normals.view.index,
        .emissive_specular  = specular.view.index,
        .output_texture     = record.reflection_history[next].view.index,
        .output_depth       = record.reflection_depth[next].view.index,
        .sampler_index      = renderer.linear_clamp_sampler,
        .width              = record.reflection.width,
        .height             = record.reflection.height,
        .pre_exposure_ratio = pre_exposure_ratio,
        .max_roughness      = record.desc.ray_tracing.max_reflection_roughness,
        .flags              = history_valid ? shader::RT_REFLECTION_TEMPORAL_FLAG_HISTORY_VALID : 0,
    };

    gpu::cmd_bind_pipeline(&renderer.commands, renderer.reflection_pipelines.temporal)!;
    dispatch_over(renderer, root.address, &record.reflection_history[next])!;

    return &record.reflection_history[next];
}

<*
 @require record.desc.shading != ShadingPath.PATH_TRACED
 @require record.reflection.texture.is_valid()
 @require !reflection_half_resolution(&record.desc) || record.reflection_half.texture.is_valid()
 @require !reflection_accumulates(&record.desc) || record.velocity.texture.is_valid()
*>
fn void? record_reflections(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    ReflectionLights lights,
    bool history_valid,
) @private {
    bool half_resolution = reflection_half_resolution(&record.desc);
    bool accumulates = reflection_accumulates(&record.desc);
    acquire_reflection_pipelines(renderer, half_resolution, accumulates)!;
    bool forward = record.desc.shading == ShadingPath.FORWARD;
    Target* normals = forward ? &record.reflection_gbuffer : deferred_normals(record);
    Target* specular = forward ? &record.reflection_gbuffer : deferred_specular(record);
    Target* traced = half_resolution ? &record.reflection_half : &record.reflection;
    uint noise_frame = temporal_noise_frame(record, accumulates);
    record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    normals.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    if (specular != normals) specular.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    traced.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan trace_root = slot.upload.take(&renderer.device, RtReflectionRoot::size, STREAM_ALIGNMENT)!;
    *(RtReflectionRoot*)trace_root.bytes.ptr = {
        .frame             = frame,
        .lights            = lights.address,
        .light_spatial     = lights.spatial,
        .depth             = record.depth.view.index,
        .normal_roughness  = normals.view.index,
        .emissive_specular = specular.view.index,
        .output_texture    = traced.view.index,
        .width             = traced.width,
        .height            = traced.height,
        .max_roughness     = record.desc.ray_tracing.max_reflection_roughness,
        .noise_frame       = noise_frame,
        .light_count       = lights.count,
        .ray_count         = math::max(record.desc.ray_tracing.reflection_rays, 1u),
        .trace_shift       = half_resolution ? RT_REFLECTION_HALF_SHIFT : 0,
    };

    @profile_pass(renderer, Pass.RT_REFLECTIONS) {
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.reflection_pipelines.trace)!;
        dispatch_over(renderer, trace_root.address, traced)!;

        if (half_resolution) {
            traced.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
            record.reflection.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
            gpu::MappedGpuSpan upsample_root = slot.upload.take(
                &renderer.device, RtReflectionUpsampleRoot::size, STREAM_ALIGNMENT)!;
            *(RtReflectionUpsampleRoot*)upsample_root.bytes.ptr = {
                .frame             = frame,
                .input_texture     = traced.view.index,
                .depth             = record.depth.view.index,
                .normal_roughness  = normals.view.index,
                .emissive_specular = specular.view.index,
                .output_texture    = record.reflection.view.index,
                .width             = record.reflection.width,
                .height            = record.reflection.height,
                .input_width       = traced.width,
                .input_height      = traced.height,
                .offset            = noise_frame % RT_REFLECTION_HALF_PHASES,
            };

            gpu::cmd_bind_pipeline(&renderer.commands, renderer.reflection_pipelines.upsample)!;
            dispatch_over(renderer, upsample_root.address, &record.reflection)!;
        }

        record.reflection.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
        Target* blur_input = &record.reflection;
        if (accumulates) {
            blur_input = record_reflection_history(
                renderer:      renderer,
                record:        record,
                frame:         frame,
                normals:       normals,
                specular:      specular,
                history_valid: history_valid,
            )!;
            blur_input.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
        }

        record.reflection_blur.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        gpu::MappedGpuSpan blur_root = slot.upload.take(
            &renderer.device, RtReflectionBlurRoot::size, STREAM_ALIGNMENT)!;
        *(RtReflectionBlurRoot*)blur_root.bytes.ptr = {
            .frame             = frame,
            .input_texture     = blur_input.view.index,
            .depth             = record.depth.view.index,
            .normal_roughness  = normals.view.index,
            .emissive_specular = specular.view.index,
            .output_texture    = record.reflection_blur.view.index,
            .width             = record.reflection_blur.width,
            .height            = record.reflection_blur.height,
        };

        gpu::cmd_bind_pipeline(&renderer.commands, renderer.reflection_pipelines.blur)!;
        dispatch_over(renderer, blur_root.address, &record.reflection_blur)!;
    }!;

    record.reflection_blur.transition(&renderer.commands, gpu::sampled_at({ .fragment_shader }))!;
    renderer.stats.post_dispatches += (half_resolution ? 3 : 2) + (accumulates ? 1 : 0);
}
