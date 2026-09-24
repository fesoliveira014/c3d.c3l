module c3d::test::views;

import c3d;
import c3d::render @public;
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

fn void test_view_desc_rejects_rt_shadows_without_ray_queries() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    ViewDesc desc = render::default_view_desc();
    desc.ray_tracing.shadows = true;
    if (catch excuse = render::validate_view_desc(renderer, &desc)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false);
    }
    renderer.caps.ray_queries.enabled = true;
    render::validate_view_desc(renderer, &desc)!!;
}

fn void test_view_desc_rejects_ray_traced_and_invalid_ambient_occlusion() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    ViewDesc desc = render::default_view_desc();

    desc.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
    render::validate_view_desc(renderer, &desc)!!;

    desc.ambient_occlusion.kind = AoKind.RAY_TRACED;
    if (catch excuse = render::validate_view_desc(renderer, &desc)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false);
    }

    desc.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
    desc.ambient_occlusion.radius = 0;
    if (catch excuse = render::validate_view_desc(renderer, &desc)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
}

fn void test_view_targets_list_every_image_once() @test {
    ViewRecord* record = mem::new(ViewRecord);
    defer free(record);
    Target*[render::VIEW_TARGET_COUNT] targets = render::view_targets(record);
    bool raw_listed;
    bool ao_listed;
    foreach (usz index, target : targets) {
        assert(target != null);
        for (usz other = index + 1; other < targets.len; other++) assert(target != targets[other]);
        if (target == &record.ao_raw) raw_listed = true;
        if (target == &record.ao) ao_listed = true;
    }
    assert(raw_listed && ao_listed);
}
