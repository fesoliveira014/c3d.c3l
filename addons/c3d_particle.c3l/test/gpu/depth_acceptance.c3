module particle_gpu_acceptance;

import c3d;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::particle;
import c3d::particle::gpu;
import c3d::render;
import c3d::scene;
import std::math;

const uint DEPTH_BURST @private = 64;
const float DEPTH_DROP_HEIGHT @private = 2;
const float BEHIND_HEIGHT @private = -0.01f; // just under the floor, inside the thickness of a hit
const float DEPTH_PARTICLE_SIZE @private = 0.05f;
const float DEPTH_RADIUS @private = 0.025f; // the size times the default radius scale of one half
const float DEPTH_LIFETIME @private = 10;
const float DEPTH_VIEW_WIDTH @private = 8; // world units across the target, so eight pixels to the unit
const float DEPTH_CAMERA_HEIGHT @private = 10;
const uint DEPTH_TARGET @private = 64;
const float FLOOR_SIZE @private = 20;
const uint AIRBORNE_STEP @private = 12; // the particles have fallen less than half a metre
const float AIRBORNE_MINIMUM @private = 1;
const uint DEPTH_FRAMES @private = 90; // the fall takes about 40 steps, and the particles launched upward are down by 60
const float REST_MARGIN @private = 0.05f; // the most a settled particle may lie above the floor
const float REST_TOLERANCE @private = 1e-3f;
const float FALLEN_THROUGH @private = -0.5f; // a particle that met no floor lies far below by the end
const float SLAB_HEIGHT @private = 0.5f;
const float SLAB_EDGE @private = 0.5f; // a pixel boundary of the view, so the next pixel past it sees the floor
const float SLAB_WIDTH @private = 0.8f; // off the view's centre on both axes, so a mirrored lookup lands on the floor
const float SLAB_DEPTH @private = 2.5f;
const float SLAB_CENTER_Z @private = -1.75f;
const Vec3 SLAB_LANDING @private = { 0.45f, DEPTH_DROP_HEIGHT, -1.5f }; // inside the last pixel of the slab's top
const float SLAB_TOLERANCE @private = 5e-3f; // the wrong normal leaves the particle 0.02 low

struct DepthScene @private {
    Node* emitter;
    Node* camera;
    RenderTargetId target;
    ViewId view;
    BillboardRecord[CAPACITY] settled; // the records of the frame FRAMES_IN_FLIGHT before the last
    uint settled_count;
}

fn DepthScene? create_depth_scene(
    Fixture* fixture,
    bool slab,
    bool launched = true,
    float drop_height = DEPTH_DROP_HEIGHT,
) @private {
    DepthScene depth;
    StandardParams matte = material::STANDARD_PARAMS_DEFAULT;
    matte.metallic = 0;
    matte.roughness = 0.9f;
    MaterialId floor_material = fixture.assets.add_material(material::standard(matte))!;
    @pool() {
        Geometry plane = geometry::plane(tmem, FLOOR_SIZE, FLOOR_SIZE);
        fixture.scene.add_mesh(fixture.assets.add_geometry(&plane)!, floor_material)!;
        if (slab) {
            Geometry box = geometry::box(
                allocator: tmem,
                width: SLAB_WIDTH,
                height: 2 * SLAB_HEIGHT,
                depth: SLAB_DEPTH,
            );
            Node* top = fixture.scene.add_mesh(fixture.assets.add_geometry(&box)!, floor_material)!;
            top.local.position = { SLAB_EDGE - SLAB_WIDTH / 2, 0, SLAB_CENTER_Z };
        }
    };

    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = CAPACITY;
    desc.material = fixture.material;
    desc.lifetime = { .min = DEPTH_LIFETIME, .max = DEPTH_LIFETIME };
    desc.speed = launched ? (ParticleRange){ .min = 0.5f, .max = 1.5f } : (ParticleRange){};
    desc.size = { .min = DEPTH_PARTICLE_SIZE, .max = DEPTH_PARTICLE_SIZE };
    desc.gravity_scale = 1;
    desc.collision.response = CollisionResponse.STICK;
    desc.execution = ParticleExecution.GPU;
    depth.emitter = fixture.scene.add_particle_system(desc)!;
    depth.emitter.local.position = slab ? SLAB_LANDING : (Vec3){ 0, drop_height, 0 };

    depth.camera = fixture.scene.add_camera(camera::orthographic(DEPTH_VIEW_WIDTH, 0.1f, 100))!;
    depth.camera.local.position = { 0, DEPTH_CAMERA_HEIGHT, 0 };
    depth.camera.local.rotation = maths::rotation_between({ 0, 0, -1 }, { 0, -1, 0 });
    depth.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(DEPTH_TARGET, DEPTH_TARGET, PixelFormat.RGBA32_FLOAT),
    )!;
    ViewDesc view_desc = render::texture_view_desc(depth.target);
    view_desc.post.anti_aliasing = AntiAliasing.NONE;
    depth.view = render::create_view(&fixture.renderer, view_desc)!;
    fixture.scene.update_world();
    return depth;
}

