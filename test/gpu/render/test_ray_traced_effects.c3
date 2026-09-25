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

const Vec3 MIRROR_CAMERA_POSITION @private = { 0, 1, 2 };
const Vec3 MIRROR_CAMERA_TARGET @private = { 0, 0, -1 };  // top edge at +11.57 degrees clears the emitter
const Vec3 EMITTER_POSITION @private = { 0, 3, -4 };
const Vec3 EMITTER_LOWEST_POINT @private = { 0, 2.5f, -3.975f }; // bottom front edge, the emitter's point nearest the frame
const Vec3 EMITTER_IMAGE_POINT @private = { 0, 0, 0.5f };  // camera ray to the mirrored emitter centre meets the floor here
const Vec3 MISS_POINT @private = { 0, 0, 0 };              // mirror ray passes y = 2 at z = -4, under the emitter
const Vec3 MIRROR_AMBIENT @private = { 0, 0, 1 };
const float MIRROR_AMBIENT_INTENSITY @private = 0.5f;
const float MIRROR_ROUGHNESS @private = 0.02f;
const float ROUGH_FLOOR_ROUGHNESS @private = 0.9f;
const float MISS_WEIGHT_MINIMUM @private = 0.85f;           // split-sum weight x + y of a white metal near normal incidence
const int DARK_MAXIMUM @private = 8;
const int EMITTER_MINIMUM @private = 200;
const int MIRROR_TOLERANCE @private = 2;

struct MirrorScene @private {
    Scene       scene;
    Node*       camera;
    MaterialId  mirror;
    MaterialId  rough;
    Node*       floor;
}

fn MirrorScene? create_mirror_scene(Fixture* fixture, bool sunlit) @private {
    MirrorScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_color = MIRROR_AMBIENT;
    result.scene.ambient_intensity = MIRROR_AMBIENT_INTENSITY;

    GeometryId floor;
    GeometryId panel;
    @pool() {
        Geometry plane = geometry::plane(tmem, 20, 20);
        floor = fixture.assets.add_geometry(&plane)!;
        Geometry panel_box = geometry::box(tmem, 2, 1, 0.05f);
        panel = fixture.assets.add_geometry(&panel_box)!;
    };
    StandardParams metal = { .base_color = { 1, 1, 1, 1 }, .metallic = 1, .roughness = MIRROR_ROUGHNESS };
    result.mirror = fixture.assets.add_material(material::standard(metal))!;
    metal.roughness = ROUGH_FLOOR_ROUGHNESS;
    result.rough = fixture.assets.add_material(material::standard(metal))!;
    StandardParams glow = { .base_color = { 0, 0, 0, 1 }, .emissive = { 1, 0, 0 }, .emissive_strength = 1, .roughness = 1 };
    MaterialId emitter = fixture.assets.add_material(material::standard(glow))!;

    result.floor = result.scene.add_mesh(floor, result.mirror, name: "floor")!;
    Node* panel_node = result.scene.add_mesh(panel, emitter, name: "emitter")!;
    panel_node.local.position = EMITTER_POSITION;
    if (sunlit) {
        Node* sun = result.scene.add_light(light::directional({ 1, 1, 1 }, 1, shadow: false), name: "sun")!;
        sun.local.rotation = maths::look_rotation((Vec3){ 0.3f, -1, -0.4f }.normalize(), { 0, 0, -1 });
    }

    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.camera.local.position = MIRROR_CAMERA_POSITION;
    result.camera.local.rotation = maths::look_rotation(
        (MIRROR_CAMERA_TARGET - MIRROR_CAMERA_POSITION).normalize(),
        { 0, 1, 0 },
    );
    result.scene.update_world();
    return result;
}

fn Vec4 mirror_clip(MirrorScene* mirror, Vec3 point) @private {
    Camera* camera = mirror.scene.get(mirror.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(
        *camera,
        mirror.camera.world,
        { AO_TARGET_WIDTH, AO_TARGET_HEIGHT },
    );
    return matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
}

fn Vec2 mirror_uv(MirrorScene* mirror, Vec3 point) @private {
    Vec4 clip = mirror_clip(mirror, point);
    return { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f };
}

fn uint? render_mirror(Fixture* fixture, MirrorScene* mirror, ViewId view, Vec3 point) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&mirror.scene, mirror.camera, view)!;
    sample(fixture, render::read_view_color(view), mirror_uv(mirror, point))!;
    record_readback(fixture)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn void? set_reflections(Fixture* fixture, ViewId view, bool enabled) @private {
    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.ray_tracing.reflections = enabled;
    return render::configure_view(&fixture.renderer, view, desc);
}

fn int green(uint pixel) @private {
    return (int)((pixel >> 8) & 0xff);
}

fn int blue(uint pixel) @private {
    return (int)((pixel >> 16) & 0xff);
}

