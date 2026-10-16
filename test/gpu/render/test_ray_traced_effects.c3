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
const Vec3 BLOCKER_POSITION @private = { 0, 0.5f, 1.25f }; // on the camera ray to the emitter image point
const int FORWARD_DEFERRED_TOLERANCE @private = 12; // loose: the two stages evaluate one surface through different code
const float EMITTER_SHEET_SIZE @private = 2; // wide enough to hold the emitter image point's reflection ray
const Vec3 LAMP_POSITION @private = { 0, 4.45f, -3.674f }; // 1.5 from the hit point along the top frustum plane's normal
const float LAMP_RANGE @private = 1.9f; // reaches the hit point and stops short of the view frustum
const float LAMP_INTENSITY @private = 40;
const int LAMP_LIT_MINIMUM @private = 40;
const uint PATH_LAMP_TARGET_SIZE @private = 32;
const uint PATH_LAMP_SAMPLES @private = 64;
const uint PATH_LAMP_RECEIVER_LAYERS @private = 1;
const float PATH_LAMP_MINIMUM @private = 0.15f;
const float PATH_LAMP_DARK_TOLERANCE @private = 0.001f;
const uint HIT_LAMP_FRAMES @private = 32;
const uint HIT_LAMP_RAYS @private = 4;
const uint HIT_LAMP_TOON_STEPS @private = 8;
const int HIT_LAMP_MINIMUM @private = 10;
const uint EXCLUDED_RECEIVER_LAYERS @private = 2; // the emitter carries the default layer only
const Vec3 COAT_LAMP_POSITION @private = { 0, 3.649f, -2.977f }; // along the floor ray mirrored about the panel face
const float COAT_LAMP_RANGE @private = 1.4f; // reaches the hit point and stops short of the floor
const float COAT_LAMP_INTENSITY @private = 6;
const float COAT_ROUGHNESS @private = 0.3f;
const float HIGH_INDEX @private = 2.4f;
const Vec3 TINTED_SPECULAR @private = { 1, 0.5f, 0.2f };
const float GLASS_THICKNESS @private = 0.5f;
const int COAT_MINIMUM @private = 20;
const Vec3 FABRIC_SHEEN_COLOR @private = { 1, 1, 1 };
const float FABRIC_SHEEN_ROUGHNESS @private = 1;
const int FABRIC_MINIMUM @private = 10;
const float BRUSHED_ROUGHNESS @private = 0.6f;
const int BRUSHED_MINIMUM @private = 20;
const HeightFog HAZE @private = { .density = 0.12f, .falloff = 0.05f, .albedo = { 0, 0, 1 }, .max_distance = 100 };
const Vec3 FAR_EMITTER_POSITION @private = { 0, 5.667f, -8 }; // on the same reflected ray, twice as far
const int FOG_MINIMUM @private = 10; // half the smallest separation measured between the fogged images
const Atmosphere DENSE_AIR @private = {
    .planet_radius         = 6_360_000,
    .atmosphere_height     = 2_000,
    .rayleigh_scattering   = { 0.02f, 0.06f, 0.16f },
    .rayleigh_scale_height = 10,
    .mie_scattering        = 0,
    .mie_absorption        = 0,
    .mie_scale_height      = 1_200,
    .mie_anisotropy        = 0,
    .ozone_absorption      = { 0, 0, 0 },
    .ozone_center_altitude = 1_000,
    .ozone_half_width      = 500,
    .ground_albedo         = { 0.3f, 0.3f, 0.3f },
    .sun_angular_radius    = 0.004675f,
    .observer_altitude     = 0,
};
const float AIR_SUN_INTENSITY @private = 10;
const int AIR_MINIMUM @private = 10; // about half the smaller change measured between the near and far images

struct FloorKinds @private {
    Fixture*     fixture;
    MirrorScene* mirror;
    ViewId       view;
}

struct PhysicalPanel @private {
    Fixture*     fixture;
    MirrorScene* mirror;
    ViewId       view;
}

struct MirrorScene @private {
    Scene       scene;
    Node*       camera;
    MaterialId  mirror;
    MaterialId  rough;
    Node*       floor;
    Node*       emitter;
    StandardParams glow;
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
    result.glow = { .base_color = { 0, 0, 0, 1 }, .emissive = { 1, 0, 0 }, .emissive_strength = 1, .roughness = 1 };
    MaterialId emitter = fixture.assets.add_material(material::standard(result.glow))!;