fn void? depth_frame(
    Fixture* fixture,
    DepthScene* depth,
    float dt,
    bool renders,
    bool reads,
) @private {
    Renderer* renderer = &fixture.renderer;
    particle::update(&fixture.scene, dt);
    fixture.scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::update(
        particles: &fixture.particles,
        renderer: renderer,
        scene: &fixture.scene,
        dt: dt,
        depth: { .view = depth.view, .camera = depth.camera.id },
    )!;
    copy_records(fixture, fixture.scene.get(depth.emitter, ParticleSystem))!;
    if (reads) {
        char[] copied = renderer.read_buffer(fixture.copied)!;
        depth.settled_count = *(uint*)(copied.ptr + CAPACITY * BillboardRecord::size);
        depth.settled = *(BillboardRecord[CAPACITY]*)copied.ptr;
    }
    if (renders) {
        renderer.render_view(&fixture.scene, depth.camera, depth.view)!;
        renderer.finish_view(depth.view)!;
    }
    renderer.end_frame()!;
}

fn void run_depth_frames(
    Fixture* fixture,
    DepthScene* depth,
    uint count,
    bool renders_every_frame,
    bool starts_above = true,
) @private {
    ParticleSystem* system = fixture.scene.get(depth.emitter, ParticleSystem);
    system.emit_burst(count);
    uint steps = DEPTH_FRAMES + render::FRAMES_IN_FLIGHT;
    for (uint step = 0; step < steps; step++) {
        depth_frame(
            fixture: fixture,
            depth: depth,
            dt: step < DEPTH_FRAMES ? STEP_SECONDS : 0,
            renders: renders_every_frame || step == 0,
            reads: (starts_above && step == AIRBORNE_STEP) || step + 1 == steps,
        )!!;
        if (starts_above && step == AIRBORNE_STEP) {
            assert(depth.settled_count == count);
            foreach (record : depth.settled[:count]) assert(record.position_width.y > AIRBORNE_MINIMUM);
        }
    }
}

fn void test_gpu_particles_stick_on_the_depth_view() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    DepthScene depth = create_depth_scene(&fixture, false)!!;
    run_depth_frames(&fixture, &depth, DEPTH_BURST, true);
    assert(depth.settled_count == DEPTH_BURST);
    foreach (record : depth.settled[:DEPTH_BURST]) {
        assert(record.position_width.y >= -REST_TOLERANCE && record.position_width.y <= REST_MARGIN);
    }
}

fn void test_gpu_depth_collision_waits_for_a_rendering_of_the_view() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    DepthScene depth = create_depth_scene(&fixture, false)!!;
    run_depth_frames(&fixture, &depth, DEPTH_BURST, false);
    assert(depth.settled_count == DEPTH_BURST);
    foreach (record : depth.settled[:DEPTH_BURST]) assert(record.position_width.y < FALLEN_THROUGH);
}

fn void test_gpu_depth_collision_leaves_particles_that_start_behind_the_surface() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    DepthScene depth = create_depth_scene(&fixture, false, false, BEHIND_HEIGHT)!!;
    run_depth_frames(&fixture, &depth, DEPTH_BURST, true, false);
    assert(depth.settled_count == DEPTH_BURST);
    foreach (record : depth.settled[:DEPTH_BURST]) assert(record.position_width.y < FALLEN_THROUGH);
}

fn void test_gpu_depth_collision_takes_the_normal_from_the_smaller_depth_step() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    DepthScene depth = create_depth_scene(&fixture, true, false)!!;
    run_depth_frames(&fixture, &depth, 1, true);
    assert(depth.settled_count == 1);
    BillboardRecord resting = depth.settled[0];
    assert(math::abs(resting.position_width.y - (SLAB_HEIGHT + DEPTH_RADIUS)) <= SLAB_TOLERANCE);
    assert(math::abs(resting.position_width.x - SLAB_LANDING.x) <= SLAB_TOLERANCE);
    assert(math::abs(resting.position_width.z - SLAB_LANDING.z) <= SLAB_TOLERANCE);
}

fn void test_gpu_update_refuses_a_depth_view_or_camera_that_cannot_serve() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    DepthScene depth = create_depth_scene(&fixture, false)!!;
    ViewId gone = render::create_view(&fixture.renderer, render::texture_view_desc(depth.target))!!;
    render::destroy_view(&fixture.renderer, gone)!!;

    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!!;
    assert(@catch(gpu::update(
        particles: &fixture.particles,
        renderer: renderer,
        scene: &fixture.scene,
        dt: STEP_SECONDS,
        depth: { .view = gone, .camera = depth.camera.id },
    )) == c3d::INVALID_ID);
    assert(@catch(gpu::update(
        particles: &fixture.particles,
        renderer: renderer,
        scene: &fixture.scene,
        dt: STEP_SECONDS,
        depth: { .view = depth.view, .camera = depth.emitter.id },
    )) == c3d::INVALID_ARGUMENT);
    render::abort_frame(renderer);
}
