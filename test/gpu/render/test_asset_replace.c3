module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render @public;
import c3d::scene;
import c3d::shader::compile;
import std::io;
import std::math;

const String REPLACE_FONT_CASE @private = "test_replace_font_with_smaller_capacity";
const uint REPLACE_WINDOW_SIZE @private = 256;
const uint REPLACE_WINDOW_FRAMES @private = 3;
const uint REPLACE_LEFT_COLUMN @private = BLEND_TARGET_SIZE / 4;
const uint REPLACE_RIGHT_COLUMN @private = 3 * BLEND_TARGET_SIZE / 4;
const uint REPLACE_ROW @private = BLEND_TARGET_SIZE / 2;
const float REPLACE_QUAD_OFFSET @private = 0.5f; // world x of the left and right quad centers in the orthographic view
const Vec4 REPLACE_SHAPE_COLOR @private = { 1, 0, 0, 1 };
const uint REPLACE_WIDE_PAYLOAD_BYTES @private = 32;

struct ReplaceWidePayload @private {
    Vec4 color;
    Vec4 unused;
}
$assert ReplaceWidePayload::size == REPLACE_WIDE_PAYLOAD_BYTES;

fn Vec4 replace_pixel(Vec4[] pixels, uint column) @private {
    return pixels[REPLACE_ROW * BLEND_TARGET_SIZE + column];
}

fn Geometry replace_rectangle(Allocator allocator, float min_x, float max_x, uint segments) @private {
    uint vertex_count = 2 * (segments + 1);
    Geometry rectangle = {
        .positions = alloc::new_array(allocator, Vec3, vertex_count),
        .normals   = alloc::new_array(allocator, Vec3, vertex_count),
        .uv0       = alloc::new_array(allocator, Vec2, vertex_count),
        .indices   = alloc::new_array(allocator, uint, (sz)(6 * segments)),
    };
    for (uint column = 0; column <= segments; column++) {
        float x = min_x + (max_x - min_x) * (float)column / (float)segments;
        rectangle.positions[2 * column] = { x, -0.4f, 0 };
        rectangle.positions[2 * column + 1] = { x, 0.4f, 0 };
    }
    foreach (&normal : rectangle.normals) *normal = { 0, 0, 1 };
    for (uint segment = 0; segment < segments; segment++) {
        uint bottom = 2 * segment;
        uint[6] corners = { bottom, bottom + 2, bottom + 3, bottom, bottom + 3, bottom + 1 };
        foreach (uint corner, vertex : corners) rectangle.indices[6 * segment + corner] = vertex;
    }
    rectangle.finalize();
    return rectangle;
}

fn Node*? add_replace_quad(Scene* scene, GeometryId geometry, MaterialId material_id, float x) @private {
    Node* node = scene.add_mesh(geometry, material_id)!;
    node.local.position = { x, 0, 0 };
    node.local.rotation = maths::look_rotation({ 0, 1, 0 }, { 0, 0, 1 });
    scene.get(node, Mesh).cast_shadow = false;
    return node;
}

fn MaterialId? add_replace_textured(Fixture* fixture, TextureId texture) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    return fixture.assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map   = material::texture_slot(texture),
    }, common));
}

fn char[] replace_solid(Allocator allocator, uint width, uint height, Vec4 color) @private {
    char[] pixels = alloc::new_array(allocator, char, (sz)width * height * 4);
    for (usz texel = 0; texel < (usz)width * height; texel++) {
        for (usz channel = 0; channel < 4; channel++) pixels[texel * 4 + channel] = (char)(color[channel] * 255 + 0.5f);
    }
    return pixels;
}