    result.floor = result.scene.add_mesh(floor, result.mirror, name: "floor")!;
    result.emitter = result.scene.add_mesh(panel, emitter, name: "emitter")!;
    result.emitter.local.position = EMITTER_POSITION;
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
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
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
            io::eprintfn(
                "%s, %s ray traced: crease %d -> %d, open %d -> %d",
                trace_name(ray_queries),
                shading,
                crease_none,
                crease_ao,
                open_none,
                open_ao,
            );

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
        io::eprintfn(
            "%s, crease ratio: gtao %.3f, ray traced (%d rays) %.3f",
            trace_name(ray_queries),
            screen_space_ratio,
            ray_traced.ray_count,
            ray_traced_ratio,
        );
        assert(screen_space_ratio < CREASE_RATIO_MAXIMUM && ray_traced_ratio < CREASE_RATIO_MAXIMUM);
        check_validation(&fixture.renderer);
    }
}

fn void test_forward_surfaces_of_a_deferred_view_use_their_own_normals() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        CreaseScene crease = create_crease_scene(&fixture)!!;
        defer scene::destroy_scene(&crease.scene);
        ToonParams toon = material::TOON_PARAMS_DEFAULT;
        toon.color = { LIT_ALBEDO, LIT_ALBEDO, LIT_ALBEDO, 1 };
        MaterialId forward_only = fixture.assets.add_material(material::toon(toon))!!;
        crease.scene.get(crease.floor, Mesh).material = forward_only;
        AoView ao_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &ao_view);
        crease.view = ao_view.view;

        int crease_none = red(render_and_read(&fixture, &crease, CREASE_POINT)!!);
        int open_none = red(render_and_read(&fixture, &crease, OPEN_POINT)!!);
        AoKind[2] kinds = { AoKind.SSAO, AoKind.RAY_TRACED };
        foreach (kind : kinds) {
            AmbientOcclusionDesc ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
            ambient_occlusion.kind = kind;
            set_ambient_occlusion(&fixture, ao_view.view, ambient_occlusion)!!;
            int crease_ao = red(render_and_read(&fixture, &crease, CREASE_POINT)!!);
            int open_ao = red(render_and_read(&fixture, &crease, OPEN_POINT)!!);
            io::eprintfn(
                "%s, %s on a forward surface: crease %d -> %d, open %d -> %d",
                trace_name(ray_queries),
                kind,
                crease_none,
                crease_ao,
                open_none,
                open_ao,
            );
            assert((float)crease_ao < CREASE_RATIO_MAXIMUM * (float)crease_none);
            assert((float)open_ao > OPEN_RATIO_MINIMUM * (float)open_none);
        }
        check_validation(&fixture.renderer);
    }
}

fn void test_reflection_images_follow_the_settings() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
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
}

fn uint? render_view_pair(
    Fixture* fixture,
    MirrorScene* mirror,
    ViewId[2] views,
    uint sampled,
    Vec3 point,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    foreach (view : views) renderer.render_view(&mirror.scene, mirror.camera, view)!;
    sample(fixture, render::read_view_color(views[sampled]), mirror_uv(mirror, point))!;
    record_readback(fixture)!;
    foreach (view : views) renderer.finish_view(view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn uint? post_dispatches_of_frame(Fixture* fixture, MirrorScene* mirror, ViewId view) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&mirror.scene, mirror.camera, view)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    return renderer.stats.post_dispatches;
}

