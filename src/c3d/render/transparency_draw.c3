module c3d::render;

import c3d;
import c3d::material;
import c3d::shader;
import gpu;

struct TransparencyDraw @private {
    DrawItem* item;
    gpu::PipelineHandle pipeline;
    gpu::GpuAddress root;
    uint color_count;
}

fn void? clear_transparency_geometry(
    Renderer* renderer,
    Target* color,
    Target* anchor,
    Target* depth,
) @private {
    color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    anchor.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;

    gpu::ColorTargetDesc[2] colors = {
        { .view = color.attachment, .load_op = gpu::LoadOp.CLEAR, .store_op = gpu::StoreOp.STORE },
        { .view = anchor.attachment, .load_op = gpu::LoadOp.CLEAR, .store_op = gpu::StoreOp.STORE },
    };
    gpu::DepthTargetDesc depth_target = {
        .view = depth.attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .depth = DEPTH_CLEAR },
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth = &depth_target,
        .width = color.width,
        .height = color.height,
    };

    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
    renderer.work_recorded = true;
}

fn void? clear_transparency_anchor(Renderer* renderer, Target* anchor) @private {
    gpu::ColorTargetDesc[1] colors = {{
        .view = anchor.attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
    }};
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .width = anchor.width,
        .height = anchor.height,
    };

    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
}

fn void? record_transparency_run(
    Renderer* renderer,
    TransparencyDraw[] draws,
    Target* color,
    Target* anchor,
    Target* depth,
    bool capture,
    bool clear_color,
    bool clear_anchor,
    bool clear_depth,
) @private {
    uint color_count = draws[0].color_count;
    gpu::ColorTargetDesc[2] colors = {
        {
            .view = color.attachment,
            .load_op = clear_color ? gpu::LoadOp.CLEAR : gpu::LoadOp.LOAD,
            .store_op = gpu::StoreOp.STORE,
        },
        {
            .view = anchor.attachment,
            .load_op = clear_anchor ? gpu::LoadOp.CLEAR : gpu::LoadOp.LOAD,
            .store_op = gpu::StoreOp.STORE,
        },
    };
    gpu::DepthTargetDesc depth_target = {
        .view = depth.attachment,
        .load_op = clear_depth ? gpu::LoadOp.CLEAR : gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .depth = DEPTH_CLEAR },
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[:color_count],
        .depth = &depth_target,
        .width = color.width,
        .height = color.height,
    };
    gpu::ColorTargetState[2] outputs = { gpu::color_blend_disabled(), gpu::color_blend_disabled() };
    gpu::GraphicsState state = gpu::render_geometry_state(color.width, color.height)!;
    state.viewport = flipped_viewport(color.width, color.height);
    state.color.targets = outputs[:color_count];
    state.depth = { .test_enable = true, .write_enable = capture, .compare = gpu::CompareOp.GREATER };

    gpu::cmd_bind_pipeline(&renderer.commands, draws[0].pipeline)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::PipelineHandle bound = draws[0].pipeline;
    foreach (draw : draws) {
        DrawItem* item = draw.item;
        MaterialCommon* common = &material_data(renderer, item.material).common;
        if (draw.pipeline.index != bound.index) {
            gpu::cmd_bind_pipeline(&renderer.commands, draw.pipeline)!;
            bound = draw.pipeline;
        }

        state.raster.cull_mode = common.double_sided ? gpu::CullMode.NONE : gpu::CullMode.BACK;
        state.raster.front_face = item.front_face;
        state.raster.topology = primitive_topology(item.geometry.topology);
        outputs[0] = blend_target(!capture && common.alpha_mode == AlphaMode.BLEND, common.blend_mode);
        gpu::cmd_set_graphics_state(&renderer.commands, &state)!;

        if (candidate_instanced(item.candidate)) {
            record_batch_draw(
                renderer: renderer,
                root: draw.root,
                geometry: item.geometry,
                range: item.range,
            )!;
        } else {
            record_geometry_draw(renderer, draw.root, item.geometry)!;
        }
    }

    gpu::cmd_end_render_pass(&renderer.commands)!;
    renderer.work_recorded = true;
}

fn void? record_transparency_geometry(
    Renderer* renderer,
    ViewRecord* record,
    FrameRoot frame,
    TransparencyGpu transparency,
    DrawItem[] items,
    Target* color,
    Target* anchor,
    Target* depth,
    bool capture,
    bool clear_depth,
) @private {
    if (!items.len) {
        if (capture && clear_depth) {
            return clear_transparency_geometry(
                renderer: renderer,
                color: color,
                anchor: anchor,
                depth: depth,
            );
        }
        return;
    }

    @pool() {
        TransparencyDraw[] draws = alloc::new_array(tmem, TransparencyDraw, items.len);
        uint shadow_flags = rt_shadow_flags(renderer, record.desc.ray_tracing.shadows);

        foreach (index, &item : items) {
            Material* material = material_data(renderer, item.material);
            draws[index] = {
                .item = item,
                .pipeline = transparency_pipeline_for(
                    renderer: renderer,
                    material: material,
                    vertex: item.vertex,
                    shadow_flags: shadow_flags,
                    capture: capture,
                    color_format: color.format,
                )!,
                .color_count = material.kind == MaterialKind.CUSTOM ? 1 : 2,
            };
        }

        gpu::GpuAddress phase_frame = upload_transparency_frame(
            renderer: renderer,
            frame: frame,
            transparency: transparency,
            source: frame.scene_color,
        )!;
        foreach (&draw : draws) {
            DrawRoot root = *draw.item.draw;
            root.frame = phase_frame;
            draw.root = upload_bytes(renderer, &root, DrawRoot::size)!;
        }

        color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
        anchor.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
        depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;

        usz begin;
        bool first = true;
        bool anchor_cleared = !(capture && clear_depth);
        while (begin < draws.len) {
            uint color_count = draws[begin].color_count;
            usz end = begin + 1;
            while (end < draws.len && draws[end].color_count == color_count) end++;

            TransparencyWork work = TransparencyWork.RETAINED;
            if (capture) {
                work = TransparencyWork.CAPTURE;
            } else if (transparency.phase == shader::TRANSPARENCY_TAIL) {
                work = TransparencyWork.REMAINDER;
            }

            @profile_pass(renderer, transparency_work_pass(work)) {
                record_transparency_run(
                    renderer: renderer,
                    draws: draws[begin:end - begin],
                    color: color,
                    anchor: anchor,
                    depth: depth,
                    capture: capture,
                    clear_color: capture && clear_depth && first,
                    clear_anchor: !anchor_cleared && color_count == 2,
                    clear_depth: capture && clear_depth && first,
                )!;
            }!;

            count_transparency_work(renderer, &record.stats.transparency, work);
            if (color_count == 2) anchor_cleared = true;

            first = false;
            begin = end;
        }

        if (!anchor_cleared) clear_transparency_anchor(renderer, anchor)!;
    };
}
