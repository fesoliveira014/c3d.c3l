module c3d::render::post;

import c3d::render @public;
import gpu;

const gpu::Format TILE_FORMAT @private = gpu::Format.RG16_FLOAT;
const gpu::Format VELOCITY_FORMAT @private = gpu::Format.RG16_FLOAT;
const gpu::Format TEMPORAL_VELOCITY_FORMAT @private = gpu::Format.RGBA16_FLOAT; // z carries the expected previous depth
const ZString[BLOOM_MAX_LEVELS] BLOOM_LEVEL_NAMES @private = {
    "bloom_0", "bloom_1", "bloom_2", "bloom_3", "bloom_4", "bloom_5", "bloom_6", "bloom_7",
};

<*
 Allocate the view's grade image when absent and a window output exists.
 @param [&inout] renderer : "Sizes the image from hdr_color."
 @param [&inout] record : "Receives post_a."
 @return? gpu::INVALID_ARGUMENT, gpu::UNSUPPORTED_FEATURE, gpu::SLOT_TABLE_FULL
 @return? gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? acquire_post_targets(Renderer* renderer, ViewRecord* record) {
    if (record.post_a.texture.is_valid() || !record.hdr_color.texture.is_valid()) return;

    record.post_a = render::allocate_storage_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     render::HDR_FORMAT,
        debug_name: "post_a",
    )!;
}

<*
 Allocate the FXAA compute output when the fragment route cannot write the output directly.
 @param [&inout] renderer : "Sizes the image from hdr_color."
 @param [&inout] record : "Receives post_b once."
 @return? gpu::INVALID_ARGUMENT, gpu::UNSUPPORTED_FEATURE, gpu::SLOT_TABLE_FULL
 @return? gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? acquire_fxaa_fallback_target(Renderer* renderer, ViewRecord* record) {
    if (record.post_b.texture.is_valid()) return;

    record.post_b = render::allocate_storage_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
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
fn void? acquire_effect_targets(Renderer* renderer, ViewRecord* record) {
    if (!record.hdr_color.texture.is_valid()) return;
    PostStack* stack = &record.desc.post;
    if (stack.bloom && !record.bloom_levels) acquire_bloom_chain(renderer, record)!;
    if (stack.depth_of_field && !record.dof_near.texture.is_valid()) acquire_dof_layers(renderer, record)!;
    if (uses_tiles(stack) && !record.tile_max.texture.is_valid()) acquire_tiles(renderer, record)!;
    if (uses_velocity(stack) && !record.velocity.texture.is_valid()) acquire_velocity_image(renderer, record)!;
    if (stack.motion_blur && !record.motion_blur_out.texture.is_valid()) acquire_motion_blur_output(renderer, record)!;
    if (stack.anti_aliasing == AntiAliasing.TAA && !record.taa_color[0].texture.is_valid()) {
        acquire_taa_images(renderer, record)!;
    }
    if (taa_debug_enabled(stack) && !record.taa_debug.texture.is_valid()) acquire_taa_debug_image(renderer, record)!;
}

<*
 Hand the images of every disabled or resized effect to the last submitted frame's retirement.
 @param [&inout] renderer : "No open frame."
 @param [&inout] record : "Retired images are cleared."
*>
fn void retire_effect_targets(Renderer* renderer, ViewRecord* record) {
    PostStack* stack = &record.desc.post;
    RetireList* retire = render::last_submitted_retire(renderer);
    bool bloom_stale = record.bloom_levels != stack.bloom_params.levels;
    if (record.bloom_levels && (!stack.bloom || bloom_stale)) {
        for (uint level = 0; level < record.bloom_levels; level++) {
            render::retire_storage_target(retire, &record.bloom[level]);
        }
        record.bloom_levels = 0;
    }
    if (!stack.depth_of_field && record.dof_near.texture.is_valid()) {
        render::retire_storage_target(retire, &record.dof_near);
        render::retire_storage_target(retire, &record.dof_far);
        render::retire_storage_target(retire, &record.dof_near_blur);
        render::retire_storage_target(retire, &record.dof_far_blur);
    }
    if (!uses_tiles(stack) && record.tile_max.texture.is_valid()) {
        render::retire_storage_target(retire, &record.tile_max);
        render::retire_storage_target(retire, &record.tile_neighbor);
    }
    bool velocity_stale = !uses_velocity(stack) || record.velocity.format != velocity_format(stack);
    if (record.velocity.texture.is_valid() && velocity_stale) {
        retire.push({ .kind = RetiredKind.ATTACHMENT_VIEW, .attachment_view = record.velocity.attachment });
        render::retire_storage_target(retire, &record.velocity);
    }
    if (!stack.motion_blur && record.motion_blur_out.texture.is_valid()) {
        render::retire_storage_target(retire, &record.motion_blur_out);
    }
    if (stack.anti_aliasing != AntiAliasing.TAA && record.taa_color[0].texture.is_valid()) {
        foreach (&image : record.taa_color) render::retire_storage_target(retire, image);
        foreach (&image : record.taa_depth) render::retire_storage_target(retire, image);
        foreach (&image : record.taa_velocity) render::retire_storage_target(retire, image);
    }
    if (!taa_debug_enabled(stack) && record.taa_debug.texture.is_valid()) {
        render::retire_storage_target(retire, &record.taa_debug);
    }
}

<*
 Destroy every effect image now.
 @param [&inout] device : "Owner of the images."
 @param [&inout] record : "Effect images are cleared."
*>
fn void release_effect_targets(gpu::Device* device, ViewRecord* record) {
    for (uint level = 0; level < record.bloom_levels; level++) {
        render::release_storage_target(device, &record.bloom[level]);
    }
    record.bloom_levels = 0;
    release_dof_layers(device, record);
    release_tiles(device, record);
    release_motion_blur_images(device, record);
    release_taa_images(device, record);
}

fn bool uses_tiles(PostStack* stack) @private {
    return stack.depth_of_field || stack.motion_blur;
}

fn bool uses_velocity(PostStack* stack) @private {
    return stack.motion_blur || stack.anti_aliasing == AntiAliasing.TAA;
}

fn gpu::Format velocity_format(PostStack* stack) @private {
    return stack.anti_aliasing == AntiAliasing.TAA ? TEMPORAL_VELOCITY_FORMAT : VELOCITY_FORMAT;
}

fn void? acquire_velocity_image(Renderer* renderer, ViewRecord* record) @private {
    record.velocity = render::allocate_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     velocity_format(&record.desc.post),
        usage:      { .color_attach, .sampled, .storage },
        debug_name: "velocity",
    )!;
}

