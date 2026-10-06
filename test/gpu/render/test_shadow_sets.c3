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
const float SHADOW_SET_NO_SHADOW_DISTANCE @private = 0.05f; // under the camera's near plane: no cascade covers anything
const InstanceFade SHADOW_SET_BATCH_FADE @private = { .start = 7.5f, .end = 8.5f };
const Vec3 SHADOW_SET_BATCH_POSITION @private = { 0, 8, 4 }; // 6 m above the main camera, 10 m above the mirror
const float SHADOW_SET_BATCH_SPACING @private = 0.6f; // instances touch, so the batch shades one bar
const uint SHADOW_SET_WALL_COLUMNS @private = 24;
const uint SHADOW_SET_WALL_ROWS @private = 8;
const uint SHADOW_SET_OCCLUSION_MARGIN @private = 2; // pixels kept clear of the board's projection
const float SHADOW_SET_AGREEING_SHARE @private = 0.95f; // of the samples, within SHADOW_SET_REFLECTED_TOLERANCE
const float SHADOW_SET_REFLECTED_TOLERANCE @private = 0.1f; // share of the lit level
const float SHADOW_SET_REFLECTED_MEAN_TOLERANCE @private = 0.03f; // share of the lit level
const float SHADOW_SET_REFLECTED_SHADOWED_SHARE @private = 0.05f; // the board shades at least this share of the samples
const Vec3 SHADOW_SET_BORROWER_OFFSET @private = { 40, 0, 0 }; // inside the shadow camera's last cascade only
const Vec3 SHADOW_SET_FAR_BORROWER_OFFSET @private = { 120, 0, 0 }; // outside every cascade of the shadow camera
const float SHADOW_SET_BORROWER_PROBE_DEPTH @private = 5; // selects the second cascade of the shadow camera's set
const Vec3 SHADOW_SET_BATCH_HALF_EXTENT @private = { 1.2f, 0.3f, 0.3f };
const float SHADOW_SET_LOD_RADIUS @private = 0.6f;
const float SHADOW_SET_LOD_COARSE_BIAS @private = -4; // the mirror selects the coarse sphere; main keeps the fine one
const float SHADOW_SET_LOD_DEPTH @private = 6;
const float SHADOW_SET_LOD_SWITCH_SIZE @private = 0.05f;
const float SHADOW_SET_LOD_COUNT_TOLERANCE @private = 0.06f; // 12 against 32 segments: areas differ by about 4 %
const uint SHADOW_SET_LOD_MINIMUM_SHADOWED @private = 50;
const Vec3 SHADOW_SET_SPOT_POSITION @private = { 0, 3.2f, 0 }; // in the main frustum, its reflection outside it
const float SHADOW_SET_SPOT_RANGE @private = 1;
const float SHADOW_SET_SPOT_INTENSITY @private = 50; // outshines the sun on the panel
const Vec3 SHADOW_SET_PANEL_CENTER @private = { 0, 3.2f, -0.7f };
const Vec3 SHADOW_SET_PANEL_SIZE @private = { 2, 2, 0.2f };
const Vec3 SHADOW_SET_SPOT_CASTER_CENTER @private = { 0, 3.2f, -0.3f };
const float SHADOW_SET_SPOT_CASTER_SIZE @private = 0.2f;
const float SHADOW_SET_SPOT_LIT_OFFSET @private = 0.45f;
const Vec3 SHADOW_SET_CAPTURE_POSITION @private = { 20, 5, 0 };
const Vec3 SHADOW_SET_MIRROR_ONLY_SPOT_POSITION @private = { 0, 19, -30 }; // inside the mirror frustum, above main's

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

fn void? shadow_set_render_pair(ShadowSetFixture* fixture, bool shared = true) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame(SHADOW_SET_FRAME_INFO)!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(
        scene:         &fixture.scene,
        camera_node:   fixture.mirror,
        view:          fixture.mirror_view,
        shadow_camera: shared ? fixture.main : null,
    )!;
    renderer.finish_view(fixture.mirror_view)!;
    renderer.render_view(&fixture.scene, fixture.main, fixture.main_view)!;
    renderer.finish_view(fixture.main_view)!;
    return renderer.end_frame();
}

