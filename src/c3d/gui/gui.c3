module c3d::gui;

import c3d::gui::backend;
import c3d::platform;
import c3d::render;
import imgui;
import std::math;

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

const float DELTA_TIME_MIN @local = 1.0f / 100000; // ImGui rejects a zero frame delta; the first frame has one

<*
 Begin GUI input and update independent capture flags.
 @param [&inout] self : "Window polling has finished for this frame."
 @require self.context != null, !self.frame_open
*>
fn void GuiRenderer.new_frame(&self) {
    imgui::set_current_context(self.context);
    platform::Window* window = self.window;
    float density = window.pixel_density;
    imgui::io_set_display_size((float)window.width / density, (float)window.height / density);
    imgui::io_set_display_framebuffer_scale(density, density);
    imgui::io_set_delta_time(math::max(window.clock.delta, DELTA_TIME_MIN));
    imgui::Io io = imgui::get_io();
    foreach (&event : window.events()) feed_event(io, event, density);
    imgui::new_frame();

    window.input.mouse_captured_by_gui = imgui::io_get_want_capture_mouse();
    window.input.keyboard_captured_by_gui = imgui::io_get_want_capture_keyboard();
    window.set_text_input(imgui::io_get_want_text_input());

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
 @return? CONTEXT_CREATE_FAILED, FONT_BUILD_FAILED
 @require !renderer.frame_open, renderer.swapchain.is_valid()
*>
fn GuiRenderer? create_gui_renderer(Allocator allocator, Renderer* renderer, platform::Window* window) {
    imgui::Context context = imgui::create_context((imgui::FontAtlas)null);
    if (!context) return CONTEXT_CREATE_FAILED~;
    defer catch imgui::destroy_context(context);

    imgui::set_current_context(context);
    imgui::io_set_ini_filename(null);
    imgui::platform_io_set_clipboard_handlers(&clipboard_get, &clipboard_set, null);

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

    expose_builtin_components();
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

    gui.window.set_text_input(false);
    imgui::destroy_context(gui.context);

    *gui = {};
}

fn void feed_event(imgui::Io io, platform::Event* event, float density) @local {
    switch (event.kind) {
        case KEY_DOWN:
        case KEY_UP:
            bool down = event.kind == EventKind.KEY_DOWN;
            imgui::io::add_key_event(io, imgui::KEY_IM_GUI_MOD_CTRL, event.modifiers.ctrl);
            imgui::io::add_key_event(io, imgui::KEY_IM_GUI_MOD_SHIFT, event.modifiers.shift);
            imgui::io::add_key_event(io, imgui::KEY_IM_GUI_MOD_ALT, event.modifiers.alt);
            imgui::io::add_key_event(io, imgui::KEY_IM_GUI_MOD_SUPER, event.modifiers.gui);
            imgui::Key key = imgui_key_of(event.scancode);
            if (key != imgui::KEY_NONE) imgui::io::add_key_event(io, key, down);
        case TEXT_INPUT:
            @pool() {
                imgui::io::add_input_characters_utf8(io, event.text.zstr_tcopy());
            };
        case MOUSE_MOTION:
            imgui::io::add_mouse_pos_event(io, event.position.x / density, event.position.y / density);
        case MOUSE_BUTTON_DOWN:
        case MOUSE_BUTTON_UP:
            imgui::io::add_mouse_pos_event(io, event.position.x / density, event.position.y / density);
            int button;
            if (imgui_button_of(event.button, &button)) {
                imgui::io::add_mouse_button_event(io, button, event.kind == EventKind.MOUSE_BUTTON_DOWN);
            }
        case MOUSE_WHEEL:
            imgui::io::add_mouse_wheel_event(io, event.scroll.x, event.scroll.y);
        case FOCUS_GAINED:
            imgui::io::add_focus_event(io, true);
        case FOCUS_LOST:
            imgui::io::add_focus_event(io, false);
        case RESIZED:
        case QUIT:
            break;
    }
}

fn ZString clipboard_get(imgui::Context context) @local {
    return platform::clipboard_text();
}

fn void clipboard_set(imgui::Context context, ZString text) @local {
    (void)platform::set_clipboard_text(text.str_view());
}
