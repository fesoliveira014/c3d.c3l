module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::ecs;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import std::math;

const uint BILLBOARD_TARGET_SIZE @private = 64;
const float BILLBOARD_VIEW_HEIGHT @private = 4;
const float BILLBOARD_PIXEL_TOLERANCE @private = 0.02f;
const uint BILLBOARD_TEST_CAPACITY @private = 16;
const Vec4 BILLBOARD_WHITE @private = { 1, 1, 1, 1 };

struct BillboardScene @private {
    Scene scene;
    Node* holder;
    Node* node;
    Node*[2] cameras;
    RenderTargetId[2] targets;
    ViewId[2] views;
    MaterialId material;
}

fn void destroy_billboard_scene(Fixture* fixture, BillboardScene* target) @private {
    foreach (view : target.views) {
        if (view.generation) render::destroy_view(&fixture.renderer, view)!!;
    }
    foreach (image : target.targets) {
        if (image.generation) render::destroy_render_target(&fixture.renderer, image)!!;
    }
    scene::destroy_scene(&target.scene);
}

fn BillboardScene? create_billboard_scene(
    Fixture* fixture,
    Billboard[] values,
    BillboardFacing facing = BillboardFacing.CAMERA,
) @private {
    BillboardScene target = { .scene = scene::create_scene(mem, { .max_nodes = 16 }) };
    defer catch destroy_billboard_scene(fixture, &target);
    target.scene.background.color = {};
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.depth_write = false;
    target.material = fixture.assets.add_material(material::basic(common: common))!;
    target.holder = target.scene.add_node()!;
    target.node = target.scene.add_billboards(
        material: target.material,
        capacity: BILLBOARD_TEST_CAPACITY,
        billboards: values,
        facing: facing,
        parent: target.holder,
    )!;
    foreach (index, &camera : target.cameras) {
        *camera = target.scene.add_camera(camera::orthographic(BILLBOARD_VIEW_HEIGHT, 0.1f, 100))!;
        (*camera).local.position = index ? (Vec3){ 5, 0, 0 } : (Vec3){ 0, 0, 5 };
        target.targets[index] = render::create_render_target(
            renderer: &fixture.renderer,
            desc: render::render_target_desc(BILLBOARD_TARGET_SIZE, BILLBOARD_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
        )!;
        ViewDesc desc = render::texture_view_desc(target.targets[index]);
        desc.post.anti_aliasing = AntiAliasing.NONE;
        target.views[index] = render::create_view(&fixture.renderer, desc)!;
    }
    target.scene.update_world();
    target.cameras[1].look_at({});
    target.scene.update_world();
    return target;
}

fn void? render_billboard_frames(
    Fixture* fixture,
    BillboardScene* target,
    uint frames = render::FRAMES_IN_FLIGHT + 1,
    bool both_views = false,
) @private {
    target.scene.update_world();
    for (uint frame = 0; frame < frames; frame++) {
        fixture.renderer.begin_frame()!;
        defer catch render::abort_frame(&fixture.renderer);
        for (uint view = 0; view < (both_views ? 2u : 1u); view++) {
            fixture.renderer.render_view(&target.scene, target.cameras[view], target.views[view])!;
            fixture.renderer.finish_view(target.views[view])!;
        }
        fixture.renderer.end_frame()!;
    }
}

fn Vec4 billboard_pixel(Vec4[] pixels, Vec2 offset = {}) @private {
    uint x = (uint)((float)BILLBOARD_TARGET_SIZE * (0.5f + offset.x / BILLBOARD_VIEW_HEIGHT));
    uint y = (uint)((float)BILLBOARD_TARGET_SIZE * (0.5f - offset.y / BILLBOARD_VIEW_HEIGHT));
    return pixels[y * BILLBOARD_TARGET_SIZE + x];
}

fn void check_billboard_pixel(Vec4 found, Vec4 expected) @private {
    for (uint channel = 0; channel < 4; channel++) {
        assert(math::is_finite(found[channel]));
        assert(math::abs(found[channel] - expected[channel]) <= BILLBOARD_PIXEL_TOLERANCE);
    }
}

fn void test_camera_billboard_faces_two_views() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Billboard[1] values = { scene::BILLBOARD_DEFAULT };
    values[0].size = { 2, 1 };
    BillboardScene target = create_billboard_scene(&fixture, values[..])!!;
    defer destroy_billboard_scene(&fixture, &target);
    BillboardBatch* batch = target.scene.get(target.node, BillboardBatch);
    uint revision = batch.revision;
    render_billboard_frames(fixture: &fixture, target: &target, both_views: true)!!;
    foreach (image : target.targets) {
        Vec4[] pixels = read_float_target(&fixture, image)!!;
        defer free(pixels);
        check_billboard_pixel(billboard_pixel(pixels), BILLBOARD_WHITE);
        check_billboard_pixel(billboard_pixel(pixels, { 0.75f, 0 }), BILLBOARD_WHITE);
        check_billboard_pixel(billboard_pixel(pixels, { 0, 0.75f }), {});
    }
    assert(batch.revision == revision && batch.billboards[0].size == values[0].size);
    render_billboard_frames(
        fixture: &fixture,
        target: &target,
        frames: 1,
        both_views: true,
    )!!;
    assert(fixture.renderer.stats.upload_bytes == 0);
    check_validation(&fixture.renderer);
}