fn void test_replace_texture_shared_by_two_materials() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialBlendScene target = create_material_blend_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialBlendView blend_view = create_material_blend_view(&fixture)!!;
    defer destroy_material_blend_view(&fixture, &blend_view);

    TextureId texture;
    @pool() {
        material::TextureDesc desc = material::texture_2d_desc(2, 2, RGBA8_UNORM, "replace_shared");
        desc.generate_mips = false;
        texture = fixture.assets.add_texture(desc, replace_solid(tmem, 2, 2, { 1, 0, 0, 1 }))!!;
    };
    MaterialId left = add_replace_textured(&fixture, texture)!!;
    MaterialId right = add_replace_textured(&fixture, texture)!!;
    GeometryId quad;
    @pool() {
        Geometry geometry = geometry::plane(tmem, 0.8f, 0.8f);
        quad = fixture.assets.add_geometry(&geometry)!!;
    };
    add_replace_quad(&target.scene, quad, left, -REPLACE_QUAD_OFFSET)!!;
    add_replace_quad(&target.scene, quad, right, REPLACE_QUAD_OFFSET)!!;
    target.scene.update_world();

    Vec4[] red = render_material_blend_pixels(&fixture, &target, &blend_view)!!;
    defer free(red);
    check_material_blend_pixel(replace_pixel(red, REPLACE_LEFT_COLUMN), { 1, 0, 0, 1 });
    check_material_blend_pixel(replace_pixel(red, REPLACE_RIGHT_COLUMN), { 1, 0, 0, 1 });

    @pool() {
        material::TextureDesc desc = material::texture_2d_desc(8, 8, RGBA8_UNORM, "replace_shared");
        desc.generate_mips = false;
        fixture.assets.replace_texture(texture, desc, replace_solid(tmem, 8, 8, { 0, 0, 1, 1 }))!!;
    };
    Vec4[] blue = render_material_blend_pixels(&fixture, &target, &blend_view)!!;
    defer free(blue);
    check_material_blend_pixel(replace_pixel(blue, REPLACE_LEFT_COLUMN), { 0, 0, 1, 1 });
    check_material_blend_pixel(replace_pixel(blue, REPLACE_RIGHT_COLUMN), { 0, 0, 1, 1 });
    check_validation(&fixture.renderer);
}

fn void test_replace_geometry_changes_vertex_count() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialBlendScene target = create_material_blend_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialBlendView blend_view = create_material_blend_view(&fixture)!!;
    defer destroy_material_blend_view(&fixture, &blend_view);

    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    MaterialId shape = fixture.assets.add_material(material::basic({ .color = REPLACE_SHAPE_COLOR }, common))!!;
    GeometryId geometry;
    @pool() {
        Geometry left = replace_rectangle(tmem, -0.9f, -0.1f, 1);
        geometry = fixture.assets.add_geometry(&left)!!;
    };
    target.scene.add_mesh(geometry, shape)!!;
    target.scene.update_world();

    Vec4[] first = render_material_blend_pixels(&fixture, &target, &blend_view)!!;
    defer free(first);
    check_material_blend_pixel(replace_pixel(first, REPLACE_LEFT_COLUMN), REPLACE_SHAPE_COLOR);
    check_material_blend_pixel(replace_pixel(first, REPLACE_RIGHT_COLUMN), BLEND_BACKGROUND);

    @pool() {
        Geometry right = replace_rectangle(tmem, 0.1f, 0.9f, 8);
        fixture.assets.replace_geometry(geometry, &right)!!;
    };
    Vec4[] second = render_material_blend_pixels(&fixture, &target, &blend_view)!!;
    defer free(second);
    check_material_blend_pixel(replace_pixel(second, REPLACE_LEFT_COLUMN), BLEND_BACKGROUND);
    check_material_blend_pixel(replace_pixel(second, REPLACE_RIGHT_COLUMN), REPLACE_SHAPE_COLOR);

    @pool() {
        Geometry middle = replace_rectangle(tmem, -0.9f, 0.9f, 3);
        fixture.assets.replace_geometry(geometry, &middle)!!;
        Geometry left = replace_rectangle(tmem, -0.9f, -0.1f, 5);
        fixture.assets.replace_geometry(geometry, &left)!!;
    };
    Vec4[] third = render_material_blend_pixels(&fixture, &target, &blend_view)!!;
    defer free(third);
    check_material_blend_pixel(replace_pixel(third, REPLACE_LEFT_COLUMN), REPLACE_SHAPE_COLOR);
    check_material_blend_pixel(replace_pixel(third, REPLACE_RIGHT_COLUMN), BLEND_BACKGROUND);
    check_validation(&fixture.renderer);
}

