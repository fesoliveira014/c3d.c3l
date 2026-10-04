module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::math;
import std::math::quaternion;

const float VERTEX_STEP @private = 0.125f; // about one pixel of motion at the fixture camera
const float VERTEX_VELOCITY_TOLERANCE @private = 2e-3f; // UV; a sixteenth of a pixel at TARGET_SIZE
const float STILL_VELOCITY @private = 1e-5f;
const float QUAD_SIZE @private = 2;
const uint VERTEX_SETTLE_FRAMES @private = 3;

struct VertexScene @private {
    DeformedScene target;
    GeometryId    geometry;
    GeometryId    spare;
    MaterialId    material;
}

fn VertexScene? create_vertex_scene(Fixture* fixture, bool deformed = false) @private {
    VertexScene result;
    MaterialCommon two_sided = material::MATERIAL_COMMON_DEFAULT;
    two_sided.double_sided = true;
    result.material = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }, two_sided))!;
    @pool() {
        Geometry quad = deformed ? deformed_quad(tmem) : geometry::plane(tmem, QUAD_SIZE, QUAD_SIZE);
        result.geometry = fixture.assets.add_geometry(&quad)!;
        result.spare = fixture.assets.add_geometry(&quad)!;
    };
    result.target.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.target.scene);
    result.target.mesh = result.target.scene.add_mesh(result.geometry, result.material)!;
    Quat upright = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::PI * 0.5f);
    result.target.mesh.local.rotation = upright;
    Mesh* mesh = result.target.scene.get(result.target.mesh, Mesh);
    mesh.vertex_motion = true;
    if (deformed) {
        mesh.morph_weights = alloc::new_array(result.target.scene.allocator, float, 1);
        mesh.morph_weights[0] = 0.5f;
        Node* joint = result.target.scene.add_node(name: "joint")!;
        joint.local.rotation = upright;
        Node*[] joints = alloc::new_array(result.target.scene.allocator, Node*, 1);
        joints[0] = joint;
        result.target.scene.add(result.target.mesh, (SkinBinding){ .skeleton = fixture.skeleton, .joints = joints });
    }
    result.target.camera = result.target.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.target.camera.local.position = CAMERA_POSITION;
    result.target.scene.update_world();
    return result;
}

fn Geometry deformed_quad(Allocator allocator) @private {
    Geometry quad = geometry::plane(allocator, QUAD_SIZE, QUAD_SIZE);
    quad.joints = alloc::new_array(allocator, ushort[<4>], quad.positions.len);
    quad.weights = alloc::new_array(allocator, Vec4, quad.positions.len);
    foreach (&weight : quad.weights) *weight = { 1, 0, 0, 0 };
    quad.targets = alloc::new_array(allocator, MorphTarget, 1);
    quad.targets[0] = {
        .position_deltas = alloc::new_array(allocator, Vec3, quad.positions.len),
        .normal_deltas   = alloc::new_array(allocator, Vec3, quad.positions.len),
    };
    foreach (&delta : quad.targets[0].position_deltas) *delta = { 0, 0, 0.25f };
    return quad;
}

fn void move_quad(Fixture* fixture, GeometryId geometry, float step) @private {
    foreach (&position : fixture.assets.geometry(geometry).data.positions) position.x += step;
    fixture.assets.mark_geometry_dirty(geometry);
}

fn LodVelocityProbe? create_velocity_probe(Fixture* fixture) @private {
    gpu::AllocationDesc desc = {
        .size = TARGET_SIZE * TARGET_SIZE * Vec4::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "vertex_velocity_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &desc)!;
    return {
        .readback = readback,
        .output = fixture.renderer.create_buffer({ .size = desc.size, .debug_name = "vertex_velocity_output" })!,
        .shader = add_compute_shader(fixture, (String)PROBE_READBACK_SOURCE[..])!,
    };
}

fn void? configure_vertex_view(Fixture* fixture, ViewId view, ShadingPath path, bool taa = true) @private {
    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.shading = path;
    desc.post.anti_aliasing = taa ? AntiAliasing.TAA : AntiAliasing.NONE;
    desc.post.motion_blur = true;
    return render::configure_view(&fixture.renderer, view, desc);
}

fn Vec4? render_vertex_frame(
    Fixture* fixture,
    VertexScene* target,
    LodVelocityProbe* probe,
    ViewId view,
    Vec3 reference = {},
) @private {
    Renderer* renderer = &fixture.renderer;
    target.target.scene.update_world();
    renderer.begin_frame({ .time = 1, .delta = 1.0f / 60, .reference_position = reference })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&target.target.scene, target.target.camera, view)!;
    record_lod_target(fixture, probe, &renderer.views.get(view).velocity)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, probe.readback.span)!;
    return lod_velocity_pixel(probe.readback, CENTER_UV);
}

fn Vec2 vertex_step_velocity(VertexScene* target, float step) @private {
    Camera* camera = target.target.scene.get(target.target.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, target.target.camera.world, { TARGET_SIZE, TARGET_SIZE });
    return projected_uv(&matrices, {}) - projected_uv(&matrices, { -step, 0, 0 });
}

