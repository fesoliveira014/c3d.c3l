module c3d::render;

import c3d;
import c3d::material;
import c3d::shader;
import gpu;

fn bool material_outlined(Material* material) @private {
    return material.kind == MaterialKind.TOON && material.toon.outline_width > 0 && writes_own_depth(material);
}

fn bool outlined(Material* material, MeshCandidate* candidate, GpuGeometry* geometry) @private {
    return material_outlined(material) && !candidate.billboards && !candidate.impostor
        && geometry.topology == Topology.TRIANGLES;
}

fn ShaderVariant outline_vertex_variant(ShaderVariant vertex) @private {
    return { .shader = MESH, .flags = vertex.flags | shader::SHADER_FLAG_OUTLINE };
}

fn PipelineKey outline_pipeline_key(ShaderVariant vertex, gpu::PolygonMode polygon) @private {
    return {
        .vertex = outline_vertex_variant(vertex),
        .fragment = { .shader = TOON_OUTLINE },
        .color_formats = { [0] = HDR_FORMAT },
        .color_count = 1,
        .depth_format = DEPTH_FORMAT,
        .samples = gpu::SampleCount.ONE,
        .polygon = polygon,
    };
}

fn gpu::PipelineHandle? outline_pipeline_for(Renderer* renderer, Material* material, ShaderVariant vertex) @private {
    renderer.stats.pipeline_lookups++;
    bool wireframe = material.common.wireframe && renderer.caps.line_polygon_mode;
    PipelineKey key = outline_pipeline_key(vertex, wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL);
    return renderer.pipelines.get(&renderer.device, key);
}

// The hull always writes depth against the nearest surface, whatever depth state the pass gave the draw before it.
fn void? record_outline_draw(Renderer* renderer, DrawItem* item, gpu::GraphicsState* state) @private {
    gpu::cmd_bind_pipeline(&renderer.commands, item.outline_pipeline)!;
    state.raster.cull_mode = gpu::CullMode.FRONT;
    state.raster.front_face = item.front_face;
    state.raster.topology = gpu::PrimitiveTopology.TRIANGLES;
    state.color.targets[0] = gpu::color_blend_disabled();
    state.depth = {
        .test_enable  = true,
        .write_enable = true,
        .compare      = gpu::CompareOp.GREATER,
    };
    gpu::cmd_set_graphics_state(&renderer.commands, state)!;

    record_item_draw(renderer, item)!;
}