fn ViewId? shadow_set_add_view(ShadowSetFixture* fixture, uint[<2>] extent, RenderTargetId* target) @private {
    *target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(extent.x, extent.y, PixelFormat.RGBA32_FLOAT),
    )!;
    ViewDesc desc = render::texture_view_desc(*target);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    return render::create_view(&fixture.renderer, desc);
}

fn void? shadow_set_share(ShadowSetFixture* fixture, ViewId view, bool share) @private {
    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.share_shadows = share;
    return render::configure_view(&fixture.renderer, view, desc);
}

fn Node*? shadow_set_add_faded_batch(ShadowSetFixture* fixture) @private {
    Transform[4] transforms;
    foreach (uint index, &transform : transforms) {
        *transform = maths::TRANSFORM_IDENTITY;
        transform.position = { ((float)index - 1.5f) * SHADOW_SET_BATCH_SPACING, 0, 0 };
        transform.scale = { SHADOW_SET_BATCH_SPACING, SHADOW_SET_BATCH_SPACING, SHADOW_SET_BATCH_SPACING };
    }
    Node* node = fixture.scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.matte,
        capacity:   transforms.len,
        transforms: transforms[..],
    )!;
    node.local.position = SHADOW_SET_BATCH_POSITION;
    fixture.scene.get(node, InstancedMesh).fade = SHADOW_SET_BATCH_FADE;
    fixture.scene.update_world();
    return node;
}

fn void test_main_view_binding_the_mirror_set_matches_its_own_set_bitwise() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    // No LodGroup casters: a set the mirror records casts with the mirror's LOD levels.
    shadow_set_add_fog(&fixture)!!;
    float[2] depths = shadow_set_blend_band_middles(&fixture);
    foreach (depth : depths) shadow_set_add_caster_over(&fixture, shadow_set_ground_point(fixture.main, depth))!!;
    shadow_set_add_faded_batch(&fixture)!!;
    Vec4[] own = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(own);
    Vec4[] borrowed = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(borrowed);

    for (uint index = 0; index < ShadowSetCase::len; index++) {
        ShadowSetCase own_case = ShadowSetCase::from_ordinal(index);
        shadow_set_configure_view(&fixture, fixture.main_view, own_case)!!;
        shadow_set_configure_view(&fixture, fixture.mirror_view, own_case)!!;
        shadow_set_render_pair(fixture: &fixture, shared: false)!!;
        shadow_set_read_image(&fixture, fixture.main_target, own)!!;
        shadow_set_render_pair(&fixture)!!;
        assert(fixture.renderer.stats.shadow_sets_shared == 1);
        shadow_set_read_image(&fixture, fixture.main_target, borrowed)!!;
        assert(mem::equals(own, borrowed));
    }
}

fn void test_a_sun_without_layers_binds_none_in_own_and_borrowing_views() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    fixture.scene.get(fixture.sun, Light).shadow.max_distance = SHADOW_SET_NO_SHADOW_DISTANCE;
    Vec4[] own = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(own);
    Vec4[] borrowed = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(borrowed);

    bool[2] borrowing = { false, true };
    foreach (borrows : borrowing) {
        shadow_set_render_pair(fixture: &fixture, shared: borrows)!!;
        // The mirror lights the sun but its set, fitted to main, holds no layers for it.
        assert(renderer.stats.shadow_layers == 0);
        assert(renderer.stats.shadow_lights_unshared == (borrows ? 1 : 0));
        assert(renderer.shadow_set.layer_count == 0 && renderer.shadow_set.light_count == 0);
        assert((ulong)renderer.shadow_set.shadows == 0);
        assert(renderer.stats.shadow_sets_shared == (borrows ? 1 : 0));
        shadow_set_read_image(&fixture, fixture.main_target, borrows ? borrowed : own)!!;
    }
    assert(mem::equals(own, borrowed));
}

