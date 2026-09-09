module c3d::test::image;

import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::material;
import c3d::render;
import std::io::path;

fn String fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures", name)!!;
}

fn AssetStore create_image_store(Allocator allocator, uint max_textures = 8) @local {
    return asset::create_asset_store(allocator, {
        .max_geometries = 1,
        .max_textures = max_textures,
        .max_materials = 1,
        .max_samplers = 5,
    });
}

fn void test_decode_rgba_preserves_rows_and_alpha() @test {
    char[] encoded = $embed("../fixtures/rgba.png");
    image::Image decoded = image::decode_image(mem, encoded)!!;
    defer image::destroy_image(&decoded);

    assert(decoded.width == 2 && decoded.height == 2 && decoded.format == RGBA8_UNORM);
    char[16] expected = { 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 64, 255, 255, 255, 0 };
    assert(decoded.pixels == expected[..]);
}

fn void test_decode_hdr_retains_float_range() @test {
    image::Image decoded = image::decode_image(mem, $embed("../fixtures/radiance.hdr"))!!;
    defer image::destroy_image(&decoded);

    assert(decoded.width == 2 && decoded.height == 1 && decoded.format == RGBA32_FLOAT);
    float[] pixels = ((float*)decoded.pixels.ptr)[:decoded.pixels.len / float::size];
    float[8] expected = { 2, 1, 0.5f, 1, 0.25f, 0.5f, 1, 1 };
    assert(pixels == expected[..]);
}

fn void test_decode_reports_specific_faults() @test {
    if (catch excuse = image::decode_image(mem, (char[]){})) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Invalid input was accepted");
    }

    if (catch excuse = image::decode_image(mem, "not an image")) {
        assert(excuse == c3d::ASSET_FORMAT_ERROR);
    } else {
        assert(false, "Invalid input was accepted");
    }
}

fn void test_decoded_pixels_copy_into_store() @test {
    AssetStore assets = create_image_store(mem, 5);
    defer asset::destroy_asset_store(&assets);

    image::Image decoded = image::decode_image(mem, $embed("../fixtures/rgba.png"))!!;
    defer image::destroy_image(&decoded);

    TextureId texture = assets.add_texture(
        material::texture_2d_desc(decoded.width, decoded.height, RGBA8_SRGB),
        decoded.pixels,
    )!!;
    decoded.pixels[0] = 0;

    assert(assets.texture(texture).pixels[0] == 255);
    assert(assets.texture(texture).desc.format == RGBA8_SRGB);
}

fn void test_released_source_keeps_identity_and_revision() @test {
    AssetStore assets = create_image_store(mem, 5);
    defer asset::destroy_asset_store(&assets);

    image::Image decoded = image::decode_image(assets.allocator, $embed("../fixtures/rgba.png"))!!;
    defer image::destroy_image(&decoded);

    TextureId texture = assets.add_texture_owned(
        material::texture_2d_desc(decoded.width, decoded.height, RGBA8_UNORM),
        decoded.pixels,
    )!!;
    assert(assets.texture(texture).pixels.ptr == decoded.pixels.ptr);
    decoded.pixels = {};

    uint revision = assets.texture(texture).header.revision;
    assets.release_texture_cpu(texture);

    assert(assets.textures.is_live(texture));
    assert(assets.texture(texture).header.revision == revision);
    assert(assets.texture(texture).desc.width == 2 && assets.texture(texture).pixels.len == 0);
    if (catch excuse = render::create_texture_mips(mem, assets.texture(texture).desc, assets.texture(texture).pixels)) {
        assert(excuse == c3d::ASSET_DATA_UNAVAILABLE);
    } else {
        assert(false, "Released pixels were accepted for preparation");
    }
}

fn void test_image_file_error_is_specific() @test {
    if (catch excuse = image::load_image(mem, "__missing_image_for_test__/image.png")) {
        assert(excuse == c3d::ASSET_IO_ERROR);
    } else {
        assert(false, "Missing file path was loaded");
    }

    @pool() {
        if (catch excuse = image::load_image(mem, fixture_path("truncated.png"))) {
            assert(excuse == c3d::ASSET_FORMAT_ERROR);
        } else {
            assert(false, "Malformed file was loaded");
        }
    };
}