fn void? acquire_motion_blur_output(Renderer* renderer, ViewRecord* record) @private {
    record.motion_blur_out = render::allocate_storage_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     render::HDR_FORMAT,
        debug_name: "motion_blur_out",
    )!;
}

fn void release_motion_blur_images(gpu::Device* device, ViewRecord* record) @private {
    if (record.velocity.texture.is_valid()) render::release_target(device, &record.velocity);
    if (record.motion_blur_out.texture.is_valid()) render::release_storage_target(device, &record.motion_blur_out);
}

fn void? acquire_dof_layers(Renderer* renderer, ViewRecord* record) @private {
    uint width = bloom_level_extent(record.hdr_color.width, 0);
    uint height = bloom_level_extent(record.hdr_color.height, 0);
    Target*[4] layers = { &record.dof_near, &record.dof_far, &record.dof_near_blur, &record.dof_far_blur };
    ZString[4] names = { "dof_near", "dof_far", "dof_near_blur", "dof_far_blur" };
    defer catch release_dof_layers(&renderer.device, record);
    foreach (index, layer : layers) {
        *layer = render::allocate_storage_target(
            device:     &renderer.device,
            width:      width,
            height:     height,
            format:     render::HDR_FORMAT,
            debug_name: names[index],
        )!;
    }
}

fn void? acquire_tiles(Renderer* renderer, ViewRecord* record) @private {
    uint width = tile_count(record.hdr_color.width);
    uint height = tile_count(record.hdr_color.height);
    defer catch release_tiles(&renderer.device, record);
    record.tile_max = render::allocate_storage_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     TILE_FORMAT,
        debug_name: "tile_max",
    )!;
    record.tile_neighbor = render::allocate_storage_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     TILE_FORMAT,
        debug_name: "tile_neighbor",
    )!;
}

fn void release_dof_layers(gpu::Device* device, ViewRecord* record) @private {
    Target*[4] layers = { &record.dof_near, &record.dof_far, &record.dof_near_blur, &record.dof_far_blur };
    foreach (layer : layers) {
        if (layer.texture.is_valid()) render::release_storage_target(device, layer);
    }
}

fn void release_tiles(gpu::Device* device, ViewRecord* record) @private {
    if (record.tile_max.texture.is_valid()) render::release_storage_target(device, &record.tile_max);
    if (record.tile_neighbor.texture.is_valid()) render::release_storage_target(device, &record.tile_neighbor);
}

fn void? acquire_bloom_chain(Renderer* renderer, ViewRecord* record) @private {
    uint levels = record.desc.post.bloom_params.levels;
    defer catch release_effect_targets(&renderer.device, record);
    for (uint level = 0; level < levels; level++) {
        record.bloom[level] = render::allocate_storage_target(
            device:     &renderer.device,
            width:      bloom_level_extent(record.hdr_color.width, level),
            height:     bloom_level_extent(record.hdr_color.height, level),
            format:     render::HDR_FORMAT,
            debug_name: BLOOM_LEVEL_NAMES[level],
        )!;
        record.bloom_levels = level + 1;
    }
}

<*
 Hand the view's images to the last submitted frame's retirement.
 @param [&inout] renderer : "No open frame."
 @param [&inout] record : "post_a and post_b are cleared."
*>
fn void retire_post_targets(Renderer* renderer, ViewRecord* record) {
    if (!record.post_a.texture.is_valid()) return;

    RetireList* retire = render::last_submitted_retire(renderer);
    render::retire_storage_target(retire, &record.post_a);
    if (record.post_b.texture.is_valid()) render::retire_storage_target(retire, &record.post_b);
}

<*
 Destroy the view's images now.
 @param [&inout] device : "Owner of the images."
 @param [&inout] record : "post_a and post_b are cleared."
*>
fn void release_post_targets(gpu::Device* device, ViewRecord* record) {
    if (!record.post_a.texture.is_valid()) return;

    render::release_storage_target(device, &record.post_a);
    if (record.post_b.texture.is_valid()) render::release_storage_target(device, &record.post_b);
}