fn void test_replace_font_with_smaller_capacity() @test {
    platform::Window? opened = platform::create_window(
        platform::default_window_desc("c3d replace font", REPLACE_WINDOW_SIZE, REPLACE_WINDOW_SIZE));
    if (catch excuse = opened) {
        io::eprintfn("%s: skipped, no window (%s)", REPLACE_FONT_CASE, excuse);
        return;
    }
    platform::Window window = opened;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "render_acceptance" },
    )!!;
    defer render::destroy_renderer(&renderer);

    char[] latin = $embed("../../fixtures/fonts/latin.ttf");
    FontDesc large = {
        .max_glyphs   = 128,
        .curve_texels = 4 * asset::FONT_TEXTURE_WIDTH,
        .band_texels  = 16 * asset::FONT_TEXTURE_WIDTH,
    };
    FontDesc small = {
        .max_glyphs   = 64,
        .curve_texels = asset::FONT_TEXTURE_WIDTH,
        .band_texels  = 4 * asset::FONT_TEXTURE_WIDTH,
    };
    FontId font = assets.add_font(latin, large)!!;
    OverlayList list = render::create_overlay_list(mem, render::default_overlay_list_desc());
    defer render::destroy_overlay_list(&list);

    usz bound = (usz)large.curve_texels * Vec4::size + (usz)large.band_texels * uint::size;
    uint drawn_frames;
    for (uint frame = 0; frame < REPLACE_WINDOW_FRAMES; frame++) {
        if (frame == 1) assets.replace_font(font, latin, small)!!;
        window.poll();
        platform::sync_window(&window, &renderer);
        GlyphPlacement[8] placements;
        usz placed = assets.place_text(font, "Replace", placements[..])!!;
        list.clear();
        list.add_glyphs({
            .font        = font,
            .glyphs      = placements[:placed],
            .origin      = { 16, 64 },
            .size_pixels = 32,
            .color       = { 1, 1, 1, 1 },
        })!!;
        renderer.begin_frame()!!;
        if (renderer.has_output) {
            renderer.prepare_overlay_list(&list)!!;
            assert(renderer.stats.upload_bytes <= bound);
            OverlayContext overlay = renderer.begin_overlay()!!;
            overlay.draw_list(&list)!!;
            renderer.end_overlay(&overlay)!!;
            drawn_frames++;
        }
        renderer.end_frame()!!;
    }
    if (!drawn_frames) io::eprintfn("%s: skipped, no window output", REPLACE_FONT_CASE);
    check_validation(&renderer);
}

fn void test_replace_custom_material_payload_size() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialBlendScene target = create_material_blend_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialBlendView blend_view = create_material_blend_view(&fixture)!!;
    defer destroy_material_blend_view(&fixture, &blend_view);

    ShaderId narrow;
    ShaderId wide;
    @pool() {
        char[] fragment = compile::compile_glsl(tmem, (String)MATERIAL_BLEND_FRAGMENT[..], ShaderStage.FRAGMENT)!!;
        ShaderDesc narrow_desc = { .fragment = fragment, .param_block_size = MaterialBlendParams::size };
        narrow = fixture.assets.add_shader(&narrow_desc)!!;
        ShaderDesc wide_desc = { .fragment = fragment, .param_block_size = ReplaceWidePayload::size };
        wide = fixture.assets.add_shader(&wide_desc)!!;
    };
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    MaterialBlendParams first = { .color = { 0.9f, 0.1f, 0.1f, 1 } };
    MaterialId custom = fixture.assets.add_material(
        material::custom(shader: narrow, param_block: material::@as_bytes(first), common: common),
    )!!;
    GeometryId quad;
    @pool() {
        Geometry geometry = geometry::plane(tmem, 1, 1);
        quad = fixture.assets.add_geometry(&geometry)!!;
    };
    add_replace_quad(&target.scene, quad, custom, 0)!!;
    target.scene.update_world();

    Vec4[] before = render_material_blend_pixels(&fixture, &target, &blend_view)!!;
    defer free(before);
    check_material_blend_pixel(replace_pixel(before, BLEND_TARGET_SIZE / 2), first.color);

    ReplaceWidePayload second = { .color = { 0.1f, 0.8f, 0.1f, 1 } };
    fixture.assets.replace_material(
        custom,
        material::custom(shader: wide, param_block: material::@as_bytes(second), common: common),
    );
    Vec4[] after = render_material_blend_pixels(&fixture, &target, &blend_view)!!;
    defer free(after);
    check_material_blend_pixel(replace_pixel(after, BLEND_TARGET_SIZE / 2), second.color);
    check_validation(&fixture.renderer);
}
