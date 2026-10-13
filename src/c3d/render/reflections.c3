module c3d::render;

import c3d;
import c3d::material;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

$assert RtReflectionRoot::size == 56;
$assert RtReflectionBlurRoot::size == 40;

<*
 Roughness above which a pixel keeps the raster environment reflection.
*>
const float RT_REFLECTION_ROUGHNESS_DEFAULT = 0.5f; // above it one ray per pixel reads as grain

<*
 Format of the thin reflection G-buffer: octahedral normal, roughness, specular weight.
*>
const gpu::Format REFLECTION_SURFACE_FORMAT = gpu::Format.RGBA16_FLOAT; // 8 B per pixel of the view's working extent

enum ReflectionPrepass @private {
    OFF,     // the pass binds no thin target
    MASKED,  // the thin target is bound with every channel write masked
    WRITTEN, // the draw writes the thin target
}

struct ReflectionLights @private {
    gpu::GpuAddress address;
    uint            count;
}

struct ReflectionPipelines @private {
    gpu::PipelineHandle trace;
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
    return { .address = upload_lights(renderer, lights)!, .count = (uint)lights.len };
}

fn void? acquire_reflection_pipelines(Renderer* renderer) @private {
    acquire_compute_slot(renderer, ComputeSlot.REFLECTION)!;
    acquire_compute_slot(renderer, ComputeSlot.REFLECTION_BLUR)!;
}

fn void destroy_reflection_pipelines(gpu::Device* device, ReflectionPipelines* pipelines) @private {
    if (pipelines.trace.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.trace);
    if (pipelines.blur.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.blur);
    *pipelines = {};
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
}

<*
 @require record.desc.shading != ShadingPath.PATH_TRACED
 @require record.reflection.texture.is_valid()
*>
fn void? record_reflections(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    ReflectionLights lights,
) @private {
    acquire_reflection_pipelines(renderer)!;
    bool forward = record.desc.shading == ShadingPath.FORWARD;
    Target* normals = forward
      ? &record.reflection_gbuffer : &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS.ordinal];
    Target* specular = forward
      ? &record.reflection_gbuffer : &record.gbuffer[GBufferChannel.EMISSIVE_SPECULAR.ordinal];
    record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    normals.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    if (specular != normals) specular.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.reflection.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan trace_root = slot.upload.take(&renderer.device, RtReflectionRoot::size, STREAM_ALIGNMENT)!;
    *(RtReflectionRoot*)trace_root.bytes.ptr = {
        .frame             = frame,
        .lights            = lights.address,
        .depth             = record.depth.view.index,
        .normal_roughness  = normals.view.index,
        .emissive_specular = specular.view.index,
        .output_texture    = record.reflection.view.index,
        .width             = record.reflection.width,
        .height            = record.reflection.height,
        .max_roughness     = record.desc.ray_tracing.max_reflection_roughness,
        .noise_frame       = temporal_noise_frame(record, false),
        .light_count       = lights.count,
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
