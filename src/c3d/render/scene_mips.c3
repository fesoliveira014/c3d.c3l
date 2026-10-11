module c3d::render;

import c3d;
import c3d::material;
import c3d::shader;
import gpu;

const uint SCENE_MIP_CAPACITY @private = 16; // a 32768 px edge; 512 B of view handles per view

struct SceneMips @private {
    gpu::AttachmentViewHandle[SCENE_MIP_CAPACITY] attachments; // [0] stays empty: scene_color.attachment draws mip 0
    gpu::TextureView[SCENE_MIP_CAPACITY]          views;       // one single-level view per mip, mip 0 included
    uint                                          levels;
}

fn uint scene_mip_levels(uint width, uint height) @private {
    uint levels = material::texture_mip_count(width, height);
    return levels < SCENE_MIP_CAPACITY ? levels : SCENE_MIP_CAPACITY;
}

fn SceneMips? create_scene_mips(gpu::Device* device, gpu::TextureHandle texture, uint levels) @private {
    SceneMips mips;
    defer catch release_scene_mips(device, &mips);
    for (uint level = 0; level < levels; level++) {
        if (level > 0) {
            gpu::AttachmentViewDesc attachment_desc = { .texture = texture, .mip_level = level };
            mips.attachments[level] = gpu::create_attachment_view(device, &attachment_desc)!;
        }
        gpu::TextureViewDesc view_desc = { .base_mip = level, .mip_count = 1 };
        mips.views[level] = gpu::create_texture_view(device, texture, &view_desc)!;
    }
    mips.levels = levels;
    return mips;
}

fn void release_scene_mips(gpu::Device* device, SceneMips* mips) @private {
    foreach (attachment : mips.attachments) {
        if (attachment.is_valid()) (void)gpu::destroy_attachment_view(device, attachment);
    }
    foreach (view : mips.views) {
        if (view.is_valid()) (void)gpu::destroy_texture_view(device, view);
    }
    *mips = {};
}

fn void retire_scene_mips(RetireList* retire, SceneMips* mips) @private {
    foreach (attachment : mips.attachments) {
        if (attachment.is_valid()) retire.push({ .kind = RetiredKind.ATTACHMENT_VIEW, .attachment_view = attachment });
    }
    foreach (view : mips.views) {
        if (view.is_valid()) retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = view });
    }
    *mips = {};
}

fn void? transition_scene_levels(
    Renderer* renderer,
    Target* color,
    uint base_level,
    uint level_count,
    gpu::TextureState before,
    gpu::TextureState after,
) @private {
    gpu::TextureBarrier barrier = gpu::texture_view_transition(
        texture: color.texture,
        view:    { .base_mip = base_level, .mip_count = level_count },
        before:  before,
        after:   after,
    )!;
    gpu::cmd_texture_barrier(&renderer.commands, &barrier)!;
}

fn void? record_scene_mips(Renderer* renderer, ViewRecord* record) @private {
    SceneMips* mips = &record.scene_mips;
    Target* color = &record.scene_color;
    if (mips.levels < 2) return;

    @profile_pass(renderer, Pass.SCENE_MIPS) {
        gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, composite_pipeline_key(color.format))!;
        Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];

        // Each level returns to color.state as soon as it is written, so the full-chain view is never read
        // while a level sits in another layout.
        transition_scene_levels(
            renderer:    renderer,
            color:       color,
            base_level:  1,
            level_count: 0,
            before:      color.state,
            after:       COLOR_ATTACHMENT_STATE,
        )!;
        for (uint level = 1; level < mips.levels; level++) {
            gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, CompositeRoot::size)!;
            *(CompositeRoot*)root.bytes.ptr = {
                .source_texture = mips.views[level - 1].index,
                .source_sampler = renderer.linear_clamp_sampler,
            };

            Target level_target = {
                .texture    = color.texture,
                .attachment = mips.attachments[level],
                .format     = color.format,
                .width      = material::texture_mip_extent(color.width, level),
                .height     = material::texture_mip_extent(color.height, level),
            };
            record_fullscreen_pass(
                renderer:      renderer,
                target:        &level_target,
                pipeline:      pipeline,
                fragment_root: root.address,
                rect:          {},
                load:          gpu::LoadOp.DONT_CARE,
            )!;

            transition_scene_levels(
                renderer:    renderer,
                color:       color,
                base_level:  level,
                level_count: 1,
                before:      COLOR_ATTACHMENT_STATE,
                after:       color.state,
            )!;
        }
    }!;
}