fn void test_same_camera_views_share_unless_one_opts_out() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    RenderTargetId target;
    ViewId twin = shadow_set_add_view(&fixture, SHADOW_SET_HALF_EXTENT, &target)!!;
    Vec4[] borrowed = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT / 4);
    defer free(borrowed);
    Vec4[] own = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT / 4);
    defer free(own);
    ViewId[2] views = { fixture.main_view, twin };
    bool[2][3] shares = { { true, true }, { true, false }, { false, true } };

    foreach (frame, share : shares) {
        foreach (index, view : views) shadow_set_share(&fixture, view, share[index])!!;
        renderer.begin_frame(SHADOW_SET_FRAME_INFO)!!;
        foreach (view : views) {
            renderer.render_view(&fixture.scene, fixture.main, view)!!;
            renderer.finish_view(view)!!;
        }
        renderer.end_frame()!!;
        bool shared = share[0] && share[1];
        assert(renderer.stats.shadow_sets_recorded == (shared ? 1 : 2));
        assert(renderer.stats.shadow_sets_shared == (shared ? 1 : 0));
        assert(renderer.view_stats(twin)!!.shadow_set_shared == shared);
        if (frame < 2) shadow_set_read_image(&fixture, target, frame ? own : borrowed)!!;
    }
    assert(mem::equals(borrowed, own));
}

fn Node*? shadow_set_add_lod_sphere(ShadowSetFixture* fixture, Vec3 position) @private {
    GeometryId[2] spheres;
    @pool() {
        Geometry fine = geometry::sphere(
            allocator: tmem,
            radius:    SHADOW_SET_LOD_RADIUS,
            slices:    32,
            stacks:    16,
        );
        spheres[0] = fixture.assets.add_geometry(&fine)!;
        Geometry coarse = geometry::sphere(
            allocator: tmem,
            radius:    SHADOW_SET_LOD_RADIUS,
            slices:    12,
            stacks:    6,
        );
        spheres[1] = fixture.assets.add_geometry(&coarse)!;
    };
    LodLevel[2] levels = {
        { .first_part = 0, .part_count = 1, .min_screen_size = SHADOW_SET_LOD_SWITCH_SIZE },
        { .first_part = 1, .part_count = 1, .min_screen_size = 0 },
    };
    LodPart[2] parts = {
        { .geometry = spheres[0], .material = fixture.matte, .local = matrix::IDENTITY4 },
        { .geometry = spheres[1], .material = fixture.matte, .local = matrix::IDENTITY4 },
    };
    Node* node = fixture.scene.add_lod_group(&fixture.assets, { .levels = levels[..], .parts = parts[..] })!;
    node.local.position = position;
    fixture.scene.update_world();
    return node;
}

// Whether the cascade's map holds the point; depth coverage is not checked.
fn bool shadow_set_cascade_holds(ShadowCascade* cascade, Vec3 point) @private {
    Vec4 clip = cascade.camera.view_proj.apply({ point.x, point.y, point.z, 1 });
    Vec2 uv = { (clip.x / clip.w + 1) * 0.5f, (1 - clip.y / clip.w) * 0.5f };
    return uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1;
}

fn uint shadow_set_darkened_pixels(Vec4[] image, Vec4[] reference) @private {
    uint count;
    foreach (index, pixel : image) {
        if (shadow_set_luminance(pixel) < SHADOW_SET_SHADOWED_RATIO * shadow_set_luminance(reference[index])) count++;
    }
    return count;
}

fn void test_mirror_records_the_main_cameras_set_once_per_frame() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;

    shadow_set_render_pair(&fixture)!!;
    assert(renderer.stats.shadow_sets_recorded == 1 && renderer.stats.shadow_sets_shared == 1);
    assert(renderer.stats.shadow_layers == SHADOW_SET_SUN_CASCADES && renderer.stats.shadow_lights_unshared == 0);
    assert(renderer.view_stats(fixture.main_view)!!.shadow_set_shared);
    assert(!renderer.view_stats(fixture.mirror_view)!!.shadow_set_shared);

    shadow_set_render_pair(fixture: &fixture, shared: false)!!;
    assert(renderer.stats.shadow_sets_recorded == 2 && renderer.stats.shadow_sets_shared == 0);
    assert(renderer.stats.shadow_layers == 2 * SHADOW_SET_SUN_CASCADES);
    assert(!renderer.view_stats(fixture.main_view)!!.shadow_set_shared);
}

