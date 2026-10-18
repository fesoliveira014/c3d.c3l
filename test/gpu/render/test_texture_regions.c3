module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render @public;
import std::math;

const uint REGION_WIDTH @private = 37;
const uint REGION_HEIGHT @private = 23;
const uint REGION_LEVELS @private = 6;
const uint REGION_TEXEL_BYTES @private = 4;
const TextureRegion REGION_EDIT @private = { .x = 5, .y = 4, .width = 11, .height = 7, .depth = 1 };

// Hand-derived from the 37x23 level extents: the edit's box at each level, widened to the texels whose filter reads it.
const uint[REGION_LEVELS] REGION_LEVEL_TEXELS @private = { 77, 30, 9, 4, 1, 1 };

fn char[] region_pattern(Allocator allocator) @private {
    char[] pixels = alloc::new_array(allocator, char, (sz)REGION_WIDTH * REGION_HEIGHT * REGION_TEXEL_BYTES);

    for (uint row = 0; row < REGION_HEIGHT; row++) {
        for (uint column = 0; column < REGION_WIDTH; column++) {
            for (uint channel = 0; channel < REGION_TEXEL_BYTES; channel++) {
                usz index = ((usz)row * REGION_WIDTH + column) * REGION_TEXEL_BYTES + channel;

                pixels[index] = (char)((column * 29 + row * 53 + channel * 71 + column * row) % 251);
            }
        }
    }

    return pixels;
}

fn void region_invert(char[] pixels, TextureRegion region) @private {
    for (uint row = region.y; row < region.y + region.height; row++) {
        for (uint column = region.x; column < region.x + region.width; column++) {
            for (uint channel = 0; channel < REGION_TEXEL_BYTES; channel++) {
                usz index = ((usz)row * REGION_WIDTH + column) * REGION_TEXEL_BYTES + channel;

                pixels[index] = (char)(255 - pixels[index]);
            }
        }
    }
}

fn void test_texture_region_upload_matches_whole_upload() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityHarness harness = create_fidelity_harness(&fixture)!!;
    defer destroy_fidelity_harness(&fixture, &harness);

    Renderer* renderer = &fixture.renderer;
    material::TextureDesc desc = material::texture_2d_desc(REGION_WIDTH, REGION_HEIGHT, RGBA8_UNORM, "region_edited");

    @pool() {
        char[] pixels = region_pattern(tmem);
        TextureId edited = fixture.assets.add_texture(desc, pixels)!!;

        renderer.upload_texture(edited)!!;

        TextureAsset* record = fixture.assets.texture(edited);
        Vec4[] before = fidelity_sample(&fixture, &harness, edited, 0)!!;
        Vec4 untouched = before[0];

        renderer.begin_frame()!!;
        sample(&fixture, render::read_texture(edited))!!;

        region_invert(record.pixels, REGION_EDIT);
        fixture.assets.mark_texture_region_dirty(edited, 0, REGION_EDIT)!!;

        sample(&fixture, render::read_texture(edited))!!;
        renderer.end_frame()!!;

        usz staged_texels;
        foreach (texels : REGION_LEVEL_TEXELS) staged_texels += texels;

        assert(renderer.stats.uploads == 1);
        assert(renderer.stats.upload_bytes == staged_texels * REGION_TEXEL_BYTES);

        Vec4[] after = fidelity_sample(&fixture, &harness, edited, 0)!!;

        material::TextureDesc reference_desc = desc;
        reference_desc.debug_name = "region_reference";
        TextureId reference = fixture.assets.add_texture(reference_desc, record.pixels)!!;
        bool changed;

        for (uint mip = 0; mip < REGION_LEVELS; mip++) {
            Vec4[] actual = fidelity_sample(&fixture, &harness, edited, mip)!!;
            Vec4[] expected = fidelity_sample(&fixture, &harness, reference, mip)!!;

            assert(actual.len == expected.len);

            foreach (index, texel : actual) {
                assert(texel == expected[index], "mip %d texel %d", mip, index);
            }
        }

        assert(after[0] == untouched);
        foreach (index, texel : after) changed = changed || texel != before[index];
        assert(changed);
    };

    check_validation(renderer);
}
