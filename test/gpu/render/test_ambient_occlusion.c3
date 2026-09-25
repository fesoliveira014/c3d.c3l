module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::io;
import std::math;

const uint AO_TARGET_WIDTH @private = 128;
const uint AO_TARGET_HEIGHT @private = 96;
const Vec3 CREASE_POINT @private = { 1, 0, -1.95f }; // on the floor 5 cm from the wall, clear of the quad
const Vec3 OPEN_POINT @private = { 1, 0, -0.5f };    // three radii from the wall
const Vec3 QUAD_POINT @private = { 0, 0.3f, -1.69f };
const Vec3 MASKED_TOP_POINT @private = { -1, 0.5f, -1 };
const Vec3 CUT_POINT @private = { -1, 0.5f, -0.3f };
const Vec3 CREASE_CAMERA_POSITION @private = { 0, 1.5f, 1 };
const Vec3 CREASE_CAMERA_TARGET @private = { 0, 0.25f, -2 };
const float LIT_ALBEDO @private = 0.8f;
const float CREASE_RATIO_MAXIMUM @private = 0.9f;
const float OPEN_RATIO_MINIMUM @private = 0.97f;
const int UNOCCLUDED_TOLERANCE @private = 2;
const int SHADING_PATH_TOLERANCE @private = 3;

struct CreaseScene @private {
    Scene  scene;
    ViewId view;
    Node*  camera;
    Node*  floor;
    Node*  quad;
    Node*  masked_box;
    Node*  cut_box;
    Node*  sun;
}

struct AoView @private {
    RenderTargetId target;
    ViewId         view;
}

fn CreaseScene? create_crease_scene(Fixture* fixture) @private {
    CreaseScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_color = { 1, 1, 1 };
    result.scene.ambient_intensity = 1;

    GeometryId floor;
    GeometryId wall;
    GeometryId quad;
    GeometryId small_box;
    @pool() {
        Geometry plane = geometry::plane(tmem, 10, 10);
        floor = fixture.assets.add_geometry(&plane)!;
        Geometry wall_box = geometry::box(tmem, 10, 4, 0.5f);
        wall = fixture.assets.add_geometry(&wall_box)!;
        Geometry quad_box = geometry::box(tmem, 0.6f, 0.6f, 0.02f);
        quad = fixture.assets.add_geometry(&quad_box)!;
        Geometry masked = geometry::box(tmem, 0.5f, 0.5f, 0.5f);
        small_box = fixture.assets.add_geometry(&masked)!;
    };
    StandardParams grey = { .base_color = { LIT_ALBEDO, LIT_ALBEDO, LIT_ALBEDO, 1 }, .roughness = 1 };
    MaterialId surface = fixture.assets.add_material(material::standard(grey))!;
    MaterialCommon blended = material::MATERIAL_COMMON_DEFAULT;
    blended.alpha_mode = AlphaMode.BLEND;
    MaterialId glass = fixture.assets.add_material(material::standard(params: grey, common: blended))!;
    MaterialCommon cutout = material::MATERIAL_COMMON_DEFAULT;
    cutout.alpha_mode = AlphaMode.MASK;
    cutout.alpha_cutoff = 0.5f;
    MaterialId kept = fixture.assets.add_material(material::standard(params: grey, common: cutout))!;
    StandardParams clear = grey;
    clear.base_color.a = 0;
    MaterialId removed = fixture.assets.add_material(material::standard(params: clear, common: cutout))!;

    result.floor = result.scene.add_mesh(floor, surface, name: "floor")!;
    Node* wall_node = result.scene.add_mesh(wall, surface, name: "wall")!;
    wall_node.local.position = { 0, 2, -2.25f };
    result.quad = result.scene.add_mesh(quad, glass, name: "quad")!;
    result.quad.local.position = { 0, 0.3f, -1.7f };
    result.quad.visible = false;
    result.masked_box = result.scene.add_mesh(small_box, kept, name: "masked_box")!;
    result.masked_box.local.position = { -1, 0.25f, -1 };
    result.masked_box.visible = false;
    result.cut_box = result.scene.add_mesh(small_box, removed, name: "cut_box")!;
    result.cut_box.local.position = { -1, 0.25f, -0.3f };
    result.cut_box.visible = false;
    result.sun = result.scene.add_light(light::directional({ 1, 1, 1 }, 1, shadow: false), name: "sun")!;
    result.sun.local.rotation = maths::look_rotation({ 0.3f, -1, -0.4f }, { 0, 0, -1 });
    result.sun.visible = false;

    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.camera.local.position = CREASE_CAMERA_POSITION;
    result.camera.local.rotation = maths::look_rotation(
        (CREASE_CAMERA_TARGET - CREASE_CAMERA_POSITION).normalize(),
        { 0, 1, 0 },
    );
    result.scene.update_world();
    return result;
}