fn void check_still(Vec4 velocity) @private {
    assert(velocity.w == 0 && math::abs(velocity.x) < STILL_VELOCITY && math::abs(velocity.y) < STILL_VELOCITY);
}

fn void check_rejected(Vec4 velocity) @private {
    assert(velocity.w == 1 && velocity.x == 0 && velocity.y == 0);
}

fn void check_step(Vec4 velocity, Vec2 expected) @private {
    assert(math::abs(expected.x) > 10 * VERTEX_VELOCITY_TOLERANCE);
    assert(math::abs(velocity.x - expected.x) < VERTEX_VELOCITY_TOLERANCE);
    assert(math::abs(velocity.y - expected.y) < VERTEX_VELOCITY_TOLERANCE);
}

fn void? settle_vertex_view(Fixture* fixture, VertexScene* target, LodVelocityProbe* probe, ViewId view) @private {
    check_rejected(render_vertex_frame(fixture, target, probe, view)!);
    for (uint frame = 1; frame < VERTEX_SETTLE_FRAMES; frame++) check_still(render_vertex_frame(fixture, target, probe, view)!);
}

fn void test_vertex_motion_moves_a_still_mesh() @test {
    ShadingPath[2] paths = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
    foreach (path : paths) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        LodVelocityProbe probe = create_velocity_probe(&fixture)!!;
        defer free_lod_readback(&fixture.renderer, probe.readback);
        VertexScene target = create_vertex_scene(&fixture)!!;
        defer scene::destroy_scene(&target.target.scene);
        configure_vertex_view(&fixture, fixture.view, path)!!;

        settle_vertex_view(&fixture, &target, &probe, fixture.view)!!;
        move_quad(&fixture, target.geometry, VERTEX_STEP);
        check_step(render_vertex_frame(&fixture, &target, &probe, fixture.view)!!, vertex_step_velocity(&target, VERTEX_STEP));
        check_still(render_vertex_frame(&fixture, &target, &probe, fixture.view)!!);
        check_validation(&fixture.renderer);
    }
}

fn void test_vertex_motion_without_taa_keeps_motion_blur_velocity() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    LodVelocityProbe probe = create_velocity_probe(&fixture)!!;
    defer free_lod_readback(&fixture.renderer, probe.readback);
    VertexScene target = create_vertex_scene(&fixture)!!;
    defer scene::destroy_scene(&target.target.scene);
    configure_vertex_view(&fixture, fixture.view, ShadingPath.FORWARD, taa: false)!!;

    for (uint frame = 0; frame < VERTEX_SETTLE_FRAMES; frame++) render_vertex_frame(&fixture, &target, &probe, fixture.view)!!;
    move_quad(&fixture, target.geometry, VERTEX_STEP);
    Vec4 moved = render_vertex_frame(&fixture, &target, &probe, fixture.view)!!;
    Vec2 expected = vertex_step_velocity(&target, VERTEX_STEP);
    assert(math::abs(moved.x - expected.x) < VERTEX_VELOCITY_TOLERANCE && math::abs(moved.y - expected.y) < VERTEX_VELOCITY_TOLERANCE);
    check_validation(&fixture.renderer);
}

fn void test_vertex_motion_rejects_unmatched_history() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    LodVelocityProbe probe = create_velocity_probe(&fixture)!!;
    defer free_lod_readback(renderer, probe.readback);
    VertexScene target = create_vertex_scene(&fixture)!!;
    defer scene::destroy_scene(&target.target.scene);
    configure_vertex_view(&fixture, fixture.view, ShadingPath.FORWARD)!!;
    Mesh* mesh = target.target.scene.get(target.target.mesh, Mesh);

    settle_vertex_view(&fixture, &target, &probe, fixture.view)!!;
    mesh.geometry = target.spare;
    settle_vertex_view(&fixture, &target, &probe, fixture.view)!!;

    render::reset_view_history(renderer, fixture.view)!!;
    settle_vertex_view(&fixture, &target, &probe, fixture.view)!!;

    GeometryAsset* spare = fixture.assets.geometry(target.spare);
    fixture.assets.release_geometry_cpu(target.spare);
    spare.data = geometry::plane(fixture.assets.allocator, QUAD_SIZE, QUAD_SIZE, 2, 1);
    fixture.assets.mark_geometry_dirty(target.spare);
    settle_vertex_view(&fixture, &target, &probe, fixture.view)!!;

    mesh.vertex_motion = false;
    render_vertex_frame(&fixture, &target, &probe, fixture.view)!!;
    mesh.vertex_motion = true;
    settle_vertex_view(&fixture, &target, &probe, fixture.view)!!;

    target.target.scene.update_world();
    renderer.begin_frame({ .time = 1, .delta = 1.0f / 60 })!!;
    renderer.render_view(&target.target.scene, target.target.camera, fixture.view)!!;
    render::abort_frame(renderer);
    settle_vertex_view(&fixture, &target, &probe, fixture.view)!!;
    check_validation(renderer);
}