fn void test_forward_view_reflects_the_emitter_like_a_deferred_view() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        print_adapter(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
        defer scene::destroy_scene(&mirror.scene);
        AoView forward = create_ao_view(&fixture, ShadingPath.FORWARD)!!;
        defer destroy_ao_view(&fixture, &forward);
        AoView deferred = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &deferred);
        ViewId[2] views = { forward.view, deferred.view };
        ViewRecord* record = fixture.renderer.views.get(forward.view);

        assert(!record.reflection_gbuffer.texture.is_valid());
        uint off_dispatches = post_dispatches_of_frame(&fixture, &mirror, forward.view)!!;
        uint image_off = render_view_pair(&fixture, &mirror, views, 0, EMITTER_IMAGE_POINT)!!;

        set_reflections(&fixture, forward.view, true)!!;
        set_reflections(&fixture, deferred.view, true)!!;
        assert(record.reflection_gbuffer.texture.is_valid());
        assert(record.reflection_gbuffer.format == gpu::Format.RGBA16_FLOAT);
        assert(record.reflection_gbuffer.width == AO_TARGET_WIDTH);
        assert(record.reflection_gbuffer.height == AO_TARGET_HEIGHT);
        assert(!fixture.renderer.views.get(deferred.view).reflection_gbuffer.texture.is_valid());
        uint on_dispatches = post_dispatches_of_frame(&fixture, &mirror, forward.view)!!;
        assert(on_dispatches == off_dispatches + 2);

        uint forward_image = render_view_pair(&fixture, &mirror, views, 0, EMITTER_IMAGE_POINT)!!;
        uint deferred_image = render_view_pair(&fixture, &mirror, views, 1, EMITTER_IMAGE_POINT)!!;
        uint forward_miss = render_view_pair(&fixture, &mirror, views, 0, MISS_POINT)!!;
        uint deferred_miss = render_view_pair(&fixture, &mirror, views, 1, MISS_POINT)!!;
        io::eprintfn(
            "%s, forward vs deferred: emitter off %06x forward %06x deferred %06x; miss forward %06x deferred %06x",
            trace_name(ray_queries),
            image_off,
            forward_image,
            deferred_image,
            forward_miss,
            deferred_miss,
        );

        assert(red(image_off) < DARK_MAXIMUM);
        assert(red(forward_image) > EMITTER_MINIMUM && green(forward_image) < DARK_MAXIMUM);
        assert(red(deferred_image) > EMITTER_MINIMUM);
        assert(math::abs(red(forward_image) - red(deferred_image)) <= FORWARD_DEFERRED_TOLERANCE);
        assert(math::abs(blue(forward_miss) - blue(deferred_miss)) <= FORWARD_DEFERRED_TOLERANCE);

        ViewDesc desc = record.desc;
        desc.shading = ShadingPath.DEFERRED;
        render::configure_view(&fixture.renderer, forward.view, desc)!!;
        assert(!record.reflection_gbuffer.texture.is_valid() && record.reflection.texture.is_valid());
        desc.shading = ShadingPath.FORWARD;
        render::configure_view(&fixture.renderer, forward.view, desc)!!;
        assert(record.reflection_gbuffer.texture.is_valid());
        render::resize_render_target(&fixture.renderer, forward.target, AO_TARGET_WIDTH + 16, AO_TARGET_HEIGHT + 8)!!;
        assert(record.reflection_gbuffer.width == AO_TARGET_WIDTH + 16);
        assert(record.reflection_gbuffer.height == AO_TARGET_HEIGHT + 8);
        assert(post_dispatches_of_frame(&fixture, &mirror, forward.view)!! == on_dispatches);

        set_reflections(&fixture, forward.view, false)!!;
        assert(!record.reflection_gbuffer.texture.is_valid() && !record.reflection.texture.is_valid());
        assert(post_dispatches_of_frame(&fixture, &mirror, forward.view)!! == off_dispatches);
        check_validation(&fixture.renderer);
    }
}

fn uint? FloorKinds.render(&self, MaterialId material) @private {
    self.mirror.scene.get(self.mirror.floor, Mesh).material = material;
    self.fixture.renderer.prepare_scene(&self.mirror.scene)!;
    return render_mirror(self.fixture, self.mirror, self.view, EMITTER_IMAGE_POINT);
}

fn void test_forward_reflections_trace_standard_and_plain_physical_surfaces_only() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
        defer scene::destroy_scene(&mirror.scene);
        AoView forward = create_ao_view(&fixture, ShadingPath.FORWARD)!!;
        defer destroy_ao_view(&fixture, &forward);
        set_reflections(&fixture, forward.view, true)!!;
        FloorKinds floors = { .fixture = &fixture, .mirror = &mirror, .view = forward.view };

        StandardParams metal = { .base_color = { 1, 1, 1, 1 }, .metallic = 1, .roughness = MIRROR_ROUGHNESS };
        MaterialCommon cutout = material::MATERIAL_COMMON_DEFAULT;
        cutout.alpha_mode = AlphaMode.MASK;
        cutout.alpha_cutoff = 0.5f;
        PhysicalParams plain = material::PHYSICAL_PARAMS_DEFAULT;
        plain.standard = metal;
        PhysicalParams coated = plain;
        coated.clearcoat = 1;
        ToonParams toon = material::TOON_PARAMS_DEFAULT;
        toon.color = { 1, 1, 1, 1 };

        uint standard = floors.render(mirror.mirror)!!;
        uint masked = floors.render(fixture.assets.add_material(material::standard(params: metal, common: cutout))!!)!!;
        uint plain_physical = floors.render(fixture.assets.add_material(material::physical(plain))!!)!!;
        uint coated_physical = floors.render(fixture.assets.add_material(material::physical(coated))!!)!!;
        uint toon_floor = floors.render(fixture.assets.add_material(material::toon(toon))!!)!!;

        mirror.scene.get(mirror.floor, Mesh).material = mirror.mirror;
        GeometryId blocker_geometry;
        @pool() {
            Geometry blocker_shape = geometry::box(tmem, 0.2f, 0.2f, 0.2f);
            blocker_geometry = fixture.assets.add_geometry(&blocker_shape)!!;
        };
        Node* blocker = mirror.scene.add_mesh(
            blocker_geometry,
            fixture.assets.add_material(material::toon(toon))!!,
            name: "blocker",
        )!!;
        blocker.local.position = BLOCKER_POSITION;
        mirror.scene.update_world();
        uint covered = floors.render(mirror.mirror)!!;
        io::eprintfn(
            "%s, forward floors: standard %06x, mask %06x, physical %06x, clearcoat %06x, toon %06x, covered %06x",
            trace_name(ray_queries),
            standard,
            masked,
            plain_physical,
            coated_physical,
            toon_floor,
            covered,
        );

        assert(red(standard) > EMITTER_MINIMUM);
        assert(math::abs(red(masked) - red(standard)) <= MIRROR_TOLERANCE);
        assert(math::abs(red(plain_physical) - red(standard)) <= FORWARD_DEFERRED_TOLERANCE);
        assert(red(coated_physical) < DARK_MAXIMUM);
        assert(red(toon_floor) < DARK_MAXIMUM);
        assert(red(covered) < DARK_MAXIMUM);
        check_validation(&fixture.renderer);
    }
}

