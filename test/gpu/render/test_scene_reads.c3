module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader::compile;
import gpu;
import std::math;

const char[*] SCENE_PROBE_SOURCE @private = $embed("scene_probe.frag.glsl");
const uint SCENE_READ_TARGET_SIZE @private = 64;
const float SCENE_READ_GAP_RANGE @private = 2; // mirrored as GAP_RANGE in scene_probe.frag.glsl
const float SCENE_READ_CAMERA_HEIGHT @private = 3;
const float SCENE_READ_FOV_DEGREES @private = 60;
const float SCENE_READ_ORTHOGRAPHIC_HEIGHT @private = 4;
const float SCENE_READ_NEAR @private = 0.1f;
const float SCENE_READ_FAR @private = 10;
const float SCENE_READ_PROBE_HEIGHT @private = 0.5f;
const float SCENE_READ_LOWER_HEIGHT @private = 0.3f;
const float SCENE_READ_UPPER_HEIGHT @private = 0.8f;
const float SCENE_READ_PLANE_SIZE @private = 20; // covers the view at every tested height
const Vec3 SCENE_READ_BOX_SIZE @private = { 2, 0.2f, 2 }; // top below the lower probe; covers the centre pixels
const Vec4 SCENE_READ_FLOOR_COLOR @private = { 0.2f, 0.6f, 0.3f, 1 };
const Vec4 SCENE_READ_BOX_COLOR @private = { 0.9f, 0.4f, 0.1f, 1 };
const Vec4 SCENE_READ_FLAT_COLOR @private = { 0.2f, 0.4f, 0.6f, 1 }; // mirrored as FLAT_COLOR in scene_probe.frag.glsl
const uint SCENE_READ_TAA_FRAMES @private = 8;
const int SCENE_READ_COLOR_TOLERANCE @private = 1;
const int SCENE_READ_TAA_TOLERANCE @private = 2;
const int SCENE_READ_GAP_TOLERANCE @private = 2;

struct SceneReadScene @private {
    Scene      scene;
    Node*      camera;
    Node*      box;
    GeometryId plane;
}

struct SceneReadView @private {
    RenderTargetId target;
    ViewId         view;
}

fn SceneReadScene? create_scene_read_scene(Fixture* fixture, Camera camera) @private {
    SceneReadScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);

    GeometryId box;
    @pool() {
        Geometry plane = geometry::plane(tmem, SCENE_READ_PLANE_SIZE, SCENE_READ_PLANE_SIZE);
        result.plane = fixture.assets.add_geometry(&plane)!;
        Geometry box_geometry = geometry::box(
            allocator: tmem,
            width:     SCENE_READ_BOX_SIZE.x,
            height:    SCENE_READ_BOX_SIZE.y,
            depth:     SCENE_READ_BOX_SIZE.z,
        );
        box = fixture.assets.add_geometry(&box_geometry)!;
    };
    MaterialId floor_material = fixture.assets.add_material(material::basic({ .color = SCENE_READ_FLOOR_COLOR }))!;
    MaterialId box_material = fixture.assets.add_material(material::basic({ .color = SCENE_READ_BOX_COLOR }))!;
    result.scene.add_mesh(result.plane, floor_material, name: "floor")!;
    result.box = result.scene.add_mesh(box, box_material, name: "box")!;
    result.box.local.position = { 0, SCENE_READ_BOX_SIZE.y / 2, 0 };

    result.camera = result.scene.add_camera(camera, name: "camera")!;
    result.camera.local.position = { 0, SCENE_READ_CAMERA_HEIGHT, 0 };
    result.camera.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 });
    result.scene.update_world();
    return result;
}

fn SceneReadView? create_scene_read_view(
    Fixture* fixture,
    ShadingPath shading,
    float render_scale = 1,
    bool taa = false,
) @private {
    SceneReadView result;
    result.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(SCENE_READ_TARGET_SIZE, SCENE_READ_TARGET_SIZE),
    )!;
    ViewDesc desc = render::texture_view_desc(result.target);
    desc.shading = shading;
    desc.render_scale = render_scale;
    desc.instance_culling = true;
    if (taa) desc.post.anti_aliasing = AntiAliasing.TAA;
    result.view = render::create_view(&fixture.renderer, desc)!;
    return result;
}

