module c3d::render::acceptance;

import c3d;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::io;
import std::math;

const uint GI_TARGET_WIDTH @private = 256;
const uint GI_TARGET_HEIGHT @private = 192;
const ShadingPath[2] GI_PATHS @private = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
const Vec3 GI_CAMERA_POSITION @private = { 0, 3, 5 };
const Vec3 GI_CAMERA_TARGET @private = { 0, 0, 0 };
const Vec3 EDGE_CAMERA_POSITION @private = { 0, 0.4f, 3 };  // low, so the cube stands against the wall
const Vec3 EDGE_CAMERA_TARGET @private = { 0, 0.3f, -2.75f };
const float GI_FLOOR_ALBEDO @private = 0.5f;
const float GI_AMBIENT @private = 0.05f;
const Vec3 CUBE_SIZE @private = { 0.5f, 0.5f, 0.5f };
const Vec3 CUBE_EMISSION @private = { 1, 0, 0 };
const float CUBE_STRENGTH @private = 4;
const Vec3 CUBE_PLACE @private = { 0, 0.25f, 0 };
const Vec3 CUBE_MOVED_PLACE @private = { -3, 0.25f, 0 };  // beyond max_distance of the old place
const Vec3 BESIDE_CUBE @private = { 0.45f, 0, 0 };
const Vec3 BESIDE_MOVED_CUBE @private = { -2.55f, 0, 0 };
const Vec3 FAR_FROM_CUBE @private = { -2.5f, 0, -1 };
const Vec3 WALL_CENTER @private = { 0, 1, -2.75f };
const Vec3 WALL_SIZE @private = { 8, 2, 0.1f };
const Vec3 WALL_BESIDE_SILHOUETTE @private = { 0.62f, 0.3f, -2.7f };
const uint SSGI_SETTLE_FRAMES @private = 60;       // 0.9^60 leaves 0.2 percent of a stale history
const int HALO_MIN @private = 4;                   // red levels the bounce must add beside the cube
const int FAR_TOLERANCE @private = 1;
const int EDGE_TOLERANCE @private = 2;
const int MOVE_TOLERANCE @private = 2;
const float CORNER_ALBEDO @private = 0.8f;
const Vec3 CORNER_LIGHT @private = { -0.5f, 0.6f, -0.5f };
const float CORNER_LIGHT_INTENSITY @private = 0.3f;
const Vec3[4] CORNER_POINTS @private = {
    { -0.7f, 0, -0.7f },
    { -0.4f, 0, -0.4f },
    { -0.95f, 0.4f, -0.3f },
    { -0.3f, 0.4f, -0.95f },
};
const uint FEEDBACK_FIRST @private = 250;
const uint FEEDBACK_SECOND @private = 300;
const float FEEDBACK_TOLERANCE @private = 0.02f;   // relative change of the region mean over 50 frames

struct GiScene @private {
    Scene scene;
    Node* camera;
    Node* cube;
    Node* wall;
}

fn int pixel_channel(uint pixel, uint channel) @private {
    return (int)((pixel >> (8 * channel)) & 0xff);
}

fn GiScene? create_gi_scene(
    Fixture* fixture,
    bool wall = false,
    Vec3 camera_position = GI_CAMERA_POSITION,
    Vec3 camera_target = GI_CAMERA_TARGET,
) @private {
    GiScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_color = { 1, 1, 1 };
    result.scene.ambient_intensity = GI_AMBIENT;

    GeometryId floor;
    GeometryId unit_box;
    @pool() {
        Geometry plane = geometry::plane(tmem, 10, 10);
        floor = fixture.assets.add_geometry(&plane)!;
        Geometry box = geometry::box(tmem, 1, 1, 1);
        unit_box = fixture.assets.add_geometry(&box)!;
    };
    StandardParams grey = material::STANDARD_PARAMS_DEFAULT;
    grey.base_color = { GI_FLOOR_ALBEDO, GI_FLOOR_ALBEDO, GI_FLOOR_ALBEDO, 1 };
    grey.roughness = 1;
    grey.metallic = 0;
    MaterialId surface = fixture.assets.add_material(material::standard(grey))!;
    StandardParams glowing = material::STANDARD_PARAMS_DEFAULT;
    glowing.base_color = { 0, 0, 0, 1 };
    glowing.roughness = 1;
    glowing.metallic = 0;
    glowing.emissive = CUBE_EMISSION;
    glowing.emissive_strength = CUBE_STRENGTH;
    MaterialId emissive = fixture.assets.add_material(material::standard(glowing))!;

    result.scene.add_mesh(floor, surface, name: "floor")!;
    result.cube = result.scene.add_mesh(unit_box, emissive, name: "cube")!;
    result.cube.local.position = CUBE_PLACE;
    result.cube.local.scale = CUBE_SIZE;
    if (wall) {
        result.wall = result.scene.add_mesh(unit_box, surface, name: "wall")!;
        result.wall.local.position = WALL_CENTER;
        result.wall.local.scale = WALL_SIZE;
    }
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.camera.local.position = camera_position;
    result.camera.local.rotation = maths::look_rotation((camera_target - camera_position).normalize(), { 0, 1, 0 });
    result.scene.update_world();
    return result;
}

