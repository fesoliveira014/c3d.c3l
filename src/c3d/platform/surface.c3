module c3d::platform;

import c3d;
import gpu::surface::wayland;
import gpu::surface::win32;
import gpu::surface::x11;
import sdl;

<*
 Create a gpu surface from the window's native handles.
 @param [&in] window : "Must outlive the surface."
 @param [&inout] runtime : "Runtime owning the returned surface."
 @return? c3d::UNSUPPORTED, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE
 @return? gpu::INVALID_RESOURCE_STATE, gpu::SLOT_TABLE_FULL, gpu::UNSUPPORTED_FEATURE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_LOST
 @return? gpu::SURFACE_LOST, gpu::BACKEND_ERROR
*>
fn gpu::Surface? create_surface(Window* window, gpu::Runtime* runtime) {
    sdl::PropertiesID properties = sdl::get_window_properties(window.handle);
    String driver = ((ZString)sdl::get_current_video_driver()).str_view();

    switch (driver) {
        case "x11":
            return gpu::surface::x11::create_surface(
                runtime,
                (gpu::surface::x11::DisplayHandle)sdl::get_pointer_property(
                    properties, (char*)sdl::WindowProperties.X11_DISPLAY_POINTER, null),
                (gpu::surface::x11::WindowHandle)sdl::get_number_property(
                    properties, (char*)sdl::WindowProperties.X11_WINDOW_NUMBER, 0),
            );
        case "wayland":
            return gpu::surface::wayland::create_surface(
                runtime,
                (gpu::surface::wayland::DisplayHandle)sdl::get_pointer_property(
                    properties, (char*)sdl::WindowProperties.WAYLAND_DISPLAY_POINTER, null),
                (gpu::surface::wayland::SurfaceHandle)sdl::get_pointer_property(
                    properties, (char*)sdl::WindowProperties.WAYLAND_SURFACE_POINTER, null),
            );
        case "windows":
            return gpu::surface::win32::create_surface(
                runtime,
                (gpu::surface::win32::InstanceHandle)sdl::get_pointer_property(
                    properties, (char*)sdl::WindowProperties.WIN32_INSTANCE_POINTER, null),
                (gpu::surface::win32::WindowHandle)sdl::get_pointer_property(
                    properties, (char*)sdl::WindowProperties.WIN32_HWND_POINTER, null),
            );
        default:
            return c3d::UNSUPPORTED~;
    }
}
