module c3d::render;

import c3d;
import c3d::material;
import gpu;

<*
 Largest number of exact camera transparency depth groups.
*>
const uint TRANSPARENCY_LAYER_CAPACITY_MAX = 16; // At most seventeen depth images and geometry capture passes.

const gpu::Format TRANSPARENCY_COMPOSITION_FORMAT @private
  = gpu::Format.RGBA16_FLOAT; // Half precision bounds K16 memory; four composition images cost 32 bytes per pixel.

// Extra depth plus four color pairs.
const uint TRANSPARENCY_TARGET_COUNT @private = TRANSPARENCY_LAYER_CAPACITY_MAX + 9;

<*
 Four exact depth groups with a sorted remainder.
*>
const TransparencyDesc TRANSPARENCY_LAYERED_DEFAULT = {
    .mode = TransparencyMode.LAYERED,
    .layer_capacity = 4,
}; // Retained depths add sixteen bytes per pixel, plus overflow.

<*
 Camera transparency ordering and composition.
*>
enum TransparencyMode {
    SORTED,
    LAYERED,
}

<*
 Camera transparency quality; SORTED ignores layer_capacity.
*>
struct TransparencyDesc {
    TransparencyMode mode;
    uint layer_capacity;
}

struct TransparencyPyramid @private {
    Target image;
    gpu::TextureView[material::TEXTURE_MIP_CAPACITY] levels;
    uint mip_count;
    usz texel_bytes;
}

struct TransparencyState @private {
    Target[TRANSPARENCY_LAYER_CAPACITY_MAX + 1] depths;
    Target[2] raw_color;
    Target[2] local_color;
    Target[2] continuation_depth;
    TransparencyPyramid[2] raw_pyramid;
    uint layer_capacity;
    usz texel_bytes;
}

fn bool transparency_desc_valid(TransparencyDesc desc) @private {
    if ((uint)desc.mode > (uint)TransparencyMode.LAYERED) return false;

    switch (desc.mode) {
        case SORTED: return true;
        case LAYERED:
            return desc.layer_capacity > 0 && desc.layer_capacity <= TRANSPARENCY_LAYER_CAPACITY_MAX;
    }
}

<*
 @require width > 0, height > 0
 @require layer_capacity > 0, layer_capacity <= TRANSPARENCY_LAYER_CAPACITY_MAX
*>
fn TransparencyState? allocate_transparency_state(
    Renderer* renderer,
    uint width,
    uint height,
    uint layer_capacity,
) @private {
    TransparencyState state = { .layer_capacity = layer_capacity };
    defer catch release_transparency_state(&renderer.device, &state);

    for (uint group = 0; group <= layer_capacity; group++) {
        state.depths[group] = allocate_target(
            device: &renderer.device,
            width: width,
            height: height,
            format: gpu::Format.D32_FLOAT,
            usage: { .depth_attach, .sampled, .transfer_src },
            debug_name: "transparency_group_depth",
        )!;
        state.texel_bytes += (usz)width * height * float::size;
    }

    for (uint side = 0; side < state.raw_color.len; side++) {
        state.raw_color[side] = allocate_transparency_color(
            renderer: renderer,
            width: width,
            height: height,
            format: TRANSPARENCY_COMPOSITION_FORMAT,
            debug_name: "transparency_raw_color",
        )!;
        state.local_color[side] = allocate_transparency_color(
            renderer: renderer,
            width: width,
            height: height,
            format: TRANSPARENCY_COMPOSITION_FORMAT,
            debug_name: "transparency_local_color",
        )!;
        state.continuation_depth[side] = allocate_transparency_color(
            renderer: renderer,
            width: width,
            height: height,
            format: gpu::Format.R32_FLOAT,
            debug_name: "transparency_continuation_depth",
        )!;
        state.texel_bytes += (usz)width * height * (2 * 4 * ushort::size + float::size);

        state.raw_pyramid[side] = allocate_transparency_pyramid(
            renderer: renderer,
            width: width,
            height: height,
            debug_name: "transparency_raw_pyramid",
        )!;
        state.texel_bytes += state.raw_pyramid[side].texel_bytes;
    }

    return state;
}