fn GiScene? create_corner_scene(Fixture* fixture) @private {
    GiScene result = create_gi_scene(fixture)!;
    defer catch scene::destroy_scene(&result.scene);
    result.cube.visible = false;
    GeometryId unit_box;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        unit_box = fixture.assets.add_geometry(&box)!;
    };
    StandardParams pale = material::STANDARD_PARAMS_DEFAULT;
    pale.base_color = { CORNER_ALBEDO, CORNER_ALBEDO, CORNER_ALBEDO, 1 };
    pale.roughness = 1;
    pale.metallic = 0;
    MaterialId surface = fixture.assets.add_material(material::standard(pale))!;
    Node* side = result.scene.add_mesh(unit_box, surface, name: "side_wall")!;
    side.local.position = { -1.05f, 0.75f, 0 };
    side.local.scale = { 0.1f, 1.5f, 3 };
    Node* back = result.scene.add_mesh(unit_box, surface, name: "back_wall")!;
    back.local.position = { 0, 0.75f, -1.05f };
    back.local.scale = { 3, 1.5f, 0.1f };
    Node* lamp = result.scene.add_light(light::point({ 1, 1, 1 }, CORNER_LIGHT_INTENSITY, 4), name: "lamp")!;
    lamp.local.position = CORNER_LIGHT;
    result.scene.update_world();
    return result;
}

fn float corner_mean(Fixture* fixture, GiScene* gi, ViewId view) @private {
    float sum;
    foreach (point : CORNER_POINTS) {
        uint pixel = render_gi_pixel(fixture, gi, view, point)!!;
        for (uint channel = 0; channel < 3; channel++) sum += (float)pixel_channel(pixel, channel);
    }
    return sum / (float)(CORNER_POINTS.len * 3);
}

fn ViewId? create_gi_view(
    Fixture* fixture,
    RenderTargetId target,
    ShadingPath shading,
    bool screen_space_gi,
    bool depth_prepass = true,
    float history_weight = render::SCREEN_SPACE_GI_DEFAULT.history_weight,
) @private {
    ViewDesc desc = render::texture_view_desc(target);
    desc.shading = shading;
    desc.depth_prepass = depth_prepass;
    if (screen_space_gi) {
        desc.screen_space_gi = render::SCREEN_SPACE_GI_DEFAULT;
        desc.screen_space_gi.history_weight = history_weight;
    }
    return render::create_view(&fixture.renderer, desc);
}

fn Vec2 project_gi_uv(GiScene* gi, Vec3 point) @private {
    Camera* camera = gi.scene.get(gi.camera, Camera);
    Vec2 viewport = { GI_TARGET_WIDTH, GI_TARGET_HEIGHT };
    CameraMatrices matrices = camera::derive_matrices(*camera, gi.camera.world, viewport);
    Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
    return { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f };
}

fn uint? render_gi_pixel(Fixture* fixture, GiScene* gi, ViewId view, Vec3 point) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&gi.scene, gi.camera, view)!;
    sample(fixture, render::read_view_color(view), project_gi_uv(gi, point))!;
    record_readback(fixture)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn void? render_gi_frames(Fixture* fixture, GiScene* gi, ViewId view, uint frames) @private {
    for (uint frame = 0; frame < frames; frame++) {
        fixture.renderer.begin_frame()!;
        defer catch render::abort_frame(&fixture.renderer);
        fixture.renderer.render_view(&gi.scene, gi.camera, view)!;
        fixture.renderer.finish_view(view)!;
        fixture.renderer.end_frame()!;
    }
}

struct GiViews @private {
    RenderTargetId target;
    ViewId         with_gi;
    ViewId         without_gi;
}

fn GiViews? create_gi_views(Fixture* fixture, ShadingPath shading, bool depth_prepass = true) @private {
    GiViews views;
    views.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(GI_TARGET_WIDTH, GI_TARGET_HEIGHT),
    )!;
    views.with_gi = create_gi_view(fixture, views.target, shading, true, depth_prepass)!;
    views.without_gi = create_gi_view(fixture, views.target, shading, false)!;
    return views;
}