fn AoView? create_ao_view(Fixture* fixture, ShadingPath shading) @private {
    AoView result;
    result.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(AO_TARGET_WIDTH, AO_TARGET_HEIGHT),
    )!;
    ViewDesc desc = render::texture_view_desc(result.target);
    desc.shading = shading;
    result.view = render::create_view(&fixture.renderer, desc)!;
    return result;
}

fn void destroy_ao_view(Fixture* fixture, AoView* ao_view) @private {
    render::destroy_view(&fixture.renderer, ao_view.view)!!;
    render::destroy_render_target(&fixture.renderer, ao_view.target)!!;
}

fn void? set_ambient_occlusion(Fixture* fixture, ViewId view, AmbientOcclusionDesc ambient_occlusion) @private {
    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.ambient_occlusion = ambient_occlusion;
    return render::configure_view(&fixture.renderer, view, desc);
}

fn void? set_depth_prepass(Fixture* fixture, ViewId view, bool enabled) @private {
    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.depth_prepass = enabled;
    return render::configure_view(&fixture.renderer, view, desc);
}

fn Vec2 project_crease_uv(CreaseScene* crease, Vec3 point) @private {
    Camera* camera = crease.scene.get(crease.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(
        *camera,
        crease.camera.world,
        { AO_TARGET_WIDTH, AO_TARGET_HEIGHT },
    );
    Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
    return { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f };
}

fn uint? render_and_read(Fixture* fixture, CreaseScene* crease, Vec3 point) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&crease.scene, crease.camera, crease.view)!;
    sample(fixture, render::read_view_color(crease.view), project_crease_uv(crease, point))!;
    record_readback(fixture)!;
    renderer.finish_view(crease.view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn int red(uint pixel) @private {
    return (int)(pixel & 0xff);
}

fn void test_ambient_occlusion_images_follow_the_settings() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    CreaseScene crease = create_crease_scene(&fixture)!!;
    defer scene::destroy_scene(&crease.scene);
    AoView ao_view = create_ao_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_ao_view(&fixture, &ao_view);
    crease.view = ao_view.view;
    ViewRecord* record = fixture.renderer.views.get(ao_view.view);

    set_ambient_occlusion(&fixture, ao_view.view, render::AMBIENT_OCCLUSION_DEFAULT)!!;
    assert(record.ao_raw.texture.is_valid() && record.ao.texture.is_valid());
    assert(record.ao_raw.width == AO_TARGET_WIDTH / 2 && record.ao_raw.height == AO_TARGET_HEIGHT / 2);
    assert(record.ao.width == AO_TARGET_WIDTH && record.ao.height == AO_TARGET_HEIGHT);

    AmbientOcclusionDesc full = render::AMBIENT_OCCLUSION_DEFAULT;
    full.full_resolution = true;
    set_ambient_occlusion(&fixture, ao_view.view, full)!!;
    assert(record.ao_raw.width == AO_TARGET_WIDTH && record.ao_raw.height == AO_TARGET_HEIGHT);
    assert(record.ao.width == AO_TARGET_WIDTH && record.ao.height == AO_TARGET_HEIGHT);

    set_ambient_occlusion(&fixture, ao_view.view, {})!!;
    assert(!record.ao_raw.texture.is_valid() && !record.ao.texture.is_valid());

    set_ambient_occlusion(&fixture, ao_view.view, render::AMBIENT_OCCLUSION_DEFAULT)!!;
    assert(record.ao_raw.texture.is_valid() && record.ao.texture.is_valid());
    (void)render_and_read(&fixture, &crease, OPEN_POINT)!!;
    check_validation(&fixture.renderer);
}

fn void test_gtao_darkens_a_crease_and_leaves_open_floor() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    CreaseScene crease = create_crease_scene(&fixture)!!;
    defer scene::destroy_scene(&crease.scene);

    int unoccluded = (int)(LIT_ALBEDO * 255 + 0.5f);
    int[2] open_values;
    ShadingPath[2] paths = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
    foreach (index, shading : paths) {
        AoView ao_view = create_ao_view(&fixture, shading)!!;
        defer destroy_ao_view(&fixture, &ao_view);
        crease.view = ao_view.view;

        int crease_none = red(render_and_read(&fixture, &crease, CREASE_POINT)!!);
        int open_none = red(render_and_read(&fixture, &crease, OPEN_POINT)!!);
        set_ambient_occlusion(&fixture, ao_view.view, render::AMBIENT_OCCLUSION_DEFAULT)!!;
        int crease_ao = red(render_and_read(&fixture, &crease, CREASE_POINT)!!);
        int open_ao = red(render_and_read(&fixture, &crease, OPEN_POINT)!!);
        io::eprintfn("%s: crease %d -> %d, open %d -> %d", shading, crease_none, crease_ao, open_none, open_ao);

        assert(math::abs(crease_none - unoccluded) <= UNOCCLUDED_TOLERANCE);
        assert(math::abs(open_none - unoccluded) <= UNOCCLUDED_TOLERANCE);
        assert((float)crease_ao < CREASE_RATIO_MAXIMUM * (float)crease_none);
        assert((float)open_ao > OPEN_RATIO_MINIMUM * (float)open_none);
        open_values[index] = open_ao;
    }
    assert(math::abs(open_values[0] - open_values[1]) <= SHADING_PATH_TOLERANCE);
    check_validation(&fixture.renderer);
}

