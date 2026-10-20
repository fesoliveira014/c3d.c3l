module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
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
const char[*] DEVICE_RIBBONS_STAGE @private = $embed("device_ribbons.comp.glsl");
const uint DEVICE_RIBBON_CAPACITY @private = 8; // mirrored as the invocation count of device_ribbons.comp.glsl
const uint DEVICE_RIBBON_LIVE @private = 4;
const float DEVICE_RIBBON_SPACING @private = 0.5f;
const float DEVICE_RIBBON_WIDTH @private = 0.25f;
const usz DEVICE_RIBBON_COUNT_OFFSET @private = (DEVICE_RIBBON_CAPACITY + 1) * RibbonPointGpu::size; // after records
const usz DEVICE_RIBBON_ARENA_BYTES @private = render::CULL_COUNTER_BYTES; // no room for the draw arguments

// Mirrors DeviceRibbonsRoot in device_ribbons.comp.glsl.
struct DeviceRibbonsRoot @private {
    ulong records;
    ulong count;
    uint live;
    uint capacity;
    float spacing;
    float width;
}
$assert DeviceRibbonsRoot::size == 32;

struct DeviceRibbonScene @private {
    Scene scene;
    Node* node;
    Node* camera;
    RenderTargetId image;
    ViewId view;
}

fn RibbonPoint ribbon_point(Vec3 position, uint flags = 0) @private {
    RibbonPoint point = scene::RIBBON_POINT_DEFAULT;
    point.position = position;
    point.width = RIBBON_WIDTH;
    point.flags = flags;
    return point;
}

fn MaterialId? add_blended_material(AssetStore* assets) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.depth_write = false;
    return assets.add_material(material::basic(common: common));
}

fn void test_ribbon_strip_faces_two_views_with_a_break_and_a_cusp() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    scene.background.color = {};
    MaterialId blended = add_blended_material(&fixture.assets)!!;

    RibbonPoint[5] strip = {
        ribbon_point({ 0, -RIBBON_END, 0 }),
        ribbon_point({ 0, -RIBBON_END, 0 }),
        ribbon_point({ 0, -RIBBON_GAP, 0 }),
        ribbon_point({ 0, RIBBON_GAP, 0 }, scene::RIBBON_BREAK),
        ribbon_point({ 0, RIBBON_END, 0 }),
    };
    strip[4].width = 0;
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
            check_billboard_pixel(
                billboard_pixel(pixels, { RIBBON_CUSP_OFFSET + side, RIBBON_CUSP_PROBE }),
                BILLBOARD_WHITE,
            );
        }
        check_billboard_pixel(billboard_pixel(pixels, { 0, -RIBBON_END - RIBBON_MARGIN }), {});
        check_billboard_pixel(billboard_pixel(pixels, { 0, 0 }), {});
        check_billboard_pixel(billboard_pixel(pixels, { 0, RIBBON_GAP + RIBBON_MARGIN }), BILLBOARD_WHITE);
        check_billboard_pixel(billboard_pixel(pixels, { RIBBON_INSIDE, RIBBON_END - RIBBON_MARGIN }), {});
        check_billboard_pixel(billboard_pixel(pixels, { RIBBON_CUSP_OFFSET + RIBBON_OUTSIDE, RIBBON_CUSP_PROBE }), {});
    }
    check_validation(&fixture.renderer);
}

fn void destroy_device_ribbon_scene(Fixture* fixture, DeviceRibbonScene* target) @private {
    if (target.view.generation) render::destroy_view(&fixture.renderer, target.view)!!;
    if (target.image.generation) render::destroy_render_target(&fixture.renderer, target.image)!!;
    scene::destroy_scene(&target.scene);
}

