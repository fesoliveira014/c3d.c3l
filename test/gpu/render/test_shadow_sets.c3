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
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::hash::fnv64a;
import std::io;
import std::math;

const char[*] SHADOW_SET_STANDARD_LIGHTS_SOURCE @private = $embed("standard_lights.frag.glsl");
const uint SHADOW_SET_WIDTH @private = 192;
const uint SHADOW_SET_HEIGHT @private = 108; // 16:9, so the half-size mirror keeps the main aspect
const uint[<2>] SHADOW_SET_EXTENT @private = { SHADOW_SET_WIDTH, SHADOW_SET_HEIGHT };
const uint[<2>] SHADOW_SET_HALF_EXTENT @private = { SHADOW_SET_WIDTH / 2, SHADOW_SET_HEIGHT / 2 };
const uint SHADOW_SET_SHADOW_RESOLUTION @private = 1024;
const uint SHADOW_SET_SHADOW_LAYERS @private = 8; // one four-cascade sun and one spot
const uint SHADOW_SET_SUN_CASCADES @private = 4;
const uint SHADOW_SET_WATER_LAYER @private = 1 << 4;
const Plane SHADOW_SET_WATER_PLANE @private = { .normal = { 0, 1, 0 }, .d = 0 };
const float SHADOW_SET_GROUND_SIZE @private = 400; // wide enough for receivers 120 m to the side
const Vec3 SHADOW_SET_CAMERA_POSITION @private = { 0, 2, 4 };
const float SHADOW_SET_CAMERA_PITCH_DEGREES @private = -8;
const Vec3 SHADOW_SET_SUN_TRAVEL @private = { 0.3f, -0.4f, -0.85f }; // about 24 degrees up: the board shades the wall
const float SHADOW_SET_SHADOW_DISTANCE @private = 60;
const FrameInfo SHADOW_SET_FRAME_INFO @private = { .time = 1.25, .delta = 1.0f / 60 };
const float SHADOW_SET_CASTER_HEIGHT @private = 1.5f; // metres above the receiver it shades
const float SHADOW_SET_CASTER_SIZE @private = 1.2f;
const float SHADOW_SET_LIT_OFFSET @private = 2.5f; // metres to the right of a shaded probe, outside its shadow
const float SHADOW_SET_SHADOWED_RATIO @private = 0.5f; // a shaded probe reads at most this share of its lit neighbour
const Vec3 SHADOW_SET_WALL_CENTER @private = { 0, 3, -15 };
const Vec3 SHADOW_SET_WALL_SIZE @private = { 20, 6, 0.5f };
const Vec3 SHADOW_SET_BOARD_CENTER @private = { -7.5f, 2.5f, -11 }; // its wall shadow clears its own occlusion
const Vec3 SHADOW_SET_BOARD_SIZE @private = { 2, 5, 0.3f };

enum ShadowSetCase : int (String name) @private {
    FORWARD { "forward" },
    DEFERRED { "deferred" },
    STANDARD_LIGHTS { "standard_lights" },
    VOLUMETRIC_FOG { "volumetric_fog" },
}

struct ShadowSetFixture @private {
    AssetStore     assets;
    Scene          scene;
    Renderer       renderer;
    Node*          main;
    Node*          mirror;
    Node*          sun;
    Node*          ground;
    GeometryId     box;
    MaterialId     matte;
    MaterialId     standard_lights;
    RenderTargetId main_target;
    RenderTargetId mirror_target;
    ViewId         main_view;
    ViewId         mirror_view;
}

