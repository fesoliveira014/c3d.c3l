module c3d::render;

import c3d;
import gpu;

const gpu::Format PROXY_SKIP_FORMAT @private = gpu::Format.R32_UINT; // 4 B per pixel; the G-buffer flags format

// A deferred view packs the height into its G-buffer flags; a forward view writes the same word in its prepass.
fn bool proxy_skip_wanted(ViewDesc* desc) @private {
    return desc.shading == ShadingPath.FORWARD && desc.ambient_occlusion.kind == AoKind.RAY_TRACED;
}

fn void? acquire_proxy_skip(Renderer* renderer, ViewRecord* record) @private {
    if (!proxy_skip_wanted(&record.desc)) return;
    if (record.proxy_skip.texture.is_valid() || !record.hdr_color.texture.is_valid()) return;

    record.proxy_skip = allocate_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     PROXY_SKIP_FORMAT,
        usage:      { .color_attach, .sampled },
        debug_name: "proxy_skip",
    )!;
}

// The traced effects read a single-sample image, so a multisampled view reads the copy of sample 0.
fn Target* proxy_skip_word(ViewRecord* record) @private {
    if (record.desc.shading == ShadingPath.FORWARD) return &record.proxy_skip;
    if (record.desc.msaa == MsaaSamples.ONE) return &record.gbuffer[GBufferChannel.FLAGS.ordinal];

    return &record.flags_sample_zero;
}