fn DeviceRibbonScene? create_device_ribbon_scene(Fixture* fixture) @private {
    DeviceRibbonScene target = { .scene = scene::create_scene(mem, { .max_nodes = 4 }) };
    defer catch destroy_device_ribbon_scene(fixture, &target);
    target.scene.background.color = {};
    target.node = target.scene.add_ribbons(
        material: add_blended_material(&fixture.assets)!,
        capacity: DEVICE_RIBBON_CAPACITY,
        source: RibbonSource.DEVICE,
    )!;
    target.camera = target.scene.add_camera(camera::orthographic(BILLBOARD_VIEW_HEIGHT, 0.1f, 100))!;
    target.camera.local.position = { 0, 0, 5 };
    target.image = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(BILLBOARD_TARGET_SIZE, BILLBOARD_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    ViewDesc desc = render::texture_view_desc(target.image);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    target.view = render::create_view(&fixture.renderer, desc)!;
    target.scene.update_world();
    return target;
}

fn BufferId? attach_device_ribbons(Fixture* fixture, DeviceRibbonScene* target) @private {
    BufferId buffer = fixture.renderer.create_buffer({
        .size       = DEVICE_RIBBON_COUNT_OFFSET + uint::size,
        .debug_name = "device_ribbons",
    })!;
    target.scene.set_ribbon_device(
        target.node,
        {
            .buffer         = buffer,
            .records_offset = 0,
            .count_offset   = DEVICE_RIBBON_COUNT_OFFSET,
            .capacity       = DEVICE_RIBBON_CAPACITY,
        },
        { .min = { -2, -1, -1 }, .max = { 2, 1, 1 } },
    );
    return buffer;
}

fn void? render_device_ribbon_frames(
    Fixture* fixture,
    DeviceRibbonScene* target,
    ComputeShaderId stage,
    BufferId buffer,
) @private {
    Renderer* renderer = &fixture.renderer;
    ulong records = (ulong)renderer.buffer_address(buffer);
    DeviceRibbonsRoot root = {
        .records  = records,
        .count    = records + DEVICE_RIBBON_COUNT_OFFSET,
        .live     = DEVICE_RIBBON_LIVE,
        .capacity = DEVICE_RIBBON_CAPACITY,
        .spacing  = DEVICE_RIBBON_SPACING,
        .width    = DEVICE_RIBBON_WIDTH,
    };
    BufferId[1] writes = { buffer };
    for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT + 1; frame++) {
        renderer.begin_frame()!;
        defer catch render::abort_frame(renderer);
        renderer.dispatch({
            .shader = stage,
            .root   = ((char*)&root)[:DeviceRibbonsRoot::size],
            .groups = { 1, 1, 1 },
            .writes = writes[..],
        })!;
        renderer.render_view(&target.scene, target.camera, target.view)!;
        renderer.finish_view(target.view)!;
        renderer.end_frame()!;
    }
}

fn float device_segment_middle(uint segment) @private {
    return ((float)segment + 0.5f - 0.5f * (float)(DEVICE_RIBBON_CAPACITY - 1)) * DEVICE_RIBBON_SPACING;
}

fn void check_device_segments(Vec4[] pixels, bool drawn_live) @private {
    for (uint segment = 0; segment < DEVICE_RIBBON_CAPACITY - 1; segment++) {
        bool live = drawn_live && segment + 1 < DEVICE_RIBBON_LIVE;
        check_billboard_pixel(
            billboard_pixel(pixels, { device_segment_middle(segment), 0 }),
            live ? BILLBOARD_WHITE : (Vec4){},
        );
    }
}

fn void test_device_ribbons_draw_the_counted_points() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ComputeShaderId stage = add_compute_shader(&fixture, (String)DEVICE_RIBBONS_STAGE[..])!!;
    DeviceRibbonScene target = create_device_ribbon_scene(&fixture)!!;
    defer destroy_device_ribbon_scene(&fixture, &target);
    BufferId buffer = attach_device_ribbons(&fixture, &target)!!;
    render_device_ribbon_frames(
        fixture: &fixture,
        target:  &target,
        stage:   stage,
        buffer:  buffer,
    )!!;
    Vec4[] pixels = read_float_target(&fixture, target.image)!!;
    defer free(pixels);
    check_device_segments(pixels, true);
    check_validation(&fixture.renderer);
}

fn void test_device_ribbons_with_a_destroyed_buffer_are_skipped_and_counted() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeviceRibbonScene target = create_device_ribbon_scene(&fixture)!!;
    defer destroy_device_ribbon_scene(&fixture, &target);
    BufferId buffer = attach_device_ribbons(&fixture, &target)!!;
    fixture.renderer.destroy_buffer(buffer)!!;
    fixture.renderer.begin_frame()!!;
    fixture.renderer.render_view(&target.scene, target.camera, target.view)!!;
    fixture.renderer.finish_view(target.view)!!;
    fixture.renderer.end_frame()!!;
    assert(fixture.renderer.stats.dangling_refs == 1);
    check_validation(&fixture.renderer);
}

fn void test_device_ribbons_that_overflow_the_cull_arena_draw_nothing() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, instance_cull_bytes: DEVICE_RIBBON_ARENA_BYTES)!!;
    defer destroy_fixture(&fixture);
    ComputeShaderId stage = add_compute_shader(&fixture, (String)DEVICE_RIBBONS_STAGE[..])!!;
    DeviceRibbonScene target = create_device_ribbon_scene(&fixture)!!;
    defer destroy_device_ribbon_scene(&fixture, &target);
    BufferId buffer = attach_device_ribbons(&fixture, &target)!!;
    render_device_ribbon_frames(
        fixture: &fixture,
        target:  &target,
        stage:   stage,
        buffer:  buffer,
    )!!;
    assert(fixture.renderer.stats.cull_overflows == 1);
    Vec4[] pixels = read_float_target(&fixture, target.image)!!;
    defer free(pixels);
    check_device_segments(pixels, false);
    check_validation(&fixture.renderer);
}
