module c3d::render;

import c3d;
import c3d::material;
import c3d::shader;
import gpu;

const gpu::Format WEIGHTED_ACCUM_FORMAT @private = gpu::Format.RGBA16_FLOAT; // 8 B per pixel
const gpu::Format WEIGHTED_REVEALAGE_FORMAT @private = gpu::Format.R16_FLOAT; // 2 B per pixel

fn bool joins_weighted_pass(Material* material, TransparencyMode mode) @private {
    if (mode != TransparencyMode.WEIGHTED) return false;
    MaterialCommon* common = &material.common;
    return material.kind != MaterialKind.CUSTOM
      && common.alpha_mode == AlphaMode.BLEND
      && common.blend_mode == BlendMode.PREMULTIPLIED_ALPHA;
}

fn void? acquire_weighted_targets(Renderer* renderer, ViewRecord* record) @private {
    if (record.weighted_accum.texture.is_valid()) return;

    record.weighted_accum = allocate_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     WEIGHTED_ACCUM_FORMAT,
        usage:      { .color_attach, .sampled },
        debug_name: "weighted_accum",
    )!;
    defer catch release_target(&renderer.device, &record.weighted_accum);
    record.weighted_revealage = allocate_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     WEIGHTED_REVEALAGE_FORMAT,
        usage:      { .color_attach, .sampled },
        debug_name: "weighted_revealage",
    )!;
}

fn PipelineKey weighted_composite_pipeline_key() @private {
    PipelineKey key = composite_pipeline_key(HDR_FORMAT);
    key.fragment = { .shader = WEIGHTED_COMPOSITE };
    return key;
}

fn gpu::ColorTargetState weighted_revealage_blend() @private {
    return {
        .blend = {
            .enable    = true,
            .src_color = gpu::BlendFactor.ZERO,
            .dst_color = gpu::BlendFactor.ONE_MINUS_SRC_COLOR,
            .color_op  = gpu::BlendOp.ADD,
            .src_alpha = gpu::BlendFactor.ZERO,
            .dst_alpha = gpu::BlendFactor.ONE_MINUS_SRC_COLOR,
            .alpha_op  = gpu::BlendOp.ADD,
        },
        .write_mask = { .red = true },
    };
}

fn void? record_weighted_transparency(Renderer* renderer, ViewRecord* record, DrawItem[] items) @private {
    Target* accum = &record.weighted_accum;
    Target* revealage = &record.weighted_revealage;
    accum.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    revealage.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    record.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;

    gpu::ColorTargetDesc[2] colors = {
        {
            .view     = accum.attachment,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0, 0, 0, 0 } },
        },
        {
            .view     = revealage.attachment,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 1, 1, 1, 1 } },
        },
    };
    gpu::DepthTargetDesc depth = {
        .view     = record.depth.attachment,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth  = &depth,
        .width  = record.hdr_color.width,
        .height = record.hdr_color.height,
    };
    gpu::ColorTargetState[2] color_targets = { gpu::additive_blend(), weighted_revealage_blend() };
    gpu::PipelineHandle pipeline = first_pipeline(renderer, items)!;

    @profile_pass(renderer, Pass.FORWARD_TRANSPARENT) {
        // Bound before the pass begins: the backend checks the bound pipeline against the pass formats at begin.
        gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
        gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
        record_draws(
            renderer:   renderer,
            record:     record,
            items:      items,
            pipeline:   pipeline,
            pass_state: {
                .color_targets = color_targets[..],
                .depth_compare = gpu::CompareOp.GREATER,
                .depth_write   = false,
                .fixed_blend   = true,
            },
        )!;
        gpu::cmd_end_render_pass(&renderer.commands)!;
    }!;

    accum.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    revealage.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    record.hdr_color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, WeightedCompositeRoot::size)!;
    *(WeightedCompositeRoot*)root.bytes.ptr = {
        .accum_texture     = accum.view.index,
        .revealage_texture = revealage.view.index,
    };
    gpu::PipelineHandle composite = renderer.pipelines.get(&renderer.device, weighted_composite_pipeline_key())!;
    @profile_pass(renderer, Pass.TRANSPARENT_COMPOSITE) {
        record_fullscreen_pass(
            renderer:      renderer,
            target:        &record.hdr_color,
            pipeline:      composite,
            fragment_root: root.address,
            rect:          {},
            load:          gpu::LoadOp.LOAD,
            color_state:   gpu::premultiplied_alpha_blend(),
        )!;
    }!;
}
