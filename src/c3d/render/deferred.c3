module c3d::render;

import c3d;
import c3d::material;
import c3d::shader;
import gpu;
import std::math;

$assert LightingResolveRoot::size == 56;
$assert GBUFFER_CHANNEL_COUNT == KEY_COLOR_TARGETS;

fn ShaderVariant gbuffer_fragment(Material* material) @private {
    switch (material.kind) {
        case STANDARD: return { .shader = STANDARD_GBUFFER };
        case PHYSICAL: return { .shader = PHYSICAL_GBUFFER };
        case CUSTOM:   return {};
        case BASIC:
        case TOON:
            unreachable("not encodable");
    }
}

fn PipelineKey gbuffer_pipeline_key(
    ShaderVariant vertex,
    ShaderVariant fragment,
    gpu::PolygonMode polygon,
    gpu::SampleCount samples = gpu::SampleCount.ONE,
) @private {
    return {
        .vertex        = vertex,
        .fragment      = fragment,
        .color_formats = GBUFFER_FORMATS,
        .color_count   = GBUFFER_CHANNEL_COUNT,
        .depth_format  = DEPTH_FORMAT,
        .samples       = samples,
        .polygon       = polygon,
    };
}

fn gpu::PipelineHandle? gbuffer_pipeline_for(
    Renderer* renderer,
    Material* material,
    ShaderVariant vertex,
    gpu::SampleCount samples = gpu::SampleCount.ONE,
) @private {
    renderer.stats.pipeline_lookups++;
    bool wireframe = material.common.wireframe && renderer.caps.line_polygon_mode;
    PipelineKey key = gbuffer_pipeline_key(
        vertex:   vertex,
        fragment: vertex.shader == IMPOSTOR_VERTEX ? (ShaderVariant){ .shader = IMPOSTOR_GBUFFER } : gbuffer_fragment(material),
        polygon:  wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL,
        samples:  samples,
    );
    if (material.kind != MaterialKind.CUSTOM) return renderer.pipelines.get(&renderer.device, key);

    ShaderRes* published = resolve_shader(renderer, material.custom.shader)!;
    key.custom = { .vertex = published.desc.vertex.shaded.len > 0, .gbuffer = true };
    if (key.custom.vertex) key.vertex = { .shader = MESH, .flags = vertex.flags & shader::SHADER_FLAG_INSTANCED };
    return custom_pipeline(renderer, published, key);
}

fn gpu::PipelineHandle? default_gbuffer_pipeline(
    Renderer* renderer,
    gpu::SampleCount samples = gpu::SampleCount.ONE,
) @private {
    renderer.stats.pipeline_lookups++;
    PipelineKey key = gbuffer_pipeline_key(
        vertex:   { .shader = MESH },
        fragment: { .shader = STANDARD_GBUFFER },
        polygon:  gpu::PolygonMode.FILL,
        samples:  samples,
    );
    return renderer.pipelines.get(&renderer.device, key);
}

fn PipelineKey lighting_resolve_pipeline_key(
    uint shadow_flags,
    gpu::SampleCount samples = gpu::SampleCount.ONE,
    bool pixel_rate = false,
) @private {
    uint multisample = samples == gpu::SampleCount.ONE ? 0 : shader::SHADER_FLAG_MULTISAMPLE;
    if (pixel_rate) multisample |= shader::SHADER_FLAG_MULTISAMPLE_PIXEL;
    return {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = LIGHTING_RESOLVE, .flags = shadow_flags | multisample },
        .color_formats = { [0] = HDR_FORMAT },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = samples,
        .polygon       = gpu::PolygonMode.FILL,
    };
}

fn void? record_deferred_shading(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    DrawItem[] opaque,
    DrawItem[] transparent,
    gpu::GpuAddress sky_root,
    bool sky,
    bool atmosphere,
    Vec4 clear_color,
    bool history_valid,
    ReflectionLights reflection_lights,
) @private {
    if (record.desc.ambient_occlusion.kind != AoKind.NONE) {
        record_ambient_occlusion(
            renderer:      renderer,
            record:        record,
            frame:         frame,
            history_valid: history_valid,
        )!;
    }

    if (record.desc.screen_space_gi.enabled) record_screen_space_gi(renderer, record, frame, history_valid)!;
    if (record.desc.ray_tracing.reflections) {
        record_reflections(
            renderer:      renderer,
            record:        record,
            frame:         frame,
            lights:        reflection_lights,
            history_valid: history_valid,
        )!;
    }
    record_lighting_pass(renderer, record, frame, clear_color)!;
    if (record.desc.msaa == MsaaSamples.ONE) record.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;

    record_forward_pass(
        renderer:      renderer,
        record:        record,
        opaque:        opaque,
        transparent:   transparent,
        sky_root:      sky_root,
        sky:           sky,
        atmosphere:    atmosphere,
        clear_color:   clear_color,
        color_loaded:  true,
        depth_matched: true,
    )!;
}