fn void test_reflected_receivers_inside_the_main_cascades_match_the_own_set() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    shadow_set_add_fog(&fixture)!!;
    uint width = SHADOW_SET_WIDTH / 2;
    uint height = SHADOW_SET_HEIGHT / 2;
    Vec4[] own = mem::new_array(Vec4, (sz)(width * height));
    defer free(own);
    Vec4[] borrowed = mem::new_array(Vec4, (sz)(width * height));
    defer free(borrowed);
    CameraMatrices matrices = shadow_set_matrices(&fixture, fixture.mirror, SHADOW_SET_HALF_EXTENT);
    uint[<2>] board_min = { width, height };
    uint[<2>] board_max;
    for (uint corner = 0; corner < 8; corner++) {
        Vec3 sign = { corner & 1 ? 1 : -1, corner & 2 ? 1 : -1, corner & 4 ? 1 : -1 };
        uint[<2>] pixel;
        if (!shadow_set_pixel_of(
            matrices: &matrices,
            world:    SHADOW_SET_BOARD_CENTER + sign * SHADOW_SET_BOARD_SIZE * 0.5f,
            width:    width,
            height:   height,
            pixel:    &pixel,
        )) continue;
        board_min = math::min(board_min, pixel);
        board_max = math::max(board_max, pixel);
    }
    bool[2] fogged = { false, true };

    foreach (fog : fogged) {
        ViewDesc desc = fixture.renderer.views.get(fixture.mirror_view).desc;
        desc.volumetric_fog = fog;
        render::configure_view(&fixture.renderer, fixture.mirror_view, desc)!!;
        shadow_set_render_pair(fixture: &fixture, shared: false)!!;
        shadow_set_read_image(&fixture, fixture.mirror_target, own)!!;
        shadow_set_render_pair(&fixture)!!;
        shadow_set_read_image(&fixture, fixture.mirror_target, borrowed)!!;

        float lit;
        float[SHADOW_SET_WALL_COLUMNS * SHADOW_SET_WALL_ROWS] own_samples;
        float[SHADOW_SET_WALL_COLUMNS * SHADOW_SET_WALL_ROWS] borrowed_samples;
        uint count;
        for (uint row = 0; row < SHADOW_SET_WALL_ROWS; row++) {
            for (uint column = 0; column < SHADOW_SET_WALL_COLUMNS; column++) {
                float across = ((float)column + 0.5f) / SHADOW_SET_WALL_COLUMNS - 0.5f;
                Vec3 point = {
                    SHADOW_SET_WALL_CENTER.x + SHADOW_SET_WALL_SIZE.x * across * 0.9f,
                    SHADOW_SET_WALL_SIZE.y * ((float)row + 0.5f) / SHADOW_SET_WALL_ROWS,
                    SHADOW_SET_WALL_CENTER.z + SHADOW_SET_WALL_SIZE.z * 0.5f,
                };
                uint[<2>] pixel;
                if (!shadow_set_pixel_of(
                    matrices: &matrices,
                    world:    point,
                    width:    width,
                    height:   height,
                    pixel:    &pixel,
                )) continue;
                uint margin = SHADOW_SET_OCCLUSION_MARGIN;
                if (pixel.x + margin >= board_min.x && pixel.x <= board_max.x + margin
                    && pixel.y + margin >= board_min.y && pixel.y <= board_max.y + margin) {
                    continue;
                }
                own_samples[count] = shadow_set_luminance(own[pixel.y * width + pixel.x]);
                borrowed_samples[count] = shadow_set_luminance(borrowed[pixel.y * width + pixel.x]);
                lit = math::max(lit, own_samples[count]);
                count++;
            }
        }
        uint shadowed;
        uint agreeing;
        float difference;
        for (uint index = 0; index < count; index++) {
            if (own_samples[index] < SHADOW_SET_SHADOWED_RATIO * lit) shadowed++;
            float delta = math::abs(own_samples[index] - borrowed_samples[index]);
            if (delta <= SHADOW_SET_REFLECTED_TOLERANCE * lit) agreeing++;
            difference += delta;
        }
        io::eprintfn(
            "reflected fog=%s samples=%d shadowed=%d agreeing=%d mean=%.5f lit=%.5f",
            fog,
            count,
            shadowed,
            agreeing,
            difference / count,
            lit,
        );
        assert((float)shadowed >= SHADOW_SET_REFLECTED_SHADOWED_SHARE * count);
        assert((float)agreeing >= SHADOW_SET_AGREEING_SHARE * count);
        assert(difference / count <= SHADOW_SET_REFLECTED_MEAN_TOLERANCE * lit);
    }
}

