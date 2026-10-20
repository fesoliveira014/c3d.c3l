module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader::compile;
import std::math;

const char[*] VERTEX_FETCH_VERTEX_SOURCE @private = $embed("vertex_fetch.vert.glsl");
const char[*] VERTEX_FETCH_FRAGMENT_SOURCE @private = $embed("vertex_fetch.frag.glsl");
const usz VERTEX_FETCH_TEXEL_BYTES @private = 4;
const usz VERTEX_FETCH_IMAGE_BYTES @private = (usz)TEXTURE_SIZE * TEXTURE_SIZE * VERTEX_FETCH_TEXEL_BYTES;
const Vec4 VERTEX_FETCH_HIDDEN @private = { 0, 0, 0, 1 }; // vertex_fetch.vert.glsl moves the box out of view
const Vec4 VERTEX_FETCH_SHOWN @private = { 1, 0, 0, 1 };

fn ShaderId? add_vertex_fetch_shader(Fixture* fixture) @private {
    String[1] depth_only = { "DEPTH_ONLY" };
    String vertex_source = (String)VERTEX_FETCH_VERTEX_SOURCE[..];
    asset::ShaderDesc desc = {
        .fragment = compile::compile_glsl(
            allocator: fixture.allocator,
            source:    (String)VERTEX_FETCH_FRAGMENT_SOURCE[..],
            stage:     ShaderStage.FRAGMENT,
        )!,
    };
    defer asset::free_shader_desc(fixture.allocator, &desc);
    desc.vertex.shaded = compile_vertex_stage(fixture, vertex_source)!;
    desc.vertex.depth = compile_vertex_stage(fixture, vertex_source, depth_only[..])!;

    return fixture.assets.add_shader(&desc);
}

fn DeformedScene? create_vertex_fetch_scene(Fixture* fixture, ShaderId shader, TextureId texture) @private {
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
    slots[0] = material::texture_slot(texture);
    MaterialId fetching = fixture.assets.add_material(material::custom(shader, slots: slots))!;

    return create_single_box_scene(fixture, fixture.box, fetching, false);
}

fn void paint_vertex_fetch_texture(char[] pixels, Vec4 color) @private {
    for (usz texel = 0; texel < pixels.len; texel += VERTEX_FETCH_TEXEL_BYTES) {
        for (uint channel = 0; channel < VERTEX_FETCH_TEXEL_BYTES; channel++) {
            pixels[texel + channel] = (char)(color[channel] * 255 + 0.5f);
        }
    }
}

fn TextureId? add_vertex_fetch_texture(Fixture* fixture, Vec4 color, ZString debug_name) @private {
    material::TextureDesc desc = material::texture_2d_desc(
        width:      TEXTURE_SIZE,
        height:     TEXTURE_SIZE,
        format:     RGBA8_UNORM,
        debug_name: debug_name,
    );
    desc.generate_mips = false;
    TextureId texture;

    @pool() {
        char[] pixels = alloc::new_array(tmem, char, VERTEX_FETCH_IMAGE_BYTES);

        paint_vertex_fetch_texture(pixels, color);
        texture = fixture.assets.add_texture(desc, pixels)!;
    };

    return texture;
}

fn uint? draw_vertex_fetch(Fixture* fixture, DeformedScene* target) @private {
    Renderer* renderer = &fixture.renderer;

    renderer.render_view(&target.scene, target.camera, fixture.view)!;
    sample(fixture, render::read_view_color(fixture.view))!;
    record_readback(fixture)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;

    return read_pixel(fixture);
}

fn void check_vertex_fetch_hidden(uint pixel) @private {
    assert((pixel & PIXEL_COLOR_MASK) == 0);
}

fn void check_dispatch_write_reaches_vertex_stage(Fixture* fixture, ShaderId shader) @private {
    Renderer* renderer = &fixture.renderer;
    TextureId written = fixture.assets.add_texture_empty(storage_texture_desc("vertex_fetch_written"))!!;
    DeformedScene target = create_vertex_fetch_scene(fixture, shader, written)!!;
    defer scene::destroy_scene(&target.scene);

    renderer.begin_frame()!!;
    fill(fixture, written, VERTEX_FETCH_HIDDEN)!!;
    check_vertex_fetch_hidden(draw_vertex_fetch(fixture, &target)!!);
    check_validation(renderer);

    renderer.begin_frame()!!;
    fill(fixture, written, VERTEX_FETCH_SHOWN)!!;
    check_opaque_color(draw_vertex_fetch(fixture, &target)!!);
    check_validation(renderer);
}

fn void check_region_upload_reaches_vertex_stage(Fixture* fixture, ShaderId shader) @private {
    Renderer* renderer = &fixture.renderer;
    TextureId edited = add_vertex_fetch_texture(fixture, VERTEX_FETCH_HIDDEN, "vertex_fetch_edited")!!;
    renderer.upload_texture(edited)!!;
    DeformedScene target = create_vertex_fetch_scene(fixture, shader, edited)!!;
    defer scene::destroy_scene(&target.scene);

    renderer.begin_frame()!!;
    check_vertex_fetch_hidden(draw_vertex_fetch(fixture, &target)!!);

    paint_vertex_fetch_texture(fixture.assets.texture(edited).pixels, VERTEX_FETCH_SHOWN);
    fixture.assets.mark_texture_region_dirty(
        edited,
        0,
        { .x = 0, .y = 0, .width = TEXTURE_SIZE, .height = TEXTURE_SIZE, .depth = 1 },
    )!!;
    renderer.begin_frame()!!;
    check_opaque_color(draw_vertex_fetch(fixture, &target)!!);
    assert(renderer.stats.upload_bytes == VERTEX_FETCH_IMAGE_BYTES);
    check_validation(renderer);
}

fn void check_first_upload_reaches_vertex_stage(Fixture* fixture, ShaderId shader) @private {
    Renderer* renderer = &fixture.renderer;
    TextureId fresh = add_vertex_fetch_texture(fixture, VERTEX_FETCH_SHOWN, "vertex_fetch_fresh")!!;
    DeformedScene target = create_vertex_fetch_scene(fixture, shader, fresh)!!;
    defer scene::destroy_scene(&target.scene);

    renderer.begin_frame()!!;
    check_opaque_color(draw_vertex_fetch(fixture, &target)!!);
    check_validation(renderer);
}

fn void test_vertex_stage_reads_texture_writes_made_earlier_in_the_frame() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);

    ShaderId shader = add_vertex_fetch_shader(&fixture)!!;

    check_dispatch_write_reaches_vertex_stage(&fixture, shader);
    check_region_upload_reaches_vertex_stage(&fixture, shader);
    check_first_upload_reaches_vertex_stage(&fixture, shader);
}
