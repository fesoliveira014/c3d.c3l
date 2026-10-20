module c3d::render;

import c3d;
import c3d::render::post @public;
import gpu;

const gpu::TextureUsage MSAA_COLOR_USAGE @private = { .color_attach };
const gpu::TextureUsage MSAA_DEPTH_USAGE @private = { .depth_attach };
const gpu::TextureUsage MSAA_SAMPLED_DEPTH_USAGE @private = { .depth_attach, .sampled };
const gpu::TextureUsage MSAA_SAMPLED_USAGE @private = { .color_attach, .sampled };
const gpu::TextureUsage MSAA_EDGES_USAGE @private = { .color_attach, .sampled };
const gpu::Format MSAA_EDGES_FORMAT @private = gpu::Format.R8_UINT;

<*
 Samples per pixel of a view's opaque scene passes; ONE is off.
*>
enum MsaaSamples {
    ONE,
    TWO,
    FOUR,
    EIGHT,
}

struct MsaaCounts @private {
    gpu::SampleCount[3] items;
    usz                 len;
}

struct MsaaProbe @private {
    Renderer*        renderer;
    uint[<2>]        extent;
    gpu::SampleCount samples;
}

fn bool? msaa_image_supported(MsaaProbe* probe, gpu::Format format, gpu::TextureUsage usage) @private {
    gpu::TextureDesc desc = {
        .width        = probe.extent.x,
        .height       = probe.extent.y,
        .format       = format,
        .usage        = usage,
        .access       = { .graphics },
        .sample_count = probe.samples,
    };

    return gpu::supports_texture_desc(&probe.renderer.device, &desc);
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

fn bool msaa_edges_wanted(ViewDesc* desc) @private {
    return desc.msaa != MsaaSamples.ONE && desc.shading == ShadingPath.DEFERRED;
}

fn bool msaa_reflection_gbuffer_wanted(ViewDesc* desc) @private {
    return desc.ray_tracing.reflections && desc.shading == ShadingPath.FORWARD;
}

// The deferred lighting reads the multisample depth by sample.
fn gpu::TextureUsage msaa_depth_usage(ViewDesc* desc) @private {
    if (desc.shading == ShadingPath.DEFERRED) return MSAA_SAMPLED_DEPTH_USAGE;

    return MSAA_DEPTH_USAGE;
}

fn bool msaa_normal_copy_wanted(ViewDesc* desc) @private {
    if (desc.msaa == MsaaSamples.ONE || desc.shading != ShadingPath.DEFERRED) return false;

    return desc.ambient_occlusion.kind != AoKind.NONE || desc.screen_space_gi.enabled || desc.ray_tracing.reflections;
}

fn bool msaa_specular_copy_wanted(ViewDesc* desc) @private {
    return desc.msaa != MsaaSamples.ONE && desc.shading == ShadingPath.DEFERRED && desc.ray_tracing.reflections;
}

// Screen-space effects and traced reflections read one sample of the deferred channels they use.
fn Target* deferred_normals(ViewRecord* record) @private {
    if (record.desc.msaa == MsaaSamples.ONE) return &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS.ordinal];

    return &record.normal_sample_zero;
}

fn Target* deferred_specular(ViewRecord* record) @private {
    if (record.desc.msaa == MsaaSamples.ONE) return &record.gbuffer[GBufferChannel.EMISSIVE_SPECULAR.ordinal];

    return &record.specular_sample_zero;
}

// A deferred view draws its prepass whatever the description says.
fn bool view_draws_prepass(ViewDesc* desc) @private {
    return desc.shading == ShadingPath.DEFERRED || forward_depth_prepass(desc);
}

fn gpu::TextureState opaque_depth_state(ViewRecord* record) @private {
    if (record.desc.msaa == MsaaSamples.ONE) return DEPTH_ATTACHMENT_STATE;

    return DEPTH_RESOLVE_STATE;
}

fn gpu::SampleCount draw_list_samples(ViewDesc* desc, DrawList list) @private {
    if (list == DrawList.OPAQUE || list == DrawList.GBUFFER) return msaa_sample_count(desc.msaa);

    return gpu::SampleCount.ONE;
}

