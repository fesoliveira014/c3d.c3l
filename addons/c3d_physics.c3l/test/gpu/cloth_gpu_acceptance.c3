module c3d::render::cloth_gpu_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth;
import c3d::render @public;
import c3d::render::cloth_gpu;
import c3d::scene;
import gpu;
import std::math;

const uint CELLS @private = 32; // a 33x33-vertex flag
const uint SIDE @private = CELLS + 1;
const float FLAG_WIDTH @private = 1.8f;
const float FLAG_DEPTH @private = 1.2f;
const float POLE_HEIGHT @private = 3;
const Vec3 GRAVITY @private = { 0, -9.81f, 0 };
const float DAMPING @private = 3; // per second; settles the swing within the run
const uint SETTLE_FRAMES @private = 270;
const float PIN_TOLERANCE @private = 1e-5f;
const float SETTLED_STEP @private = 5e-4f; // metres between two frames of the run's end
const float HANG_FRACTION @private = 0.9f; // share of the flag's depth the free edge must fall
const Vec3 BALL_CENTER @private = { 0.9f, 2.2f, -0.15f };
const float BALL_RADIUS @private = 0.3f;
const float CONTACT_TOLERANCE @private = 1e-3f;
const uint IMAGE_SIZE @private = 64;

struct Fixture @private {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    Renderer     renderer;
    Node*        flag;
    Node*        camera;
    RenderTargetId target;
    ViewId       view;
}

fn void? create_fixture(Fixture* fixture) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer catch scene::destroy_scene(&fixture.scene);
    physics::register_physics(&fixture.scene)!;
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = GRAVITY;
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

    fixture.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(IMAGE_SIZE, IMAGE_SIZE, PixelFormat.RGBA16_FLOAT),
    )!;
    ViewDesc view_desc = render::texture_view_desc(fixture.target);
    view_desc.post.anti_aliasing = AntiAliasing.TAA;
    view_desc.post.motion_blur = true;
    fixture.view = render::create_view(&fixture.renderer, view_desc)!;
    fixture.camera = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    fixture.camera.local.position = { FLAG_WIDTH * 0.5f, POLE_HEIGHT - 0.6f, 3 };
}

fn void destroy_fixture(Fixture* fixture) @private {
    check_validation(fixture);
    render::destroy_renderer(&fixture.renderer);
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void check_validation(Fixture* fixture) @private {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = fixture.renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        bool backend_validation = entry.category.backend && entry.category.validation;
        bool failing = entry.severity == gpu::DebugMessageSeverity.ERROR
          || entry.severity == gpu::DebugMessageSeverity.WARNING;
        assert(!(backend_validation && failing));
    }
}

// A flag in the horizontal plane, pinned along its first row, which gravity swings down to hang from the pins.
fn void? add_flag(Fixture* fixture) @private {
    GeometryId geometry;
    @pool() {
        Geometry sheet = {
            .positions = alloc::new_array(tmem, Vec3, (sz)(SIDE * SIDE)),
            .indices   = alloc::new_array(tmem, uint, (sz)(6 * CELLS * CELLS)),
        };
        for (uint row = 0; row < SIDE; row++) {
            for (uint column = 0; column < SIDE; column++) {
                sheet.positions[row * SIDE + column] = {
                    (float)column / CELLS * FLAG_WIDTH,
                    0,
                    (float)row / CELLS * FLAG_DEPTH,
                };
            }
        }
        usz next;
        for (uint row = 0; row < CELLS; row++) {
            for (uint column = 0; column < CELLS; column++) {
                uint top_left = row * SIDE + column;
                uint bottom_left = top_left + SIDE;
                uint[6] corners = { top_left, top_left + 1, bottom_left, top_left + 1, bottom_left + 1, bottom_left };
                sheet.indices[next:6] = corners[..];
                next += 6;
            }
        }
        sheet.finalize();
        geometry = fixture.assets.add_geometry(&sheet)!;
    };
    MaterialCommon two_sided = material::MATERIAL_COMMON_DEFAULT;
    two_sided.double_sided = true;
    MaterialId material = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }, two_sided))!;
    fixture.flag = fixture.scene.add_mesh(geometry, material, name: "flag")!;
    fixture.flag.local.position = { 0, POLE_HEIGHT, 0 };
    fixture.scene.update_world();

    Node* ball = fixture.scene.add_node(name: "ball")!;
    ball.local.position = BALL_CENTER;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(SPHERE);
    collider.radius = BALL_RADIUS;
    fixture.physics.add_body(ball, physics::default_body_desc(STATIC), (&collider)[:1])!;
    fixture.physics.update(0);

    @pool() {
        uint[] pins = alloc::new_array(tmem, uint, (sz)SIDE);
        foreach (index, &pin : pins) *pin = (uint)index;
        Entity[1] colliders = { ball.id };
        ClothDesc desc = cloth::default_cloth_desc();
        desc.pins = pins;
        desc.colliders = colliders[..];
        desc.bend_stiffness = 0;
        desc.damping = DAMPING;
        fixture.scene.add_cloth(&fixture.assets, fixture.flag, desc, &fixture.physics)!;
    };
}

