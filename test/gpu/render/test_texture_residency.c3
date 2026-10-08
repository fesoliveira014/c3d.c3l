module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::io;
import std::math;

const uint RESIDENCY_EXTENT @private = 256;
const uint RESIDENCY_MIPS @private = 9;
const uint RESIDENCY_VIEW_EXTENT @private = 256;
const float RESIDENCY_VIEW_HEIGHT @private = 1; // world units; one texel per pixel puts the face at mip zero
const usz RESIDENCY_BUDGET_BYTES @private = 160 * 1024; // above every tail, below one full chain
const usz RESIDENCY_UNBOUNDED_BYTES @private = 256 << 20;
const usz RESIDENCY_BUDGET_MARGIN @private = 1024;
const uint RESIDENCY_SETTLE_FRAMES @private = 3;
const uint RESIDENCY_DRAIN_FRAMES @private = 8;
const uint RESIDENCY_FULL_READ_MIP @private = 5;
const uint RESIDENCY_BC_BLOCK_BYTES @private = 8;
const uint RESIDENCY_BC_BLOCK_EXTENT @private = 4;
const uint RESIDENCY_COLOR_BASE @private = 30;
const uint RESIDENCY_COLOR_STEP @private = 25;
const uint RESIDENCY_ALPHA @private = 255;

struct ResidencyScene @private {
    Scene scene;
    Node* camera;
    ViewId view;
}

fn char[4] residency_level_color(uint mip) @private {
    return {
        (char)(RESIDENCY_COLOR_BASE + RESIDENCY_COLOR_STEP * mip),
        (char)(240 - RESIDENCY_COLOR_STEP * mip),
        (char)(40 + 10 * mip),
        (char)RESIDENCY_ALPHA,
    };
}

fn Vec4 residency_expected(char[4] color) @private {
    return { color[0] / 255.0f, color[1] / 255.0f, color[2] / 255.0f, 1 };
}

fn uint residency_packed(char[4] color) @private {
    return (uint)color[0] | (uint)color[1] << 8 | (uint)color[2] << 16 | (uint)color[3] << 24;
}

fn char[] residency_rgba_level(Allocator allocator, uint mip) @private {
    uint size = RESIDENCY_EXTENT >> mip;
    char[4] color = residency_level_color(mip);
    char[] texels = alloc::new_array(allocator, char, (sz)size * size * 4);
    for (usz texel = 0; texel < (usz)size * size; texel++) texels[texel * 4:4] = color[..];
    return texels;
}

fn char[4] residency_bc1_color(uint mip) @private {
    char[4] color = residency_level_color(mip);
    char red = color[0] >> 3;
    char green = color[1] >> 2;
    char blue = color[2] >> 3;
    return {
        (char)(red << 3 | red >> 2),
        (char)(green << 2 | green >> 4),
        (char)(blue << 3 | blue >> 2),
        (char)RESIDENCY_ALPHA,
    };
}

fn char[] residency_bc1_level(Allocator allocator, uint mip) @private {
    uint extent = RESIDENCY_EXTENT >> mip;
    uint blocks = math::max(1u, (extent + RESIDENCY_BC_BLOCK_EXTENT - 1) / RESIDENCY_BC_BLOCK_EXTENT);
    char[4] color = residency_level_color(mip);
    ushort packed = (ushort)((color[0] >> 3) << 11 | (color[1] >> 2) << 5 | (color[2] >> 3));
    char[] bytes = alloc::new_array(allocator, char, (sz)blocks * blocks * RESIDENCY_BC_BLOCK_BYTES);
    for (usz block = 0; block < (usz)blocks * blocks; block++) {
        char* destination = &bytes[block * RESIDENCY_BC_BLOCK_BYTES];
        destination[0] = (char)(packed & 0xff);
        destination[1] = (char)(packed >> 8);
        destination[2] = (char)(packed & 0xff);
        destination[3] = (char)(packed >> 8);
    }
    return bytes;
}