fn void test_borrowed_set_shadows_a_receiver_its_selected_cascade_misses() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Node* borrower = fixture.scene.add_camera(*fixture.scene.get(fixture.main, Camera), name: "borrower")!!;
    borrower.local.rotation = fixture.main.local.rotation;
    RenderTargetId target;
    ViewId view = shadow_set_add_view(&fixture, SHADOW_SET_EXTENT, &target)!!;
    Vec4[] image = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(image);
    Vec3[2] offsets = { SHADOW_SET_BORROWER_OFFSET, SHADOW_SET_FAR_BORROWER_OFFSET };
    Vec3[2] shaded;
    foreach (index, offset : offsets) {
        borrower.local.position = SHADOW_SET_CAMERA_POSITION + offset;
        fixture.scene.update_world();
        shaded[index] = shadow_set_ground_point(borrower, SHADOW_SET_BORROWER_PROBE_DEPTH);
        shadow_set_add_caster_over(&fixture, shaded[index])!!;
    }

    Camera lens = *fixture.scene.get(fixture.main, Camera);
    ShadowSettings settings = fixture.scene.get(fixture.sun, Light).shadow;
    CascadeSplits splits = render::directional_cascade_splits(lens, settings);
    assert(SHADOW_SET_BORROWER_PROBE_DEPTH > splits.far_depths[0]);
    assert(SHADOW_SET_BORROWER_PROBE_DEPTH <= splits.far_depths[1]);
    CameraMatrices main_matrices = shadow_set_matrices(&fixture, fixture.main, SHADOW_SET_EXTENT);
    ShadowCascade[SHADOW_SET_SUN_CASCADES] cascades;
    foreach (uint index, &cascade : cascades) {
        float near_depth = index
          ? render::cascade_blend_depth(splits, index - 1, settings.cascade_blend) : splits.near_depth;
        *cascade = render::fit_directional_cascade(
            view:               &main_matrices,
            near_depth:         near_depth,
            far_depth:          splits.far_depths[index],
            light_direction:    SHADOW_SET_SUN_TRAVEL.normalize(),
            casters:            {},
            resolution:         SHADOW_SET_SHADOW_RESOLUTION,
            normal_bias_texels: settings.directional_normal_bias_texels,
        );
    }
    assert(!shadow_set_cascade_holds(&cascades[0], shaded[0]));
    assert(!shadow_set_cascade_holds(&cascades[1], shaded[0]) && !shadow_set_cascade_holds(&cascades[2], shaded[0]));
    assert(shadow_set_cascade_holds(&cascades[3], shaded[0]));
    foreach (&cascade : cascades) assert(!shadow_set_cascade_holds(cascade, shaded[1]));

    foreach (index, offset : offsets) {
        borrower.local.position = SHADOW_SET_CAMERA_POSITION + offset;
        fixture.scene.update_world();
        CameraMatrices matrices = shadow_set_matrices(&fixture, borrower, SHADOW_SET_EXTENT);
        Vec3 lit_point = shadow_set_ground_point(borrower, SHADOW_SET_BORROWER_PROBE_DEPTH, SHADOW_SET_LIT_OFFSET);
        bool[2] borrowing = { true, false };
        foreach (borrows : borrowing) {
            renderer.begin_frame(SHADOW_SET_FRAME_INFO)!!;
            renderer.render_view(&fixture.scene, fixture.main, fixture.main_view)!!;
            renderer.finish_view(fixture.main_view)!!;
            renderer.render_view(
                scene:         &fixture.scene,
                camera_node:   borrower,
                view:          view,
                shadow_camera: borrows ? fixture.main : null,
            )!!;
            renderer.finish_view(view)!!;
            renderer.end_frame()!!;
            assert(renderer.stats.shadow_sets_shared == (borrows ? 1 : 0));
            shadow_set_read_image(&fixture, target, image)!!;
            float shadowed = shadow_set_probe(
                image:    image,
                matrices: &matrices,
                world:    shaded[index],
                width:    SHADOW_SET_WIDTH,
                height:   SHADOW_SET_HEIGHT,
            );
            float lit = shadow_set_probe(
                image:    image,
                matrices: &matrices,
                world:    lit_point,
                width:    SHADOW_SET_WIDTH,
                height:   SHADOW_SET_HEIGHT,
            );
            io::eprintfn(
                "borrower index=%d borrows=%s shadowed=%.5f lit=%.5f",
                index,
                borrows,
                shadowed,
                lit,
            );
            // The near probe falls through to the last cascade; the far one misses every cascade and reads lit.
            assert((shadowed <= SHADOW_SET_SHADOWED_RATIO * lit) == (!borrows || index == 0));
        }
    }
}