// Distinct counts above ONE among the live views; prepassed keeps the views that draw a depth prepass and
// deferred the views that shade a G-buffer.
fn MsaaCounts live_msaa_counts(Renderer* renderer, bool prepassed = false, bool deferred = false) @private {
    MsaaCounts counts;
    uint seen;
    foreach (&view : renderer.views.items) {
        ViewDesc* desc = &view.desc;
        if (!view.live || desc.msaa == MsaaSamples.ONE) continue;
        if (prepassed && !view_draws_prepass(desc)) continue;
        if (deferred && desc.shading != ShadingPath.DEFERRED) continue;

        uint bit = 1u << desc.msaa.ordinal;
        if (seen & bit) continue;

        seen |= bit;
        counts.items[counts.len++] = msaa_sample_count(desc.msaa);
    }

    return counts;
}

fn bool? msaa_gbuffer_supported(MsaaProbe* probe) @private {
    foreach (format : GBUFFER_FORMATS) {
        if (!msaa_image_supported(probe, format, MSAA_SAMPLED_USAGE)!) return false;
    }

    return true;
}

// A window view without a surface has no images to check.
fn void? validate_msaa_support(Renderer* renderer, ViewDesc* desc, uint[<2>] output) @private {
    if (desc.msaa == MsaaSamples.ONE) return;
    if (desc.shading == ShadingPath.DEFERRED && !renderer.caps.sample_rate_shading) return c3d::UNSUPPORTED~;
    if (output.x == 0 || output.y == 0) return;

    MsaaProbe probe = {
        .renderer = renderer,
        .extent   = working_extent(
            viewport:      desc.viewport,
            output_width:  output.x,
            output_height: output.y,
            render_scale:  desc.render_scale,
        ),
        .samples  = msaa_sample_count(desc.msaa),
    };

    bool supported = msaa_image_supported(&probe, HDR_FORMAT, MSAA_COLOR_USAGE)!
        && msaa_image_supported(&probe, DEPTH_FORMAT, msaa_depth_usage(desc))!;
    if (supported && desc.shading == ShadingPath.DEFERRED) supported = msaa_gbuffer_supported(&probe)!;
    if (supported && post::uses_velocity(desc)) {
        supported = msaa_image_supported(&probe, post::velocity_format(desc), MSAA_SAMPLED_USAGE)!;
    }

    if (supported && msaa_reflection_gbuffer_wanted(desc)) {
        supported = msaa_image_supported(&probe, REFLECTION_SURFACE_FORMAT, MSAA_SAMPLED_USAGE)!;
    }

    if (!supported) return c3d::UNSUPPORTED~;
}

fn Target? allocate_msaa_target(
    Renderer* renderer,
    ViewRecord* record,
    gpu::Format format,
    gpu::TextureUsage usage,
    ZString debug_name,
) @local {
    return allocate_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     format,
        usage:      usage,
        debug_name: debug_name,
        samples:    msaa_sample_count(record.desc.msaa),
    );
}

fn Target? allocate_sample_zero_target(
    Renderer* renderer,
    ViewRecord* record,
    GBufferChannel channel,
    ZString debug_name,
) @local {
    return allocate_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     GBUFFER_FORMATS[channel.ordinal],
        usage:      MSAA_SAMPLED_USAGE,
        debug_name: debug_name,
    );
}

