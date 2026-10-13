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
    RenderTargetId target; // zero for the window
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

    begin_overlay_pass(self, &self.window_target)!;
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
 Open a color overlay over a render target, keeping its contents.
 A target nothing has written holds undefined contents.
 @param [&inout] self : "No window output needed; no attachment pass is open."
 @return? c3d::INVALID_ID
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.frame_open, !self.overlay_open
*>
fn OverlayContext? Renderer.begin_overlay_target(&self, RenderTargetId target) {
    Target* image = &self.targets.try_get(target)!.target;
    image.transition(&self.commands, COLOR_ATTACHMENT_STATE)!;

    begin_overlay_pass(self, image)!;
    self.overlay_open = true;
    self.work_recorded = true;

    return {
        .renderer = self,
        .commands = &self.commands,
        .width = image.width,
        .height = image.height,
        .color_format = image.format,
        .target = target,
    };
}

<*
 Close the pass and invalidate its overlay borrow.
 Leaves a render target readable by shaders.
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
    if (!c3d::same_id(overlay.target, (RenderTargetId){})) {
        self.targets.get(overlay.target).target.transition(&self.commands, self.sampled_state)!;
    }

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
 Prepare after every view that renders its output or a target it samples.
 @param [&inout] self : "Frame open; overlay not yet open; window output when target is zero."
 @param [&inout] list : "Items must stay unchanged until draw_list records them."
 @param target : "Render target the list is drawn into; zero for the window."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::UNSUPPORTED_FEATURE
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.frame_open, !self.overlay_open
 @require self.has_output || !c3d::same_id(target, (RenderTargetId){})
*>
fn void? Renderer.prepare_overlay_list(&self, OverlayList* list, RenderTargetId target = {}) {
    check_overlay_refs(self.assets, &self.targets, list, target)!;
    bool window = c3d::same_id(target, (RenderTargetId){});
    if (window && list.backdrop_count && !self.swapchain_info.usage.transfer_src) return c3d::UNSUPPORTED~;

    defer catch abort_frame(self);

    foreach (index, &entry : list.entries[:list.item_count]) {
        OverlayBinding* binding = &list.bindings[index];
        if (entry.kind == TRIANGLE || entry.kind == SEGMENT) continue;
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
                TextureRes* texture_mirror = resolve_texture(self, rect.texture.asset, full_reader: true)!;
                binding.texture = texture_mirror.view.index;
            case RENDER_TARGET:
                binding.texture = self.targets.get(rect.texture.target).target.view.index;
        }
    }

    record_pending_copies(self, &self.commands)!;
    foreach (&entry : list.entries[:list.item_count]) {
        if (entry.kind != RECT || entry.rect.texture.kind != RENDER_TARGET) continue;
        Target* sampled = &self.targets.get(entry.rect.texture.target).target;
        // Read after read needs no barrier: a target a view or an earlier rect already readied keeps its state.
        if (same_texture_state(sampled.state, self.sampled_state)) continue;
        sampled.transition(&self.commands, self.sampled_state)!;
    }

    list.prepared.run_count = 0;
    list.prepared.backdrop_count = 0;
    list.prepared.transformed = false;
    if (list.item_count) {
        Target* output = overlay_output(self, target);
        // A glyph entry emits one item per placement, so entries plus placements bound the emitted items.
        uint capacity = list.item_count + list.glyph_count;
        Frame* slot = &self.frames[self.frame_index % FRAMES_IN_FLIGHT];
        gpu::MappedGpuSpan items = slot.upload.take(&self.device, (usz)capacity * OverlayItemGpu::size)!;
        pack_overlay_items(
            list:        list,
            assets:      self.assets,
            width:       output.width,
            height:      output.height,
            destination: ((OverlayItemGpu*)items.bytes.ptr)[:capacity],
        );
        list.prepared.items = items.address;

        list.prepared.transforms = (gpu::GpuAddress)0;
        if (list.prepared.transformed) {
            usz table_bytes = (usz)list.transform_count * shader::OverlayTransformGpu::size;
            gpu::MappedGpuSpan table = slot.upload.take(&self.device, table_bytes)!;
            mem::copy(table.bytes.ptr, list.transforms.ptr, (sz)table_bytes);
            list.prepared.transforms = table.address;
        }
        if (list.prepared.backdrop_count) prepare_overlay_backdrop(self, output, window)!;
    }
    list.prepared.target = target;
    list.prepared.frame = self.frame_index + 1;
}

<*
 Record a prepared list over the overlay's output.
 A backdrop item ends and reopens the overlay pass.
 @param [&inout] self : "Active overlay of the renderer that prepared the list."
 @param [&in] list : "Prepared this frame for this output and unchanged since."
 @return? c3d::SHADER_NOT_FOUND, PIPELINE_REJECTED, gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::RESOURCE_IN_USE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::UNSUPPORTED_FEATURE, gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.renderer.overlay_open, list.prepared.frame == self.renderer.frame_index + 1
 @require c3d::same_id(list.prepared.target, self.target)
*>
fn void? OverlayContext.draw_list(&self, OverlayList* list) {
    if (!list.prepared.run_count) return;

    Renderer* renderer = self.renderer;
    uint shader_flags = list.prepared.transformed ? shader::SHADER_FLAG_TRANSFORMED : 0;
    PipelineKey key = {
        .vertex        = { .shader = OVERLAY_VERTEX, .flags = shader_flags },
        .fragment      = { .shader = OVERLAY_FRAGMENT, .flags = shader_flags },
        .color_formats = { [0] = self.color_format },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, key)!;
    gpu::PipelineHandle backdrop_pipeline;
    if (list.prepared.backdrop_count) {
        key.fragment.flags |= shader::SHADER_FLAG_BACKDROP;
        backdrop_pipeline = renderer.pipelines.get(&renderer.device, key)!;
    }

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

        uint next_backdrop;
        bool plain_bound = true;
        foreach (run_index, &run : list.runs[:list.prepared.run_count]) {
            bool backdrop = next_backdrop < list.prepared.backdrop_count
                && list.backdrops[next_backdrop].run == run_index;
            if (!backdrop && !plain_bound) {
                gpu::cmd_bind_pipeline(self.commands, pipeline)!;
                gpu::cmd_set_graphics_state(self.commands, &state)!;
                plain_bound = true;
            }

            gpu::MappedGpuSpan root = self.alloc(backdrop ? OverlayBackdropRoot::size : OverlayRoot::size)!;
            *(OverlayRoot*)root.bytes.ptr = {
                .items      = (gpu::GpuAddress)((ulong)list.prepared.items + run.first * OverlayItemGpu::size),
                .transforms = list.prepared.transforms,
                .scale      = scale,
                .translate  = { -1, 1 },
            };

            if (backdrop) {
                record_overlay_backdrop(
                    context:  self,
                    run:      &list.backdrops[next_backdrop],
                    root:     (OverlayBackdropRoot*)root.bytes.ptr,
                    pipeline: backdrop_pipeline,
                    state:    &state,
                )!;
                next_backdrop++;
                plain_bound = false;
            }

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

fn void? begin_overlay_pass(Renderer* renderer, Target* output) @private {
    gpu::ColorTargetDesc[1] colors = {{
        .view = output.attachment,
        .load_op = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    }};

    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .width = output.width,
        .height = output.height,
    };

    return gpu::cmd_begin_render_pass(&renderer.commands, &pass);
}

fn Target* overlay_output(Renderer* renderer, RenderTargetId target) @private {
    return c3d::same_id(target, (RenderTargetId){}) ? &renderer.window_target : &renderer.targets.get(target).target;
}