fn void? shadow_set_create_fixture(ShadowSetFixture* fixture) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    defer catch scene::destroy_scene(&fixture.scene);
    GeometryId ground_geometry;
    @pool() {
        Geometry ground = geometry::plane(tmem, SHADOW_SET_GROUND_SIZE, SHADOW_SET_GROUND_SIZE);
        ground_geometry = fixture.assets.add_geometry(&ground)!;
        Geometry box = geometry::box(
            allocator: tmem,
            width:     1,
            height:    1,
            depth:     1,
        );
        fixture.box = fixture.assets.add_geometry(&box)!;
    };
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.metallic = 0;
    params.roughness = 1;
    fixture.matte = fixture.assets.add_material(material::standard(params))!;
    fixture.ground = fixture.scene.add_mesh(ground_geometry, fixture.matte)!;
    shadow_set_add_box(fixture, SHADOW_SET_WALL_CENTER, SHADOW_SET_WALL_SIZE)!;
    shadow_set_add_box(fixture, SHADOW_SET_BOARD_CENTER, SHADOW_SET_BOARD_SIZE)!;

    Light sun = light::directional({ 1, 1, 1 }, 3);
    sun.shadow.cascades = SHADOW_SET_SUN_CASCADES;
    sun.shadow.max_distance = SHADOW_SET_SHADOW_DISTANCE;
    fixture.sun = fixture.scene.add_light(sun)!;
    fixture.sun.local.rotation = maths::look_rotation(SHADOW_SET_SUN_TRAVEL.normalize(), { 0, 1, 0 });
    Camera lens = camera::perspective_deg(60, 0.1f);
    lens.aspect = (float)SHADOW_SET_WIDTH / (float)SHADOW_SET_HEIGHT;
    fixture.main = fixture.scene.add_camera(lens, name: "main")!;
    fixture.main.local.position = SHADOW_SET_CAMERA_POSITION;
    fixture.main.local.rotation = quaternion::from_axis_angle{float}(
        { 1, 0, 0 },
        math::deg_to_rad(SHADOW_SET_CAMERA_PITCH_DEGREES),
    );
    lens.layers &= ~SHADOW_SET_WATER_LAYER;
    fixture.mirror = fixture.scene.add_camera(lens, name: "mirror")!;
    shadow_set_place_mirror(fixture)!;

    fixture.renderer = render::create_renderer(
        allocator: mem,
        assets:    &fixture.assets,
        desc:      {
            .validation        = true,
            .shadow_resolution = SHADOW_SET_SHADOW_RESOLUTION,
            .max_shadow_layers = SHADOW_SET_SHADOW_LAYERS,
            .application_name  = "shadow_set_acceptance",
        },
    )!;
    defer catch render::destroy_renderer(&fixture.renderer);
    fixture.standard_lights = shadow_set_add_lights_material(fixture)!;
    fixture.main_target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(SHADOW_SET_WIDTH, SHADOW_SET_HEIGHT, PixelFormat.RGBA32_FLOAT),
    )!;
    fixture.mirror_target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(
            SHADOW_SET_HALF_EXTENT.x,
            SHADOW_SET_HALF_EXTENT.y,
            PixelFormat.RGBA32_FLOAT,
        ),
    )!;
    ViewDesc main_desc = render::texture_view_desc(fixture.main_target);
    main_desc.post.anti_aliasing = AntiAliasing.NONE;
    fixture.main_view = render::create_view(&fixture.renderer, main_desc)!;
    ViewDesc mirror_desc = render::texture_view_desc(fixture.mirror_target);
    mirror_desc.post.anti_aliasing = AntiAliasing.NONE;
    mirror_desc.clip_plane = SHADOW_SET_WATER_PLANE;
    fixture.mirror_view = render::create_view(&fixture.renderer, mirror_desc)!;
}

