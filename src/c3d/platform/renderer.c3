module c3d::platform;

import c3d::render;
import gpu::surface::wayland;
import gpu::surface::win32;
import gpu::surface::x11;

<*
 Create a renderer presenting to the window.
 @param [&in] window : "Must outlive the renderer."
 @return? c3d::UNSUPPORTED, gpu::UNSUPPORTED_BACKEND, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::SLOT_TABLE_FULL
 @return? gpu::DESCRIPTOR_HEAP_FULL, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED
 @return? gpu::DEVICE_LOST, gpu::DEVICE_BUSY, gpu::SURFACE_LOST, gpu::BACKEND_ERROR
*>
fn render::Renderer? create_window_renderer(Allocator allocator, Window* window,
  render::RendererDesc desc = {}) {
    desc.surface_fn    = &window_surface;
    desc.surface_user  = window;
    desc.output_width  = window.width;
    desc.output_height = window.height;
    return render::create_renderer(allocator, desc);
}

<*
 Hand the window's pixel size and dormancy to the renderer.
 @param [&inout] window : "Its resize flag is cleared."
 @param [&inout] renderer : "Window output updated for its next frame."
*>
fn void sync_window(Window* window, render::Renderer* renderer) {
    renderer.set_window_output(window.width, window.height, window.minimized);
    window.resized = false;
}

fn gpu::Surface? window_surface(gpu::Runtime* runtime, void* user) @private {
    return create_surface((Window*)user, runtime);
}