fn void test_billboard_draws_in_a_reflected_view() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Billboard[1] values = { scene::BILLBOARD_DEFAULT };
    values[0].size = { 2, 1 };
    BillboardScene target = create_billboard_scene(&fixture, values[..])!!;
    defer destroy_billboard_scene(&fixture, &target);
    target.cameras[0].local.scale = { -1, 1, 1 };
    render_billboard_frames(&fixture, &target)!!;
    Vec4[] pixels = read_float_target(&fixture, target.targets[0])!!;
    defer free(pixels);
    check_billboard_pixel(billboard_pixel(pixels), BILLBOARD_WHITE);
    check_billboard_pixel(billboard_pixel(pixels, { 0.75f, 0 }), BILLBOARD_WHITE);
    check_billboard_pixel(billboard_pixel(pixels, { 0, 0.75f }), {});
    check_validation(&fixture.renderer);
}

fn void test_directional_billboard_projection_and_fallback() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Billboard[1] values = { scene::BILLBOARD_DEFAULT };
    values[0].size = { 0.5f, 2 };
    values[0].direction = { 1, 0, 0 };
    BillboardScene target = create_billboard_scene(&fixture, values[..], BillboardFacing.DIRECTIONAL)!!;
    defer destroy_billboard_scene(&fixture, &target);
    for (uint variant = 0; variant < 4; variant++) {
        values[0].rotation = variant == 1 ? (float)math::PI / 2 : 0;
        if (variant == 2) values[0].direction = { 0, 0, 1 };
        if (variant == 3) values[0].direction = {};
        target.scene.set_billboards(target.node, values[..])!!;
        render_billboard_frames(&fixture, &target)!!;
        Vec4[] pixels = read_float_target(&fixture, target.targets[0])!!;
        defer free(pixels);
        check_billboard_pixel(billboard_pixel(pixels, { 0.75f, 0 }), variant == 0 ? BILLBOARD_WHITE : (Vec4){});
        check_billboard_pixel(billboard_pixel(pixels, { 0, 0.75f }), variant == 0 ? (Vec4){} : BILLBOARD_WHITE);
    }
    check_validation(&fixture.renderer);
}

fn void test_billboard_sort_and_cull_keep_source_mapping() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Billboard[3] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
    values[0].position.z = 1;
    values[0].color = { 1, 0, 0, 0.5f };
    values[1].color = { 0, 0, 1, 0.5f };
    values[2].position.x = 20;
    values[2].color = { 0, 1, 0, 1 };
    BillboardScene target = create_billboard_scene(&fixture, values[..])!!;
    defer destroy_billboard_scene(&fixture, &target);
    bool[2] modes = { true, false };
    foreach (culling : modes) {
        ViewDesc desc = fixture.renderer.views.get(target.views[0]).desc;
        desc.instance_culling = culling;
        render::configure_view(&fixture.renderer, target.views[0], desc)!!;
        render_billboard_frames(&fixture, &target)!!;
        Vec4[] pixels = read_float_target(&fixture, target.targets[0])!!;
        defer free(pixels);
        check_billboard_pixel(billboard_pixel(pixels), { 0.5f, 0, 0.25f, 0.75f });
        assert(fixture.renderer.stats.instances_tested == 3);
        assert(fixture.renderer.stats.instances_visible == (culling ? 2u : 3u));
    }
    assert(target.scene.get(target.node, BillboardBatch).billboards[0].position.z == 1);
    check_validation(&fixture.renderer);
}