fn TextureId? residency_texture(Fixture* fixture, bool compressed) @private {
    TextureMipData[RESIDENCY_MIPS] levels;
    @pool() {
        foreach (uint mip, &level : levels) {
            *level = {
                .mip = mip,
                .bytes = compressed ? residency_bc1_level(tmem, mip) : residency_rgba_level(tmem, mip),
            };
        }
        material::TextureDesc desc = material::texture_2d_desc(
            width: RESIDENCY_EXTENT,
            height: RESIDENCY_EXTENT,
            format: compressed ? PixelFormat.BC1_RGBA_UNORM : PixelFormat.RGBA8_UNORM,
        );
        desc.generate_mips = false;
        desc.mip_levels = RESIDENCY_MIPS;
        return fixture.assets.add_texture_mips(desc, levels[..]);
    };
}

fn ResidencyScene? create_residency_scene(Fixture* fixture, TextureId texture) @private {
    ResidencyScene shown;
    shown.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&shown.scene);
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry = fixture.assets.add_geometry(&box)!;
        MaterialId material = fixture.assets.add_material(material::basic({
            .color = { 1, 1, 1, 1 },
            .map = material::texture_slot(texture),
        }))!;
        shown.scene.add_mesh(geometry, material)!;
    };
    shown.camera = shown.scene.add_camera(camera::orthographic(RESIDENCY_VIEW_HEIGHT, 0.1f, 100))!;
    shown.camera.local.position = CAMERA_POSITION;
    shown.scene.update_world();
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(RESIDENCY_VIEW_EXTENT, RESIDENCY_VIEW_EXTENT),
    )!;
    shown.view = render::create_view(&fixture.renderer, render::texture_view_desc(target))!;
    return shown;
}

fn uint? residency_frame(Fixture* fixture, ResidencyScene* shown) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&shown.scene, shown.camera, shown.view)!;
    sample(fixture, render::read_view_color(shown.view))!;
    record_readback(fixture)!;
    renderer.finish_view(shown.view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn void? residency_empty_frame(Fixture* fixture) @private {
    fixture.renderer.begin_frame()!;
    return fixture.renderer.end_frame();
}

fn void test_texture_residency_over_budget_scene_samples_the_resident_base_and_stays_under_budget() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, texture_budget_bytes: RESIDENCY_BUDGET_BYTES)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    TextureId texture = residency_texture(&fixture, false)!!;
    ResidencyScene shown = create_residency_scene(&fixture, texture)!!;
    defer scene::destroy_scene(&shown.scene);

    uint pixel;
    for (uint frame = 0; frame < RESIDENCY_SETTLE_FRAMES; frame++) pixel = residency_frame(&fixture, &shown)!!;
    TextureResidency residency = renderer.texture_residency(texture)!!;
    assert(residency.resident_base > 0);
    check_rgb(pixel, residency_expected(residency_level_color(residency.resident_base)));
    assert(renderer.stats.texture_bytes <= RESIDENCY_BUDGET_BYTES);

    renderer.set_texture_budget(0);
    uint raises;
    for (uint frame = 0; frame < RESIDENCY_DRAIN_FRAMES; frame++) {
        pixel = residency_frame(&fixture, &shown)!!;
        raises += renderer.stats.texture_raises;
    }
    assert(renderer.texture_residency(texture)!!.resident_base == 0);
    check_rgb(pixel, residency_expected(residency_level_color(0)));
    assert(raises >= 1);
    check_validation(renderer);
}