fn void? record_gbuffer_pass(Renderer* renderer, ViewRecord* record, DrawItem[] gbuffer) @private {
    bool multisample = record.desc.msaa != MsaaSamples.ONE;
    Target* depth_image = multisample ? &record.msaa_depth : &record.depth;
    foreach (&target : record.gbuffer) target.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    gpu::ColorTargetDesc[GBUFFER_CHANNEL_COUNT] colors;
    gpu::ColorTargetState[GBUFFER_CHANNEL_COUNT] color_targets;
    foreach (channel, &color : colors) {
        *color = {
            .view     = record.gbuffer[channel].attachment,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
        };
        color_targets[channel] = gpu::color_blend_disabled();
    }
    gpu::DepthTargetDesc depth = {
        .view     = depth_image.attachment,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth  = &depth,
        .width  = record.depth.width,
        .height = record.depth.height,
    };
    gpu::PipelineHandle first = gbuffer.len
      ? gbuffer[0].pipeline : default_gbuffer_pipeline(renderer, msaa_sample_count(record.desc.msaa))!;

    @profile_pass(renderer, Pass.GBUFFER) {
        // Bound before the pass begins: the backend checks the bound pipeline against the pass formats at begin.
        gpu::cmd_bind_pipeline(&renderer.commands, first)!;
        gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
        record_draws(
            renderer:   renderer,
            record:     record,
            items:      gbuffer,
            pipeline:   first,
            pass_state: {
                .color_targets = color_targets[..],
                .depth_compare = gpu::CompareOp.EQUAL,
                .depth_write   = false,
            },
        )!;
        gpu::cmd_end_render_pass(&renderer.commands)!;

        if (multisample) record_deferred_sample_zero(renderer, record)!;
    }!;
}

fn void? record_deferred_sample_zero(Renderer* renderer, ViewRecord* record) @private {
    if (record.normal_sample_zero.texture.is_valid()) {
        record_sample_zero(
            renderer:    renderer,
            source:      &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS.ordinal],
            destination: &record.normal_sample_zero,
        )!;
    }

    if (record.specular_sample_zero.texture.is_valid()) {
        record_sample_zero(
            renderer:    renderer,
            source:      &record.gbuffer[GBufferChannel.EMISSIVE_SPECULAR.ordinal],
            destination: &record.specular_sample_zero,
        )!;
    }
}

fn void? record_lighting_pass(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    Vec4 clear_color,
) @private {
    bool multisample = record.desc.msaa != MsaaSamples.ONE;
    bool classified = record.msaa_edges.texture.is_valid();
    Target* color = multisample ? &record.msaa_color : &record.hdr_color;
    Target* depth = multisample ? &record.msaa_depth : &record.depth;
    foreach (&target : record.gbuffer) target.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    depth.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    bool reflections = record.desc.ray_tracing.reflections;
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, LightingResolveRoot::size, STREAM_ALIGNMENT)!;
    *(LightingResolveRoot*)root.bytes.ptr = {
        .frame                    = frame,
        .base_color_metallic      = record.gbuffer[GBufferChannel.BASE_COLOR_METALLIC.ordinal].view.index,
        .normal_roughness         = record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS.ordinal].view.index,
        .emissive_specular        = record.gbuffer[GBufferChannel.EMISSIVE_SPECULAR.ordinal].view.index,
        .layers                   = record.gbuffer[GBufferChannel.LAYERS.ordinal].view.index,
        .flags                    = record.gbuffer[GBufferChannel.FLAGS.ordinal].view.index,
        .depth                    = depth.view.index,
        .sampler_index            = renderer.linear_clamp_sampler,
        .reflection_texture       = reflections ? record.reflection_blur.view.index : (gpu::TextureIndex)0,
        .brdf_lut                 = reflections ? renderer.environment_state.brdf_lut.view.index : (gpu::TextureIndex)0,
        .max_reflection_roughness = record.desc.ray_tracing.max_reflection_roughness,
        .msaa_edges               = classified ? record.msaa_edges.view.index : (gpu::TextureIndex)0,
        .msaa_edge_tolerance      = renderer.msaa_edge_mode == MsaaEdgeMode.TOLERANT ? MSAA_EDGE_COLOR_TOLERANCE : 0,
    };
    if (classified) record_msaa_edges(renderer, record, root.address)!;

    uint shadow_flags = rt_shadow_flags(renderer, record.desc.ray_tracing.shadows, record.soft_shadows);
    gpu::SampleCount samples = msaa_sample_count(record.desc.msaa);
    gpu::PipelineHandle pipeline = renderer.pipelines.get(
        &renderer.device,
        lighting_resolve_pipeline_key(shadow_flags, samples),
    )!;
    gpu::PipelineHandle second_pipeline;
    if (classified) {
        second_pipeline = pipeline;
        pipeline = renderer.pipelines.get(
            &renderer.device,
            lighting_resolve_pipeline_key(shadow_flags, samples, pixel_rate: true),
        )!;
    }

    @profile_pass(renderer, Pass.LIGHTING) {
        record_fullscreen_pass(
            renderer:        renderer,
            target:          color,
            pipeline:        pipeline,
            fragment_root:   root.address,
            rect:            {},
            load:            gpu::LoadOp.CLEAR,
            clear_color:     clear_color,
            second_pipeline: second_pipeline,
        )!;
    }!;
}