fn void test_vertex_motion_released_positions_fault_and_recover() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    LodVelocityProbe probe = create_velocity_probe(&fixture)!!;
    defer free_lod_readback(renderer, probe.readback);
    VertexScene target = create_vertex_scene(&fixture)!!;
    defer scene::destroy_scene(&target.target.scene);
    configure_vertex_view(&fixture, fixture.view, ShadingPath.FORWARD)!!;
    settle_vertex_view(&fixture, &target, &probe, fixture.view)!!;

    GeometryAsset* source = fixture.assets.geometry(target.geometry);
    fixture.assets.release_geometry_cpu(target.geometry);
    target.target.scene.update_world();
    renderer.begin_frame({ .time = 1, .delta = 1.0f / 60 })!!;
    fault excuse = @catch(renderer.render_view(&target.target.scene, target.target.camera, fixture.view));
    render::abort_frame(renderer);
    assert(excuse == c3d::ASSET_DATA_UNAVAILABLE);

    source.data = geometry::plane(fixture.assets.allocator, QUAD_SIZE, QUAD_SIZE);
    fixture.assets.mark_geometry_dirty(target.geometry);
    check_still(render_vertex_frame(&fixture, &target, &probe, fixture.view)!!);
    check_validation(renderer);
}

fn void test_vertex_motion_follows_each_view_and_reference() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    LodVelocityProbe probe = create_velocity_probe(&fixture)!!;
    defer free_lod_readback(renderer, probe.readback);
    LodVelocityProbe second_probe = create_velocity_probe(&fixture)!!;
    defer free_lod_readback(renderer, second_probe.readback);
    VertexScene target = create_vertex_scene(&fixture)!!;
    defer scene::destroy_scene(&target.target.scene);
    configure_vertex_view(&fixture, fixture.view, ShadingPath.FORWARD)!!;
    configure_vertex_view(&fixture, fixture.second_view, ShadingPath.DEFERRED)!!;
    Vec2 single = vertex_step_velocity(&target, VERTEX_STEP);
    Vec2 double_step = vertex_step_velocity(&target, 2 * VERTEX_STEP);

    settle_vertex_view(&fixture, &target, &probe, fixture.view)!!;
    settle_vertex_view(&fixture, &target, &second_probe, fixture.second_view)!!;
    move_quad(&fixture, target.geometry, VERTEX_STEP);
    check_step(render_vertex_frame(&fixture, &target, &probe, fixture.view)!!, single);
    move_quad(&fixture, target.geometry, VERTEX_STEP);
    target.target.scene.update_world();
    renderer.begin_frame({ .time = 1, .delta = 1.0f / 60 })!!;
    renderer.render_view(&target.target.scene, target.target.camera, fixture.view)!!;
    record_lod_target(&fixture, &probe, &renderer.views.get(fixture.view).velocity)!!;
    renderer.finish_view(fixture.view)!!;
    renderer.render_view(&target.target.scene, target.target.camera, fixture.second_view)!!;
    record_lod_target(&fixture, &second_probe, &renderer.views.get(fixture.second_view).velocity)!!;
    renderer.finish_view(fixture.second_view)!!;
    renderer.end_frame()!!;
    usz vertex_count = fixture.assets.geometry(target.geometry).data.positions.len;
    assert(renderer.stats.vertex_history_bytes == 2 * vertex_count * Vec3::size);
    render::wait_frames(renderer)!!;
    gpu::invalidate_mapped_span(&renderer.device, probe.readback.span)!!;
    gpu::invalidate_mapped_span(&renderer.device, second_probe.readback.span)!!;
    check_step(lod_velocity_pixel(probe.readback, CENTER_UV), single);
    check_step(lod_velocity_pixel(second_probe.readback, CENTER_UV), double_step);

    target.target.scene.root.local.position = DISTANT_OFFSET;
    check_still(render_vertex_frame(&fixture, &target, &probe, fixture.view, DISTANT_OFFSET)!!);
    check_still(render_vertex_frame(&fixture, &target, &probe, fixture.view, DISTANT_OFFSET)!!);
    move_quad(&fixture, target.geometry, VERTEX_STEP);
    Vec3 crossed = DISTANT_OFFSET + REFERENCE_CROSSING;
    check_step(render_vertex_frame(&fixture, &target, &probe, fixture.view, crossed)!!, single);
    check_still(render_vertex_frame(&fixture, &target, &probe, fixture.view, crossed)!!);
    check_validation(renderer);
}

fn void test_vertex_motion_composes_with_previous_skin_and_morph() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    LodVelocityProbe probe = create_velocity_probe(&fixture)!!;
    defer free_lod_readback(&fixture.renderer, probe.readback);
    VertexScene target = create_vertex_scene(&fixture, deformed: true)!!;
    defer scene::destroy_scene(&target.target.scene);
    configure_vertex_view(&fixture, fixture.view, ShadingPath.FORWARD)!!;

    settle_vertex_view(&fixture, &target, &probe, fixture.view)!!;
    move_quad(&fixture, target.geometry, VERTEX_STEP);
    check_step(render_vertex_frame(&fixture, &target, &probe, fixture.view)!!, vertex_step_velocity(&target, VERTEX_STEP));
    check_still(render_vertex_frame(&fixture, &target, &probe, fixture.view)!!);
    check_validation(&fixture.renderer);
}