fn void test_reflections_show_an_off_screen_emitter() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
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
        io::eprintfn(
            "%s, emitter image: off %06x on %06x; miss: off %06x on %06x",
            trace_name(ray_queries),
            image_off,
            image_on,
            miss_off,
            miss_on,
        );

        assert(red(image_off) < DARK_MAXIMUM && blue(image_off) < DARK_MAXIMUM);
        assert(red(image_on) > EMITTER_MINIMUM && green(image_on) < DARK_MAXIMUM);
        float ambient = MIRROR_AMBIENT_INTENSITY * 255;
        assert(blue(miss_off) < DARK_MAXIMUM);
        assert((float)blue(miss_on) >= MISS_WEIGHT_MINIMUM * ambient && (float)blue(miss_on) <= ambient + 1);
        assert(red(miss_on) < DARK_MAXIMUM);
        check_validation(&fixture.renderer);
    }
}

fn void test_reflections_leave_rough_pixels_to_the_environment() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, true)!!;
        defer scene::destroy_scene(&mirror.scene);
        mirror.scene.get(mirror.floor, Mesh).material = mirror.rough;
        AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &mirror_view);

        uint reflections_off = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        set_reflections(&fixture, mirror_view.view, true)!!;
        uint reflections_on = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        io::eprintfn("%s, rough floor: off %06x on %06x", trace_name(ray_queries), reflections_off, reflections_on);

        assert(red(reflections_off) > DARK_MAXIMUM);
        assert(math::abs(red(reflections_on) - red(reflections_off)) <= MIRROR_TOLERANCE);
        assert(math::abs(green(reflections_on) - green(reflections_off)) <= MIRROR_TOLERANCE);
        assert(math::abs(blue(reflections_on) - blue(reflections_off)) <= MIRROR_TOLERANCE);
        check_validation(&fixture.renderer);
    }
}

fn void test_reflections_skip_a_single_sided_panel_seen_from_behind() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
        defer scene::destroy_scene(&mirror.scene);
        AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &mirror_view);
        set_reflections(&fixture, mirror_view.view, true)!!;
        GeometryId sheet;
        @pool() {
            Geometry plane = geometry::plane(tmem, EMITTER_SHEET_SIZE, EMITTER_SHEET_SIZE);
            sheet = fixture.assets.add_geometry(&plane)!!;
        };
        MaterialCommon both_faces = material::MATERIAL_COMMON_DEFAULT;
        both_faces.double_sided = true;
        MaterialId double_sided = fixture.assets.add_material(material::standard(mirror.glow, both_faces))!!;
        // The sheet's front faces up, away from the floor that reflects it.
        Mesh* emitter = mirror.scene.get(mirror.emitter, Mesh);
        emitter.geometry = sheet;
        mirror.scene.update_world();

        uint single_sided = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        emitter.material = double_sided;
        uint both = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        io::eprintfn(
            "%s, sheet seen from behind: single-sided %06x, double-sided %06x",
            trace_name(ray_queries),
            single_sided,
            both,
        );
        float ambient = MIRROR_AMBIENT_INTENSITY * 255;
        assert(red(single_sided) < DARK_MAXIMUM && (float)blue(single_sided) >= MISS_WEIGHT_MINIMUM * ambient);
        assert(red(both) > EMITTER_MINIMUM && green(both) < DARK_MAXIMUM);
        check_validation(&fixture.renderer);
    }
}

