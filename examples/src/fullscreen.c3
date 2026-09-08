module fullscreen_example;

import c3d;
import c3d::asset;
import c3d::platform;
import c3d::render;
import c3d::shader;
import sdl;
import std::io;

fn int main() {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d fullscreen", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_fullscreen" },
    )!!;
    defer render::destroy_renderer(&renderer);

    RenderTargetId hdr = render::create_render_target(&renderer,
      { .width = window.width, .height = window.height })!!;
    defer (void)render::destroy_render_target(&renderer, hdr);

    while (window.poll()) {
        if (window.input.keys_released[(usz)sdl::Scancode.ESCAPE]) break;
        if (window.resized && window.width && window.height) {
            render::resize_render_target(&renderer, hdr, window.width, window.height)!!;
        }
        platform::sync_window(&window, &renderer);

        renderer.begin_frame({ .time = window.clock.total, .delta = window.clock.delta })!!;
        renderer.draw_fullscreen(hdr, { .shader = GRADIENT })!!;
        renderer.composite(hdr)!!;
        renderer.end_frame()!!;
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
