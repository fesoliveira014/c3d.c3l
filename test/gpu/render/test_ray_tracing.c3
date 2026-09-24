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

const Vec3 SHADOWED_POINT @private = { 1.5f, 0, 0 };
const Vec3 LIT_POINT @private = { -2, 0, 0 };
const Vec3 SUN_DIRECTION @private = { 0.6f, -0.8f, 0 }; // the 3-unit box shades x in 0.5 to 2.75 on the ground
const float OVERHEAD_HEIGHT @private = 8;
const int SHADE_TOLERANCE @private = 2;

struct ShadowScene @private {
    Scene      scene;
    Node*      camera;
    Node*      box;
    GeometryId box_geometry;
    MaterialId opaque;
    MaterialId transparent;
}

fn ShadowScene? create_shadow_scene(Fixture* fixture) @private {
    ShadowScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    GeometryId ground;
    @pool() {
        Geometry plane = geometry::plane(tmem, 10, 10);
        ground = fixture.assets.add_geometry(&plane)!;
        Geometry box = geometry::box(tmem, 1, 3, 1);
        result.box_geometry = fixture.assets.add_geometry(&box)!;
    };
    MaterialId ground_material = fixture.assets.add_material(material::standard({
        .base_color = { 0.8f, 0.8f, 0.8f, 1 },
        .roughness  = 1,
    }))!;
    result.opaque = fixture.assets.add_material(material::standard({ .base_color = { 1, 1, 1, 1 }, .roughness = 1 }))!;
    MaterialCommon cutout = material::MATERIAL_COMMON_DEFAULT;
    cutout.alpha_mode = AlphaMode.MASK;
    cutout.alpha_cutoff = 0.5f;
    result.transparent = fixture.assets.add_material(material::standard(
        params: { .base_color = { 1, 1, 1, 0 }, .roughness = 1 },
        common: cutout,
    ))!;

    result.scene.add_mesh(ground, ground_material, name: "ground")!;
    result.box = result.scene.add_mesh(result.box_geometry, result.opaque, name: "box")!;
    result.box.local.position = { 0, 1.5f, 0 };
    Light sun = light::directional({ 1, 1, 1 }, 3);
    sun.shadow.cascades = 1;
    sun.shadow.max_distance = 20;
    sun.shadow.ray_traced = true;
    Node* sun_node = result.scene.add_light(sun, name: "sun")!;
    sun_node.local.rotation = maths::look_rotation(SUN_DIRECTION.normalize(), { 0, 0, -1 });
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.camera.local.position = { 0, OVERHEAD_HEIGHT, 0 };
    result.camera.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 });
    result.scene.update_world();
    return result;
}

fn Vec2 project_uv(ShadowScene* shadow, Vec3 point) @private {
    Camera* camera = shadow.scene.get(shadow.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, shadow.camera.world, { TARGET_SIZE, TARGET_SIZE });
    Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
    return { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f };
}

fn uint? render_and_sample(Fixture* fixture, ShadowScene* shadow, Vec3 point) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&shadow.scene, shadow.camera, fixture.view)!;
    sample(fixture, render::read_view_color(fixture.view), project_uv(shadow, point))!;
    record_readback(fixture)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn int shade(uint pixel) @private {
    return (int)(pixel & 0xff) + (int)((pixel >> 8) & 0xff) + (int)((pixel >> 16) & 0xff);
}

fn void? set_ray_traced_shadows(Fixture* fixture, bool enabled) @private {
    ViewDesc desc = fixture.renderer.views.get(fixture.view).desc;
    desc.ray_tracing.shadows = enabled;
    return render::configure_view(&fixture.renderer, fixture.view, desc);
}

fn void test_ray_query_shadow_matches_the_atlas_on_a_plane() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    ShadowScene shadow = create_shadow_scene(&fixture)!!;
    defer scene::destroy_scene(&shadow.scene);
    Mesh* box_mesh = shadow.scene.get(shadow.box, Mesh);

    bool[2] modes = { false, true };
    foreach (ray_traced : modes) {
        set_ray_traced_shadows(&fixture, ray_traced)!!;
        box_mesh.material = shadow.opaque;
        box_mesh.cast_shadow = true;
        int shadowed = shade(render_and_sample(&fixture, &shadow, SHADOWED_POINT)!!);
        assert(fixture.renderer.stats.shadow_layers == (ray_traced ? 0 : 1));
        int lit = shade(render_and_sample(&fixture, &shadow, LIT_POINT)!!);
        io::eprintfn("Ray traced %s: shadowed %d, lit %d", ray_traced, shadowed, lit);
        // The fixture's 64-texel atlas only darkens; the traced shadow must be black.
        assert(ray_traced ? shadowed == 0 && lit > 0 : shadowed < lit - 3 * SHADE_TOLERANCE);

        box_mesh.material = shadow.transparent;
        int masked = shade(render_and_sample(&fixture, &shadow, SHADOWED_POINT)!!);
        assert(math::abs(masked - lit) <= 3 * SHADE_TOLERANCE);

        box_mesh.material = shadow.opaque;
        box_mesh.cast_shadow = false;
        int uncast = shade(render_and_sample(&fixture, &shadow, SHADOWED_POINT)!!);
        assert(math::abs(uncast - lit) <= 3 * SHADE_TOLERANCE);
    }
}

