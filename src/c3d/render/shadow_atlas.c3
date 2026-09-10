module c3d::render;

import gpu;

<* Attachment and sampled views of one atlas layer. *>
struct ShadowLayer {
    gpu::AttachmentViewHandle attachment;
    gpu::TextureView view;
}

<* Owned directional depth layers and their shared image state. *>
struct ShadowAtlas {
    Allocator allocator;
    gpu::TextureHandle texture;
    ShadowLayer[] layers;
    uint resolution;
    gpu::SamplerIndex sampler;
    gpu::TextureState state;
}

fn void? transition_shadow_atlas(ShadowAtlas* atlas, gpu::CommandList* commands, gpu::TextureState next) @private {
    gpu::TextureBarrier barrier = gpu::texture_transition(atlas.texture, atlas.state, next)!;
    gpu::cmd_texture_barrier(commands, &barrier)!;
    atlas.state = next;
}

fn ShadowAtlas? create_shadow_atlas(
    Allocator allocator,
    gpu::Device* device,
    uint resolution,
    uint layer_count,
) @private {
    ShadowAtlas atlas = {
        .allocator = allocator,
        .layers = alloc::new_array(allocator, ShadowLayer, layer_count),
        .resolution = resolution,
    };
    defer catch destroy_shadow_atlas(device, &atlas);

    gpu::TextureDesc desc = {
        .width = resolution,
        .height = resolution,
        .mip_levels = 1,
        .array_layers = layer_count,
        .format = gpu::Format.D32_FLOAT,
        .usage = { .depth_attach, .sampled },
        .access = { .graphics },
        .debug_name = "shadow_atlas",
    };
    atlas.texture = gpu::create_texture(device, &desc)!;
    foreach (index, &layer : atlas.layers) {
        gpu::AttachmentViewDesc attachment = { .texture = atlas.texture, .array_layer = (uint)index };
        layer.attachment = gpu::create_attachment_view(device, &attachment)!;
        gpu::TextureViewDesc sampled = { .base_layer = (uint)index, .layer_count = 1, .mip_count = 1 };
        layer.view = gpu::create_texture_view(device, atlas.texture, &sampled)!;
    }
    gpu::SamplerDesc sampler = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
        .compare_enable = true,
        .compare = gpu::CompareOp.GREATER_EQUAL,
        .debug_name = "shadow_compare",
    };
    atlas.sampler = gpu::intern_sampler(device, &sampler)!;
    return atlas;
}

fn void destroy_shadow_atlas(gpu::Device* device, ShadowAtlas* atlas) @private {
    foreach (layer : atlas.layers) {
        if (layer.view.is_valid()) (void)gpu::destroy_texture_view(device, layer.view);
        if (layer.attachment.is_valid()) (void)gpu::destroy_attachment_view(device, layer.attachment);
    }
    if (atlas.texture.is_valid()) (void)gpu::destroy_texture(device, atlas.texture);
    if (atlas.layers.len) alloc::free(atlas.allocator, atlas.layers.ptr);
    *atlas = {};
}