fn void destroy_gi_views(Fixture* fixture, GiViews* views) @private {
    render::destroy_view(&fixture.renderer, views.with_gi)!!;
    render::destroy_view(&fixture.renderer, views.without_gi)!!;
    render::destroy_render_target(&fixture.renderer, views.target)!!;
}

fn void test_ssgi_adds_a_tinted_halo_beside_a_bright_object() @test {
    foreach (shading : GI_PATHS) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        GiScene gi = create_gi_scene(&fixture)!!;
        defer scene::destroy_scene(&gi.scene);
        GiViews views = create_gi_views(&fixture, shading)!!;
        defer destroy_gi_views(&fixture, &views);

        render_gi_frames(&fixture, &gi, views.with_gi, SSGI_SETTLE_FRAMES)!!;
        uint halo = render_gi_pixel(&fixture, &gi, views.with_gi, BESIDE_CUBE)!!;
        uint far = render_gi_pixel(&fixture, &gi, views.with_gi, FAR_FROM_CUBE)!!;
        uint plain = render_gi_pixel(&fixture, &gi, views.without_gi, BESIDE_CUBE)!!;
        uint plain_far = render_gi_pixel(&fixture, &gi, views.without_gi, FAR_FROM_CUBE)!!;
        io::eprintfn(
            "%s halo: beside %08x without %08x; far %08x without %08x",
            shading, halo, plain, far, plain_far,
        );
        assert(pixel_channel(halo, 0) - pixel_channel(plain, 0) > HALO_MIN);
        assert(pixel_channel(halo, 0) > pixel_channel(halo, 1));
        for (uint channel = 0; channel < 3; channel++) {
            assert(math::abs(pixel_channel(far, channel) - pixel_channel(plain_far, channel)) <= FAR_TOLERANCE);
        }
        check_validation(&fixture.renderer);
    }
}

fn void test_ssgi_does_not_bleed_across_a_depth_edge() @test {
    foreach (shading : GI_PATHS) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        GiScene gi = create_gi_scene(
            fixture:         &fixture,
            wall:            true,
            camera_position: EDGE_CAMERA_POSITION,
            camera_target:   EDGE_CAMERA_TARGET,
        )!!;
        defer scene::destroy_scene(&gi.scene);
        GiViews views = create_gi_views(&fixture, shading)!!;
        defer destroy_gi_views(&fixture, &views);

        render_gi_frames(&fixture, &gi, views.with_gi, SSGI_SETTLE_FRAMES)!!;
        uint wall = render_gi_pixel(&fixture, &gi, views.with_gi, WALL_BESIDE_SILHOUETTE)!!;
        uint plain = render_gi_pixel(&fixture, &gi, views.without_gi, WALL_BESIDE_SILHOUETTE)!!;
        io::eprintfn("%s edge: wall %08x without %08x", shading, wall, plain);
        for (uint channel = 0; channel < 3; channel++) {
            assert(math::abs(pixel_channel(wall, channel) - pixel_channel(plain, channel)) <= EDGE_TOLERANCE);
        }
        check_validation(&fixture.renderer);
    }
}

fn void test_ssgi_follows_a_moved_object() @test {
    foreach (shading : GI_PATHS) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        GiScene gi = create_gi_scene(&fixture)!!;
        defer scene::destroy_scene(&gi.scene);
        GiViews views = create_gi_views(&fixture, shading)!!;
        defer destroy_gi_views(&fixture, &views);
        // Without accumulation the first frame after the move shows the raw bounce the hit's velocity finds.
        ViewId unaccumulated = create_gi_view(&fixture, views.target, shading, true, history_weight: 0)!!;
        defer render::destroy_view(&fixture.renderer, unaccumulated)!!;

        render_gi_frames(&fixture, &gi, views.with_gi, SSGI_SETTLE_FRAMES)!!;
        render_gi_frames(&fixture, &gi, unaccumulated, SSGI_SETTLE_FRAMES)!!;
        uint settled = render_gi_pixel(&fixture, &gi, views.with_gi, BESIDE_CUBE)!!;
        gi.cube.local.position = CUBE_MOVED_PLACE;
        gi.scene.update_world();
        uint new_place = render_gi_pixel(&fixture, &gi, unaccumulated, BESIDE_MOVED_CUBE)!!;
        uint old_place = render_gi_pixel(&fixture, &gi, views.with_gi, BESIDE_CUBE)!!;
        uint plain_new = render_gi_pixel(&fixture, &gi, views.without_gi, BESIDE_MOVED_CUBE)!!;
        render_gi_frames(&fixture, &gi, views.with_gi, SSGI_SETTLE_FRAMES)!!;
        uint old_settled = render_gi_pixel(&fixture, &gi, views.with_gi, BESIDE_CUBE)!!;
        uint new_settled = render_gi_pixel(&fixture, &gi, views.with_gi, BESIDE_MOVED_CUBE)!!;
        uint plain_old = render_gi_pixel(&fixture, &gi, views.without_gi, BESIDE_CUBE)!!;
        io::eprintfn(
            "%s moved: settled %08x; after the move new %08x (without %08x) old %08x; "
            "later old %08x (without %08x) new %08x",
            shading, settled, new_place, plain_new, old_place, old_settled, plain_old, new_settled,
        );
        assert(pixel_channel(new_place, 0) - pixel_channel(plain_new, 0) > HALO_MIN);
        assert(pixel_channel(old_place, 0) < pixel_channel(settled, 0));
        for (uint channel = 0; channel < 3; channel++) {
            int difference = pixel_channel(old_settled, channel) - pixel_channel(plain_old, channel);
            assert(math::abs(difference) <= MOVE_TOLERANCE);
        }
        assert(pixel_channel(new_settled, 0) - pixel_channel(plain_new, 0) > HALO_MIN);
        check_validation(&fixture.renderer);
    }
}

