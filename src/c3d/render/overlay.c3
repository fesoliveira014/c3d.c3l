module c3d::render;

import c3d;
import c3d::asset;
import c3d::shader;
import gpu;
import std::math;

<*
 Borrowed commands and frame storage for one output overlay.
*>
struct OverlayContext {
    Renderer* renderer;
    gpu::CommandList* commands;
    uint width;
    uint height;
    gpu::Format color_format;
}

<*
 Open a color overlay over the composed window, recording requested previews first.
 @param [&inout] self : "Composition finished; no attachment pass is open."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::UNSUPPORTED_FEATURE, gpu::SLOT_TABLE_FULL
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.frame_open, self.has_output, !self.overlay_open
*>
fn OverlayContext? Renderer.begin_overlay(&self) {
    record_previews(self)!;
    self.window_target.transition(&self.commands, COLOR_ATTACHMENT_STATE)!;

    gpu::ColorTargetDesc[1] colors = {{
        .view = self.window_target.attachment,
        .load_op = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    }};

    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .width = self.window_target.width,
        .height = self.window_target.height,
    };

    gpu::cmd_begin_render_pass(&self.commands, &pass)!;
    self.overlay_open = true;
    self.work_recorded = true;

    return {
        .renderer = self,
        .commands = &self.commands,
        .width = self.window_target.width,
        .height = self.window_target.height,
        .color_format = self.window_target.format,
    };
}

<*
 Close the pass and invalidate its overlay borrow.
 @param [&inout] self : "Renderer that opened this overlay."
 @param [&inout] overlay : "Cleared after successful pass closure."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.frame_open, self.overlay_open
 @require overlay.renderer == self, overlay.commands == &self.commands
*>
fn void? Renderer.end_overlay(&self, OverlayContext* overlay) {
    gpu::cmd_end_render_pass(&self.commands)!;
    self.overlay_open = false;

    *overlay = {};
}

<*
 Borrow aligned frame storage that survives until GPU completion.
 @param [&inout] self : "Active overlay borrowing its renderer's current slot."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::UNSUPPORTED_FEATURE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_BUSY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.renderer != null, self.renderer.frame_open, self.renderer.overlay_open
 @require bytes > 0, alignment > 0, alignment <= UPLOAD_RING_ALIGNMENT
 @require (alignment & (alignment - 1)) == 0
*>
fn gpu::MappedGpuSpan? OverlayContext.alloc(&self, usz bytes, usz alignment = 16) {
    Frame* slot = &self.renderer.frames[self.renderer.frame_index % FRAMES_IN_FLIGHT];
    return slot.upload.take(&self.renderer.device, bytes, alignment);
}

<*
 Resolve the list's textures and fonts, ready its render targets and upload its instances.
 Render targets it samples must not be rendered again this frame.
 @param [&inout] self : "Frame open with output; overlay not yet open."
 @param [&inout] list : "Items must stay unchanged until draw_list records them."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::UNSUPPORTED_FEATURE
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.frame_open, self.has_output, !self.overlay_open
*>
fn void? Renderer.prepare_overlay_list(&self, OverlayList* list) {
    check_overlay_refs(self.assets, &self.targets, list)!;
    defer catch abort_frame(self);

    uint target_bits;
    foreach (index, &entry : list.entries[:list.item_count]) {
        OverlayBinding* binding = &list.bindings[index];
        if (entry.kind == GLYPHS) {
            FontRes* font_mirror = resolve_font(self, entry.text.font)!;
            *binding = { .texture = font_mirror.curve_view.index, .bands = font_mirror.band_view.index };
            continue;
        }

        OverlayRect* rect = &entry.rect;
        SamplerId sampler = c3d::same_id(rect.sampler, (SamplerId){}) ? asset::SAMPLER_LINEAR_CLAMP : rect.sampler;
        SamplerRes* sampler_mirror = resolve_sampler(self, sampler)!;
        *binding = { .sampler = sampler_mirror.index };
        if (overlay_ref_solid(rect.texture)) continue;

        switch (rect.texture.kind) {
            case ASSET:
                TextureRes* texture_mirror = resolve_texture(self, rect.texture.asset)!;
                binding.texture = texture_mirror.view.index;
            case RENDER_TARGET:
                target_bits |= 1u << rect.texture.target.index;
                binding.texture = self.targets.get(rect.texture.target).target.view.index;
        }
    }

    record_pending_copies(self, &self.commands)!;
    foreach (index, &record : self.targets.items) {
        if (target_bits & (1u << index)) record.target.transition(&self.commands, self.sampled_state)!;
    }

    list.prepared.run_count = 0;
    if (list.item_count) {
        // A glyph entry emits one item per placement, so entries plus placements bound the emitted items.
        uint capacity = list.item_count + list.glyph_count;
        Frame* slot = &self.frames[self.frame_index % FRAMES_IN_FLIGHT];
        gpu::MappedGpuSpan items = slot.upload.take(&self.device, (usz)capacity * OverlayItemGpu::size)!;
        pack_overlay_items(
            list:        list,
            assets:      self.assets,
            width:       self.window_target.width,
            height:      self.window_target.height,
            destination: ((OverlayItemGpu*)items.bytes.ptr)[:capacity],
        );
        list.prepared.items = items.address;
    }
    list.prepared.frame = self.frame_index + 1;
}