fn void? prepare_frame(Fixture* fixture, Scene* scene, TraceKind kind = TraceKind.HARDWARE) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.prepare_scene_trace(scene, kind)!;
    return renderer.end_frame();
}

fn void test_tlas_rebuilds_only_on_a_dirty_set() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_mesh(fixture.box, fixture.plain, name: "first")!!;
    Node* second = scene.add_mesh(fixture.box, fixture.plain, name: "second")!!;
    second.local.position = { 2, 0, 0 };
    scene.update_world();
    Renderer* renderer = &fixture.renderer;

    assert(renderer.prepare_scene_trace(&scene, TraceKind.HARDWARE)!! != (gpu::GpuAddress)0);
    assert(renderer.stats.blas_builds == 1 && renderer.stats.tlas_builds == 1);
    prepare_frame(&fixture, &scene)!!;
    assert(renderer.stats.blas_builds == 0 && renderer.stats.tlas_builds == 0);
    prepare_frame(&fixture, &scene)!!;
    assert(renderer.stats.blas_builds == 0 && renderer.stats.tlas_builds == 0);

    first.local.position = { 0, 1, 0 };
    scene.update_world();
    prepare_frame(&fixture, &scene)!!;
    assert(renderer.stats.blas_builds == 0 && renderer.stats.tlas_builds == 1);
    prepare_frame(&fixture, &scene)!!;
    assert(renderer.stats.tlas_builds == 0);

    renderer.begin_frame()!!;
    renderer.prepare_scene_trace(&scene, TraceKind.HARDWARE)!!;
    renderer.prepare_scene_trace(&scene, TraceKind.SOFTWARE)!!;
    renderer.end_frame()!!;
    assert(renderer.stats.tlas_builds == 0);

    scene.get(first, Mesh).trace = false;
    scene.get(second, Mesh).trace = false;
    prepare_frame(&fixture, &scene)!!;
    assert(renderer.stats.trace_instances == 0 && renderer.stats.tlas_builds == 0);
    scene.get(first, Mesh).trace = true;
    scene.get(second, Mesh).trace = true;
    prepare_frame(&fixture, &scene)!!;
    assert(renderer.stats.trace_instances == 2 && renderer.stats.tlas_builds == 1);
}

fn void test_blas_follows_the_geometry_revision() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    GeometryId geometry;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        geometry = fixture.assets.add_geometry(&box)!!;
    };
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.add_mesh(geometry, fixture.plain, name: "box")!!;
    scene.update_world();
    Renderer* renderer = &fixture.renderer;

    prepare_frame(&fixture, &scene)!!;
    assert(renderer.stats.blas_builds == 1 && renderer.stats.tlas_builds == 1);
    foreach (&position : fixture.assets.geometry(geometry).data.positions) *position *= 2;
    fixture.assets.mark_geometry_dirty(geometry);
    prepare_frame(&fixture, &scene)!!;
    assert(renderer.stats.blas_builds == 1 && renderer.stats.tlas_builds == 1);
    for (uint frame = 0; frame < 3; frame++) prepare_frame(&fixture, &scene)!!;
    assert(renderer.stats.blas_builds == 0 && renderer.stats.tlas_builds == 0);
}

fn void test_renderer_without_ray_queries_rejects_hardware() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    if (catch excuse = fixture.renderer.prepare_scene_trace(&fixture.scene, TraceKind.HARDWARE)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false);
    }
    assert(fixture.renderer.prepare_scene_trace(&fixture.scene)!! != (gpu::GpuAddress)0);
    if (catch excuse = set_ray_traced_shadows(&fixture, true)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false);
    }
    assert(!fixture.renderer.views.get(fixture.view).desc.ray_tracing.shadows);
}
