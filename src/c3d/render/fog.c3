module c3d::render;

import c3d::shader;
import gpu;

$assert FogPassRoot::size == 32;

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