<*
 Record a prepared list over the composed window.
 @param [&inout] self : "Active overlay of the renderer that prepared the list."
 @param [&in] list : "Prepared this frame and unchanged since."
 @return? c3d::SHADER_NOT_FOUND, PIPELINE_REJECTED, gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::RESOURCE_IN_USE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::UNSUPPORTED_FEATURE, gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.renderer.overlay_open, list.prepared.frame == self.renderer.frame_index + 1
*>
fn void? OverlayContext.draw_list(&self, OverlayList* list) {
    if (!list.prepared.run_count) return;

    Renderer* renderer = self.renderer;
    PipelineKey key = {
        .vertex        = { .shader = OVERLAY_VERTEX },
        .fragment      = { .shader = OVERLAY_FRAGMENT },
        .color_formats = { [0] = self.color_format },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, key)!;

    gpu::ColorTargetState[1] colors = { gpu::color_blend_disabled() };
    colors[0].blend = {
        .enable    = true,
        .src_color = gpu::BlendFactor.SRC_ALPHA,
        .dst_color = gpu::BlendFactor.ONE_MINUS_SRC_ALPHA,
        .color_op  = gpu::BlendOp.ADD,
        .src_alpha = gpu::BlendFactor.ONE,
        .dst_alpha = gpu::BlendFactor.ONE_MINUS_SRC_ALPHA,
        .alpha_op  = gpu::BlendOp.ADD,
    };
    gpu::GraphicsState state = fullscreen_state(
        width:         self.width,
        height:        self.height,
        rect:          {},
        color_targets: colors[..],
    )!;
    state.raster = { .topology = gpu::PrimitiveTopology.TRIANGLES, .cull_mode = gpu::CullMode.NONE };
    state.depth = {};
    state.stencil = {};
    Vec2 scale = { 2.0f / self.width, -2.0f / self.height };

    @profile_pass(renderer, Pass.OVERLAY) {
        gpu::cmd_bind_pipeline(self.commands, pipeline)!;
        gpu::cmd_set_graphics_state(self.commands, &state)!;

        foreach (&run : list.runs[:list.prepared.run_count]) {
            gpu::MappedGpuSpan root = self.alloc(OverlayRoot::size)!;
            *(OverlayRoot*)root.bytes.ptr = {
                .items     = (gpu::GpuAddress)((ulong)list.prepared.items + run.first * OverlayItemGpu::size),
                .scale     = scale,
                .translate = { -1, 1 },
            };

            gpu::cmd_set_scissor(self.commands, &run.scissor);
            gpu::cmd_draw(
                commands:       self.commands,
                vertex_root:    root.address,
                fragment_root:  root.address,
                vertex_count:   shader::OVERLAY_QUAD_VERTICES,
                instance_count: run.count,
            )!;
            renderer.stats.draws++;
        }
    }!;
}
