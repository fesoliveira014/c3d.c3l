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
import std::io;
import std::math;

const uint MANUAL_EXPOSURE_TARGET_SIZE @private = 64;
const ulong MANUAL_EXPOSURE_FNV_OFFSET @private = 0xcbf29ce484222325;
const ulong MANUAL_EXPOSURE_FNV_PRIME @private = 0x100000001b3;

struct ManualExposureScene @private {
    Scene scene;
    Node* camera;
}

fn ManualExposureScene? manual_exposure_create_scene(Fixture* fixture) @private {
    ManualExposureScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_intensity = 0.05f;
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    @pool() {
        Geometry plane = geometry::plane(tmem, 4, 4);
        Geometry ball = geometry::sphere(tmem, 0.3f);
        GeometryId plane_id = fixture.assets.add_geometry(&plane)!;
        GeometryId ball_id = fixture.assets.add_geometry(&ball)!;
        MaterialId grey = fixture.assets.add_material(material::standard({
            .base_color = { 0.5f, 0.5f, 0.5f, 1 },
            .roughness  = 0.7f,
        }))!;
        MaterialId lamp = fixture.assets.add_material(material::standard({
            .base_color        = { 0.1f, 0.1f, 0.1f, 1 },
            .roughness         = 0.5f,
            .emissive          = { 1, 0.7f, 0.4f },
            .emissive_strength = 8,
        }))!;
        Node* floor = result.scene.add_mesh(plane_id, grey, name: "floor")!;
        floor.local.position = { 0, -0.5f, -2 };
        Node* glow = result.scene.add_mesh(ball_id, lamp, name: "lamp")!;
        glow.local.position = { 0.4f, 0, -2 };
        Node* sun = result.scene.add_light(light::directional({ 1, 1, 1 }, 3, shadow: false), name: "sun")!;
        sun.local.rotation = maths::look_rotation((Vec3){ 0.3f, -1, -0.4f }.normalize(), { 0, 1, 0 });
    };
    result.scene.get(result.camera, Camera).exposure = 1.5f;
    result.scene.update_world();
    fixture.renderer.prepare_scene(&result.scene)!;
    return result;
}

fn ViewDesc manual_exposure_view_desc(RenderTargetId target) @private {
    ViewDesc desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.post.bloom = true;
    desc.post.bloom_params.intensity = 0.25f;
    return desc;
}

fn void? manual_exposure_render_frame(Fixture* fixture, ManualExposureScene* manual, ViewId view) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&manual.scene, manual.camera, view)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
}

fn void test_manual_exposure_digest_with_bloom() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    ManualExposureScene manual = manual_exposure_create_scene(&fixture)!!;
    defer scene::destroy_scene(&manual.scene);
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(MANUAL_EXPOSURE_TARGET_SIZE, MANUAL_EXPOSURE_TARGET_SIZE),
    )!!;
    ViewId view = render::create_view(&fixture.renderer, manual_exposure_view_desc(target))!!;
    manual_exposure_render_frame(&fixture, &manual, view)!!;

    char[] bytes = mem::new_array(char, (usz)MANUAL_EXPOSURE_TARGET_SIZE * MANUAL_EXPOSURE_TARGET_SIZE * 8);
    defer free(bytes);
    fixture.renderer.read_render_target(target, bytes)!!;
    ulong digest = MANUAL_EXPOSURE_FNV_OFFSET;
    bool lit;
    foreach (byte : bytes) {
        digest = (digest ^ byte) * MANUAL_EXPOSURE_FNV_PRIME;
        lit |= byte != 0;
    }
    assert(lit);
    io::eprintfn("manual exposure digest: %016x", digest);
    check_validation(&fixture.renderer);
}
