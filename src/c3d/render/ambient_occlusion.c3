module c3d::render;

import c3d;
import c3d::render::post;
import c3d::shader;
import gpu;
import std::math;

$assert SsaoRoot::size == 48;
$assert AoBlurRoot::size == 48;
$assert RtAoRoot::size == 48;

<*
 Fewest rays per texel on the ray-traced AO path.
*>
const uint RT_AO_RAYS_MIN = 1;

<*
 Most rays per texel on the ray-traced AO path.
*>
const uint RT_AO_RAYS_MAX = 16; // 16 rays over a half-resolution 1080p estimate trace 8.3 M rays a frame

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
}

struct AmbientOcclusionPipelines @private {
    gpu::PipelineHandle ssao;
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

<*
 Pixel extent of the AO estimate for a working extent.
 @require width > 0 && height > 0
 @pure
*>
fn uint[<2>] ambient_occlusion_extent(uint width, uint height, bool full_resolution) {
    if (full_resolution) return { width, height };
    return { (width + 1) / 2, (height + 1) / 2 };
}

fn void? acquire_ambient_occlusion_pipelines(Renderer* renderer) @private {
    AmbientOcclusionPipelines* pipelines = &renderer.ambient_occlusion_pipelines;
    acquire_compute_pipeline(renderer, &pipelines.ssao, SSAO, "ssao")!;
    acquire_compute_pipeline(renderer, &pipelines.blur, AO_BLUR, "ao_blur")!;
}

fn void destroy_ambient_occlusion_pipelines(gpu::Device* device, AmbientOcclusionPipelines* pipelines) @private {
    if (pipelines.ssao.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.ssao);
    if (pipelines.blur.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.blur);
    *pipelines = {};
}

fn void? acquire_ao_images(Renderer* renderer, ViewRecord* record) @private {
    AmbientOcclusionDesc* desc = &record.desc.ambient_occlusion;
    if (desc.kind == AoKind.NONE || record.ao.texture.is_valid() || !record.hdr_color.texture.is_valid()) return;

    defer catch release_ao_images(&renderer.device, record);
    uint width = record.hdr_color.width;
    uint height = record.hdr_color.height;
    uint[<2>] extent = ambient_occlusion_extent(width, height, desc.full_resolution);
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

fn void retire_ao_images(Renderer* renderer, ViewRecord* record) @private {
    if (!record.ao.texture.is_valid()) return;

    RetireList* retire = last_submitted_retire(renderer);
    retire_storage_target(retire, &record.ao_raw);
    retire_storage_target(retire, &record.ao);
}

fn void release_ao_images(gpu::Device* device, ViewRecord* record) @private {
    if (record.ao_raw.texture.is_valid()) release_storage_target(device, &record.ao_raw);
    if (record.ao.texture.is_valid()) release_storage_target(device, &record.ao);
}

fn uint ambient_occlusion_noise_frame(ViewRecord* record) @private {
    return record.desc.post.anti_aliasing == AntiAliasing.TAA ? record.history.sample_index : 0;
}

<*
 @require record.ao.texture.is_valid()
*>
fn void? record_ambient_occlusion(Renderer* renderer, ViewRecord* record, gpu::GpuAddress frame) @private {
    acquire_ambient_occlusion_pipelines(renderer)!;
    bool deferred = record.desc.shading == ShadingPath.DEFERRED;
    Target* normals = &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS.ordinal];
    record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    if (deferred) normals.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.ao_raw.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan ssao_root = slot.upload.take(&renderer.device, SsaoRoot::size, STREAM_ALIGNMENT)!;
    *(SsaoRoot*)ssao_root.bytes.ptr = {
        .frame          = frame,
        .depth          = record.depth.view.index,
        .normals        = deferred ? normals.view.index : (gpu::TextureIndex)0,
        .output_texture = record.ao_raw.view.index,
        .width          = record.ao_raw.width,
        .height         = record.ao_raw.height,
        .radius         = record.desc.ambient_occlusion.radius,
        .intensity      = record.desc.ambient_occlusion.intensity,
        .noise_frame    = ambient_occlusion_noise_frame(record),
    };

    begin_profile_pass(renderer, Pass.AMBIENT_OCCLUSION)!;
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.ambient_occlusion_pipelines.ssao)!;
    dispatch_over(renderer, ssao_root.address, &record.ao_raw)!;

    record.ao_raw.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
    record.ao.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    gpu::MappedGpuSpan blur_root = slot.upload.take(&renderer.device, AoBlurRoot::size, STREAM_ALIGNMENT)!;
    *(AoBlurRoot*)blur_root.bytes.ptr = {
        .frame          = frame,
        .input_texture  = record.ao_raw.view.index,
        .depth          = record.depth.view.index,
        .output_texture = record.ao.view.index,
        .width          = record.ao.width,
        .height         = record.ao.height,
        .input_width    = record.ao_raw.width,
        .input_height   = record.ao_raw.height,
    };
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.ambient_occlusion_pipelines.blur)!;
    dispatch_over(renderer, blur_root.address, &record.ao)!;
    end_profile_pass(renderer, Pass.AMBIENT_OCCLUSION)!;

    record.ao.transition(&renderer.commands, gpu::sampled_at({ .fragment_shader }))!;
    renderer.stats.post_dispatches += 2;
}