fn void test_ssgi_camera_cut_clears_the_term() @test {
    foreach (shading : GI_PATHS) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        GiScene gi = create_gi_scene(&fixture)!!;
        defer scene::destroy_scene(&gi.scene);
        GiViews views = create_gi_views(&fixture, shading)!!;
        defer destroy_gi_views(&fixture, &views);

        render_gi_frames(&fixture, &gi, views.with_gi, SSGI_SETTLE_FRAMES)!!;
        render::reset_view_history(&fixture.renderer, views.with_gi)!!;
        uint cut = render_gi_pixel(&fixture, &gi, views.with_gi, BESIDE_CUBE)!!;
        uint plain = render_gi_pixel(&fixture, &gi, views.without_gi, BESIDE_CUBE)!!;
        render_gi_frames(&fixture, &gi, views.with_gi, SSGI_SETTLE_FRAMES)!!;
        uint back = render_gi_pixel(&fixture, &gi, views.with_gi, BESIDE_CUBE)!!;
        io::eprintfn("%s cut: after the cut %08x without %08x; later %08x", shading, cut, plain, back);
        for (uint channel = 0; channel < 3; channel++) {
            assert(math::abs(pixel_channel(cut, channel) - pixel_channel(plain, channel)) <= FAR_TOLERANCE);
        }
        assert(pixel_channel(back, 0) - pixel_channel(plain, 0) > HALO_MIN);
        check_validation(&fixture.renderer);
    }
}

fn void test_ssgi_forces_the_forward_prepass() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    GiScene gi = create_gi_scene(&fixture)!!;
    defer scene::destroy_scene(&gi.scene);
    GiViews views = create_gi_views(&fixture, ShadingPath.FORWARD, depth_prepass: false)!!;
    defer destroy_gi_views(&fixture, &views);

    assert(fixture.renderer.has_depth_prepass_view());
    render_gi_frames(&fixture, &gi, views.with_gi, SSGI_SETTLE_FRAMES)!!;
    uint halo = render_gi_pixel(&fixture, &gi, views.with_gi, BESIDE_CUBE)!!;
    uint plain = render_gi_pixel(&fixture, &gi, views.without_gi, BESIDE_CUBE)!!;
    io::eprintfn("forced prepass: beside %08x without %08x", halo, plain);
    assert(pixel_channel(halo, 0) - pixel_channel(plain, 0) > HALO_MIN);
    check_validation(&fixture.renderer);
}

fn void test_ssgi_feedback_stays_bounded() @test {
    foreach (shading : GI_PATHS) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        GiScene gi = create_corner_scene(&fixture)!!;
        defer scene::destroy_scene(&gi.scene);
        GiViews views = create_gi_views(&fixture, shading)!!;
        defer destroy_gi_views(&fixture, &views);

        render_gi_frames(&fixture, &gi, views.with_gi, FEEDBACK_FIRST - (uint)CORNER_POINTS.len)!!;
        float first = corner_mean(&fixture, &gi, views.with_gi);
        render_gi_frames(&fixture, &gi, views.with_gi, FEEDBACK_SECOND - FEEDBACK_FIRST - (uint)CORNER_POINTS.len)!!;
        float second = corner_mean(&fixture, &gi, views.with_gi);
        float plain = corner_mean(&fixture, &gi, views.without_gi);
        io::eprintfn(
            "%s feedback: mean %f after %d frames, %f after %d; without %f",
            shading, first, FEEDBACK_FIRST, second, FEEDBACK_SECOND, plain,
        );
        assert(first > plain);
        assert(math::abs(second - first) <= FEEDBACK_TOLERANCE * first);
        check_validation(&fixture.renderer);
    }
}