fn void test_reflections_show_a_mirrored_emitter_like_its_twin() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
        defer scene::destroy_scene(&mirror.scene);
        AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &mirror_view);
        set_reflections(&fixture, mirror_view.view, true)!!;

        uint twin = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        mirror.emitter.local.scale = { -1, 1, 1 };
        mirror.scene.update_world();
        uint mirrored = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        io::eprintfn("%s, emitter image: twin %06x, mirrored %06x", trace_name(ray_queries), twin, mirrored);
        assert(red(twin) > EMITTER_MINIMUM);
        assert(math::abs(red(mirrored) - red(twin)) <= MIRROR_TOLERANCE);
        assert(math::abs(green(mirrored) - green(twin)) <= MIRROR_TOLERANCE);
        assert(math::abs(blue(mirrored) - blue(twin)) <= MIRROR_TOLERANCE);
        check_validation(&fixture.renderer);
    }
}

fn void test_reflections_light_a_hit_from_an_off_camera_lamp_by_receiver_layers() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
        defer scene::destroy_scene(&mirror.scene);
        AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &mirror_view);
        set_reflections(&fixture, mirror_view.view, true)!!;

        StandardParams plain = { .base_color = { 1, 1, 1, 1 }, .metallic = 0, .roughness = 1 };
        mirror.scene.get(mirror.emitter, Mesh).material = fixture.assets.add_material(material::standard(plain))!!;
        Camera* camera = mirror.scene.get(mirror.camera, Camera);
        CameraMatrices matrices = camera::derive_matrices(
            *camera,
            mirror.camera.world,
            { AO_TARGET_WIDTH, AO_TARGET_HEIGHT },
        );
        assert(!maths::frustum_intersects_sphere(&matrices.frustum, { .center = LAMP_POSITION, .radius = LAMP_RANGE }));

        uint unlit = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        Node* excluded = mirror.scene.add_light(light::point({ 1, 0, 0 }, LAMP_INTENSITY, LAMP_RANGE))!!;
        excluded.local.position = LAMP_POSITION;
        mirror.scene.get(excluded, Light).layers = EXCLUDED_RECEIVER_LAYERS;
        mirror.scene.update_world();
        uint excluded_lit = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        Node* lamp = mirror.scene.add_light(light::point({ 1, 0, 0 }, LAMP_INTENSITY, LAMP_RANGE))!!;
        lamp.local.position = LAMP_POSITION;
        mirror.scene.update_world();
        uint lit = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        io::eprintfn(
            "%s, off-camera lamp: none %06x, excluded %06x, receiving %06x",
            trace_name(ray_queries),
            unlit,
            excluded_lit,
            lit,
        );
        assert(math::abs(red(excluded_lit) - red(unlit)) <= MIRROR_TOLERANCE);
        assert(red(lit) > red(unlit) + LAMP_LIT_MINIMUM);
        check_validation(&fixture.renderer);
    }
}

fn uint? render_hit_lamp_frames(Fixture* fixture, MirrorScene* mirror, ViewId view) @private {
    uint pixel;
    for (uint frame = 0; frame < HIT_LAMP_FRAMES; frame++) {
        pixel = render_mirror(
            fixture: fixture,
            mirror: mirror,
            view: view,
            point: EMITTER_IMAGE_POINT,
        )!;
    }
    return pixel;
}

fn void test_reflections_light_toon_and_custom_hits_from_an_off_camera_lamp() @test {
    ShadingPath[2] paths = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
    MaterialKind[2] kinds = { MaterialKind.TOON, MaterialKind.CUSTOM };
    foreach (ray_queries : TRACE_KINDS) {
        foreach (shading : paths) {
            foreach (kind : kinds) {
                Fixture fixture;
                create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
                defer destroy_fixture(&fixture);
                MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
                defer scene::destroy_scene(&mirror.scene);
                MaterialId panel;
                if (kind == MaterialKind.TOON) {
                    ToonParams toon = material::TOON_PARAMS_DEFAULT;
                    toon.color = { 1, 1, 1, 1 };
                    toon.steps = HIT_LAMP_TOON_STEPS;
                    panel = fixture.assets.add_material(material::toon(toon))!!;
                } else {
                    StandardParams plain = { .base_color = { 1, 1, 1, 1 }, .roughness = 1 };
                    panel = twin_material(&fixture, add_twin_shader(&fixture, false)!!, plain)!!;
                }
                mirror.scene.get(mirror.emitter, Mesh).material = panel;
                Camera* camera = mirror.scene.get(mirror.camera, Camera);
                CameraMatrices matrices = camera::derive_matrices(
                    *camera,
                    mirror.camera.world,
                    { AO_TARGET_WIDTH, AO_TARGET_HEIGHT },
                );
                assert(!maths::frustum_intersects_sphere(&matrices.frustum, {
                    .center = LAMP_POSITION,
                    .radius = LAMP_RANGE,
                }));
                AoView shot = create_ao_view(&fixture, shading)!!;
                defer destroy_ao_view(&fixture, &shot);
                ViewDesc desc = fixture.renderer.views.get(shot.view).desc;
                desc.ray_tracing.reflections = true;
                desc.ray_tracing.reflection_rays = HIT_LAMP_RAYS;
                desc.ray_tracing.reflection_resolution = ReflectionResolution.FULL;
                desc.ray_tracing.reflection_history = true;
                render::configure_view(&fixture.renderer, shot.view, desc)!!;

                uint unlit = render_hit_lamp_frames(&fixture, &mirror, shot.view)!!;
                Node* lamp = mirror.scene.add_light(light::point({ 1, 0, 0 }, LAMP_INTENSITY, LAMP_RANGE))!!;
                lamp.local.position = LAMP_POSITION;
                mirror.scene.update_world();
                uint lit = render_hit_lamp_frames(&fixture, &mirror, shot.view)!!;
                io::eprintfn(
                    "%s, %s %s hit: unlit %06x, lit %06x",
                    trace_name(ray_queries),
                    shading,
                    kind,
                    unlit,
                    lit,
                );
                assert(red(lit) > red(unlit) + HIT_LAMP_MINIMUM);
                check_validation(&fixture.renderer);
            }
        }
    }
}

