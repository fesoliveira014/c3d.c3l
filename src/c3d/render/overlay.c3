module c3d::render;

import gpu;

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
 Open a color overlay over the composed window.
 @param [&inout] self : "Composition finished; no attachment pass is open."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.frame_open, self.has_output, !self.overlay_open
*>
fn OverlayContext? Renderer.begin_overlay(&self) {
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