fn void destroy_scene_read_view(Fixture* fixture, SceneReadView* scene_read_view) @private {
    render::destroy_view(&fixture.renderer, scene_read_view.view)!!;
    render::destroy_render_target(&fixture.renderer, scene_read_view.target)!!;
}

fn asset::ShaderDesc? scene_probe_desc(Fixture* fixture, String[] defines, SceneReads reads) @private {
    return {
        .fragment = compile::compile_glsl(
            allocator: fixture.allocator,
            source:    (String)SCENE_PROBE_SOURCE[..],
            stage:     ShaderStage.FRAGMENT,
            defines:   defines,
        )!,
        .scene_reads = reads,
    };
}

fn ShaderId? add_scene_probe_shader(Fixture* fixture, String[] defines, SceneReads reads) @private {
    asset::ShaderDesc desc = scene_probe_desc(fixture, defines, reads)!;
    defer alloc::free(fixture.allocator, desc.fragment.ptr);
    return fixture.assets.add_shader(&desc);
}

fn void? replace_scene_probe_shader(
    Fixture* fixture,
    ShaderId shader,
    String[] defines,
    SceneReads reads,
) @private {
    asset::ShaderDesc desc = scene_probe_desc(fixture, defines, reads)!;
    defer alloc::free(fixture.allocator, desc.fragment.ptr);
    return fixture.assets.replace_shader(shader, &desc);
}

fn Node*? add_scene_probe_plane(SceneReadScene* target, MaterialId probe, float height) @private {
    Node* node = target.scene.add_mesh(target.plane, probe, name: "probe")!;
    node.local.position = { 0, height, 0 };
    target.scene.get(node, Mesh).cast_shadow = false;
    target.scene.update_world();
    return node;
}

fn uint? render_scene_read_pixel(Fixture* fixture, SceneReadScene* target, ViewId view) @private {
    Renderer* renderer = &fixture.renderer;
    target.scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&target.scene, target.camera, view)!;
    sample(fixture, render::read_view_color(view), CENTER_UV)!;
    record_readback(fixture)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn int scene_read_gap_red(float gap) @private {
    return (int)math::round(gap / SCENE_READ_GAP_RANGE * 255);
}

fn void test_color_reader_shows_the_scene_behind_it() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Camera perspective = camera::perspective_deg(SCENE_READ_FOV_DEGREES, SCENE_READ_NEAR);
    SceneReadScene target = create_scene_read_scene(&fixture, perspective)!!;
    defer scene::destroy_scene(&target.scene);
    String[1] color_probe = { "PROBE_COLOR" };
    ShaderId shader = add_scene_probe_shader(&fixture, color_probe[..], { .color })!!;
    MaterialId probe_material = fixture.assets.add_material(material::custom(shader))!!;
    Node* probe = add_scene_probe_plane(&target, probe_material, SCENE_READ_PROBE_HEIGHT)!!;

    ShadingPath[4] shadings = { FORWARD, FORWARD, DEFERRED, FORWARD };
    float[4] render_scales = { 1, 0.5f, 1, 1 };
    bool[4] taa = { false, false, false, true };
    for (usz index = 0; index < shadings.len; index++) {
        SceneReadView scene_read_view = create_scene_read_view(
            fixture:      &fixture,
            shading:      shadings[index],
            render_scale: render_scales[index],
            taa:          taa[index],
        )!!;
        defer destroy_scene_read_view(&fixture, &scene_read_view);
        uint frames = taa[index] ? SCENE_READ_TAA_FRAMES : 1;
        int tolerance = taa[index] ? SCENE_READ_TAA_TOLERANCE : SCENE_READ_COLOR_TOLERANCE;

        probe.visible = false;
        uint behind;
        for (uint frame = 0; frame < frames; frame++) {
            behind = render_scene_read_pixel(&fixture, &target, scene_read_view.view)!!;
        }
        probe.visible = true;
        uint through;
        for (uint frame = 0; frame < frames; frame++) {
            through = render_scene_read_pixel(&fixture, &target, scene_read_view.view)!!;
        }
        assert_channels_close(through, behind, tolerance);
        assert(renderer.stats.scene_snapshots == 1);
        ViewRecord* record = renderer.views.get(scene_read_view.view);
        assert(record.scene_color.texture.is_valid() && !record.scene_depth.texture.is_valid());
    }
    check_validation(renderer);
}

