module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::math;

const uint RIBBON_VIEWS @private = 2;
const float RIBBON_WIDTH @private = 0.5f;
const float RIBBON_INSIDE @private = 0.2f; // within half the width
const float RIBBON_OUTSIDE @private = 0.4f; // beyond half the width
const float RIBBON_END @private = 1.8f; // the strip's outer points, above and below the origin
const float RIBBON_GAP @private = 0.4f; // the points either side of the break
const float RIBBON_MARGIN @private = 0.1f;
const float RIBBON_CUSP_OFFSET @private = 1; // screen x of the doubled-back strip in both views
const float RIBBON_CUSP_LOW @private = -1.5f;
const float RIBBON_CUSP_HIGH @private = -0.5f;
const float RIBBON_CUSP_PROBE @private = -1;

fn RibbonPoint ribbon_point(Vec3 position, uint flags = 0) @private {
    RibbonPoint point = scene::RIBBON_POINT_DEFAULT;
    point.position = position;
    point.width = RIBBON_WIDTH;
    point.flags = flags;
    return point;
}

fn void test_ribbon_strip_faces_two_views_with_a_break_and_a_cusp() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    scene.background.color = {};
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.depth_write = false;
    MaterialId blended = fixture.assets.add_material(material::basic(common: common))!!;

    RibbonPoint[5] strip = {
        ribbon_point({ 0, -RIBBON_END, 0 }),
        ribbon_point({ 0, -RIBBON_END, 0 }),
        ribbon_point({ 0, -RIBBON_GAP, 0 }),
        ribbon_point({ 0, RIBBON_GAP, 0 }, scene::RIBBON_BREAK),
        ribbon_point({ 0, RIBBON_END, 0 }),
    };
    scene.add_ribbons(material: blended, capacity: strip.len, points: strip[..])!!;
    RibbonPoint[3] doubled_back = {
        ribbon_point({ RIBBON_CUSP_OFFSET, RIBBON_CUSP_LOW, -RIBBON_CUSP_OFFSET }),
        ribbon_point({ RIBBON_CUSP_OFFSET, RIBBON_CUSP_HIGH, -RIBBON_CUSP_OFFSET }),
        ribbon_point({ RIBBON_CUSP_OFFSET, RIBBON_CUSP_LOW, -RIBBON_CUSP_OFFSET }),
    };
    scene.add_ribbons(material: blended, capacity: doubled_back.len, points: doubled_back[..])!!;

    Node*[RIBBON_VIEWS] cameras;
    RenderTargetId[RIBBON_VIEWS] targets;
    ViewId[RIBBON_VIEWS] views;
    defer {
        foreach (view : views) if (view.generation) render::destroy_view(&fixture.renderer, view)!!;
        foreach (image : targets) if (image.generation) render::destroy_render_target(&fixture.renderer, image)!!;
    }
    foreach (index, &camera : cameras) {
        *camera = scene.add_camera(camera::orthographic(BILLBOARD_VIEW_HEIGHT, 0.1f, 100))!!;
        (*camera).local.position = index ? (Vec3){ 5, 0, 0 } : (Vec3){ 0, 0, 5 };
        targets[index] = render::create_render_target(
            renderer: &fixture.renderer,
            desc: render::render_target_desc(BILLBOARD_TARGET_SIZE, BILLBOARD_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
        )!!;
        ViewDesc desc = render::texture_view_desc(targets[index]);
        desc.post.anti_aliasing = AntiAliasing.NONE;
        views[index] = render::create_view(&fixture.renderer, desc)!!;
    }
    scene.update_world();
    cameras[1].look_at({});
    scene.update_world();

    for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT + 1; frame++) {
        fixture.renderer.begin_frame()!!;
        defer catch render::abort_frame(&fixture.renderer);
        foreach (index, view : views) {
            fixture.renderer.render_view(&scene, cameras[index], view)!!;
            fixture.renderer.finish_view(view)!!;
        }
        fixture.renderer.end_frame()!!;
    }

    foreach (image : targets) {
        Vec4[] pixels = read_float_target(&fixture, image)!!;
        defer free(pixels);
        float[2] sides = { -RIBBON_INSIDE, RIBBON_INSIDE };
        foreach (side : sides) {
            check_billboard_pixel(billboard_pixel(pixels, { side, -RIBBON_END + RIBBON_MARGIN }), BILLBOARD_WHITE);
            check_billboard_pixel(billboard_pixel(pixels, { side, RIBBON_END - RIBBON_MARGIN }), BILLBOARD_WHITE);
            check_billboard_pixel(
                billboard_pixel(pixels, { RIBBON_CUSP_OFFSET + side, RIBBON_CUSP_PROBE }),
                BILLBOARD_WHITE,
            );
        }
        check_billboard_pixel(billboard_pixel(pixels, { 0, -RIBBON_END - RIBBON_MARGIN }), {});
        check_billboard_pixel(billboard_pixel(pixels, { 0, 0 }), {});
        check_billboard_pixel(billboard_pixel(pixels, { RIBBON_OUTSIDE, RIBBON_END - RIBBON_MARGIN }), {});
        check_billboard_pixel(billboard_pixel(pixels, { RIBBON_CUSP_OFFSET + RIBBON_OUTSIDE, RIBBON_CUSP_PROBE }), {});
    }
    check_validation(&fixture.renderer);
}