fn void shadow_set_destroy_fixture(ShadowSetFixture* fixture) @private {
    render::wait_frames(&fixture.renderer)!!;
    check_validation(&fixture.renderer);
    render::destroy_renderer(&fixture.renderer);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node*? shadow_set_add_box(ShadowSetFixture* fixture, Vec3 center, Vec3 size) @private {
    Node* node = fixture.scene.add_mesh(fixture.box, fixture.matte)!;
    node.local.position = center;
    node.local.scale = size;
    fixture.scene.update_world();
    return node;
}

fn MaterialId? shadow_set_add_lights_material(ShadowSetFixture* fixture) @private {
    @pool() {
        asset::ShaderDesc desc = {
            .fragment = compile::compile_glsl(
                allocator: tmem,
                source:    (String)SHADOW_SET_STANDARD_LIGHTS_SOURCE[..],
                stage:     ShaderStage.FRAGMENT,
            )!,
        };
        ShaderId shader = fixture.assets.add_shader(&desc)!;
        return fixture.assets.add_material(material::custom(shader));
    };
}

fn void? shadow_set_place_mirror(ShadowSetFixture* fixture) @private {
    Mat4 mirrored = maths::reflection_matrix(SHADOW_SET_WATER_PLANE).mul(fixture.main.local.to_mat4());
    fixture.mirror.local = maths::transform_from_affine(mirrored)!;
    fixture.scene.update_world();
}

// Raised against the light, so its shadow covers the receiver.
fn Node*? shadow_set_add_caster_over(
    ShadowSetFixture* fixture,
    Vec3 receiver,
    float size = SHADOW_SET_CASTER_SIZE,
) @private {
    Vec3 travel = SHADOW_SET_SUN_TRAVEL.normalize();
    Vec3 center = receiver - travel * (SHADOW_SET_CASTER_HEIGHT / -travel.y);
    return shadow_set_add_box(fixture, center, { size, size, size });
}

// A ground point on the camera's centre column at a camera-space depth.
fn Vec3 shadow_set_ground_point(Node* camera_node, float depth, float right = 0) @private {
    Vec3 position = maths::translation(camera_node.world);
    Vec3 forward = maths::transform_dir(camera_node.world, { 0, 0, -1 });
    Vec3 up = maths::transform_dir(camera_node.world, { 0, 1, 0 });
    Vec3 side = maths::transform_dir(camera_node.world, { 1, 0, 0 });
    Vec3 point = position + forward * depth + side * right;
    return point + up * (-point.y / up.y);
}

fn CameraMatrices shadow_set_matrices(ShadowSetFixture* fixture, Node* camera_node, uint[<2>] extent) @private {
    Camera lens = *fixture.scene.get(camera_node, Camera);
    return camera::derive_matrices(lens, camera_node.world, { (float)extent.x, (float)extent.y });
}

fn bool shadow_set_pixel_of(
    CameraMatrices* matrices,
    Vec3 world,
    uint width,
    uint height,
    uint[<2>]* pixel,
) @private {
    Vec4 clip = matrices.view_proj.apply({ world.x, world.y, world.z, 1 });
    if (clip.w <= 0) return false;
    float x = (clip.x / clip.w + 1) * 0.5f * (float)width;
    float y = (1 - clip.y / clip.w) * 0.5f * (float)height;
    if (x < 0 || y < 0 || x >= (float)width || y >= (float)height) return false;
    *pixel = { (uint)x, (uint)y };
    return true;
}

fn float shadow_set_luminance(Vec4 color) @private => 0.2126f * color.r + 0.7152f * color.g + 0.0722f * color.b;

fn float shadow_set_probe(
    Vec4[] image,
    CameraMatrices* matrices,
    Vec3 world,
    uint width,
    uint height,
) @private {
    uint[<2>] pixel;
    assert(shadow_set_pixel_of(
        matrices: matrices,
        world:    world,
        width:    width,
        height:   height,
        pixel:    &pixel,
    ));
    return shadow_set_luminance(image[pixel.y * width + pixel.x]);
}

fn void? shadow_set_read_image(ShadowSetFixture* fixture, RenderTargetId target, Vec4[] image) @private {
    return fixture.renderer.read_render_target(target, ((char*)image.ptr)[:image.len * Vec4::size]);
}

fn void? shadow_set_render_main(ShadowSetFixture* fixture) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame(SHADOW_SET_FRAME_INFO)!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&fixture.scene, fixture.main, fixture.main_view)!;
    renderer.finish_view(fixture.main_view)!;
    return renderer.end_frame();
}