fn void test_billboard_bounds_retain_visible_rotated_corners() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Billboard[1] values = { scene::BILLBOARD_DEFAULT };
    values[0].position.x = 2.3f;
    values[0].size = { 2, 2 };
    values[0].rotation = (float)math::PI / 4;
    BillboardScene target = create_billboard_scene(&fixture, values[..], BillboardFacing.DIRECTIONAL)!!;
    defer destroy_billboard_scene(&fixture, &target);
    render_billboard_frames(&fixture, &target)!!;
    Vec4[] culled = read_float_target(&fixture, target.targets[0])!!;
    defer free(culled);
    ViewDesc desc = fixture.renderer.views.get(target.views[0]).desc;
    desc.instance_culling = false;
    render::configure_view(&fixture.renderer, target.views[0], desc)!!;
    render_billboard_frames(&fixture, &target)!!;
    Vec4[] complete = read_float_target(&fixture, target.targets[0])!!;
    defer free(complete);
    uint visible;
    foreach (index, pixel : complete) {
        check_billboard_pixel(culled[index], pixel);
        if (pixel.x > 0.5f) visible++;
    }
    assert(visible > 0);
    check_validation(&fixture.renderer);
}

fn void test_billboard_material_depth_and_clip() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Billboard[1] values = { scene::BILLBOARD_DEFAULT };
    values[0].size = { 2, 2 };
    BillboardScene target = create_billboard_scene(&fixture, values[..])!!;
    defer destroy_billboard_scene(&fixture, &target);
    MaterialId blue = fixture.assets.add_material(material::basic({ .color = BLUE }))!!;
    Node* box = target.scene.add_mesh(fixture.box, blue)!!;
    box.local.scale = { 4, 4, 1 };
    box.local.position.z = 1;
    for (uint variant = 0; variant < 3; variant++) {
        if (variant > 0) box.local.position.z = -1;
        if (variant == 2) {
            ViewDesc desc = fixture.renderer.views.get(target.views[0]).desc;
            desc.clip_plane = { .normal = { 1, 0, 0 } };
            render::configure_view(&fixture.renderer, target.views[0], desc)!!;
        }
        render_billboard_frames(&fixture, &target)!!;
        Vec4[] pixels = read_float_target(&fixture, target.targets[0])!!;
        defer free(pixels);
        check_billboard_pixel(billboard_pixel(pixels, { 0.4f, 0 }), variant == 0 ? BLUE : BILLBOARD_WHITE);
        if (variant == 2) check_billboard_pixel(billboard_pixel(pixels, { -0.4f, 0 }), {});
    }
    check_validation(&fixture.renderer);
}

fn void test_billboard_additive_preserves_alpha() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Billboard[2] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
    foreach (&value : values) value.color = { 0.2f, 0.1f, 0, 0.5f };
    BillboardScene target = create_billboard_scene(&fixture, values[..])!!;
    defer destroy_billboard_scene(&fixture, &target);
    target.scene.background.color = { 0.1f, 0.1f, 0.1f, 0.4f };
    BlendMode[2] modes = { ADDITIVE, PREMULTIPLIED_ALPHA };
    foreach (mode : modes) {
        fixture.assets.material(target.material).data.common.blend_mode = mode;
        fixture.assets.mark_material_dirty(target.material);
        render_billboard_frames(&fixture, &target)!!;
        Vec4[] pixels = read_float_target(&fixture, target.targets[0])!!;
        defer free(pixels);
        Vec4 expected = mode == ADDITIVE ? (Vec4){ 0.3f, 0.2f, 0.1f, 0.4f } : (Vec4){ 0.175f, 0.1f, 0.025f, 0.85f };
        check_billboard_pixel(billboard_pixel(pixels), expected);
    }
    check_validation(&fixture.renderer);
}

fn void test_empty_and_zero_area_billboards_do_no_visible_work() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    BillboardScene target = create_billboard_scene(&fixture, {})!!;
    defer destroy_billboard_scene(&fixture, &target);
    render_billboard_frames(&fixture, &target)!!;
    assert(fixture.renderer.stats.indirect_draws == 0 && fixture.renderer.stats.scene_snapshots == 0);
    assert(fixture.renderer.stats.sort_dispatches == 0 && fixture.renderer.stats.cull_dispatches == 0);
    assert(!fixture.renderer.billboard_geometry.allocation.is_valid());
    Billboard[2] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
    values[0].size.x = 0;
    values[1].size.y = 0;
    values[0].direction = {};
    target.scene.set_billboards(target.node, values[..])!!;
    render_billboard_frames(&fixture, &target)!!;
    Vec4[] blank = read_float_target(&fixture, target.targets[0])!!;
    defer free(blank);
    foreach (pixel : blank) check_billboard_pixel(pixel, {});
    values[0] = scene::BILLBOARD_DEFAULT;
    target.scene.set_billboards(target.node, values[:1])!!;
    render_billboard_frames(&fixture, &target)!!;
    Vec4[] visible = read_float_target(&fixture, target.targets[0])!!;
    defer free(visible);
    check_billboard_pixel(billboard_pixel(visible), BILLBOARD_WHITE);
    check_validation(&fixture.renderer);
}