fn Vec4? path_off_camera_lamp(uint receiver_layers, uint bounces, bool lamp_enabled) @private {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!;
    defer destroy_fixture(&fixture);
    MirrorScene mirror = create_mirror_scene(&fixture, false)!;
    defer scene::destroy_scene(&mirror.scene);
    StandardParams plain = { .base_color = { 1, 1, 1, 1 }, .metallic = 0, .roughness = 1 };
    mirror.scene.get(mirror.emitter, Mesh).material = fixture.assets.add_material(material::standard(plain))!;
    Camera* camera = mirror.scene.get(mirror.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(
        *camera,
        mirror.camera.world,
        { PATH_LAMP_TARGET_SIZE, PATH_LAMP_TARGET_SIZE },
    );
    assert(!maths::frustum_intersects_sphere(&matrices.frustum, { .center = LAMP_POSITION, .radius = LAMP_RANGE }));

    if (lamp_enabled) {
        Node* lamp = mirror.scene.add_light(light::point({ 1, 0, 0 }, LAMP_INTENSITY, LAMP_RANGE))!;
        lamp.local.position = LAMP_POSITION;
        mirror.scene.get(lamp, Light).layers = receiver_layers;
        mirror.scene.update_world();
    }
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(PATH_LAMP_TARGET_SIZE, PATH_LAMP_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    defer (void)render::destroy_render_target(&fixture.renderer, target);
    ViewDesc desc = render::texture_view_desc(target, OutputMode.LINEAR_HDR);
    desc.shading = ShadingPath.PATH_TRACED;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.path_trace = { .max_bounces = bounces, .samples_per_frame = 1, .max_samples = PATH_LAMP_SAMPLES };
    ViewId view = render::create_view(&fixture.renderer, desc)!;
    defer (void)render::destroy_view(&fixture.renderer, view);
    fixture.renderer.prepare_scene(&mirror.scene)!;
    for (uint frame = 0; frame < PATH_LAMP_SAMPLES; frame++) {
        fixture.renderer.begin_frame()!;
        defer catch render::abort_frame(&fixture.renderer);
        fixture.renderer.render_view(&mirror.scene, mirror.camera, view)!;
        fixture.renderer.finish_view(view)!;
        fixture.renderer.end_frame()!;
        assert(fixture.renderer.frame_submitted);
        assert(fixture.renderer.views.get(view).stats.accumulated_samples == frame + 1);
    }
    Vec4[PATH_LAMP_TARGET_SIZE * PATH_LAMP_TARGET_SIZE] pixels;
    fixture.renderer.read_render_target(target, ((char*)&pixels)[:pixels.len * Vec4::size])!;
    Vec2 uv = mirror_uv(&mirror, EMITTER_IMAGE_POINT);
    uint column = (uint)(uv.x * PATH_LAMP_TARGET_SIZE);
    uint row = (uint)(uv.y * PATH_LAMP_TARGET_SIZE);
    check_validation(&fixture.renderer);
    return pixels[row * PATH_LAMP_TARGET_SIZE + column];
}

fn void test_path_bounce_receives_an_off_camera_lamp_by_receiver_layers() @test {
    Vec4 unlit = path_off_camera_lamp(PATH_LAMP_RECEIVER_LAYERS, 4, false)!!;
    Vec4 excluded = path_off_camera_lamp(EXCLUDED_RECEIVER_LAYERS, 4, true)!!;
    Vec4 first_hit = path_off_camera_lamp(PATH_LAMP_RECEIVER_LAYERS, 1, true)!!;
    Vec4 bounced = path_off_camera_lamp(PATH_LAMP_RECEIVER_LAYERS, 4, true)!!;
    io::eprintfn(
        "off-camera path lamp: unlit %s, excluded %s, first hit %s, bounced %s",
        unlit,
        excluded,
        first_hit,
        bounced,
    );
    assert(math::abs(excluded.x - unlit.x) < PATH_LAMP_DARK_TOLERANCE);
    assert(first_hit.x < PATH_LAMP_DARK_TOLERANCE);
    assert(bounced.x > unlit.x + PATH_LAMP_MINIMUM);
}

fn uint? PhysicalPanel.render(&self, PhysicalParams params) @private {
    MaterialId physical = self.fixture.assets.add_material(material::physical(params))!;
    self.mirror.scene.get(self.mirror.emitter, Mesh).material = physical;
    self.fixture.renderer.prepare_scene(&self.mirror.scene)!;
    return render_mirror(self.fixture, self.mirror, self.view, EMITTER_IMAGE_POINT);
}

fn void test_reflections_shade_the_physical_layers_of_a_hit() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
        defer scene::destroy_scene(&mirror.scene);
        AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &mirror_view);
        set_reflections(&fixture, mirror_view.view, true)!!;
        Node* lamp = mirror.scene.add_light(light::point({ 1, 0, 0 }, COAT_LAMP_INTENSITY, COAT_LAMP_RANGE))!!;
        lamp.local.position = COAT_LAMP_POSITION;
        mirror.scene.update_world();

        PhysicalParams plain = material::PHYSICAL_PARAMS_DEFAULT;
        plain.standard.base_color = { 1, 1, 1, 1 };
        plain.standard.metallic = 0;
        plain.standard.roughness = 1;
        PhysicalParams coated = plain;
        coated.clearcoat = 1;
        coated.clearcoat_roughness = COAT_ROUGHNESS;
        PhysicalParams high_index = plain;
        high_index.ior = HIGH_INDEX;
        high_index.specular_color = TINTED_SPECULAR;
        PhysicalParams glass = plain;
        glass.transmission = 1;
        glass.thickness = GLASS_THICKNESS;

        PhysicalPanel panel = { .fixture = &fixture, .mirror = &mirror, .view = mirror_view.view };
        uint plain_pixel = panel.render(plain)!!;
        uint coated_pixel = panel.render(coated)!!;
        uint high_index_pixel = panel.render(high_index)!!;
        uint glass_pixel = panel.render(glass)!!;
        io::eprintfn(
            "%s, physical hit: plain %06x, clearcoat %06x, high index %06x, transmission %06x",
            trace_name(ray_queries),
            plain_pixel,
            coated_pixel,
            high_index_pixel,
            glass_pixel,
        );
        assert(red(coated_pixel) > red(plain_pixel) + COAT_MINIMUM);
        check_validation(&fixture.renderer);
    }
}