<*
 @require width > 0, height > 0
*>
fn TransparencyPyramid? allocate_transparency_pyramid(
    Renderer* renderer,
    uint width,
    uint height,
    ZString debug_name,
) @private {
    TransparencyPyramid pyramid = { .mip_count = material::texture_mip_count(width, height) };
    defer catch release_transparency_pyramid(&renderer.device, &pyramid);

    gpu::TextureDesc desc = {
        .width = width,
        .height = height,
        .mip_levels = pyramid.mip_count,
        .format = gpu::Format.RGBA16_FLOAT,
        .usage = { .sampled, .storage, .transfer_src, .transfer_dst },
        .access = { .graphics },
        .debug_name = debug_name,
    };
    pyramid.image = {
        .texture = gpu::create_texture(&renderer.device, &desc)!,
        .format = desc.format,
        .width = width,
        .height = height,
    };
    pyramid.image.view = gpu::create_texture_view(&renderer.device, pyramid.image.texture, null)!;

    for (uint mip = 0; mip < pyramid.mip_count; mip++) {
        gpu::TextureViewDesc view_desc = { .base_mip = mip, .mip_count = 1 };
        pyramid.levels[mip] = gpu::create_texture_view(&renderer.device, pyramid.image.texture, &view_desc)!;

        uint mip_width = material::texture_mip_extent(width, mip);
        uint mip_height = material::texture_mip_extent(height, mip);
        pyramid.texel_bytes += (usz)mip_width * mip_height * 4 * ushort::size;
    }

    return pyramid;
}

fn Target? allocate_transparency_color(
    Renderer* renderer,
    uint width,
    uint height,
    gpu::Format format,
    ZString debug_name,
) @private {
    return allocate_target(
        device: &renderer.device,
        width: width,
        height: height,
        format: format,
        usage: { .color_attach, .sampled, .storage, .transfer_src, .transfer_dst },
        debug_name: debug_name,
    );
}

fn Target*[TRANSPARENCY_TARGET_COUNT] transparency_targets(TransparencyState* state) @private {
    Target*[TRANSPARENCY_TARGET_COUNT] targets;
    foreach (group, &depth : state.depths) targets[group] = depth;

    usz next = state.depths.len;
    foreach (side, &raw : state.raw_color) {
        targets[next++] = raw;
        targets[next++] = &state.local_color[side];
        targets[next++] = &state.continuation_depth[side];
        targets[next++] = &state.raw_pyramid[side].image;
    }

    return targets;
}

fn void release_transparency_pyramid(gpu::Device* device, TransparencyPyramid* pyramid) @private {
    foreach (level : pyramid.levels[:pyramid.mip_count]) {
        if (level.is_valid()) (void)gpu::destroy_texture_view(device, level);
    }

    if (pyramid.image.texture.is_valid()) release_storage_target(device, &pyramid.image);

    *pyramid = {};
}

fn void release_transparency_state(gpu::Device* device, TransparencyState* state) @private {
    foreach (&pyramid : state.raw_pyramid) release_transparency_pyramid(device, pyramid);

    foreach (target : transparency_targets(state)) {
        if (target.texture.is_valid()) release_target(device, target);
    }

    *state = {};
}

fn void retire_transparency_pyramid(RetireList* retire, TransparencyPyramid* pyramid) @private {
    foreach (level : pyramid.levels[:pyramid.mip_count]) {
        if (level.is_valid()) retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = level });
    }

    if (pyramid.image.texture.is_valid()) retire_storage_target(retire, &pyramid.image);

    *pyramid = {};
}

fn void retire_transparency_state(RetireList* retire, TransparencyState* state) @private {
    foreach (&pyramid : state.raw_pyramid) retire_transparency_pyramid(retire, pyramid);

    foreach (target : transparency_targets(state)) {
        if (!target.texture.is_valid()) continue;

        if (target.attachment.is_valid()) {
            retire.push({ .kind = RetiredKind.ATTACHMENT_VIEW, .attachment_view = target.attachment });
        }

        retire_storage_target(retire, target);
    }

    *state = {};
}
