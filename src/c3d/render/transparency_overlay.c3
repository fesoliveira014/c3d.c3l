module c3d::render;

import c3d;
import c3d::material;
import gpu;

<*
 Record raw overlay contributions and their remaining destination share.
 @require items.len > 0, target.format == record.hdr_color.format
*>
fn void? record_transparency_opaque_overlay(
    Renderer* renderer,
    ViewRecord* record,
    DrawItem[] items,
    Target* target,
) @private {
    gpu::ColorTargetDesc[1] colors = {{
        .view = target.attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .rgba = { 0, 0, 0, 1 } },
    }};
    gpu::DepthTargetDesc depth = {
        .view = record.depth.attachment,
        .load_op = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth = &depth,
        .width = target.width,
        .height = target.height,
    };
    gpu::PipelineHandle pipeline = first_pipeline(renderer, items)!;

    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    target.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    record.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;

    gpu::ColorTargetState[1] outputs = { gpu::premultiplied_alpha_blend() };
    gpu::GraphicsState state = gpu::render_geometry_state(target.width, target.height)!;
    state.viewport = flipped_viewport(target.width, target.height);
    state.color.targets = outputs[..];

    foreach (&item : items) {
        MaterialCommon* common = &material_data(renderer, item.material).common;

        if (item.pipeline.index != pipeline.index) {
            gpu::cmd_bind_pipeline(&renderer.commands, item.pipeline)!;
            pipeline = item.pipeline;
        }

        if (common.alpha_mode == AlphaMode.BLEND) {
            outputs[0] = blend_target(true, common.blend_mode);
            outputs[0].blend.src_alpha = gpu::BlendFactor.ZERO;
        } else {
            outputs[0] = gpu::premultiplied_alpha_blend();
            outputs[0].blend.dst_color = gpu::BlendFactor.ZERO;
            outputs[0].blend.src_alpha = gpu::BlendFactor.ZERO;
            outputs[0].blend.dst_alpha = gpu::BlendFactor.ZERO;
        }

        state.raster.cull_mode = common.double_sided ? gpu::CullMode.NONE : gpu::CullMode.BACK;
        state.raster.front_face = item.front_face;
        state.raster.topology = primitive_topology(item.geometry.topology);
        state.depth = {
            .test_enable = common.depth_test,
            .write_enable = false,
            .compare = gpu::CompareOp.GREATER,
        };
        gpu::cmd_set_graphics_state(&renderer.commands, &state)!;

        if (candidate_instanced(item.candidate)) {
            record_batch_draw(
                renderer: renderer,
                root: item.root,
                geometry: item.geometry,
                range: item.range,
            )!;
        } else {
            record_geometry_draw(renderer, item.root, item.geometry)!;
        }
    }

    gpu::cmd_end_render_pass(&renderer.commands)!;
    renderer.work_recorded = true;
}