fn void test_billboard_material_compatibility_and_lifecycle() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Billboard[1] values = { scene::BILLBOARD_DEFAULT };
    BillboardScene target = create_billboard_scene(&fixture, values[..])!!;
    defer destroy_billboard_scene(&fixture, &target);
    MaterialId custom_vertex;
    MaterialId custom_fragment;
    @pool() {
        custom_vertex = add_sort_order_material(&fixture)!!;
        custom_fragment = add_custom_material_blend(&fixture, BLUE)!!;
    };
    MaterialCommon masked_common = material::MATERIAL_COMMON_DEFAULT;
    masked_common.alpha_mode = MASK;
    MaterialId masked = fixture.assets.add_material(material::basic(common: masked_common))!!;
    PhysicalParams transmission = material::PHYSICAL_PARAMS_DEFAULT;
    transmission.transmission = 1;
    MaterialId transmissive = fixture.assets.add_material(material::physical(transmission))!!;
    MaterialId[5] unsupported = { fixture.plain, masked, transmissive, {}, custom_vertex };
    foreach (material_id : unsupported) {
        target.scene.get(target.node, BillboardBatch).material = material_id;
        target.scene.mark_billboards_dirty(target.node);
        render_billboard_frames(&fixture, &target)!!;
        assert(fixture.renderer.stats.dangling_refs == 1);
        Vec4[] pixels = read_float_target(&fixture, target.targets[0])!!;
        defer free(pixels);
        check_billboard_pixel(billboard_pixel(pixels), {});
    }
    target.scene.get(target.node, BillboardBatch).material = custom_fragment;
    target.scene.mark_billboards_dirty(target.node);
    render_billboard_frames(&fixture, &target)!!;
    Vec4[] custom = read_float_target(&fixture, target.targets[0])!!;
    defer free(custom);
    check_billboard_pixel(billboard_pixel(custom), { 0, 0, 1, 0 });
    Entity old = target.node.id;
    InstanceKey old_key = { .scene = target.scene.identity, .node = old, .kind = shader::INSTANCE_KIND_BILLBOARD };
    target.scene.remove(target.holder);
    render_billboard_frames(&fixture, &target, (uint)render::INSTANCE_ABSENCE_FRAMES + 1)!!;
    assert(!fixture.renderer.instances.lookup.has_key(old_key));
    target.holder = target.scene.add_node()!!;
    target.node = target.scene.add_billboards(
        material: target.material,
        capacity: BILLBOARD_TEST_CAPACITY,
        billboards: values[..],
        parent: target.holder,
    )!!;
    assert(target.node.id.index == old.index && target.node.id.generation != old.generation);
    render_billboard_frames(&fixture, &target)!!;
    Vec4[] replaced = read_float_target(&fixture, target.targets[0])!!;
    defer free(replaced);
    check_billboard_pixel(billboard_pixel(replaced), BILLBOARD_WHITE);
    check_validation(&fixture.renderer);
}

fn void test_billboard_aborted_upload_is_retried() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Billboard[1] values = { scene::BILLBOARD_DEFAULT };
    BillboardScene target = create_billboard_scene(&fixture, values[..])!!;
    defer destroy_billboard_scene(&fixture, &target);
    fixture.renderer.begin_frame()!!;
    fixture.renderer.render_view(&target.scene, target.cameras[0], target.views[0])!!;
    assert(fixture.renderer.billboard_geometry.revision != 0);
    render::abort_frame(&fixture.renderer);
    assert(fixture.renderer.billboard_geometry.revision == 0);
    InstanceKey key = {
        .scene = target.scene.identity,
        .node = target.node.id,
        .kind = shader::INSTANCE_KIND_BILLBOARD,
    };
    uint slot = fixture.renderer.instances.lookup.get(key)!!;
    assert(fixture.renderer.instances.slots[slot].revision == 0);
    render_billboard_frames(&fixture, &target)!!;
    Vec4[] pixels = read_float_target(&fixture, target.targets[0])!!;
    defer free(pixels);
    check_billboard_pixel(billboard_pixel(pixels), BILLBOARD_WHITE);
    check_validation(&fixture.renderer);
}
