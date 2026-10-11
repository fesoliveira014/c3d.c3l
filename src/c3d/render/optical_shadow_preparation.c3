module c3d::render;

import c3d;
import c3d::material;
import c3d::shader;
import gpu;
import std::collections::list;

fn void append_prepare_optical_shadow_pipelines(
    Renderer* renderer,
    GeometryId geometry,
    MaterialId material,
    ShaderVariant vertex,
    List{PrepareUnit}* listed,
) @private {
    Material* data = &renderer.assets.material(material).data;
    if (data.kind != MaterialKind.PHYSICAL) return;

    gpu::PolygonMode polygon = data.common.wireframe && renderer.caps.line_polygon_mode
      ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL;
    append_prepare_cache(
        listed: listed,
        key: optical_shadow_pipeline_key(vertex, polygon, false),
        pass: PreparePipelinePass.REGISTRY,
        geometry: geometry,
        material: material,
    );
    append_prepare_cache(
        listed: listed,
        key: optical_shadow_pipeline_key(vertex, polygon, true),
        pass: PreparePipelinePass.REGISTRY,
        geometry: geometry,
        material: material,
    );
    append_prepare_cache(listed, optical_store_pipeline_key());
}

fn void? prepare_optical_shadow_pipelines(Renderer* renderer, MaterialId material, ShaderVariant vertex) @private {
    Material* data = &renderer.assets.material(material).data;
    if (data.kind != MaterialKind.PHYSICAL) return;

    gpu::PolygonMode polygon = data.common.wireframe && renderer.caps.line_polygon_mode
      ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL;
    renderer.pipelines.get(&renderer.device, optical_shadow_pipeline_key(vertex, polygon, false))!;
    renderer.pipelines.get(&renderer.device, optical_shadow_pipeline_key(vertex, polygon, true))!;
    renderer.pipelines.get(&renderer.device, optical_store_pipeline_key())!;
}
