module c3d::render;

import c3d::material;
import c3d::shader;
import gpu;
import std::math;

const gpu::Format COLORED_TRANSMITTANCE_FORMAT @private = gpu::Format.RGBA8_UNORM;

<* Attachment and sampled views of one layer of the colored shadow images. *>
struct ColoredShadowLayer {
    gpu::AttachmentViewHandle transmittance_attachment;
    gpu::AttachmentViewHandle depth_attachment;
    gpu::TextureView transmittance_view;
    gpu::TextureView depth_view;
}

<* Image state the last recorded barrier left each colored shadow image in. *>
struct ColoredShadowStates {
    gpu::TextureState transmittance;
    gpu::TextureState depth;
}

<* Atlas-shaped images holding the tint and the depth of translucent casters. *>
struct ColoredShadows {
    gpu::TextureHandle transmittance;
    gpu::TextureHandle depth;
    ColoredShadowLayer[] layers;
    ColoredShadowStates states;
}

<* Choose whether translucent casters tint shadows; applies from the next frame. *>
fn void Renderer.set_colored_shadows(&self, bool enabled) {
    self.colored_shadows = enabled;
}

fn bool casts_translucent_shadow(Material* material) @private {
    if (material.kind == MaterialKind.PHYSICAL && material.physical.transmission > 0) return true;

    return material.common.alpha_mode == AlphaMode.BLEND && material.common.blend_mode == BlendMode.PREMULTIPLIED_ALPHA;
}

fn void? acquire_colored_shadows(Renderer* renderer) @private {
    ShadowAtlas* atlas = &renderer.shadow_atlas;
    if (atlas.colored.transmittance.is_valid()) return;

    defer catch destroy_colored_shadows(&renderer.device, atlas);
    ColoredShadows* colored = &atlas.colored;
    colored.layers = alloc::new_array(atlas.allocator, ColoredShadowLayer, atlas.layers.len);
    gpu::TextureDesc transmittance = {
        .width = atlas.resolution,
        .height = atlas.resolution,
        .mip_levels = 1,
        .array_layers = (uint)atlas.layers.len,
        .format = COLORED_TRANSMITTANCE_FORMAT,
        .usage = { .color_attach, .sampled },
        .access = { .graphics },
        .debug_name = "shadow_transmittance",
    };
    colored.transmittance = gpu::create_texture(&renderer.device, &transmittance)!;
    gpu::TextureDesc depth = {
        .width = atlas.resolution,
        .height = atlas.resolution,
        .mip_levels = 1,
        .array_layers = (uint)atlas.layers.len,
        .format = gpu::Format.D32_FLOAT,
        .usage = { .depth_attach, .sampled },
        .access = { .graphics },
        .debug_name = "shadow_translucent_depth",
    };
    colored.depth = gpu::create_texture(&renderer.device, &depth)!;
    foreach (index, &layer : colored.layers) {
        gpu::AttachmentViewDesc tint_attachment = { .texture = colored.transmittance, .array_layer = (uint)index };
        layer.transmittance_attachment = gpu::create_attachment_view(&renderer.device, &tint_attachment)!;
        gpu::AttachmentViewDesc depth_attachment = { .texture = colored.depth, .array_layer = (uint)index };
        layer.depth_attachment = gpu::create_attachment_view(&renderer.device, &depth_attachment)!;
        gpu::TextureViewDesc sampled = { .base_layer = (uint)index, .layer_count = 1, .mip_count = 1 };
        layer.transmittance_view = gpu::create_texture_view(&renderer.device, colored.transmittance, &sampled)!;
        layer.depth_view = gpu::create_texture_view(&renderer.device, colored.depth, &sampled)!;
    }
}

fn void destroy_colored_shadows(gpu::Device* device, ShadowAtlas* atlas) @private {
    ColoredShadows* colored = &atlas.colored;
    foreach (layer : colored.layers) {
        if (layer.transmittance_view.is_valid()) (void)gpu::destroy_texture_view(device, layer.transmittance_view);
        if (layer.depth_view.is_valid()) (void)gpu::destroy_texture_view(device, layer.depth_view);
        if (layer.transmittance_attachment.is_valid()) {
            (void)gpu::destroy_attachment_view(device, layer.transmittance_attachment);
        }
        if (layer.depth_attachment.is_valid()) (void)gpu::destroy_attachment_view(device, layer.depth_attachment);
    }
    if (colored.transmittance.is_valid()) (void)gpu::destroy_texture(device, colored.transmittance);
    if (colored.depth.is_valid()) (void)gpu::destroy_texture(device, colored.depth);
    if (colored.layers.len) alloc::free(atlas.allocator, colored.layers.ptr);
    *colored = {};
}

