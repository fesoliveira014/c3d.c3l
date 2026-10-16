module c3d::render;

import c3d;
import c3d::material;
import c3d::shader;
import gpu;

$assert DepthPyramidRoot::size == 32;

const uint DEPTH_PYRAMID_CAPACITY @private = 16; // a 32768 px edge; one handle per level

struct DepthPyramidLevels @private {
    gpu::TextureView[DEPTH_PYRAMID_CAPACITY] views; // one single-level view per level, level 0 included
    uint                                     count;
}

fn bool depth_pyramid_wanted(ViewDesc* desc) @private {
    return desc.screen_space_gi.enabled && desc.screen_space_gi.trace == SsgiTrace.HIERARCHICAL;
}

fn uint depth_pyramid_level_count(uint width, uint height) @private {
    uint levels = material::texture_mip_count(width, height);
    return levels < DEPTH_PYRAMID_CAPACITY ? levels : DEPTH_PYRAMID_CAPACITY;
}

fn DepthPyramidLevels? create_depth_pyramid_levels(
    gpu::Device* device,
    gpu::TextureHandle texture,
    uint count,
) @private {
    DepthPyramidLevels levels;
    defer catch release_depth_pyramid_levels(device, &levels);
    for (uint level = 0; level < count; level++) {
        gpu::TextureViewDesc view_desc = { .base_mip = level, .mip_count = 1 };
        levels.views[level] = gpu::create_texture_view(device, texture, &view_desc)!;
    }

    levels.count = count;
    return levels;
}

fn void release_depth_pyramid_levels(gpu::Device* device, DepthPyramidLevels* levels) @private {
    foreach (view : levels.views) {
        if (view.is_valid()) (void)gpu::destroy_texture_view(device, view);
    }

    *levels = {};
}

fn void retire_depth_pyramid_levels(RetireList* retire, DepthPyramidLevels* levels) @private {
    foreach (view : levels.views) {
        if (view.is_valid()) retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = view });
    }

    *levels = {};
}

fn void? acquire_depth_pyramid(Renderer* renderer, ViewRecord* record) @private {
    if (!depth_pyramid_wanted(&record.desc) || record.depth_pyramid.texture.is_valid()
        || !record.hdr_color.texture.is_valid()) return;

    uint width = record.hdr_color.width;
    uint height = record.hdr_color.height;
    uint count = depth_pyramid_level_count(width, height);
    record.depth_pyramid = allocate_storage_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     gpu::Format.R32_FLOAT,
        debug_name: "depth_pyramid",
        mip_levels: count,
    )!;
    defer catch release_storage_target(&renderer.device, &record.depth_pyramid);

    record.depth_pyramid_levels = create_depth_pyramid_levels(&renderer.device, record.depth_pyramid.texture, count)!;
}

<*
 @require record.depth_pyramid.texture.is_valid()
*>
fn void? record_depth_pyramid(Renderer* renderer, ViewRecord* record) @private {
    Target* pyramid = &record.depth_pyramid;
    DepthPyramidLevels* levels = &record.depth_pyramid_levels;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];

    record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    pyramid.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;

    @profile_pass(renderer, Pass.DEPTH_PYRAMID) {
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.screen_space_gi_pipelines.depth_pyramid)!;
        gpu::TextureIndex input = record.depth.view.index;
        uint input_width = record.depth.width;
        uint input_height = record.depth.height;
        for (uint level = 0; level < levels.count; level++) {
            uint width = material::texture_mip_extent(pyramid.width, level);
            uint height = material::texture_mip_extent(pyramid.height, level);
            gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, DepthPyramidRoot::size, STREAM_ALIGNMENT)!;
            *(DepthPyramidRoot*)root.bytes.ptr = {
                .input_texture  = input,
                .output_texture = levels.views[level].index,
                .input_width    = input_width,
                .input_height   = input_height,
                .width          = width,
                .height         = height,
            };
            dispatch_extent(
                renderer: renderer,
                root:     root.address,
                width:    width,
                height:   height,
            )!;

            // The next level reads this one; the last stays readable for the consumer.
            transition_levels(
                renderer:    renderer,
                target:      pyramid,
                base_level:  level,
                level_count: 1,
                before:      gpu::storage_at({ .compute }, { .write }),
                after:       gpu::sampled_at({ .compute }),
            )!;

            input = levels.views[level].index;
            input_width = width;
            input_height = height;
        }
    }!;

    pyramid.state = gpu::sampled_at({ .compute });
    renderer.stats.post_dispatches += levels.count;
}