fn void test_zero_intensity_matches_no_ambient_occlusion() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    CreaseScene crease = create_crease_scene(&fixture)!!;
    defer scene::destroy_scene(&crease.scene);
    crease.masked_box.visible = true;
    crease.cut_box.visible = true;
    crease.sun.visible = true;
    crease.scene.update_world();
    AoView ao_view = create_ao_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_ao_view(&fixture, &ao_view);
    crease.view = ao_view.view;

    Vec3[4] points = { CREASE_POINT, OPEN_POINT, MASKED_TOP_POINT, CUT_POINT };
    uint[4] without;
    foreach (index, point : points) without[index] = render_and_read(&fixture, &crease, point)!!;
    AmbientOcclusionDesc silent = render::AMBIENT_OCCLUSION_DEFAULT;
    silent.intensity = 0;
    set_ambient_occlusion(&fixture, ao_view.view, silent)!!;
    foreach (index, point : points) {
        uint with = render_and_read(&fixture, &crease, point)!!;
        for (uint channel = 0; channel < 3; channel++) {
            int before = (int)((without[index] >> (8 * channel)) & 0xff);
            int after = (int)((with >> (8 * channel)) & 0xff);
            assert(math::abs(before - after) <= CHANNEL_TOLERANCE);
        }
    }
    check_validation(&fixture.renderer);
}

fn void test_blend_draws_skip_ambient_occlusion() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    CreaseScene crease = create_crease_scene(&fixture)!!;
    defer scene::destroy_scene(&crease.scene);
    crease.quad.visible = true;
    crease.scene.update_world();
    AoView ao_view = create_ao_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_ao_view(&fixture, &ao_view);
    crease.view = ao_view.view;

    int quad_none = red(render_and_read(&fixture, &crease, QUAD_POINT)!!);
    int crease_none = red(render_and_read(&fixture, &crease, CREASE_POINT)!!);
    set_ambient_occlusion(&fixture, ao_view.view, render::AMBIENT_OCCLUSION_DEFAULT)!!;
    int quad_ao = red(render_and_read(&fixture, &crease, QUAD_POINT)!!);
    int crease_ao = red(render_and_read(&fixture, &crease, CREASE_POINT)!!);
    io::eprintfn("quad %d -> %d, crease %d -> %d", quad_none, quad_ao, crease_none, crease_ao);

    assert(math::abs(quad_none - quad_ao) <= CHANNEL_TOLERANCE);
    assert((float)crease_ao < CREASE_RATIO_MAXIMUM * (float)crease_none);
    check_validation(&fixture.renderer);
}

fn void test_forward_depth_prepass_matches_the_single_pass() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    CreaseScene crease = create_crease_scene(&fixture)!!;
    defer scene::destroy_scene(&crease.scene);
    crease.quad.visible = true;
    crease.masked_box.visible = true;
    crease.cut_box.visible = true;
    crease.sun.visible = true;
    crease.scene.update_world();
    AoView ao_view = create_ao_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_ao_view(&fixture, &ao_view);
    crease.view = ao_view.view;

    Vec3[5] points = { CREASE_POINT, OPEN_POINT, MASKED_TOP_POINT, CUT_POINT, QUAD_POINT };
    uint[5] single_pass;
    set_depth_prepass(&fixture, ao_view.view, false)!!;
    foreach (index, point : points) single_pass[index] = render_and_read(&fixture, &crease, point)!!;
    set_depth_prepass(&fixture, ao_view.view, true)!!;
    foreach (index, point : points) {
        uint prepassed = render_and_read(&fixture, &crease, point)!!;
        for (uint channel = 0; channel < 4; channel++) {
            int before = (int)((single_pass[index] >> (8 * channel)) & 0xff);
            int after = (int)((prepassed >> (8 * channel)) & 0xff);
            assert(math::abs(before - after) <= CHANNEL_TOLERANCE);
        }
    }
    check_validation(&fixture.renderer);
}