fn void? acquire_msaa_images(Renderer* renderer, ViewRecord* record) @private {
    ViewDesc* desc = &record.desc;
    if (desc.msaa == MsaaSamples.ONE || !record.hdr_color.texture.is_valid()) return;

    if (!record.msaa_color.texture.is_valid()) {
        record.msaa_color = allocate_msaa_target(
            renderer:   renderer,
            record:     record,
            format:     HDR_FORMAT,
            usage:      MSAA_COLOR_USAGE,
            debug_name: "msaa_color",
        )!;
    }

    if (!record.msaa_depth.texture.is_valid()) {
        record.msaa_depth = allocate_msaa_target(
            renderer:   renderer,
            record:     record,
            format:     DEPTH_FORMAT,
            usage:      msaa_depth_usage(desc),
            debug_name: "msaa_depth",
        )!;
    }

    if (post::uses_velocity(desc) && !record.msaa_velocity.texture.is_valid()) {
        record.msaa_velocity = allocate_msaa_target(
            renderer:   renderer,
            record:     record,
            format:     post::velocity_format(desc),
            usage:      MSAA_SAMPLED_USAGE,
            debug_name: "msaa_velocity",
        )!;
    }

    if (msaa_reflection_gbuffer_wanted(desc) && !record.msaa_reflection_gbuffer.texture.is_valid()) {
        record.msaa_reflection_gbuffer = allocate_msaa_target(
            renderer:   renderer,
            record:     record,
            format:     REFLECTION_SURFACE_FORMAT,
            usage:      MSAA_SAMPLED_USAGE,
            debug_name: "msaa_reflection_gbuffer",
        )!;
    }

    if (msaa_normal_copy_wanted(desc) && !record.normal_sample_zero.texture.is_valid()) {
        record.normal_sample_zero = allocate_sample_zero_target(
            renderer:   renderer,
            record:     record,
            channel:    GBufferChannel.NORMAL_ROUGHNESS,
            debug_name: "normal_sample_zero",
        )!;
    }

    if (msaa_specular_copy_wanted(desc) && !record.specular_sample_zero.texture.is_valid()) {
        record.specular_sample_zero = allocate_sample_zero_target(
            renderer:   renderer,
            record:     record,
            channel:    GBufferChannel.EMISSIVE_SPECULAR,
            debug_name: "specular_sample_zero",
        )!;
    }
}

// Clears the staged images a new configuration cannot reuse; the caller retires what it gave up.
fn void drop_stale_msaa_images(ViewRecord* staged, ViewDesc* previous) @private {
    ViewDesc* desc = &staged.desc;
    if (!msaa_normal_copy_wanted(desc)) staged.normal_sample_zero = {};
    if (!msaa_specular_copy_wanted(desc)) staged.specular_sample_zero = {};
    if (desc.msaa == MsaaSamples.ONE || desc.shading != ShadingPath.DEFERRED) staged.msaa_edges = {};

    if (desc.msaa != previous.msaa) {
        staged.msaa_color = {};
        staged.msaa_depth = {};
        staged.msaa_velocity = {};
        staged.msaa_reflection_gbuffer = {};
        staged.gbuffer = {};
        staged.msaa_edges = {};
        return;
    }

    if (!post::uses_velocity(desc) || staged.msaa_velocity.format != post::velocity_format(desc)) {
        staged.msaa_velocity = {};
    }

    if (!msaa_reflection_gbuffer_wanted(desc)) staged.msaa_reflection_gbuffer = {};

    // Only a deferred view samples its multisample depth, and a usage cannot change in place.
    if (staged.msaa_depth.view.is_valid() != (desc.shading == ShadingPath.DEFERRED)) staged.msaa_depth = {};
}

fn PipelineKey sample_zero_pipeline_key(gpu::Format target_format) @private {
    return {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = SAMPLE_ZERO },
        .color_formats = { [0] = target_format },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
}

// Vulkan resolves a float color attachment only by averaging; velocity and surface data take one sample.
fn void? record_sample_zero(Renderer* renderer, Target* source, Target* destination) @private {
    source.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    destination.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, CompositeRoot::size)!;
    *(CompositeRoot*)root.bytes.ptr = {
        .source_texture = source.view.index,
        .pre_exposure   = 1,
    };

    gpu::PipelineHandle pipeline = renderer.pipelines.get(
        &renderer.device,
        sample_zero_pipeline_key(destination.format),
    )!;

    return record_fullscreen_pass(
        renderer:      renderer,
        target:        destination,
        pipeline:      pipeline,
        fragment_root: root.address,
        rect:          {},
        load:          gpu::LoadOp.DONT_CARE,
    );
}

fn PipelineKey msaa_edges_pipeline_key() @private {
    return {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = MSAA_EDGES },
        .color_formats = { [0] = MSAA_EDGES_FORMAT },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
}

// The mask reads the G-buffer and depth, which the caller has left in the fragment-read state.
fn void? record_msaa_edges(Renderer* renderer, ViewRecord* record, gpu::GpuAddress root) @private {
    Target* edges = &record.msaa_edges;
    edges.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, msaa_edges_pipeline_key())!;

    @profile_pass(renderer, Pass.MSAA_EDGES) {
        record_fullscreen_pass(
            renderer:      renderer,
            target:        edges,
            pipeline:      pipeline,
            fragment_root: root,
            rect:          {},
            load:          gpu::LoadOp.DONT_CARE,
        )!;
    }!;

    edges.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
}
