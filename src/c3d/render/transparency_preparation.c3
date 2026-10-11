module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::shader;
import gpu;
import std::collections::list;

enum TransparencyPipelinePhase @private {
    CAPTURE,
    BACKGROUND_CAPTURE,
    RETAINED,
    TAIL,
}

fn bool transparency_material_participates(
    Material* material,
    bool custom_declared,
    SceneReads custom_reads = {},
) @private {
    if (!material.common.depth_test) return false;

    switch (material.kind) {
        case BASIC:
        case STANDARD:
        case TOON:
            return material.common.alpha_mode == AlphaMode.BLEND;
        case PHYSICAL:
            return material.common.alpha_mode == AlphaMode.BLEND || material.physical.transmission > 0;
        case CUSTOM:
            return custom_declared && (material.common.alpha_mode == AlphaMode.BLEND || custom_reads != (SceneReads){});
    }
}

fn PipelineKey transparency_pipeline_key(
    Material* material,
    ShaderVariant vertex,
    gpu::PolygonMode polygon,
    uint shadow_flags,
    bool capture,
    gpu::Format color_format = gpu::Format.UNDEFINED,
    gpu::Format anchor_format = gpu::Format.R32_FLOAT,
) @private {
    vertex.flags |= shader::SHADER_FLAG_LAYERED;
    ShaderVariant fragment = material_fragment(material, shadow_flags);
    fragment.flags |= shader::SHADER_FLAG_LAYERED;

    if (color_format == gpu::Format.UNDEFINED) {
        color_format = capture ? gpu::Format.R32_FLOAT : TRANSPARENCY_COMPOSITION_FORMAT;
    }

    PipelineKey key = {
        .vertex = vertex,
        .fragment = fragment,
        .color_formats = { [0] = color_format, [1] = anchor_format },
        .color_count = 2,
        .depth_format = DEPTH_FORMAT,
        .samples = gpu::SampleCount.ONE,
        .polygon = polygon,
    };
    if (material.kind == MaterialKind.CUSTOM) {
        key.color_count = 1;
        key.color_formats[1] = gpu::Format.UNDEFINED;
    }

    return key;
}

fn PipelineKey? published_transparency_pipeline_key(ShaderRes* published, PipelineKey key) @private {
    asset::ShaderDesc* desc = &published.desc;
    if (!desc.layered_transparency) return PIPELINE_REJECTED~;
    if (key.vertex.shader == BILLBOARD_VERTEX && desc.vertex.shaded.len) return PIPELINE_REJECTED~;

    key.shader = published.asset;
    key.shader_revision = published.revision;
    key.custom = { .vertex = desc.vertex.shaded.len > 0, .fragment = true, .layered = true };
    uint shadow_flags = key.fragment.flags & ~shader::SHADER_FLAG_LAYERED;
    key.fragment = custom_fragment_variant(desc, shadow_flags);
    key.fragment.flags |= shader::SHADER_FLAG_LAYERED;
    if (key.custom.vertex) {
        key.vertex = {
            .shader = MESH,
            .flags = shader::SHADER_FLAG_LAYERED | (key.vertex.flags & shader::SHADER_FLAG_INSTANCED),
        };
    }

    if (!key_stages_present(key, desc)) return PIPELINE_REJECTED~;
    return key;
}

fn gpu::PipelineHandle? transparency_pipeline_for(
    Renderer* renderer,
    Material* material,
    ShaderVariant vertex,
    uint shadow_flags,
    bool capture,
    gpu::Format color_format = gpu::Format.UNDEFINED,
    gpu::Format anchor_format = gpu::Format.R32_FLOAT,
) @private {
    renderer.stats.pipeline_lookups++;
    bool wireframe = material.common.wireframe && renderer.caps.line_polygon_mode;
    PipelineKey key = transparency_pipeline_key(
        material: material,
        vertex: vertex,
        polygon: wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL,
        shadow_flags: shadow_flags,
        capture: capture,
        color_format: color_format,
        anchor_format: anchor_format,
    );
    if (material.kind != MaterialKind.CUSTOM) {
        return renderer.pipelines.get(&renderer.device, key);
    }

    ShaderRes* published = resolve_shader(renderer, material.custom.shader)!;
    key = published_transparency_pipeline_key(published, key)!;
    return custom_pipeline(renderer, published, key);
}

fn bool preparation_transparency_declared(Renderer* renderer, Material* material) @private {
    if (material.kind != MaterialKind.CUSTOM) return false;

    ShaderId id = material.custom.shader;
    if (!renderer.assets.shaders.is_live(id)) return false;

    bool declared = renderer.assets.shader(id).desc.layered_transparency;
    ShaderRes* published = &renderer.shaders[id.index];
    if (c3d::same_id(published.asset, id)) declared |= published.desc.layered_transparency;
    return declared;
}