// A snapshot receives the positions the device left FRAMES_IN_FLIGHT frames before this one.
fn void? run_frame(Fixture* fixture, GpuCloth* flag, Vec4[] snapshot = {}) @private {
    Renderer* renderer = &fixture.renderer;
    fixture.scene.update_world();
    renderer.begin_frame({ .time = 1, .delta = physics::DEFAULT_FIXED_DT })!;
    defer catch render::abort_frame(renderer);
    if (snapshot.len) snapshot[..] = flag.read_positions(renderer)![..];
    flag.step(
        renderer:     renderer,
        scene:        &fixture.scene,
        gravity:      GRAVITY,
        step_seconds: physics::DEFAULT_FIXED_DT,
    )!;
    renderer.render_view(&fixture.scene, fixture.camera, fixture.view)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
}

fn void test_flag_settles_under_gravity_with_pins_held() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    add_flag(&fixture)!!;
    GpuCloth flag = cloth_gpu::create_gpu_cloth(
        renderer: &fixture.renderer,
        assets:   &fixture.assets,
        scene:    &fixture.scene,
        node:     fixture.flag,
    )!!;
    defer cloth_gpu::destroy_gpu_cloth(&fixture.renderer, &flag);
    ClothState* state = fixture.scene.get(fixture.flag, Cloth).state;
    Vec3[] initial = alloc::new_array(mem, Vec3, state.positions.len);
    defer alloc::free(mem, initial.ptr);
    initial[..] = state.positions[..];

    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) run_frame(&fixture, &flag)!!;
    assert(fixture.renderer.stats.upload_bytes == 0 && fixture.renderer.stats.vertex_history_bytes == 0);
    assert(fixture.renderer.stats.dispatches > 0);

    @pool() {
        Vec4[] earlier = alloc::new_array(tmem, Vec4, flag.particle_count);
        Vec4[] later = alloc::new_array(tmem, Vec4, flag.particle_count);
        run_frame(&fixture, &flag, earlier)!!;
        run_frame(&fixture, &flag, later)!!;
        float lowest = float::max;
        foreach (index, position : later) {
            Vec3 point = { position.x, position.y, position.z };
            assert(math::is_finite(point.x) && math::is_finite(point.y) && math::is_finite(point.z));
            if (index < SIDE) {
                assert((point - initial[index]).length() <= PIN_TOLERANCE);
                continue;
            }
            Vec3 before = { earlier[index].x, earlier[index].y, earlier[index].z };
            assert((point - before).length() <= SETTLED_STEP);
            assert((point - BALL_CENTER).length() >= BALL_RADIUS + state.desc.thickness - CONTACT_TOLERANCE);
            lowest = math::min(lowest, point.y);
        }
        assert(lowest <= POLE_HEIGHT - HANG_FRACTION * FLAG_DEPTH);
    };
}