fn void test_texture_residency_eviction_returns_an_undrawn_texture_to_its_tail() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    TextureId drawn = residency_texture(&fixture, false)!!;
    TextureId hidden = residency_texture(&fixture, false)!!;
    renderer.upload_texture(drawn)!!;
    renderer.upload_texture(hidden)!!;
    ResidencyScene shown = create_residency_scene(&fixture, drawn)!!;
    defer scene::destroy_scene(&shown.scene);

    uint before = residency_frame(&fixture, &shown)!!;
    check_rgb(before, residency_expected(residency_level_color(0)));
    TextureResidency hidden_record = renderer.texture_residency(hidden)!!;
    usz full_bytes = render::texture_range_bytes(&hidden_record, 0);
    usz freed = full_bytes - render::texture_range_bytes(&hidden_record, hidden_record.tail_base);
    renderer.set_texture_budget(renderer.stats.texture_bytes - freed + RESIDENCY_BUDGET_MARGIN);

    uint after = residency_frame(&fixture, &shown)!!;
    assert(renderer.stats.texture_evictions == 1);
    assert(renderer.texture_residency(hidden)!!.resident_base == hidden_record.tail_base);
    assert(renderer.texture_residency(drawn)!!.resident_base == 0);
    assert(after == before);

    fixture.assets.remove_texture(hidden);
    TextureId reused = residency_texture(&fixture, false)!!;
    assert(reused.index == hidden.index);
    assert(renderer.texture_residency(reused)!!.chain_mips == 0);
    check_validation(renderer);
}

fn void test_texture_residency_compressed_texture_survives_eviction_and_raise() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    TextureId texture = residency_texture(&fixture, true)!!;
    if (!container_upload(renderer, texture)!!) return;

    ResidencyScene shown = create_residency_scene(&fixture, texture)!!;
    defer scene::destroy_scene(&shown.scene);
    uint pixel = residency_frame(&fixture, &shown)!!;
    check_rgb(pixel, residency_expected(residency_bc1_color(0)));

    renderer.begin_frame()!!;
    usz resident_bytes = renderer.stats.texture_bytes;
    renderer.end_frame()!!;
    renderer.set_texture_budget(resident_bytes - 1);
    pixel = residency_frame(&fixture, &shown)!!;
    TextureResidency residency = renderer.texture_residency(texture)!!;
    assert(renderer.stats.texture_evictions == 1);
    assert(residency.resident_base == residency.tail_base);
    check_rgb(pixel, residency_expected(residency_bc1_color(residency.tail_base)));

    renderer.set_texture_budget(RESIDENCY_UNBOUNDED_BYTES);
    pixel = residency_frame(&fixture, &shown)!!;
    assert(renderer.texture_residency(texture)!!.resident_base == 0);
    check_rgb(pixel, residency_expected(residency_bc1_color(0)));
    check_validation(renderer);
}

fn void test_texture_residency_full_reader_keeps_the_whole_chain() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, texture_budget_bytes: RESIDENCY_BUDGET_BYTES)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ContainerSampler sampler = create_container_sampler(&fixture)!!;
    defer destroy_container_sampler(&fixture, &sampler);
    uint expected = residency_packed(residency_level_color(RESIDENCY_FULL_READ_MIP));

    TextureId first_read = residency_texture(&fixture, false)!!;
    @pool() {
        assert(container_sample_mip(&fixture, &sampler, first_read, RESIDENCY_FULL_READ_MIP)!![0] == expected);
    };
    TextureResidency record = renderer.texture_residency(first_read)!!;
    assert(record.full_reader && !record.streamed && record.resident_base == 0);

    TextureId later_read = residency_texture(&fixture, false)!!;
    renderer.upload_texture(later_read)!!;
    TextureResidency streamed = renderer.texture_residency(later_read)!!;
    assert(streamed.resident_base == streamed.tail_base);
    for (uint frame = 0; frame < RESIDENCY_SETTLE_FRAMES; frame++) {
        @pool() {
            container_sample_mip(&fixture, &sampler, later_read, RESIDENCY_FULL_READ_MIP)!!;
        };
    }
    record = renderer.texture_residency(later_read)!!;
    assert(record.full_reader && !record.streamed && record.resident_base == 0);
    @pool() {
        assert(container_sample_mip(&fixture, &sampler, later_read, RESIDENCY_FULL_READ_MIP)!![0] == expected);
    };
    check_validation(renderer);
}
