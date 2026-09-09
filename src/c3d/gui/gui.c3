module c3d::gui;

import c3d::gui::backend;
import c3d::platform;
import c3d::render;
import imgui;
import imgui::backend::sdl;

<*
 Owned GUI context and backend borrowing a renderer and window.
*>
struct GuiRenderer {
    Allocator allocator;
    Renderer* renderer;
    platform::Window* window;
    imgui::Context context;
    GuiBackend backend;
    bool frame_open;
    bool draw_ready;
}

<*
 Forward a borrowed SDL event to this GUI context.
 @param [&inout] self : "Live adapter before its next GUI frame."
 @param [&in] event : "Unmodified SDL3 event, borrowed for this call."
 @require self.context != null, !self.frame_open
*>
fn void GuiRenderer.process_event(&self, void* event) {
    imgui::set_current_context(self.context);
    (void)imgui::backend::sdl::process_event((imgui::backend::sdl::EventRef)event);
}

<*
 Begin GUI input and update independent capture flags.
 @param [&inout] self : "Window polling has finished for this frame."
 @require self.context != null, !self.frame_open
*>
fn void GuiRenderer.new_frame(&self) {
    imgui::set_current_context(self.context);
    imgui::backend::sdl::new_frame();
    imgui::new_frame();

    self.window.input.mouse_captured_by_gui = imgui::io_get_want_capture_mouse();
    self.window.input.keyboard_captured_by_gui = imgui::io_get_want_capture_keyboard();

    self.frame_open = true;
    self.draw_ready = false;
}

<*
 Finalize GUI drawing, including frames without a drawable window.
 @param [&inout] self : "Every begun panel has ended."
 @require self.frame_open
*>
fn void GuiRenderer.finish_frame(&self) {
    imgui::set_current_context(self.context);
    imgui::render();

    self.frame_open = false;
    self.draw_ready = true;
}

<*
 Record finalized GUI draws into the borrowed overlay.
 @param [&inout] self : "Draw data remains valid until the next new_frame."
 @param [&inout] overlay : "Active borrow from this adapter's renderer."
 @return? c3d::gui::backend::record_gui!
 @require !self.frame_open, self.draw_ready
 @require overlay.renderer == self.renderer, self.renderer.overlay_open
*>
fn void? GuiRenderer.record(&self, OverlayContext* overlay) {
    imgui::set_current_context(self.context);
    return c3d::gui::backend::record_gui(&self.backend, imgui::get_draw_data(), overlay);
}

<*
 Create a GUI adapter with an uploaded fixed font.
 @param [&inout] renderer : "Stable borrow; configured window output, no open frame."
 @param [&inout] window : "Stable borrow; outlives the adapter and renderer."
 @return? c3d::gui::backend::create_gui_backend!
 @return? CONTEXT_CREATE_FAILED, PLATFORM_INIT_FAILED, FONT_BUILD_FAILED
 @require !renderer.frame_open, renderer.swapchain.is_valid()
*>
fn GuiRenderer? create_gui_renderer(Allocator allocator, Renderer* renderer, platform::Window* window) {
    imgui::Context context = imgui::create_context((imgui::FontAtlas)null);
    if (!context) return CONTEXT_CREATE_FAILED~;
    defer catch imgui::destroy_context(context);

    imgui::set_current_context(context);
    imgui::io_set_ini_filename(null);

    if (!imgui::backend::sdl::init_for_other((imgui::backend::sdl::WindowHandle)window.handle)) return PLATFORM_INIT_FAILED~;
    defer catch imgui::backend::sdl::shutdown();

    imgui::FontAtlas fonts = imgui::io_get_fonts();
    if (!imgui::fonts_build(fonts)) return FONT_BUILD_FAILED~;

    char* pixels;
    int width;
    int height;
    int channels;
    imgui::font_atlas::get_tex_data_as_rgba32(
        self_: fonts,
        out_pixels: &pixels,
        out_width: &width,
        out_height: &height,
        out_bytes_per_pixel: &channels,
    );

    usz byte_count = (usz)width * (usz)height * (usz)channels;
    GuiBackend backend = c3d::gui::backend::create_gui_backend(
        allocator: allocator,
        renderer: renderer,
        rgba_pixels: pixels[:byte_count],
        width: (uint)width,
        height: (uint)height,
    )!;

    return {
        .allocator = allocator,
        .renderer = renderer,
        .window = window,
        .context = context,
        .backend = backend,
    };
}

<*
 Release the GUI after its submitted use completes.
 @param [&inout] gui : "Cleared on success; owned by caller on wait failure."
 @return? c3d::gui::backend::destroy_gui_backend!
 @require gui.context != null, !gui.frame_open, !gui.renderer.frame_open
*>
fn void? destroy_gui_renderer(GuiRenderer* gui) {
    imgui::set_current_context(gui.context);
    c3d::gui::backend::destroy_gui_backend(&gui.backend)!;

    imgui::backend::sdl::shutdown();
    imgui::destroy_context(gui.context);

    *gui = {};
}
