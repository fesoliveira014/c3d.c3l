module c3d::render;

import c3d::light;
import c3d::shader;
import gpu;

$assert FogPassRoot::size == 32;
$assert FogVolumeRoot::size == 32;

<*
 Grid of a view's fog volume; MEDIUM is the zero value.
*>
enum FogQuality : int (uint froxel_pixels, uint slices) {
    MEDIUM { 16, 64 }, // 7.03 MiB of RGBA16F per view at 2560 x 1440
    LOW { 16, 32 },    // 3.52 MiB: half of MEDIUM, with slices twice as deep
    HIGH { 8, 128 },   // 56.25 MiB: 8x MEDIUM, so opt-in
}

<*
 @require record.hdr_color.texture.is_valid()
*>
fn void? record_fog_pass(Renderer* renderer, ViewRecord* record, gpu::GpuAddress frame) @private {
    acquire_sky_pipeline(renderer, &renderer.sky_pipelines.fog, FOG)!;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    @profile_pass(renderer, Pass.FOG) {
        record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
        record.hdr_color.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read, .write }))!;
        gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, FogPassRoot::size, STREAM_ALIGNMENT)!;
        *(FogPassRoot*)root.bytes.ptr = {
            .frame  = frame,
            .color  = record.hdr_color.view.index,
            .depth  = record.depth.view.index,
            .width  = record.hdr_color.width,
            .height = record.hdr_color.height,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.fog)!;
        dispatch_over(renderer, root.address, &record.hdr_color)!;
    }!;
    renderer.stats.post_dispatches++;
}

fn uint[<2>] fog_volume_extent(uint width, uint height, uint froxel_pixels) @private {
    return {
        (width + froxel_pixels - 1) / froxel_pixels,
        (height + froxel_pixels - 1) / froxel_pixels,
    };
}

fn void? acquire_fog_volume(Renderer* renderer, ViewRecord* record) @private {
    bool wanted = record.desc.volumetric_fog && record.desc.shading != ShadingPath.PATH_TRACED;
    if (!wanted || record.fog_volume.texture.is_valid() || !record.hdr_color.texture.is_valid()) return;
    FogQuality quality = record.desc.fog_quality;
    uint[<2>] extent = fog_volume_extent(record.hdr_color.width, record.hdr_color.height, quality.froxel_pixels);
    record.fog_volume = allocate_storage_target(
        device:     &renderer.device,
        width:      extent.x,
        height:     extent.y,
        format:     gpu::Format.RGBA16_FLOAT,
        debug_name: "fog_volume",
        depth:      quality.slices,
    )!;
}

<*
 Packed index plus one of the light the volumetric fog scatters; zero for none.
 @param [&in] extraction
*>
fn uint fog_sun_light(LightExtraction* extraction, bool atmosphere) {
    if (atmosphere) return extraction.sun_light;
    foreach (index, light : extraction.lights) {
        if (light.kind == (uint)LightKind.DIRECTIONAL.ordinal) return (uint)index + 1;
    }
    return 0;
}

<*
 @require record.fog_volume.texture.is_valid()
 @require record.fog_volume.depth <= shader::FOG_VOLUME_MAX_SLICES
*>
fn void? record_fog_volume(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    uint sun_light,
    bool atlas_shadows,
) @private {
    bool traced = record.desc.ray_tracing.shadows;
    gpu::PipelineHandle* scattering = traced
      ? &renderer.sky_pipelines.fog_scattering_traced : &renderer.sky_pipelines.fog_scattering;
    acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   scattering,
        shader:     FOG_SCATTERING,
        debug_name: "sky",
        flags:      rt_shadow_flags(renderer, traced),
    )!;
    acquire_sky_pipeline(renderer, &renderer.sky_pipelines.fog_integration, FOG_INTEGRATION)!;
    if (atlas_shadows) {
        // The shadow pass leaves the atlas readable by fragments only.
        transition_shadow_atlas(
            atlas:    &renderer.shadow_atlas,
            commands: &renderer.commands,
            next:     gpu::sampled_at({ .compute, .fragment_shader }),
        )!;
    }
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, FogVolumeRoot::size, STREAM_ALIGNMENT)!;
    *(FogVolumeRoot*)root.bytes.ptr = {
        .frame     = frame,
        .volume    = record.fog_volume.view.index,
        .width     = record.fog_volume.width,
        .height    = record.fog_volume.height,
        .sun_light = sun_light,
        .slices    = record.fog_volume.depth,
    };

    @profile_pass(renderer, Pass.FOG_SCATTERING) {
        record.fog_volume.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        uint columns = (record.fog_volume.width + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
        uint rows = (record.fog_volume.height + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
        gpu::cmd_bind_pipeline(&renderer.commands, *scattering)!;
        gpu::cmd_dispatch(&renderer.commands, root.address, { columns, rows, record.fog_volume.depth })!;
    }!;
    @profile_pass(renderer, Pass.FOG_INTEGRATION) {
        record.fog_volume.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read, .write }))!;
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.fog_integration)!;
        dispatch_over(renderer, root.address, &record.fog_volume)!;
        record.fog_volume.transition(&renderer.commands, renderer.sampled_state)!;
    }!;
    renderer.stats.post_dispatches += 2;
}
