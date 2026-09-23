module c3d::test::views;

import c3d;
import c3d::render;
import c3d::render::post;
import gpu;

fn void test_working_extent_uses_the_whole_output_for_a_zero_viewport() @test {
    uint[<2>] extent = render::working_extent({}, 1280, 720, 1);
    assert(extent.x == 1280 && extent.y == 720);
}

fn void test_working_extent_scales_and_rounds() @test {
    uint[<2>] half = render::working_extent({ .width = 301, .height = 200 }, 1280, 720, 0.5f);
    assert(half.x == 151 && half.y == 100);

    uint[<2>] doubled = render::working_extent({ .width = 300, .height = 200 }, 1280, 720, 2);
    assert(doubled.x == 600 && doubled.y == 400);
}

fn void test_working_extent_floors_at_one_pixel() @test {
    uint[<2>] extent = render::working_extent({ .width = 1, .height = 1 }, 8, 8, 0.1f);
    assert(extent.x == 1 && extent.y == 1);
}

fn void test_viewport_within_accepts_zero_and_edge_rectangles() @test {
    assert(render::viewport_within({}, 1280, 720));
    assert(render::viewport_within({ .width = 1280, .height = 720 }, 1280, 720));
    assert(render::viewport_within({ .x = 640, .y = 360, .width = 640, .height = 360 }, 1280, 720));
    assert(!render::viewport_within({ .x = 1, .width = 1280, .height = 720 }, 1280, 720));
    assert(!render::viewport_within({ .height = 10 }, 1280, 720));
}

fn void test_render_target_formats() @test {
    assert(render::render_target_format_valid(PixelFormat.RGBA8_UNORM));
    assert(render::render_target_format_valid(PixelFormat.RGBA8_SRGB));
    assert(render::render_target_format_valid(PixelFormat.RGBA16_FLOAT));
    assert(render::render_target_format_valid(PixelFormat.RGBA32_FLOAT));
    assert(!render::render_target_format_valid(PixelFormat.BC7_SRGB));
}

fn void test_output_mode_allows_format() @test {
    assert(!render::output_mode_allows_format(OutputMode.LINEAR_HDR, PixelFormat.RGBA8_SRGB));
    assert(render::output_mode_allows_format(OutputMode.LINEAR_HDR, PixelFormat.RGBA16_FLOAT));
    assert(render::output_mode_allows_format(OutputMode.LINEAR_HDR, PixelFormat.RGBA32_FLOAT));
    assert(render::output_mode_allows_format(OutputMode.DISPLAY_LDR, PixelFormat.RGBA8_SRGB));
    assert(render::output_mode_allows_format(OutputMode.DISPLAY_LDR, PixelFormat.RGBA16_FLOAT));
}

fn void test_texture_view_desc_defaults() @test {
    RenderTargetId target = { .index = 3, .generation = 7 };
    ViewDesc desc = render::texture_view_desc(target);
    assert(desc.output == ViewOutput.TEXTURE);
    assert(desc.target.index == 3 && desc.target.generation == 7);
    assert(desc.viewport.width == 0 && desc.viewport.height == 0);
    assert(desc.render_scale == 1);
    assert(desc.color == OutputMode.LINEAR_HDR);
    assert(desc.post.anti_aliasing == AntiAliasing.FXAA);

    ViewDesc window = render::default_view_desc();
    assert(window.output == ViewOutput.WINDOW && window.color == OutputMode.DISPLAY_LDR);
    assert(window.render_scale == 1);
}

fn void test_texture_binding_matches_tracks_the_target() @test {
    render::TextureBinding first = {
        .target = { .index = 2, .generation = 1 },
        .texture_binding_revision = 3,
        .texture_index = (gpu::TextureIndex)9,
        .present = true,
    };
    render::TextureBinding same = first;
    assert(render::texture_binding_matches(first, same));

    render::TextureBinding regenerated = first;
    regenerated.target.generation = 2;
    assert(!render::texture_binding_matches(first, regenerated));

    render::TextureBinding resized = first;
    resized.texture_binding_revision = 4;
    assert(!render::texture_binding_matches(first, resized));
}