fn void test_spot_outside_the_mirror_frustum_shadows_the_main_view() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Light spot = light::spot(
        color:     { 1, 1, 1 },
        intensity: SHADOW_SET_SPOT_INTENSITY,
        inner:     0.7f,
        outer:     0.8f,
        range:     SHADOW_SET_SPOT_RANGE,
    );
    spot.shadow.enabled = true;
    Node* spot_node = fixture.scene.add_light(spot)!!;
    spot_node.local.position = SHADOW_SET_SPOT_POSITION;
    shadow_set_add_box(&fixture, SHADOW_SET_PANEL_CENTER, SHADOW_SET_PANEL_SIZE)!!;
    Vec3 caster_size = { SHADOW_SET_SPOT_CASTER_SIZE, SHADOW_SET_SPOT_CASTER_SIZE, SHADOW_SET_SPOT_CASTER_SIZE };
    shadow_set_add_box(&fixture, SHADOW_SET_SPOT_CASTER_CENTER, caster_size)!!;
    CameraMatrices main_matrices = shadow_set_matrices(&fixture, fixture.main, SHADOW_SET_EXTENT);
    CameraMatrices mirror_matrices = shadow_set_matrices(&fixture, fixture.mirror, SHADOW_SET_HALF_EXTENT);
    Sphere reach = { .center = SHADOW_SET_SPOT_POSITION, .radius = SHADOW_SET_SPOT_RANGE };
    assert(maths::frustum_intersects_sphere(&main_matrices.frustum, reach));
    assert(!maths::frustum_intersects_sphere(&mirror_matrices.frustum, reach));
    Vec4[] image = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(image);
    Vec3 face = SHADOW_SET_PANEL_CENTER + (Vec3){ 0, 0, SHADOW_SET_PANEL_SIZE.z * 0.5f };

    shadow_set_render_pair(&fixture)!!;
    assert(renderer.stats.shadow_sets_shared == 1);
    assert(renderer.stats.shadow_layers == SHADOW_SET_SUN_CASCADES + 1 && renderer.stats.shadow_lights_unshared == 0);
    shadow_set_read_image(&fixture, fixture.main_target, image)!!;
    float shadowed = shadow_set_probe(
        image:    image,
        matrices: &main_matrices,
        world:    face,
        width:    SHADOW_SET_WIDTH,
        height:   SHADOW_SET_HEIGHT,
    );
    float lit = shadow_set_probe(
        image:    image,
        matrices: &main_matrices,
        world:    face + (Vec3){ SHADOW_SET_SPOT_LIT_OFFSET, 0, 0 },
        width:    SHADOW_SET_WIDTH,
        height:   SHADOW_SET_HEIGHT,
    );
    assert(shadowed <= SHADOW_SET_SHADOWED_RATIO * lit);
}

