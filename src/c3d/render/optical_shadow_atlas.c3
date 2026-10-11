module c3d::render;

import gpu;

const uint OPTICAL_SHADOW_IMAGE_COUNT @private = 2 * TRANSMISSION_SHADOW_LAYERS_MAX + 2;

struct OpticalShadowAtlas @private {
    ShadowAtlas[TRANSMISSION_SHADOW_LAYERS_MAX] depths;
    ShadowAtlas[TRANSMISSION_SHADOW_LAYERS_MAX] products;
    ShadowAtlas opaque;
    ShadowAtlas overflow;
    Target accumulation;
    uint capacity;
    usz texel_bytes;
    usz scratch_bytes;
}

struct OpticalShadowStates @private {
    gpu::TextureState[TRANSMISSION_SHADOW_LAYERS_MAX] depths;
    gpu::TextureState[TRANSMISSION_SHADOW_LAYERS_MAX] products;
    gpu::TextureState opaque;
    gpu::TextureState overflow;
    gpu::TextureState accumulation;
}

fn ShadowAtlas*[OPTICAL_SHADOW_IMAGE_COUNT] optical_shadow_images(OpticalShadowAtlas* atlas) @private {
    ShadowAtlas*[OPTICAL_SHADOW_IMAGE_COUNT] images;
    for (uint group = 0; group < TRANSMISSION_SHADOW_LAYERS_MAX; group++) {
        images[2 * group] = &atlas.depths[group];
        images[2 * group + 1] = &atlas.products[group];
    }
    images[2 * TRANSMISSION_SHADOW_LAYERS_MAX] = &atlas.opaque;
    images[2 * TRANSMISSION_SHADOW_LAYERS_MAX + 1] = &atlas.overflow;
    return images;
}

fn ShadowAtlas? create_optical_shadow_image(
    Renderer* renderer,
    gpu::Format format,
    ZString name,
) @private {
    ShadowAtlas image = {
        .allocator = renderer.allocator,
        .layers = alloc::new_array(renderer.allocator, ShadowLayer, renderer.max_shadow_layers),
        .resolution = renderer.shadow_resolution,
    };
    defer catch destroy_shadow_atlas(&renderer.device, &image);

    bool depth = format == gpu::Format.D32_FLOAT;
    gpu::TextureDesc desc = {
        .width = renderer.shadow_resolution,
        .height = renderer.shadow_resolution,
        .mip_levels = 1,
        .array_layers = renderer.max_shadow_layers,
        .format = format,
        .usage = depth ? (gpu::TextureUsage){ .depth_attach, .sampled, .transfer_src }
          : (gpu::TextureUsage){ .color_attach, .sampled, .transfer_src },
        .access = { .graphics },
        .debug_name = name,
    };
    image.texture = gpu::create_texture(&renderer.device, &desc)!;
    foreach (index, &layer : image.layers) {
        gpu::AttachmentViewDesc attachment = { .texture = image.texture, .array_layer = (uint)index };
        layer.attachment = gpu::create_attachment_view(&renderer.device, &attachment)!;
        gpu::TextureViewDesc sampled = { .base_layer = (uint)index, .layer_count = 1, .mip_count = 1 };
        layer.view = gpu::create_texture_view(&renderer.device, image.texture, &sampled)!;
    }

    return image;
}

fn OpticalShadowAtlas? create_optical_shadow_atlas(Renderer* renderer) @private {
    OpticalShadowAtlas atlas = { .capacity = renderer.transmission_shadow_layers };
    defer catch destroy_optical_shadow_atlas(&renderer.device, &atlas);

    usz layer_pixels = (usz)renderer.shadow_resolution * renderer.shadow_resolution;
    usz pixels = layer_pixels * renderer.max_shadow_layers;
    for (uint group = 0; group < atlas.capacity; group++) {
        atlas.depths[group] = create_optical_shadow_image(renderer, gpu::Format.D32_FLOAT, "optical_shadow_depth")!;
        atlas.products[group] = create_optical_shadow_image(renderer, gpu::Format.RGBA16_FLOAT, "optical_shadow_product")!;
        atlas.texel_bytes += pixels * (float::size + 4 * ushort::size);
    }

    atlas.opaque = create_optical_shadow_image(renderer, gpu::Format.D32_FLOAT, "optical_shadow_opaque")!;
    atlas.overflow = create_optical_shadow_image(renderer, gpu::Format.D32_FLOAT, "optical_shadow_overflow")!;
    atlas.texel_bytes += 2 * pixels * float::size;

    atlas.accumulation = allocate_target(
        device: &renderer.device,
        width: renderer.shadow_resolution,
        height: renderer.shadow_resolution,
        format: gpu::Format.RGBA32_FLOAT,
        usage: { .color_attach, .sampled, .transfer_src },
        debug_name: "optical_shadow_accumulation",
    )!;
    atlas.scratch_bytes = layer_pixels * 4 * float::size;
    return atlas;
}

fn void? acquire_optical_shadow_atlas(Renderer* renderer) @private {
    if (renderer.optical_shadow_atlas.opaque.texture.is_valid()) return;

    OpticalShadowAtlas created = create_optical_shadow_atlas(renderer)!;
    renderer.optical_shadow_atlas = created;
}

fn void destroy_optical_shadow_atlas(gpu::Device* device, OpticalShadowAtlas* atlas) @private {
    foreach (image : optical_shadow_images(atlas)) destroy_shadow_atlas(device, image);
    if (atlas.accumulation.texture.is_valid()) release_target(device, &atlas.accumulation);

    *atlas = {};
}

fn void retire_optical_shadow_image(RetireList* retire, ShadowAtlas* image) @private {
    foreach (layer : image.layers) {
        if (layer.view.is_valid()) retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = layer.view });
        if (layer.attachment.is_valid()) {
            retire.push({ .kind = RetiredKind.ATTACHMENT_VIEW, .attachment_view = layer.attachment });
        }
    }

    if (image.texture.is_valid()) retire.push({ .kind = RetiredKind.TEXTURE, .texture = image.texture });
    if (image.layers.len) alloc::free(image.allocator, image.layers.ptr);

    *image = {};
}

fn void retire_optical_shadow_atlas(RetireList* retire, OpticalShadowAtlas* atlas) @private {
    foreach (image : optical_shadow_images(atlas)) retire_optical_shadow_image(retire, image);
    if (atlas.accumulation.texture.is_valid()) {
        if (atlas.accumulation.attachment.is_valid()) {
            retire.push({ .kind = RetiredKind.ATTACHMENT_VIEW, .attachment_view = atlas.accumulation.attachment });
        }
        retire_storage_target(retire, &atlas.accumulation);
    }

    *atlas = {};
}

fn OpticalShadowStates snapshot_optical_shadow_states(OpticalShadowAtlas* atlas) @private {
    OpticalShadowStates states = {
        .opaque = atlas.opaque.state,
        .overflow = atlas.overflow.state,
        .accumulation = atlas.accumulation.state,
    };
    for (uint group = 0; group < atlas.capacity; group++) {
        states.depths[group] = atlas.depths[group].state;
        states.products[group] = atlas.products[group].state;
    }

    return states;
}

fn void restore_optical_shadow_states(OpticalShadowAtlas* atlas, OpticalShadowStates states) @private {
    atlas.opaque.state = states.opaque;
    atlas.overflow.state = states.overflow;
    atlas.accumulation.state = states.accumulation;
    for (uint group = 0; group < atlas.capacity; group++) {
        atlas.depths[group].state = states.depths[group];
        atlas.products[group].state = states.products[group];
    }
}
