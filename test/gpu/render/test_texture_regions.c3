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
const TextureRegion REGION_CORNER_EDIT @private = { .x = 30, .y = 15, .width = 7, .height = 8, .depth = 1 };

// Hand-derived from the 37x23 level extents: the edit's box at each level, widened to the texels whose filter reads it.
const uint[REGION_LEVELS] REGION_LEVEL_TEXELS @private = { 77, 30, 9, 4, 1, 1 };
const uint[REGION_LEVELS] REGION_CORNER_LEVEL_TEXELS @private = { 56, 16, 4, 1, 1, 1 };

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

fn usz region_staged_bytes(uint[REGION_LEVELS] level_texels) @private {
    usz staged_texels;

    foreach (texels : level_texels) staged_texels += texels;

    return staged_texels * REGION_TEXEL_BYTES;
}

fn void region_stroke(Fixture* fixture, TextureId texture, TextureRegion region) @private {
    Renderer* renderer = &fixture.renderer;

    renderer.begin_frame()!!;
    sample(fixture, render::read_texture(texture))!!;

    region_invert(fixture.assets.texture(texture).pixels, region);
    fixture.assets.mark_texture_region_dirty(texture, 0, region)!!;

    sample(fixture, render::read_texture(texture))!!;
    renderer.end_frame()!!;
}

fn void region_refresh(Fixture* fixture, TextureId texture) @private {
    Renderer* renderer = &fixture.renderer;
    TextureRegion plane = { .width = REGION_WIDTH, .height = REGION_HEIGHT, .depth = 1 };

    renderer.begin_frame()!!;
    sample(fixture, render::read_texture(texture))!!;

    region_invert(fixture.assets.texture(texture).pixels, plane);
    fixture.assets.mark_texture_dirty(texture);

    sample(fixture, render::read_texture(texture))!!;
    renderer.end_frame()!!;
}

fn usz region_whole_bytes() @private {
    usz bytes;

    for (uint mip = 0; mip < REGION_LEVELS; mip++) {
        uint width = material::texture_mip_extent(REGION_WIDTH, mip);
        uint height = material::texture_mip_extent(REGION_HEIGHT, mip);

        bytes += (usz)width * height;
    }

    return bytes * REGION_TEXEL_BYTES;
}