fn void test_light_only_the_mirror_sees_draws_unshadowed_and_counts() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Light spot = light::spot(
        color:     { 1, 1, 1 },
        intensity: SHADOW_SET_SPOT_INTENSITY,
        inner:     0.7f,
        outer:     0.8f,
        range:     SHADOW_SET_SPOT_RANGE,
    );
    spot.shadow.enabled = true;
    Node* spot_node = fixture.scene.add_light(spot)!!;
    spot_node.local.position = SHADOW_SET_MIRROR_ONLY_SPOT_POSITION;
    fixture.scene.update_world();
    CameraMatrices main_matrices = shadow_set_matrices(&fixture, fixture.main, SHADOW_SET_EXTENT);
    CameraMatrices mirror_matrices = shadow_set_matrices(&fixture, fixture.mirror, SHADOW_SET_HALF_EXTENT);
    Sphere reach = { .center = SHADOW_SET_MIRROR_ONLY_SPOT_POSITION, .radius = SHADOW_SET_SPOT_RANGE };
    assert(!maths::frustum_intersects_sphere(&main_matrices.frustum, reach));
    assert(maths::frustum_intersects_sphere(&mirror_matrices.frustum, reach));

    shadow_set_render_pair(&fixture)!!;
    assert(renderer.stats.shadow_sets_recorded == 1 && renderer.stats.shadow_sets_shared == 1);
    assert(renderer.stats.shadow_layers == SHADOW_SET_SUN_CASCADES);
    assert(renderer.stats.shadow_lights_unshared == 1);
}

fn void test_faded_batch_beyond_the_mirror_fade_shadows_the_main_view() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    Node* batch = shadow_set_add_faded_batch(&fixture)!!;
    Vec3 anchor = maths::translation(batch.world);
    Vec3 mirror_position = maths::translation(fixture.mirror.world);
    Vec3 half = SHADOW_SET_BATCH_HALF_EXTENT;
    Vec3 nearest = math::clamp(mirror_position, anchor - half, anchor + half);
    assert(nearest.distance(mirror_position) > SHADOW_SET_BATCH_FADE.end);
    float main_reach = anchor.distance(maths::translation(fixture.main.world)) + SHADOW_SET_BATCH_HALF_EXTENT.length();
    assert(main_reach < SHADOW_SET_BATCH_FADE.start);
    Vec3 travel = SHADOW_SET_SUN_TRAVEL.normalize();
    Vec3 shaded = anchor + travel * (anchor.y / -travel.y);
    CameraMatrices matrices = shadow_set_matrices(&fixture, fixture.main, SHADOW_SET_EXTENT);
    Vec4[] image = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(image);

    shadow_set_render_pair(&fixture)!!;
    assert(fixture.renderer.stats.shadow_sets_shared == 1);
    shadow_set_read_image(&fixture, fixture.main_target, image)!!;
    float shadowed = shadow_set_probe(
        image:    image,
        matrices: &matrices,
        world:    shaded,
        width:    SHADOW_SET_WIDTH,
        height:   SHADOW_SET_HEIGHT,
    );
    float lit = shadow_set_probe(
        image:    image,
        matrices: &matrices,
        world:    shaded + (Vec3){ SHADOW_SET_LIT_OFFSET, 0, 0 },
        width:    SHADOW_SET_WIDTH,
        height:   SHADOW_SET_HEIGHT,
    );
    assert(shadowed <= SHADOW_SET_SHADOWED_RATIO * lit);
}

