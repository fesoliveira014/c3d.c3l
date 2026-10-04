module c3d::render::cloth_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const uint IMAGE_SIZE @private = 64;
const float VIEW_HEIGHT @private = 4;
const uint SHEET_CELLS @private = 8;
const float SHEET_SIZE @private = 2;
const uint SHEET_CENTER @private = SHEET_CELLS / 2 * (SHEET_CELLS + 1) + SHEET_CELLS / 2;
const float FALL_GRAVITY @private = 60; // m/s^2: a few frames move the sheet by whole pixels
const uint FALL_SETTLE_FRAMES @private = 8;
const uint CHECKED_FRAMES @private = 3;
const float NODE_STEP @private = 0.125f; // two pixels per frame at IMAGE_SIZE over VIEW_HEIGHT
const float VELOCITY_TOLERANCE @private = 2e-3f; // UV; an eighth of a pixel at IMAGE_SIZE
const float COVERED @private = 0.5f;

struct Fixture @private {
    AssetStore        assets;
    Scene             scene;
    PhysicsWorld      physics;
    Renderer          renderer;
    MaterialId        material;
    Node*             camera;
    RenderTargetId[2] targets;
    ViewId[2]         views;
}

fn void? create_fixture(Fixture* fixture, float gravity) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(mem, { .max_nodes = 32 });
    defer catch scene::destroy_scene(&fixture.scene);
    physics::register_physics(&fixture.scene)!;
    fixture.scene.background.color = {};
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = { 0, -gravity, 0 };
    desc.tuning.interpolate = false;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      desc,
    )!;
    defer catch physics::destroy_physics_world(&fixture.physics);
    fixture.renderer = render::create_renderer(mem, &fixture.assets, { .validation = true })!;
    defer catch render::destroy_renderer(&fixture.renderer);
    MaterialCommon two_sided = material::MATERIAL_COMMON_DEFAULT;
    two_sided.double_sided = true;
    fixture.material = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }, two_sided))!;
    fixture.camera = fixture.scene.add_camera(camera::orthographic(VIEW_HEIGHT, 0.1f, 100))!;
    fixture.camera.local.position = { 0, 0, 5 };
    foreach (index, &target : fixture.targets) {
        *target = render::create_render_target(
            renderer: &fixture.renderer,
            desc: render::render_target_desc(IMAGE_SIZE, IMAGE_SIZE, PixelFormat.RGBA32_FLOAT),
        )!;
        fixture.views[index] = render::create_view(&fixture.renderer, velocity_view(*target, ShadingPath.FORWARD))!;
    }
    fixture.scene.update_world();
}

fn void check_validation(Fixture* fixture) @private {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = fixture.renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        assert(!(entry.category.backend && entry.category.validation
            && entry.severity == gpu::DebugMessageSeverity.ERROR));
    }
}