fn void test_load_image_retains_caller_temporary_pixels() @test {
    @pool() {
        String path = fixture_path("rgba.png");
        Image decoded = image::load_image(tmem, path)!!;
        defer image::destroy_image(&decoded);

        char[] scratch = mem::temp_array(char, 4096);
        scratch[..] = 0;

        char[16] expected = { 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 64, 255, 255, 255, 0 };
        assert(decoded.pixels == expected[..]);
    };
}

fn void test_file_loaders_preserve_format_and_color_interpretation() @test {
    @pool() {
        AssetStore assets = create_image_store(mem);
        defer asset::destroy_asset_store(&assets);

        TextureId color = image::load_texture(
            assets: &assets,
            path: fixture_path("rgba.png"),
            srgb: true,
            key: "color",
        )!!;
        TextureId linear = image::load_texture(&assets, fixture_path("rgba.png"), false)!!;
        TextureId jpeg = image::load_texture(&assets, fixture_path("gray.jpg"), false)!!;
        TextureId hdr = image::load_hdr(&assets, fixture_path("radiance.hdr"))!!;

        assert(assets.texture(color).desc.format == RGBA8_SRGB);
        assert(assets.texture(linear).desc.format == RGBA8_UNORM);
        assert(assets.texture(color).pixels == assets.texture(linear).pixels);
        TextureId found = assets.find_texture("color")!!;
        assert(found.index == color.index && found.generation == color.generation);

        TextureAsset* grayscale = assets.texture(jpeg);
        char[8] expected_gray = { 128, 128, 128, 255, 128, 128, 128, 255 };
        assert(grayscale.desc.width == 2 && grayscale.desc.height == 1);
        assert(grayscale.desc.format == RGBA8_UNORM && grayscale.pixels == expected_gray[..]);

        TextureAsset* radiance = assets.texture(hdr);
        float[8] expected_hdr = { 2, 1, 0.5f, 1, 0.25f, 0.5f, 1, 1 };
        assert(radiance.desc.format == RGBA32_FLOAT);
        assert(((float*)radiance.pixels.ptr)[:8] == expected_hdr[..]);
    };
}

fn void test_loader_failures_release_decoded_pixels() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    @pool() {
        AssetStore assets = create_image_store(&tracker, 5);
        defer asset::destroy_asset_store(&assets);

        TextureId texture = image::load_texture(
            assets: &assets,
            path: fixture_path("rgba.png"),
            srgb: true,
            key: "occupied",
        )!!;
        char* pixels = assets.texture(texture).pixels.ptr;
        sz allocated = tracker.allocated();

        if (catch excuse = image::load_texture(&assets, fixture_path("rgba.png"), true)) {
            assert(excuse == c3d::CAPACITY_EXCEEDED);
        } else {
            assert(false, "Full texture pool accepted an image");
        }
        assert(tracker.allocated() == allocated);

        if (catch excuse = image::load_texture(
            assets: &assets,
            path: fixture_path("rgba.png"),
            srgb: false,
            key: "occupied",
        )) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "Duplicate texture key was accepted");
        }
        assert(tracker.allocated() == allocated);
        assert(assets.texture(texture).pixels.ptr == pixels);

        if (catch excuse = image::load_texture(&assets, fixture_path("radiance.hdr"), true)) {
            assert(excuse == c3d::ASSET_FORMAT_ERROR);
        } else {
            assert(false, "HDR was accepted as an eight-bit image");
        }
        assert(tracker.allocated() == allocated);

        if (catch excuse = image::load_hdr(&assets, fixture_path("rgba.png"))) {
            assert(excuse == c3d::ASSET_FORMAT_ERROR);
        } else {
            assert(false, "PNG was accepted as a floating-point image");
        }
        assert(tracker.allocated() == allocated);
    };

    assert(!tracker.has_leaks());
}