fn void? shadow_set_configure_view(ShadowSetFixture* fixture, ViewId view, ShadowSetCase own_case) @private {
    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.shading = own_case == ShadowSetCase.DEFERRED ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
    desc.volumetric_fog = own_case == ShadowSetCase.VOLUMETRIC_FOG;
    render::configure_view(&fixture.renderer, view, desc)!;
    fixture.scene.get(fixture.ground, Mesh).material =
      own_case == ShadowSetCase.STANDARD_LIGHTS ? fixture.standard_lights : fixture.matte;
}

fn void? shadow_set_add_fog(ShadowSetFixture* fixture) @private {
    Node* node = fixture.scene.add_node(name: "fog")!;
    HeightFog fog = {
        .density      = 0.01f,
        .falloff      = 0.05f,
        .albedo       = { 1, 1, 1 },
        .max_distance = SHADOW_SET_SHADOW_DISTANCE,
    };
    fixture.scene.add(node, fog);
    fixture.scene.update_world();
}

// Camera-space depths in the middle of the first two cascades' blend bands.
fn float[2] shadow_set_blend_band_middles(ShadowSetFixture* fixture) @private {
    Camera lens = *fixture.scene.get(fixture.main, Camera);
    ShadowSettings settings = fixture.scene.get(fixture.sun, Light).shadow;
    CascadeSplits splits = render::directional_cascade_splits(lens, settings);
    float[2] depths;
    foreach (uint index, &depth : depths) {
        float start = render::cascade_blend_depth(splits, index, settings.cascade_blend);
        *depth = (start + splits.far_depths[index]) * 0.5f;
    }
    return depths;
}

fn void test_own_shadow_sets_render_unchanged() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    shadow_set_add_fog(&fixture)!!;
    float[2] depths = shadow_set_blend_band_middles(&fixture);
    Vec3[2] shaded;
    foreach (index, depth : depths) {
        shaded[index] = shadow_set_ground_point(fixture.main, depth);
        shadow_set_add_caster_over(&fixture, shaded[index])!!;
    }
    Vec4[] first = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(first);
    Vec4[] second = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(second);
    CameraMatrices matrices = shadow_set_matrices(&fixture, fixture.main, SHADOW_SET_EXTENT);

    for (uint index = 0; index < ShadowSetCase::len; index++) {
        ShadowSetCase own_case = ShadowSetCase::from_ordinal(index);
        shadow_set_configure_view(&fixture, fixture.main_view, own_case)!!;
        shadow_set_render_main(&fixture)!!;
        shadow_set_read_image(&fixture, fixture.main_target, first)!!;
        shadow_set_render_main(&fixture)!!;
        shadow_set_read_image(&fixture, fixture.main_target, second)!!;
        assert(mem::equals(first, second));
        foreach (point_index, point : shaded) {
            float lit = shadow_set_probe(
                image:    first,
                matrices: &matrices,
                world:    shadow_set_ground_point(fixture.main, depths[point_index], SHADOW_SET_LIT_OFFSET),
                width:    SHADOW_SET_WIDTH,
                height:   SHADOW_SET_HEIGHT,
            );
            float shadowed = shadow_set_probe(
                image:    first,
                matrices: &matrices,
                world:    point,
                width:    SHADOW_SET_WIDTH,
                height:   SHADOW_SET_HEIGHT,
            );
            assert(shadowed <= SHADOW_SET_SHADOWED_RATIO * lit);
        }
        ulong hash = fnv64a::hash(((char*)first.ptr)[:first.len * Vec4::size]);
        io::eprintfn("own_set_hash case=%s fnv1a64=%016x", own_case.name, hash);
    }
}