fn void destroy_fixture(Fixture* fixture) @private {
    check_validation(fixture);
    render::destroy_renderer(&fixture.renderer);
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn ViewDesc velocity_view(RenderTargetId target, ShadingPath path) @private {
    ViewDesc desc = render::texture_view_desc(target);
    desc.shading = path;
    desc.post.anti_aliasing = AntiAliasing.TAA;
    desc.post.taa_params.debug = TaaDebug.VELOCITY;
    desc.post.motion_blur = true;
    return desc;
}

fn void configure(Fixture* fixture, uint view, ViewDesc desc) @private {
    render::configure_view(&fixture.renderer, fixture.views[view], desc)!!;
}

fn Node* add_sheet(
    Fixture* fixture,
    Vec3 centre,
    float size,
    bool pinned,
) @private {
    GeometryId geometry;
    @pool() {
        uint side = SHEET_CELLS + 1;
        Geometry sheet = {
            .positions = alloc::new_array(tmem, Vec3, (sz)(side * side)),
            .indices   = alloc::new_array(tmem, uint, (sz)(6 * SHEET_CELLS * SHEET_CELLS)),
        };
        for (uint row = 0; row < side; row++) {
            for (uint column = 0; column < side; column++) {
                sheet.positions[row * side + column] = {
                    ((float)column / SHEET_CELLS - 0.5f) * size,
                    (0.5f - (float)row / SHEET_CELLS) * size,
                    0,
                };
            }
        }
        usz next;
        for (uint row = 0; row < SHEET_CELLS; row++) {
            for (uint column = 0; column < SHEET_CELLS; column++) {
                uint top_left = row * side + column;
                uint bottom_left = top_left + side;
                uint[6] corners = { top_left, bottom_left, top_left + 1, top_left + 1, bottom_left, bottom_left + 1 };
                sheet.indices[next:6] = corners[..];
                next += 6;
            }
        }
        sheet.finalize();
        geometry = fixture.assets.add_geometry(&sheet)!!;
    };
    Node* node = fixture.scene.add_mesh(geometry, fixture.material)!!;
    node.local.position = centre;
    fixture.scene.get(node, scene::Mesh).trace = false;
    fixture.scene.update_world();
    attach(fixture, node, pinned);
    return node;
}

fn Node* falling_sheet(Fixture* fixture) @private {
    return add_sheet(
        fixture: fixture,
        centre:  {},
        size:    SHEET_SIZE,
        pinned:  false,
    );
}

fn void attach(Fixture* fixture, Node* node, bool pinned) @private {
    ClothDesc desc = cloth::default_cloth_desc();
    @pool() {
        if (pinned) {
            uint[] pins = alloc::new_array(tmem, uint, (sz)((SHEET_CELLS + 1) * (SHEET_CELLS + 1)));
            foreach (index, &pin : pins) *pin = (uint)index;
            desc.pins = pins;
        }
        fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    };
}

fn void step(Fixture* fixture, float dt) @private {
    fixture.physics.update(dt);
    fixture.scene.update_world();
    fixture.physics.update_cloths();
}

fn Vec3 published(Fixture* fixture, Node* node, uint vertex) @private {
    GeometryId geometry = fixture.scene.get(node, scene::Mesh).geometry;
    return maths::transform_point(node.world, fixture.assets.geometry(geometry).data.positions[vertex]);
}

fn void render_views(Fixture* fixture, uint[] views, bool abort = false) @private {
    fixture.renderer.begin_frame({ .time = 1, .delta = physics::DEFAULT_FIXED_DT })!!;
    foreach (view : views) {
        fixture.renderer.render_view(&fixture.scene, fixture.camera, fixture.views[view])!!;
        fixture.renderer.finish_view(fixture.views[view])!!;
    }
    if (abort) {
        render::abort_frame(&fixture.renderer);
        return;
    }
    fixture.renderer.end_frame()!!;
}

fn Vec4 pixel_at(Fixture* fixture, uint view, Vec3 world) @private {
    Vec4[IMAGE_SIZE * IMAGE_SIZE] pixels;
    fixture.renderer.read_render_target(fixture.targets[view], ((char*)&pixels)[:pixels.len * Vec4::size])!!;
    uint x = (uint)((float)IMAGE_SIZE * (0.5f + world.x / VIEW_HEIGHT));
    uint y = (uint)((float)IMAGE_SIZE * (0.5f - world.y / VIEW_HEIGHT));
    return pixels[y * IMAGE_SIZE + x];
}

fn Vec2 velocity_at(Fixture* fixture, uint view, Vec3 world) @private {
    Vec4 shown = pixel_at(fixture, view, world);
    return (Vec2){ shown.x - 0.5f, shown.y - 0.5f } * (2 * (float)shader::TAA_DEBUG_VELOCITY_RANGE / IMAGE_SIZE);
}

fn Vec2 projected_uv(Fixture* fixture, Vec3 point) @private {
    Camera* camera = fixture.scene.get(fixture.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, fixture.camera.world, { IMAGE_SIZE, IMAGE_SIZE });
    Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
    return { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f };
}

fn void check_velocity(Vec2 found, Vec2 expected) @private {
    assert(math::abs(found.x - expected.x) <= VELOCITY_TOLERANCE);
    assert(math::abs(found.y - expected.y) <= VELOCITY_TOLERANCE);
}

fn void check_motion(
    Fixture* fixture,
    uint view,
    Vec3 current,
    Vec3 previous,
) @private {
    Vec2 expected = projected_uv(fixture, current) - projected_uv(fixture, previous);
    assert(expected.length() > 10 * VELOCITY_TOLERANCE);
    check_velocity(velocity_at(fixture, view, current), expected);
}

fn void test_cloth_deformation_moves_a_still_node() @test {
    ShadingPath[2] paths = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
    foreach (path : paths) {
        Fixture fixture;
        create_fixture(&fixture, FALL_GRAVITY)!!;
        defer destroy_fixture(&fixture);
        configure(&fixture, 0, velocity_view(fixture.targets[0], path));
        Node* sheet = falling_sheet(&fixture);
        Mat4 still = sheet.world;
        uint[1] views = { 0 };
        for (uint frame = 0; frame < FALL_SETTLE_FRAMES; frame++) {
            step(&fixture, physics::DEFAULT_FIXED_DT);
            render_views(&fixture, views[..]);
        }
        for (uint frame = 0; frame < CHECKED_FRAMES; frame++) {
            Vec3 before = published(&fixture, sheet, SHEET_CENTER);
            step(&fixture, physics::DEFAULT_FIXED_DT);
            render_views(&fixture, views[..]);
            assert(sheet.world.m == still.m);
            check_motion(
                fixture:  &fixture,
                view:     0,
                current:  published(&fixture, sheet, SHEET_CENTER),
                previous: before,
            );
        }
        check_validation(&fixture);
    }
}

fn void test_cloth_pins_follow_the_node_and_free_particles_stay() @test {
    Fixture fixture;
    create_fixture(&fixture, 0)!!;
    defer destroy_fixture(&fixture);
    ViewDesc colour = render::texture_view_desc(fixture.targets[1]);
    colour.post.anti_aliasing = AntiAliasing.NONE;
    configure(&fixture, 1, colour);
    Node* attached = add_sheet(
        fixture: &fixture,
        centre:  { -1, 0, 0 },
        size:    SHEET_SIZE * 0.5f,
        pinned:  true,
    );
    Node* loose = add_sheet(
        fixture: &fixture,
        centre:  { 1, 0, 0 },
        size:    SHEET_SIZE * 0.5f,
        pinned:  false,
    );
    Vec3 loose_centre = published(&fixture, loose, SHEET_CENTER);
    uint[2] views = { 0, 1 };
    step(&fixture, physics::DEFAULT_FIXED_DT);
    render_views(&fixture, views[..]);
    for (uint frame = 0; frame < CHECKED_FRAMES; frame++) {
        Vec3 before = published(&fixture, attached, SHEET_CENTER);
        attached.local.position.y += NODE_STEP;
        loose.local.position.y += NODE_STEP;
        step(&fixture, physics::DEFAULT_FIXED_DT);
        render_views(&fixture, views[..]);
        Vec3 after = published(&fixture, attached, SHEET_CENTER);
        assert(math::abs(after.y - before.y - NODE_STEP) <= 1e-5f);
        check_motion(
            fixture:  &fixture,
            view:     0,
            current:  after,
            previous: before,
        );
        check_velocity(velocity_at(&fixture, 0, loose_centre), {});
        assert(pixel_at(&fixture, 1, loose_centre).x > COVERED);
        assert(pixel_at(&fixture, 1, after).x > COVERED);
    }
}

fn void test_cloth_views_keep_their_own_history() @test {
    Fixture fixture;
    create_fixture(&fixture, FALL_GRAVITY)!!;
    defer destroy_fixture(&fixture);
    configure(&fixture, 1, velocity_view(fixture.targets[1], ShadingPath.DEFERRED));
    Node* sheet = falling_sheet(&fixture);
    uint[2] both = { 0, 1 };
    uint[1] first = { 0 };
    for (uint frame = 0; frame < FALL_SETTLE_FRAMES; frame++) {
        step(&fixture, physics::DEFAULT_FIXED_DT);
        render_views(&fixture, both[..]);
    }
    Vec3 second_seen = published(&fixture, sheet, SHEET_CENTER);
    Vec3 before = second_seen;
    step(&fixture, physics::DEFAULT_FIXED_DT);
    render_views(&fixture, first[..]);
    check_motion(
        fixture:  &fixture,
        view:     0,
        current:  published(&fixture, sheet, SHEET_CENTER),
        previous: before,
    );

    before = published(&fixture, sheet, SHEET_CENTER);
    step(&fixture, physics::DEFAULT_FIXED_DT);
    render_views(&fixture, both[..]);
    Vec3 current = published(&fixture, sheet, SHEET_CENTER);
    check_motion(
        fixture:  &fixture,
        view:     0,
        current:  current,
        previous: before,
    );
    check_motion(
        fixture:  &fixture,
        view:     1,
        current:  current,
        previous: second_seen,
    );

    fixture.scene.remove_cloth(sheet);
    attach(&fixture, sheet, pinned: false);
    step(&fixture, physics::DEFAULT_FIXED_DT);
    render_views(&fixture, both[..]);
    current = published(&fixture, sheet, SHEET_CENTER);
    check_velocity(velocity_at(&fixture, 0, current), {});
    check_velocity(velocity_at(&fixture, 1, current), {});
}

fn void test_cloth_abort_drops_motion_for_one_rendering() @test {
    Fixture fixture;
    create_fixture(&fixture, FALL_GRAVITY)!!;
    defer destroy_fixture(&fixture);
    Node* sheet = falling_sheet(&fixture);
    uint[1] views = { 0 };
    for (uint frame = 0; frame < FALL_SETTLE_FRAMES; frame++) {
        step(&fixture, physics::DEFAULT_FIXED_DT);
        render_views(&fixture, views[..]);
    }
    step(&fixture, physics::DEFAULT_FIXED_DT);
    render_views(&fixture, views[..], abort: true);
    step(&fixture, physics::DEFAULT_FIXED_DT);
    render_views(&fixture, views[..]);
    Vec3 before = published(&fixture, sheet, SHEET_CENTER);
    check_velocity(velocity_at(&fixture, 0, before), {});
    step(&fixture, physics::DEFAULT_FIXED_DT);
    render_views(&fixture, views[..]);
    check_motion(
        fixture:  &fixture,
        view:     0,
        current:  published(&fixture, sheet, SHEET_CENTER),
        previous: before,
    );
}