fn void expect_levels_match_whole_upload(
    Fixture* fixture,
    FidelityHarness* harness,
    TextureId edited,
    ZString reference_name,
) @private {
    TextureAsset* record = fixture.assets.texture(edited);
    material::TextureDesc reference_desc = record.desc;

    reference_desc.debug_name = reference_name;

    TextureId reference = fixture.assets.add_texture(reference_desc, record.pixels)!!;

    for (uint mip = 0; mip < REGION_LEVELS; mip++) {
        Vec4[] actual = fidelity_sample(
            fixture: fixture,
            harness: harness,
            texture: edited,
            mip:     mip,
        )!!;
        Vec4[] expected = fidelity_sample(
            fixture: fixture,
            harness: harness,
            texture: reference,
            mip:     mip,
        )!!;

        assert(actual.len == expected.len);

        foreach (index, texel : actual) {
            assert(texel == expected[index], "mip %d texel %d", mip, index);
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
        TextureRes* mirror = &renderer.textures[edited.index];

        assert(mirror.mip_chain.len == 0);

        Vec4[] before = fidelity_sample(
            fixture: &fixture,
            harness: &harness,
            texture: edited,
            mip:     0,
        )!!;
        Vec4 untouched = before[0];

        region_stroke(&fixture, edited, REGION_EDIT);

        assert(renderer.stats.uploads == 1);
        assert(renderer.stats.upload_bytes == region_staged_bytes(REGION_LEVEL_TEXELS));
        assert(mirror.mip_chain.len > 0);
        assert(mirror.chain_revision == record.header.revision && mirror.revision == record.header.revision);

        char* retained = mirror.mip_chain.ptr;
        Vec4[] after = fidelity_sample(
            fixture: &fixture,
            harness: &harness,
            texture: edited,
            mip:     0,
        )!!;
        bool changed;

        expect_levels_match_whole_upload(
            fixture:        &fixture,
            harness:        &harness,
            edited:         edited,
            reference_name: "region_reference",
        );

        assert(after[0] == untouched);
        foreach (index, texel : after) changed = changed || texel != before[index];
        assert(changed);

        region_stroke(&fixture, edited, REGION_CORNER_EDIT);

        assert(renderer.stats.uploads == 1);
        assert(renderer.stats.upload_bytes == region_staged_bytes(REGION_CORNER_LEVEL_TEXELS));
        assert(mirror.mip_chain.ptr == retained);
        assert(mirror.chain_revision == record.header.revision && mirror.revision == record.header.revision);

        expect_levels_match_whole_upload(
            fixture:        &fixture,
            harness:        &harness,
            edited:         edited,
            reference_name: "region_corner_reference",
        );

        region_refresh(&fixture, edited);

        assert(renderer.stats.uploads == 1);
        assert(renderer.stats.upload_bytes == region_whole_bytes());
        assert(mirror.mip_chain.ptr == retained);
        assert(mirror.chain_revision == record.header.revision && mirror.revision == record.header.revision);

        expect_levels_match_whole_upload(
            fixture:        &fixture,
            harness:        &harness,
            edited:         edited,
            reference_name: "region_refresh_reference",
        );

        region_stroke(&fixture, edited, REGION_EDIT);

        assert(renderer.stats.upload_bytes == region_staged_bytes(REGION_LEVEL_TEXELS));
        assert(mirror.chain_revision == record.header.revision && mirror.revision == record.header.revision);

        expect_levels_match_whole_upload(
            fixture:        &fixture,
            harness:        &harness,
            edited:         edited,
            reference_name: "region_resumed_reference",
        );
    };

    check_validation(renderer);
}

fn void test_prepared_replacement_frees_the_retained_chain() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Fixture fixture;
        create_fixture(&tracker, &fixture)!!;
        defer destroy_fixture(&fixture);

        FidelityHarness harness = create_fidelity_harness(&fixture)!!;
        defer destroy_fidelity_harness(&fixture, &harness);

        Renderer* renderer = &fixture.renderer;
        material::TextureDesc desc = material::texture_2d_desc(
            width:      REGION_WIDTH,
            height:     REGION_HEIGHT,
            format:     RGBA8_UNORM,
            debug_name: "prepared_edited",
        );

        @pool() {
            TextureId edited = fixture.assets.add_texture(desc, region_pattern(tmem))!!;

            renderer.upload_texture(edited)!!;
            region_stroke(&fixture, edited, REGION_EDIT);

            TextureAsset* record = fixture.assets.texture(edited);
            TextureRes* mirror = &renderer.textures[edited.index];

            assert(mirror.mip_chain.len > 0);

            fixture.assets.mark_texture_dirty(edited);

            PrepareId prepare = renderer.begin_prepare_model(preparation_texture_model(&fixture, edited)!!)!!;

            preparation_drain(renderer, prepare, {});

            assert(mirror.mip_chain.len == 0 && mirror.chain_revision == 0);

            region_stroke(&fixture, edited, REGION_CORNER_EDIT);

            assert(mirror.mip_chain.len > 0);
            assert(mirror.chain_revision == record.header.revision && mirror.revision == record.header.revision);

            expect_levels_match_whole_upload(
            fixture:        &fixture,
            harness:        &harness,
            edited:         edited,
            reference_name: "prepared_reference",
        );
            renderer.end_prepare(prepare)!!;
        };

        check_validation(renderer);
    }

    assert(tracker.allocated() == 0);
}

fn void test_aborted_region_upload_leaves_the_chain_untrusted() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    FidelityHarness harness = create_fidelity_harness(&fixture)!!;
    defer destroy_fidelity_harness(&fixture, &harness);

    Renderer* renderer = &fixture.renderer;
    material::TextureDesc desc = material::texture_2d_desc(
        width:      REGION_WIDTH,
        height:     REGION_HEIGHT,
        format:     RGBA8_UNORM,
        debug_name: "region_aborted",
    );

    @pool() {
        TextureId edited = fixture.assets.add_texture(desc, region_pattern(tmem))!!;

        renderer.upload_texture(edited)!!;
        region_stroke(&fixture, edited, REGION_EDIT);

        TextureAsset* record = fixture.assets.texture(edited);
        TextureRes* mirror = &renderer.textures[edited.index];

        assert(mirror.chain_revision == record.header.revision);

        renderer.begin_frame()!!;
        region_invert(record.pixels, REGION_CORNER_EDIT);
        fixture.assets.mark_texture_region_dirty(edited, 0, REGION_CORNER_EDIT)!!;
        sample(&fixture, render::read_texture(edited))!!;
        render::abort_frame(renderer);

        assert(mirror.revision == 0 && mirror.chain_revision == 0 && mirror.mip_chain.len > 0);

        region_stroke(&fixture, edited, REGION_EDIT);

        assert(mirror.chain_revision == record.header.revision && mirror.revision == record.header.revision);

        expect_levels_match_whole_upload(
            fixture:        &fixture,
            harness:        &harness,
            edited:         edited,
            reference_name: "region_aborted_reference",
        );
    };

    check_validation(renderer);
}