fn void? transition_colored_shadows(ColoredShadows* colored, gpu::CommandList* commands, bool attachment) @private {
    ColoredShadowStates next = {
        .transmittance = attachment ? COLOR_ATTACHMENT_STATE : FRAGMENT_READ_STATE,
        .depth         = attachment ? DEPTH_ATTACHMENT_STATE : FRAGMENT_READ_STATE,
    };
    gpu::TextureBarrier tint = gpu::texture_transition(
        colored.transmittance,
        colored.states.transmittance,
        next.transmittance,
    )!;
    gpu::cmd_texture_barrier(commands, &tint)!;
    gpu::TextureBarrier depth = gpu::texture_transition(colored.depth, colored.states.depth, next.depth)!;
    gpu::cmd_texture_barrier(commands, &depth)!;
    colored.states = next;
}

fn gpu::ColorTargetState shadow_transmittance_blend() @private {
    return {
        .blend = {
            .enable    = true,
            .src_color = gpu::BlendFactor.ZERO,
            .dst_color = gpu::BlendFactor.SRC_COLOR,
            .color_op  = gpu::BlendOp.ADD,
            .src_alpha = gpu::BlendFactor.ZERO,
            .dst_alpha = gpu::BlendFactor.ONE,
            .alpha_op  = gpu::BlendOp.ADD,
        },
        .write_mask = { .red = true, .green = true, .blue = true },
    };
}

<*
 @require material.kind != MaterialKind.CUSTOM
*>
fn void write_translucent_caster_block(
    TranslucentCasterGpu* root,
    Material* material,
    TextureBinding binding,
) @private {
    TextureSlot slot;
    Vec4 color;
    PhysicalParams* physical;
    switch (material.kind) {
        case BASIC:
            slot = material.basic.map;
            color = material.basic.color;
        case STANDARD:
            slot = material.standard.base_color_map;
            color = material.standard.base_color;
        case PHYSICAL:
            physical = &material.physical;
            slot = physical.standard.base_color_map;
            color = physical.standard.base_color;
        case TOON:
            slot = material.toon.map;
            color = material.toon.color;
        case CUSTOM: unreachable();
    }
    MaterialFlags flags = {
        .alpha_mask   = material.common.alpha_mode == AlphaMode.MASK,
        .alpha_blend  = material.common.alpha_mode == AlphaMode.BLEND,
        .double_sided = material.common.double_sided,
    };
    *root = {
        .kind = (uint)material.kind.ordinal,
        .flags = (uint)flags,
        .alpha_cutoff = material.common.alpha_cutoff,
        .map_flags = texture_map_flags(slot, binding, shader::MATERIAL_MAP_BASE_COLOR),
        .color = color,
        .map = pack_texture_map(slot, binding),
    };
    if (!physical || physical.transmission <= 0) return;

    root.transmission = physical.transmission;
    root.thickness = physical.thickness;
    root.attenuation_color_distance = {
        physical.attenuation_color.r,
        physical.attenuation_color.g,
        physical.attenuation_color.b,
        physical.attenuation_distance,
    };
}

fn void? record_colored_layer(
    Renderer* renderer,
    ShadowDraw[] draws,
    CullRange[] ranges,
    uint layer,
    gpu::GpuAddress frame,
    bool view_reflected,
    float bias,
) @private {
    uint resolution = renderer.shadow_atlas.resolution;
    ColoredShadowLayer* images = &renderer.shadow_atlas.colored.layers[layer];

    gpu::DepthTargetDesc depth = {
        .view = images.depth_attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .depth = 0 },
    };
    gpu::RenderPassDesc depth_pass = { .depth = &depth, .width = resolution, .height = resolution };
    gpu::GraphicsState depth_state = shadow_layer_state(resolution, bias)!;
    gpu::cmd_bind_pipeline(&renderer.commands, draws[0].pipeline)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &depth_pass)!;
    record_depth_draws(
        renderer:       renderer,
        draws:          draws,
        ranges:         ranges,
        frame:          frame,
        view_reflected: view_reflected,
        state:          &depth_state,
        first:          draws[0].pipeline,
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;

    gpu::ColorTargetDesc[1] colors = {
        {
            .view = images.transmittance_attachment,
            .load_op = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear = { .rgba = { 1, 1, 1, 1 } },
        },
    };
    gpu::RenderPassDesc tint_pass = { .colors = colors[..], .width = resolution, .height = resolution };
    gpu::ColorTargetState[1] blend = { shadow_transmittance_blend() };
    gpu::GraphicsState tint_state = shadow_layer_state(resolution, 0)!;
    tint_state.depth = {};
    tint_state.color.targets = blend[..];
    gpu::cmd_bind_pipeline(&renderer.commands, draws[0].tint_pipeline)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &tint_pass)!;
    record_depth_draws(
        renderer:       renderer,
        draws:          draws,
        ranges:         ranges,
        frame:          frame,
        view_reflected: view_reflected,
        state:          &tint_state,
        first:          draws[0].tint_pipeline,
        tint:           true,
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
}