fn void test_reflections_shade_the_sheen_and_anisotropy_of_a_hit() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
        defer scene::destroy_scene(&mirror.scene);
        AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &mirror_view);
        set_reflections(&fixture, mirror_view.view, true)!!;
        Node* lamp = mirror.scene.add_light(light::point({ 1, 0, 0 }, COAT_LAMP_INTENSITY, COAT_LAMP_RANGE))!!;
        lamp.local.position = COAT_LAMP_POSITION;
        mirror.scene.update_world();

        PhysicalParams plain = material::PHYSICAL_PARAMS_DEFAULT;
        plain.standard.base_color = { 1, 1, 1, 1 };
        plain.standard.metallic = 0;
        plain.standard.roughness = 1;
        PhysicalParams sheen = plain;
        sheen.sheen_color = FABRIC_SHEEN_COLOR;
        sheen.sheen_roughness = FABRIC_SHEEN_ROUGHNESS;
        PhysicalParams metal = plain;
        metal.standard.metallic = 1;
        metal.standard.roughness = BRUSHED_ROUGHNESS;
        PhysicalParams brushed = metal;
        brushed.anisotropy = 1;

        PhysicalPanel panel = { .fixture = &fixture, .mirror = &mirror, .view = mirror_view.view };
        uint plain_pixel = panel.render(plain)!!;
        uint sheen_pixel = panel.render(sheen)!!;
        uint metal_pixel = panel.render(metal)!!;
        uint brushed_pixel = panel.render(brushed)!!;
        io::eprintfn(
            "%s, sheen and anisotropy hit: plain %06x, sheen %06x, metal %06x, brushed %06x",
            trace_name(ray_queries),
            plain_pixel,
            sheen_pixel,
            metal_pixel,
            brushed_pixel,
        );
        assert(red(sheen_pixel) + FABRIC_MINIMUM < red(plain_pixel));
        assert(blue(sheen_pixel) + FABRIC_MINIMUM < blue(plain_pixel));
        assert(math::abs(red(brushed_pixel) - red(metal_pixel)) > BRUSHED_MINIMUM);
        check_validation(&fixture.renderer);
    }
}