fn void append_prepare_transparency_pipelines(
    Renderer* renderer,
    GeometryId geometry,
    MaterialId material,
    ShaderVariant vertex,
    List{PrepareUnit}* listed,
) @private {
    Material* data = &renderer.assets.material(material).data;
    bool declared = preparation_transparency_declared(renderer, data);
    SceneReads custom_reads;
    if (data.kind == MaterialKind.CUSTOM && declared) {
        custom_reads = renderer.assets.shader(data.custom.shader).desc.scene_reads;
        ShaderRes* published = &renderer.shaders[data.custom.shader.index];
        if (c3d::same_id(published.asset, data.custom.shader)) custom_reads |= published.desc.scene_reads;
    }

    if (!transparency_material_participates(data, declared, custom_reads)) return;

    bool wireframe = data.common.wireframe && renderer.caps.line_polygon_mode;
    gpu::PolygonMode polygon = wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL;
    foreach (&view : renderer.views.items) {
        if (!view.live || view.desc.transparency.mode != TransparencyMode.LAYERED
          || view.desc.shading == ShadingPath.PATH_TRACED) continue;

        uint shadow_flags = rt_shadow_flags(renderer, view.desc.ray_tracing.shadows);
        append_prepare_mesh_key(
            renderer: renderer,
            listed: listed,
            key: forward_pipeline_key(
                material: data,
                vertex: vertex,
                polygon: polygon,
                shadow_flags: shadow_flags,
            ),
            pass: PreparePipelinePass.FORWARD,
            geometry: geometry,
            material: material,
        );

        TransparencyPipelinePhase[4] phases = {
            TransparencyPipelinePhase.CAPTURE,
            TransparencyPipelinePhase.BACKGROUND_CAPTURE,
            TransparencyPipelinePhase.RETAINED,
            TransparencyPipelinePhase.TAIL,
        };
        foreach (phase : phases) {
            bool capture = phase == TransparencyPipelinePhase.CAPTURE
              || phase == TransparencyPipelinePhase.BACKGROUND_CAPTURE;
            gpu::Format color_format = phase == TransparencyPipelinePhase.CAPTURE
              ? gpu::Format.R32_FLOAT
              : phase == TransparencyPipelinePhase.TAIL ? HDR_FORMAT : TRANSPARENCY_COMPOSITION_FORMAT;
            gpu::Format anchor_format = phase == TransparencyPipelinePhase.BACKGROUND_CAPTURE
              ? TRANSPARENCY_COMPOSITION_FORMAT : gpu::Format.R32_FLOAT;

            PipelineKey key = transparency_pipeline_key(
                material: data,
                vertex: vertex,
                polygon: polygon,
                shadow_flags: shadow_flags,
                capture: capture,
                color_format: color_format,
                anchor_format: anchor_format,
            );
            if (data.kind == MaterialKind.CUSTOM) {
                key.shader = data.custom.shader;
                key.shader_revision = renderer.assets.shader(key.shader).header.revision;
                key.custom.layered = true;
            }

            append_prepare_cache(
                listed: listed,
                key: key,
                pass: PreparePipelinePass.REGISTRY,
                geometry: geometry,
                material: material,
            );
        }
    }
}

fn void? prepare_transparency_pipelines(
    Renderer* renderer,
    Material* material,
    ShaderVariant vertex,
) @private {
    bool declared;
    SceneReads custom_reads;
    if (material.kind == MaterialKind.CUSTOM) {
        ShaderRes* published = resolve_shader(renderer, material.custom.shader)!;
        declared = published.desc.layered_transparency;
        custom_reads = published.desc.scene_reads;
    }

    if (!transparency_material_participates(material, declared, custom_reads)) return;

    foreach (&view : renderer.views.items) {
        if (!view.live || view.desc.transparency.mode != TransparencyMode.LAYERED
          || view.desc.shading == ShadingPath.PATH_TRACED) continue;

        TransparencyPipelinePhase[4] phases = {
            TransparencyPipelinePhase.CAPTURE,
            TransparencyPipelinePhase.BACKGROUND_CAPTURE,
            TransparencyPipelinePhase.RETAINED,
            TransparencyPipelinePhase.TAIL,
        };
        foreach (phase : phases) {
            bool capture = phase == TransparencyPipelinePhase.CAPTURE
              || phase == TransparencyPipelinePhase.BACKGROUND_CAPTURE;
            gpu::Format color_format = phase == TransparencyPipelinePhase.CAPTURE
              ? gpu::Format.R32_FLOAT
              : phase == TransparencyPipelinePhase.TAIL ? HDR_FORMAT : TRANSPARENCY_COMPOSITION_FORMAT;
            gpu::Format anchor_format = phase == TransparencyPipelinePhase.BACKGROUND_CAPTURE
              ? TRANSPARENCY_COMPOSITION_FORMAT : gpu::Format.R32_FLOAT;

            transparency_pipeline_for(
                renderer: renderer,
                material: material,
                vertex: vertex,
                shadow_flags: rt_shadow_flags(renderer, view.desc.ray_tracing.shadows),
                capture: capture,
                color_format: color_format,
                anchor_format: anchor_format,
            )!;
        }
    }
}
