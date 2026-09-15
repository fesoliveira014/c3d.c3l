module c3d::render::post;

import c3d::render @public;
import gpu;

const ZString[BLOOM_MAX_LEVELS] BLOOM_LEVEL_NAMES @private = {
    "bloom_0", "bloom_1", "bloom_2", "bloom_3", "bloom_4", "bloom_5", "bloom_6", "bloom_7",
};

<*
 Allocate the view's grade and FXAA images when absent and a window output exists.
 @param [&inout] renderer : "Sizes the images from hdr_color."
 @param [&inout] record : "Receives post_a and post_b."
 @return? gpu::INVALID_ARGUMENT, gpu::UNSUPPORTED_FEATURE, gpu::SLOT_TABLE_FULL
 @return? gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? ensure_post_targets(Renderer* renderer, ViewRecord* record) {
    if (record.post_a.texture.is_valid() || !renderer.hdr_color.texture.is_valid()) return;

    record.post_a = allocate_post_target(
        device:     &renderer.device,
        width:      renderer.hdr_color.width,
        height:     renderer.hdr_color.height,
        format:     render::HDR_FORMAT,
        debug_name: "post_a",
    )!;
    defer catch release_post_target(&renderer.device, &record.post_a);
    record.post_b = allocate_post_target(
        device:     &renderer.device,
        width:      renderer.hdr_color.width,
        height:     renderer.hdr_color.height,
        format:     render::HDR_FORMAT,
        debug_name: "post_b",
    )!;
}

<*
 Allocate the images of every enabled effect that has none, when a window output exists.
 @param [&inout] renderer : "Sizes the images from hdr_color."
 @param [&inout] record : "Its desc selects the effects."
 @return? gpu::INVALID_ARGUMENT, gpu::UNSUPPORTED_FEATURE, gpu::SLOT_TABLE_FULL
 @return? gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? ensure_effect_targets(Renderer* renderer, ViewRecord* record) {
    if (!renderer.hdr_color.texture.is_valid()) return;
    if (record.desc.post.bloom && !record.bloom_levels) ensure_bloom_chain(renderer, record)!;
}

<*
 Hand the images of every disabled or resized effect to the last submitted frame's retirement.
 @param [&inout] renderer : "No open frame."
 @param [&inout] record : "Retired images are cleared."
*>
fn void retire_effect_targets(Renderer* renderer, ViewRecord* record) {
    bool bloom_stale = record.bloom_levels != record.desc.post.bloom_params.levels;
    if (record.bloom_levels && (!record.desc.post.bloom || bloom_stale)) {
        RetireList* retire = last_submitted_retire(renderer);
        for (uint level = 0; level < record.bloom_levels; level++) retire_post_target(retire, &record.bloom[level]);
        record.bloom_levels = 0;
    }
}

<*
 Destroy every effect image now.
 @param [&inout] device : "Owner of the images."
 @param [&inout] record : "Effect images are cleared."
*>
fn void release_effect_targets(gpu::Device* device, ViewRecord* record) {
    for (uint level = 0; level < record.bloom_levels; level++) release_post_target(device, &record.bloom[level]);
    record.bloom_levels = 0;
}

fn void? ensure_bloom_chain(Renderer* renderer, ViewRecord* record) @private {
    uint levels = record.desc.post.bloom_params.levels;
    defer catch release_effect_targets(&renderer.device, record);
    for (uint level = 0; level < levels; level++) {
        record.bloom[level] = allocate_post_target(
            device:     &renderer.device,
            width:      bloom_level_extent(renderer.hdr_color.width, level),
            height:     bloom_level_extent(renderer.hdr_color.height, level),
            format:     render::HDR_FORMAT,
            debug_name: BLOOM_LEVEL_NAMES[level],
        )!;
        record.bloom_levels = level + 1;
    }
}

fn RetireList* last_submitted_retire(Renderer* renderer) @private {
    return &renderer.frames[(renderer.frame_index + render::FRAMES_IN_FLIGHT - 1) % render::FRAMES_IN_FLIGHT].retire;
}

<*
 Hand the view's images to the last submitted frame's retirement.
 @param [&inout] renderer : "No open frame."
 @param [&inout] record : "post_a and post_b are cleared."
*>
fn void retire_post_targets(Renderer* renderer, ViewRecord* record) {
    if (!record.post_a.texture.is_valid()) return;

    RetireList* retire = last_submitted_retire(renderer);
    retire_post_target(retire, &record.post_a);
    retire_post_target(retire, &record.post_b);
}

<*
 Destroy the view's images now.
 @param [&inout] device : "Owner of the images."
 @param [&inout] record : "post_a and post_b are cleared."
*>
fn void release_post_targets(gpu::Device* device, ViewRecord* record) {
    if (!record.post_a.texture.is_valid()) return;

    release_post_target(device, &record.post_a);
    release_post_target(device, &record.post_b);
}

fn Target? allocate_post_target(
    gpu::Device* device,
    uint width,
    uint height,
    gpu::Format format,
    ZString debug_name,
) @private {
    gpu::TextureDesc texture_desc = {
        .width      = width,
        .height     = height,
        .format     = format,
        .usage      = { .sampled, .storage },
        .access     = { .graphics },
        .debug_name = debug_name,
    };
    gpu::TextureHandle texture = gpu::create_texture(device, &texture_desc)!;
    defer catch (void)gpu::destroy_texture(device, texture);

    gpu::TextureView view = gpu::create_texture_view(device, texture, null)!;
    return {
        .texture = texture,
        .view    = view,
        .format  = format,
        .width   = width,
        .height  = height,
    };
}

fn void retire_post_target(RetireList* retire, Target* target) @private {
    retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = target.view });
    retire.push({ .kind = RetiredKind.TEXTURE, .texture = target.texture });
    *target = {};
}

fn void release_post_target(gpu::Device* device, Target* target) @private {
    (void)gpu::destroy_texture_view(device, target.view);
    (void)gpu::destroy_texture(device, target.texture);
    *target = {};
}