fn uint? render_emitter_at(Fixture* fixture, MirrorScene* mirror, ViewId view, Vec3 emitter_position) @private {
    mirror.emitter.local.position = emitter_position;
    mirror.scene.update_world();
    return render_mirror(fixture, mirror, view, EMITTER_IMAGE_POINT);
}

fn uint? render_emitter_image(
    Fixture* fixture,
    MirrorScene* mirror,
    ViewId view,
    Node* haze,
    Vec3 emitter_position,
    bool fogged,
) @private {
    haze.visible = fogged;
    return render_emitter_at(fixture, mirror, view, emitter_position);
}

fn void test_reflections_fog_the_path_from_the_surface_to_the_hit() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
        defer scene::destroy_scene(&mirror.scene);
        AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &mirror_view);
        set_reflections(&fixture, mirror_view.view, true)!!;
        Node* haze = mirror.scene.add_node(name: "haze")!!;
        mirror.scene.add(haze, HAZE);

        ViewId view = mirror_view.view;
        uint near_clear = render_emitter_image(&fixture, &mirror, view, haze, EMITTER_POSITION, false)!!;
        uint far_clear = render_emitter_image(&fixture, &mirror, view, haze, FAR_EMITTER_POSITION, false)!!;
        uint near_fogged = render_emitter_image(&fixture, &mirror, view, haze, EMITTER_POSITION, true)!!;
        uint far_fogged = render_emitter_image(&fixture, &mirror, view, haze, FAR_EMITTER_POSITION, true)!!;
        io::eprintfn(
            "%s, fogged emitter image: clear near %06x far %06x; fogged near %06x far %06x",
            trace_name(ray_queries),
            near_clear,
            far_clear,
            near_fogged,
            far_fogged,
        );

        // The camera's own fog pass takes the same share of either image, so only the hit segment separates them.
        assert(math::abs(red(far_clear) - red(near_clear)) <= MIRROR_TOLERANCE);
        assert(red(near_fogged) + FOG_MINIMUM < red(near_clear));
        assert(red(far_fogged) + FOG_MINIMUM < red(near_fogged));
        assert(blue(far_fogged) > blue(near_fogged) + FOG_MINIMUM);
        check_validation(&fixture.renderer);
    }
}

fn void test_reflections_take_the_atmosphere_over_the_path_to_the_hit() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
        defer scene::destroy_scene(&mirror.scene);
        AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &mirror_view);
        set_reflections(&fixture, mirror_view.view, true)!!;
        Light sunlight = light::directional({ 1, 1, 1 }, AIR_SUN_INTENSITY, shadow: false);
        Node* sun = mirror.scene.add_light(sunlight, name: "sun")!!;
        sun.local.rotation = maths::look_rotation((Vec3){ 0.3f, -1, -0.4f }.normalize(), { 0, 0, -1 });
        mirror.scene.add(sun, DENSE_AIR);

        ViewId view = mirror_view.view;
        uint near = render_emitter_at(&fixture, &mirror, view, EMITTER_POSITION)!!;
        uint far = render_emitter_at(&fixture, &mirror, view, FAR_EMITTER_POSITION)!!;
        io::eprintfn("%s, emitter image in dense air: near %06x far %06x", trace_name(ray_queries), near, far);

        // The camera's own fog pass takes the same share of either image, so only the hit segment separates them.
        assert(red(far) + AIR_MINIMUM < red(near));
        assert(blue(far) > blue(near) + AIR_MINIMUM);
        check_validation(&fixture.renderer);
    }
}

fn void test_ray_traced_ao_leaves_open_ground_unoccluded_at_the_image_border() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        BorderScene border = border_create_scene(&fixture)!!;
        defer border_destroy_scene(&fixture, &border);

        float[BORDER_TEXEL_COUNT] without;
        float[BORDER_TEXEL_COUNT] with;
        border_read_luminance(&fixture, &border, without[..])!!;
        AmbientOcclusionDesc ray_traced = render::AMBIENT_OCCLUSION_DEFAULT;
        ray_traced.kind = AoKind.RAY_TRACED;
        set_ambient_occlusion(&fixture, border.ao_view.view, ray_traced)!!;
        border_read_luminance(&fixture, &border, with[..])!!;
        float ratio = border_minimum_ratio(without[..], with[..]);
        io::eprintfn("%s, ray traced: border ratio at least %.4f", trace_name(ray_queries), ratio);
        assert(ratio > OPEN_RATIO_MINIMUM);
        check_validation(&fixture.renderer);
    }
}
