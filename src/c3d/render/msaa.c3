module c3d::render;

import c3d;
import c3d::render::post @public;
import gpu;

const gpu::TextureUsage MSAA_COLOR_USAGE @private = { .color_attach };
const gpu::TextureUsage MSAA_DEPTH_USAGE @private = { .depth_attach };
const gpu::TextureUsage MSAA_SAMPLED_USAGE @private = { .color_attach, .sampled };

<*
 Samples per pixel of a view's opaque scene passes; ONE is off.
*>
enum MsaaSamples {
    ONE,
    TWO,
    FOUR,
    EIGHT,
}

struct MsaaProbe @private {
    Renderer*        renderer;
    uint[<2>]        extent;
    gpu::SampleCount samples;
}

fn bool? MsaaProbe.supports(&self, gpu::Format format, gpu::TextureUsage usage) @private {
    gpu::TextureDesc desc = {
        .width        = self.extent.x,
        .height       = self.extent.y,
        .format       = format,
        .usage        = usage,
        .access       = { .graphics },
        .sample_count = self.samples,
    };
    return gpu::supports_texture_desc(&self.renderer.device, &desc);
}

<*
 Whether the sample count is compatible with the anti-aliasing and shading path.
 @param [&in] desc : "Device support is checked by create_view."
*>
fn bool msaa_desc_valid(ViewDesc* desc) {
    if (desc.msaa == MsaaSamples.ONE) return true;

    return desc.post.anti_aliasing != AntiAliasing.TAA && desc.shading != ShadingPath.PATH_TRACED;
}

fn gpu::SampleCount msaa_sample_count(MsaaSamples msaa) @private {
    switch (msaa) {
        case ONE: return gpu::SampleCount.ONE;
        case TWO: return gpu::SampleCount.TWO;
        case FOUR: return gpu::SampleCount.FOUR;
        case EIGHT: return gpu::SampleCount.EIGHT;
    }
}

fn bool msaa_reflection_gbuffer_wanted(ViewDesc* desc) @private {
    return desc.ray_tracing.reflections && desc.shading == ShadingPath.FORWARD;
}

// Deferred views wait for per-sample lighting; a window view without a surface allocates nothing to check.
fn void? validate_msaa_support(Renderer* renderer, ViewDesc* desc, uint[<2>] output) @private {
    if (desc.msaa == MsaaSamples.ONE) return;
    if (desc.shading == ShadingPath.DEFERRED) return c3d::UNSUPPORTED~;
    if (output.x == 0 || output.y == 0) return;

    MsaaProbe probe = {
        .renderer = renderer,
        .extent   = working_extent(desc.viewport, output.x, output.y, desc.render_scale),
        .samples  = msaa_sample_count(desc.msaa),
    };
    bool supported = probe.supports(HDR_FORMAT, MSAA_COLOR_USAGE)! && probe.supports(DEPTH_FORMAT, MSAA_DEPTH_USAGE)!;
    if (supported && post::uses_velocity(desc)) {
        supported = probe.supports(post::velocity_format(desc), MSAA_SAMPLED_USAGE)!;
    }
    if (supported && msaa_reflection_gbuffer_wanted(desc)) {
        supported = probe.supports(REFLECTION_SURFACE_FORMAT, MSAA_SAMPLED_USAGE)!;
    }
    if (!supported) return c3d::UNSUPPORTED~;
}