fn void test_depth_reader_measures_the_gap_to_the_floor() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Camera[2] cameras = {
        camera::orthographic(SCENE_READ_ORTHOGRAPHIC_HEIGHT, SCENE_READ_NEAR, SCENE_READ_FAR),
        camera::perspective_deg(SCENE_READ_FOV_DEGREES, SCENE_READ_NEAR),
    };
    String[1] gap_probe = { "PROBE_GAP" };
    ShaderId shader = add_scene_probe_shader(&fixture, gap_probe[..], { .depth })!!;
    MaterialId probe_material = fixture.assets.add_material(material::custom(shader))!!;
    foreach (camera : cameras) {
        SceneReadScene target = create_scene_read_scene(&fixture, camera)!!;
        defer scene::destroy_scene(&target.scene);
        target.box.visible = false;
        add_scene_probe_plane(&target, probe_material, SCENE_READ_PROBE_HEIGHT)!!;
        SceneReadView scene_read_view = create_scene_read_view(&fixture, ShadingPath.FORWARD)!!;
        defer destroy_scene_read_view(&fixture, &scene_read_view);

        uint pixel = render_scene_read_pixel(&fixture, &target, scene_read_view.view)!!;
        assert(math::abs(red(pixel) - scene_read_gap_red(SCENE_READ_PROBE_HEIGHT)) <= SCENE_READ_GAP_TOLERANCE);
        assert(renderer.stats.scene_snapshots == 1);
        assert(!renderer.views.get(scene_read_view.view).scene_color.texture.is_valid());
    }
    check_validation(renderer);
}

fn void test_blended_reader_sees_the_scene_read_list() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Camera perspective = camera::perspective_deg(SCENE_READ_FOV_DEGREES, SCENE_READ_NEAR);
    SceneReadScene target = create_scene_read_scene(&fixture, perspective)!!;
    defer scene::destroy_scene(&target.scene);
    target.box.visible = false;

    String[1] color_probe = { "PROBE_COLOR" };
    String[1] gap_probe = { "PROBE_GAP" };
    ShaderId lower_shader = add_scene_probe_shader(&fixture, color_probe[..], { .color, .depth })!!;
    ShaderId upper_shader = add_scene_probe_shader(&fixture, gap_probe[..], { .depth })!!;
    MaterialId lower = fixture.assets.add_material(material::custom(lower_shader))!!;
    MaterialCommon blended = material::MATERIAL_COMMON_DEFAULT;
    blended.alpha_mode = AlphaMode.BLEND;
    MaterialId upper = fixture.assets.add_material(material::custom(shader: upper_shader, common: blended))!!;
    add_scene_probe_plane(&target, lower, SCENE_READ_LOWER_HEIGHT)!!;
    Transform[1] instance = { maths::TRANSFORM_IDENTITY };
    Node* batch = target.scene.add_instanced_mesh(
        geometry:   target.plane,
        material:   upper,
        capacity:   1,
        transforms: instance[..],
        name:       "blended_probe",
    )!!;
    batch.local.position = { 0, SCENE_READ_UPPER_HEIGHT, 0 };
    SceneReadView scene_read_view = create_scene_read_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_scene_read_view(&fixture, &scene_read_view);

    uint pixel = render_scene_read_pixel(&fixture, &target, scene_read_view.view)!!;
    int expected = scene_read_gap_red(SCENE_READ_UPPER_HEIGHT - SCENE_READ_LOWER_HEIGHT);
    assert(math::abs(red(pixel) - expected) <= SCENE_READ_GAP_TOLERANCE);
    assert(renderer.stats.scene_snapshots == 3);
    check_validation(renderer);
}