fn void test_lod_caster_shadow_in_a_shared_set_stays_within_tolerance() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    ViewDesc desc = fixture.renderer.views.get(fixture.mirror_view).desc;
    desc.lod_bias = SHADOW_SET_LOD_COARSE_BIAS;
    render::configure_view(&fixture.renderer, fixture.mirror_view, desc)!!;
    Vec3 receiver = shadow_set_ground_point(fixture.main, SHADOW_SET_LOD_DEPTH);
    Vec3 travel = SHADOW_SET_SUN_TRAVEL.normalize();
    Node* sphere = shadow_set_add_lod_sphere(&fixture, receiver - travel * (SHADOW_SET_CASTER_HEIGHT / -travel.y))!!;
    Vec4[] reference = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(reference);
    Vec4[] own = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(own);
    Vec4[] borrowed = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(borrowed);

    sphere.visible = false;
    fixture.scene.update_world();
    shadow_set_render_pair(&fixture)!!;
    shadow_set_read_image(&fixture, fixture.main_target, reference)!!;
    sphere.visible = true;
    fixture.scene.update_world();
    shadow_set_render_pair(fixture: &fixture, shared: false)!!;
    shadow_set_read_image(&fixture, fixture.main_target, own)!!;
    shadow_set_render_pair(&fixture)!!;
    shadow_set_read_image(&fixture, fixture.main_target, borrowed)!!;

    uint own_count = shadow_set_darkened_pixels(own, reference);
    uint borrowed_count = shadow_set_darkened_pixels(borrowed, reference);
    io::eprintfn("lod shadow pixels own=%d borrowed=%d", own_count, borrowed_count);
    assert(!mem::equals(own, borrowed));
    assert(own_count >= SHADOW_SET_LOD_MINIMUM_SHADOWED);
    assert(math::abs((float)borrowed_count - (float)own_count) <= SHADOW_SET_LOD_COUNT_TOLERANCE * own_count);
}

fn void test_a_recording_between_mirror_and_main_makes_main_record() @test {
    ShadowSetFixture fixture;
    shadow_set_create_fixture(&fixture)!!;
    defer shadow_set_destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Node* capture = fixture.scene.add_camera(*fixture.scene.get(fixture.main, Camera), name: "capture")!!;
    capture.local.position = SHADOW_SET_CAPTURE_POSITION;
    capture.local.rotation = maths::look_rotation(SHADOW_SET_WALL_CENTER - SHADOW_SET_CAPTURE_POSITION, { 0, 1, 0 });
    fixture.scene.update_world();
    RenderTargetId target;
    ViewId capture_view = shadow_set_add_view(&fixture, SHADOW_SET_HALF_EXTENT, &target)!!;
    Vec4[] borrowed = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(borrowed);
    Vec4[] recorded = mem::new_array(Vec4, SHADOW_SET_WIDTH * SHADOW_SET_HEIGHT);
    defer free(recorded);

    shadow_set_render_pair(&fixture)!!;
    shadow_set_read_image(&fixture, fixture.main_target, borrowed)!!;
    bool[2] capture_first = { true, false };
    foreach (first : capture_first) {
        renderer.begin_frame(SHADOW_SET_FRAME_INFO)!!;
        renderer.render_view(
            scene:         &fixture.scene,
            camera_node:   fixture.mirror,
            view:          fixture.mirror_view,
            shadow_camera: fixture.main,
        )!!;
        renderer.finish_view(fixture.mirror_view)!!;
        if (first) {
            renderer.render_view(&fixture.scene, capture, capture_view)!!;
            renderer.finish_view(capture_view)!!;
        }
        renderer.render_view(&fixture.scene, fixture.main, fixture.main_view)!!;
        renderer.finish_view(fixture.main_view)!!;
        if (!first) {
            renderer.render_view(&fixture.scene, capture, capture_view)!!;
            renderer.finish_view(capture_view)!!;
        }
        renderer.end_frame()!!;
        assert(renderer.stats.shadow_sets_recorded == (first ? 3 : 2));
        assert(renderer.stats.shadow_sets_shared == (first ? 0 : 1));
        assert(renderer.view_stats(fixture.main_view)!!.shadow_set_shared == !first);
        if (first) {
            shadow_set_read_image(&fixture, fixture.main_target, recorded)!!;
            assert(mem::equals(borrowed, recorded));
        }
    }
}