fn void test_ray_traced_ao_darkens_a_crease_and_leaves_open_floor() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    CreaseScene crease = create_crease_scene(&fixture)!!;
    defer scene::destroy_scene(&crease.scene);

    AmbientOcclusionDesc ray_traced = render::AMBIENT_OCCLUSION_DEFAULT;
    ray_traced.kind = AoKind.RAY_TRACED;
    int[2] open_values;
    ShadingPath[2] paths = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
    foreach (index, shading : paths) {
        AoView ao_view = create_ao_view(&fixture, shading)!!;
        defer destroy_ao_view(&fixture, &ao_view);
        crease.view = ao_view.view;

        int crease_none = red(render_and_read(&fixture, &crease, CREASE_POINT)!!);
        int open_none = red(render_and_read(&fixture, &crease, OPEN_POINT)!!);
        set_ambient_occlusion(&fixture, ao_view.view, ray_traced)!!;
        int crease_ao = red(render_and_read(&fixture, &crease, CREASE_POINT)!!);
        int open_ao = red(render_and_read(&fixture, &crease, OPEN_POINT)!!);
        io::eprintfn("%s ray traced: crease %d -> %d, open %d -> %d", shading, crease_none, crease_ao, open_none, open_ao);

        assert((float)crease_ao < CREASE_RATIO_MAXIMUM * (float)crease_none);
        assert((float)open_ao > OPEN_RATIO_MINIMUM * (float)open_none);
        open_values[index] = open_ao;
    }
    assert(math::abs(open_values[0] - open_values[1]) <= SHADING_PATH_TOLERANCE);

    AoView ao_view = create_ao_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_ao_view(&fixture, &ao_view);
    crease.view = ao_view.view;
    int crease_none = red(render_and_read(&fixture, &crease, CREASE_POINT)!!);
    set_ambient_occlusion(&fixture, ao_view.view, render::AMBIENT_OCCLUSION_DEFAULT)!!;
    float screen_space_ratio = (float)red(render_and_read(&fixture, &crease, CREASE_POINT)!!) / (float)crease_none;
    ray_traced.ray_count = render::RT_AO_RAYS_MAX;
    set_ambient_occlusion(&fixture, ao_view.view, ray_traced)!!;
    float ray_traced_ratio = (float)red(render_and_read(&fixture, &crease, CREASE_POINT)!!) / (float)crease_none;
    io::eprintfn("crease ratio: gtao %.3f, ray traced (%d rays) %.3f", screen_space_ratio, ray_traced.ray_count, ray_traced_ratio);
    assert(screen_space_ratio < CREASE_RATIO_MAXIMUM && ray_traced_ratio < CREASE_RATIO_MAXIMUM);
    check_validation(&fixture.renderer);
}

fn void test_reflection_images_follow_the_settings() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
    defer scene::destroy_scene(&mirror.scene);
    AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
    defer destroy_ao_view(&fixture, &mirror_view);
    ViewRecord* record = fixture.renderer.views.get(mirror_view.view);

    assert(!record.reflection.texture.is_valid() && !record.reflection_blur.texture.is_valid());
    set_reflections(&fixture, mirror_view.view, true)!!;
    Target*[2] images = { &record.reflection, &record.reflection_blur };
    foreach (image : images) {
        assert(image.texture.is_valid());
        assert(image.width == AO_TARGET_WIDTH && image.height == AO_TARGET_HEIGHT);
        assert(image.format == gpu::Format.RGBA16_FLOAT);
    }
    (void)render_mirror(&fixture, &mirror, mirror_view.view, MISS_POINT)!!;

    set_reflections(&fixture, mirror_view.view, false)!!;
    assert(!record.reflection.texture.is_valid() && !record.reflection_blur.texture.is_valid());
    set_reflections(&fixture, mirror_view.view, true)!!;
    (void)render_mirror(&fixture, &mirror, mirror_view.view, MISS_POINT)!!;
    check_validation(&fixture.renderer);
}

fn void test_reflections_show_an_off_screen_emitter() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
    defer scene::destroy_scene(&mirror.scene);
    AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
    defer destroy_ao_view(&fixture, &mirror_view);

    Vec4 lowest = mirror_clip(&mirror, EMITTER_LOWEST_POINT);
    assert(lowest.w > 0 && lowest.y / lowest.w > 1);

    uint image_off = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
    uint miss_off = render_mirror(&fixture, &mirror, mirror_view.view, MISS_POINT)!!;
    set_reflections(&fixture, mirror_view.view, true)!!;
    uint image_on = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
    uint miss_on = render_mirror(&fixture, &mirror, mirror_view.view, MISS_POINT)!!;
    io::eprintfn("emitter image: off %06x on %06x; miss: off %06x on %06x", image_off, image_on, miss_off, miss_on);

    assert(red(image_off) < DARK_MAXIMUM && blue(image_off) < DARK_MAXIMUM);
    assert(red(image_on) > EMITTER_MINIMUM && green(image_on) < DARK_MAXIMUM);
    float ambient = MIRROR_AMBIENT_INTENSITY * 255;
    assert(blue(miss_off) < DARK_MAXIMUM);
    assert((float)blue(miss_on) >= MISS_WEIGHT_MINIMUM * ambient && (float)blue(miss_on) <= ambient + 1);
    assert(red(miss_on) < DARK_MAXIMUM);
    check_validation(&fixture.renderer);
}

fn void test_reflections_leave_rough_pixels_to_the_environment() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    MirrorScene mirror = create_mirror_scene(&fixture, true)!!;
    defer scene::destroy_scene(&mirror.scene);
    mirror.scene.get(mirror.floor, Mesh).material = mirror.rough;
    AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
    defer destroy_ao_view(&fixture, &mirror_view);

    uint reflections_off = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
    set_reflections(&fixture, mirror_view.view, true)!!;
    uint reflections_on = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
    io::eprintfn("rough floor: off %06x on %06x", reflections_off, reflections_on);

    assert(red(reflections_off) > DARK_MAXIMUM);
    assert(math::abs(red(reflections_on) - red(reflections_off)) <= MIRROR_TOLERANCE);
    assert(math::abs(green(reflections_on) - green(reflections_off)) <= MIRROR_TOLERANCE);
    assert(math::abs(blue(reflections_on) - blue(reflections_off)) <= MIRROR_TOLERANCE);
    check_validation(&fixture.renderer);
}