fn void test_views_without_readers_pay_nothing() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Camera perspective = camera::perspective_deg(SCENE_READ_FOV_DEGREES, SCENE_READ_NEAR);
    SceneReadScene target = create_scene_read_scene(&fixture, perspective)!!;
    defer scene::destroy_scene(&target.scene);
    Node* masked = target.scene.add_mesh(fixture.box, fixture.masked, name: "masked")!!;
    masked.local.position = { -1, 1, 0 };
    Node* translucent = target.scene.add_mesh(fixture.box, fixture.translucent, name: "translucent")!!;
    translucent.local.position = { 1, 1, 0 };
    SceneReadView scene_read_view = create_scene_read_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_scene_read_view(&fixture, &scene_read_view);
    ViewRecord* record = renderer.views.get(scene_read_view.view);

    render_scene_read_pixel(&fixture, &target, scene_read_view.view)!!;
    assert(renderer.stats.scene_snapshots == 0);
    assert(!record.scene_color.texture.is_valid() && !record.scene_depth.texture.is_valid());

    PhysicalParams glass = material::PHYSICAL_PARAMS_DEFAULT;
    glass.transmission = 1;
    MaterialId glass_material = fixture.assets.add_material(material::physical(glass))!!;
    Node* glass_box = target.scene.add_mesh(fixture.box, glass_material, name: "glass")!!;
    glass_box.local.position = { 0, 1, 1 };
    render_scene_read_pixel(&fixture, &target, scene_read_view.view)!!;
    assert(renderer.stats.scene_snapshots == 1);
    assert(record.scene_color.texture.is_valid() && !record.scene_depth.texture.is_valid());
    check_validation(renderer);
}

fn void test_rejected_replacement_keeps_its_scene_reads() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Camera perspective = camera::perspective_deg(SCENE_READ_FOV_DEGREES, SCENE_READ_NEAR);
    SceneReadScene target = create_scene_read_scene(&fixture, perspective)!!;
    defer scene::destroy_scene(&target.scene);
    target.box.visible = false;
    String[1] gap_probe = { "PROBE_GAP" };
    ShaderId shader = add_scene_probe_shader(&fixture, gap_probe[..], { .depth })!!;
    MaterialId probe_material = fixture.assets.add_material(material::custom(shader))!!;
    add_scene_probe_plane(&target, probe_material, SCENE_READ_PROBE_HEIGHT)!!;
    SceneReadView scene_read_view = create_scene_read_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_scene_read_view(&fixture, &scene_read_view);
    uint published = render_scene_read_pixel(&fixture, &target, scene_read_view.view)!!;

    String[2] broken = { "PROBE_GAP", "BROKEN_PUSH" };
    replace_scene_probe_shader(
        fixture: &fixture,
        shader:  shader,
        defines: broken[..],
        reads:   {},
    )!!;
    if (catch excuse = renderer.upload(shader)) {
        assert(excuse == gpu::SHADER_INVALID);
    } else {
        assert(false, "a push block the backend rejects was accepted");
    }
    uint kept = render_scene_read_pixel(&fixture, &target, scene_read_view.view)!!;
    assert(renderer.stats.scene_snapshots == 1);
    assert_channels_close(kept, published, 0);
    check_validation(renderer);

    replace_scene_probe_shader(
        fixture: &fixture,
        shader:  shader,
        defines: {},
        reads:   {},
    )!!;
    renderer.upload(shader)!!;
    uint flat = render_scene_read_pixel(&fixture, &target, scene_read_view.view)!!;
    assert(renderer.stats.scene_snapshots == 0);
    check_rgb(flat, SCENE_READ_FLAT_COLOR);
    check_validation(renderer);
}
