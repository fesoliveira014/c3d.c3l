module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::shader;
import gpu;
import std::math;

$assert LightingResolveRoot::size == 48;
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

fn PipelineKey gbuffer_pipeline_key(ShaderVariant vertex, ShaderVariant fragment, gpu::PolygonMode polygon) @private {
    return {
        .vertex        = vertex,
        .fragment      = fragment,
        .color_formats = GBUFFER_FORMATS,
        .color_count   = GBUFFER_CHANNEL_COUNT,
        .depth_format  = DEPTH_FORMAT,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = polygon,
    };
}

fn gpu::PipelineHandle? gbuffer_pipeline_for(Renderer* renderer, Material* material, ShaderVariant vertex) @private {
    renderer.stats.pipeline_lookups++;
    bool wireframe = material.common.wireframe && renderer.caps.line_polygon_mode;
    PipelineKey key = gbuffer_pipeline_key(
        vertex:   vertex,
        fragment: gbuffer_fragment(material),
        polygon:  wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL,
    );
    if (material.kind != MaterialKind.CUSTOM) return renderer.pipelines.get(&renderer.device, key);

    ShaderId shader = material.custom.shader;
    asset::ShaderDesc* stages = &renderer.assets.shader(shader).desc;
    key.shader = shader;
    key.shader_revision = renderer.shaders[shader.index].revision;
    key.custom = { .vertex = stages.vertex.shaded.len > 0, .gbuffer = true };
    if (key.custom.vertex) key.vertex = { .shader = MESH, .flags = vertex.flags & shader::SHADER_FLAG_INSTANCED };
    CustomStageSource source = custom_stage_source(stages, key);
    return renderer.pipelines.get(&renderer.device, key, &source);
}

fn gpu::PipelineHandle? default_gbuffer_pipeline(Renderer* renderer) @private {
    renderer.stats.pipeline_lookups++;
    PipelineKey key = gbuffer_pipeline_key(
        vertex:   { .shader = MESH },
        fragment: { .shader = STANDARD_GBUFFER },
        polygon:  gpu::PolygonMode.FILL,
    );
    return renderer.pipelines.get(&renderer.device, key);
}

fn PipelineKey lighting_resolve_pipeline_key(bool rt_shadows) @private {
    return {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = LIGHTING_RESOLVE, .flags = rt_shadows ? shader::SHADER_FLAG_RT_SHADOWS : 0 },
        .color_formats = { [0] = HDR_FORMAT },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
}

fn void? record_deferred_scene(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    bool view_reflected,
    DrawItem[] gbuffer,
    DrawItem[] opaque,
    DrawItem[] transparent,
    gpu::GpuAddress sky_root,
    bool sky,
    Vec4 clear_color,
) @private {
    record_depth_prepass(
        renderer:       renderer,
        record:         record,
        frame:          frame,
        view_reflected: view_reflected,
        gbuffer:        gbuffer,
        opaque:         opaque,
    )!;
    record_gbuffer_pass(renderer, record, gbuffer)!;
    if (record.desc.ambient_occlusion.kind != AoKind.NONE) record_ambient_occlusion(renderer, record, frame)!;
    if (record.desc.ray_tracing.reflections) record_reflections(renderer, record, frame)!;
    record_lighting_pass(renderer, record, frame, clear_color)!;
    record.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;
    record_forward_pass(
        renderer:      renderer,
        record:        record,
        opaque:        opaque,
        transparent:   transparent,
        sky_root:      sky_root,
        sky:           sky,
        clear_color:   clear_color,
        color_loaded:  true,
        depth_matched: true,
    )!;
}

fn void? record_gbuffer_pass(Renderer* renderer, ViewRecord* record, DrawItem[] gbuffer) @private {
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
        .view     = record.depth.attachment,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth  = &depth,
        .width  = record.depth.width,
        .height = record.depth.height,
    };
    gpu::PipelineHandle first = gbuffer.len ? gbuffer[0].pipeline : default_gbuffer_pipeline(renderer)!;

    begin_profile_pass(renderer, Pass.GBUFFER)!;
    // Bound before the pass begins: the backend checks the bound pipeline against the pass formats at begin.
    gpu::cmd_bind_pipeline(&renderer.commands, first)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    record_draws(
        renderer:   renderer,
        record:     record,
        items:      gbuffer,
        pipeline:   first,
        pass_state: { .color_targets = color_targets[..], .depth_compare = gpu::CompareOp.EQUAL, .depth_write = false },
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
    end_profile_pass(renderer, Pass.GBUFFER)!;
}

fn void? record_lighting_pass(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    Vec4 clear_color,
) @private {
    foreach (&target : record.gbuffer) target.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    record.depth.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    record.hdr_color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;

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
        .depth                    = record.depth.view.index,
        .sampler_index            = renderer.linear_clamp_sampler,
        .reflection_texture       = reflections ? record.reflection_blur.view.index : (gpu::TextureIndex)0,
        .brdf_lut                 = reflections ? renderer.environment_state.brdf_lut.view.index : (gpu::TextureIndex)0,
        .max_reflection_roughness = record.desc.ray_tracing.max_reflection_roughness,
    };
    gpu::PipelineHandle pipeline = renderer.pipelines.get(
        &renderer.device,
        lighting_resolve_pipeline_key(record.desc.ray_tracing.shadows),
    )!;

    begin_profile_pass(renderer, Pass.LIGHTING)!;
    record_fullscreen_pass(
        renderer:      renderer,
        target:        &record.hdr_color,
        pipeline:      pipeline,
        fragment_root: root.address,
        rect:          {},
        load:          gpu::LoadOp.CLEAR,
        clear_color:   clear_color,
    )!;
    end_profile_pass(renderer, Pass.LIGHTING)!;
}
