module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import c3d::test::animated_lod_fixtures;
import gpu;
import std::math;

const char[*] LOD_TRACE_DEPTH_SOURCE @private = $embed("../render/posed_depth.comp.glsl");
const uint LOD_TRACE_GROUP_SIZE @private = 8;
const uint LOD_TRACE_RASTER_HIT @private = 1;
const uint LOD_TRACE_HIT @private = 2;
const usz LOD_TRACE_PIXELS @private = TARGET_SIZE * TARGET_SIZE;
const usz LOD_TRACE_COVERAGE_MINIMUM @private = LOD_TRACE_PIXELS / 10;
const usz LOD_TRACE_EDGE_BUDGET @private = LOD_TRACE_PIXELS / 50;
const float LOD_TRACE_DEPTH_TOLERANCE @private = 1e-3f;
const float LOD_TRACE_NORMAL_AGREEMENT @private = 0.999f;
const float LOD_TRACE_CAMERA_DISTANCE @private = 1.4f;
const float LOD_TRACE_CHARACTER_DISTANCE @private = 1.6f;
const uint SHARED_POSE_FRAMES @private = 8;
const uint SHARED_POSE_VIEWS @private = 2;
const uint SHARED_POSE_CAPACITY @private = 7;
const uint SHARED_POSE_PARTS @private = 4;
const uint SHARED_POSE_PART @private = 2;
const uint SHARED_POSE_ABORT_FRAME @private = 4;
const uint SHARED_POSE_REPLACE_FRAME @private = 5;
const uint SHARED_POSE_REVISION_FRAME @private = 6;
const uint SHARED_POSE_RECYCLE_FRAME @private = 7;
const uint SHARED_POSE_PIXEL_RADIUS @private = 2;
const float SHARED_POSE_POINT_TOLERANCE @private = 1e-3f;
const float SHARED_POSE_INSTANCE_DISTANCE @private = 30;
const float SHARED_POSE_REVISION_OFFSET @private = 0.25f;
const float SHARED_POSE_RECYCLED_SCALE @private = 2;
const float[CROWD_NATIVE_INSTANCES][SHARED_POSE_FRAMES] SHARED_POSE_PHASES @private = {
    { 0.25f, 0.25f, 0.25f },
    { 0.25f, 0.75f, 0.25f },
    { 0.75f, 0.25f, 0.25f },
    { 0.25f, 0.25f, 0.25f },
    { 0.75f, 0.75f, 0.75f },
    { 0.25f, 0.25f, 0.25f },
    { 0.5f, 0.5f, 0.5f },
    { 0, 0, 0 },
};
const uint[SHARED_POSE_FRAMES] SHARED_POSE_FOLLOWERS @private = { 8, 5, 5, 8, 8, 8, 8, 0 };

struct LodTraceDepthRoot @private {
    Mat4f inv_view_proj;
    Vec4f camera;
    gpu::GpuAddress scene;
    gpu::GpuAddress output_address;
    uint size;
    uint padding0;
    uint padding1;
    uint padding2;
}
$assert LodTraceDepthRoot::size == 112;

struct LodTraceDepthResult @private {
    float raster;
    float traced;
    uint geometry_low;
    uint flags;
    uint primitive;
    uint padding;
    Vec2 barycentrics;
    float[4] normal;
    float[4] geometric_normal;
}
$assert LodTraceDepthResult::size == 64;

struct LodTraceHarness @private {
    Scene scene;
    Node* camera;
    ComputeShaderId software_shader;
    ComputeShaderId hardware_shader;
    BufferId output;
    gpu::MappedGpuSpan[2] readbacks;
}

struct SharedPoseSnapshot @private {
    gpu::MappedGpuSpan readback;
    CameraMatrices camera;
    Vec3[3] triangle;
}

fn bool create_lod_trace_fixture(Fixture* fixture, TraceKind kind) @private {
    if (catch excuse = create_fixture(mem, fixture, ray_queries: kind == TraceKind.HARDWARE)) {
        assert(kind == TraceKind.HARDWARE && excuse == gpu::UNSUPPORTED_FEATURE);
        return false;
    }
    return true;
}

fn void? create_lod_trace_harness(Fixture* fixture, LodTraceHarness* harness) @private {
    harness.scene = scene::create_scene(fixture.allocator, { .max_nodes = 2048 });
    defer catch scene::destroy_scene(&harness.scene);
    harness.camera = harness.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "lod_trace_camera")!;
    String[1] software = { "SCENE_TRACE_BVH" };
    harness.software_shader = add_compute_shader(fixture, (String)LOD_TRACE_DEPTH_SOURCE[..], software[..])!;
    if (fixture.renderer.caps.ray_queries.enabled) {
        String[1] hardware = { "SCENE_TRACE_RAY_QUERY" };
        harness.hardware_shader = add_compute_shader(fixture, (String)LOD_TRACE_DEPTH_SOURCE[..], hardware[..])!;
    }
    harness.output = fixture.renderer.create_buffer({
        .size = LOD_TRACE_PIXELS * LodTraceDepthResult::size,
        .debug_name = "animated_lod_trace_depth",
    })!;
    gpu::AllocationDesc desc = {
        .size = LOD_TRACE_PIXELS * LodTraceDepthResult::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "animated_lod_trace_readback",
    };
    foreach (&readback : harness.readbacks) *readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &desc)!;
}

fn void destroy_lod_trace_harness(Fixture* fixture, LodTraceHarness* harness) @private {
    render::wait_frames(&fixture.renderer)!!;
    foreach (readback : harness.readbacks) {
        gpu::GpuAllocation allocation = readback.span.allocation();
        if (allocation.is_valid()) gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    }
    scene::destroy_scene(&harness.scene);
    *harness = {};
}

fn void? record_lod_trace_probe(
    Fixture* fixture,
    LodTraceHarness* harness,
    Node* camera_node,
    ViewId view,
    TraceKind kind,
    gpu::MappedGpuSpan readback,
) @private {
    Renderer* renderer = &fixture.renderer;
    Camera* camera = harness.scene.get(camera_node, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, { TARGET_SIZE, TARGET_SIZE });
    LodTraceDepthRoot root = {
        .inv_view_proj = bitcast(matrices.inv_view_proj, Mat4f),
        .camera = { matrices.position.x, matrices.position.y, matrices.position.z, 1 },
        .scene = renderer.prepare_scene_trace(&harness.scene, kind)!,
        .output_address = renderer.buffer_address(harness.output),
        .size = TARGET_SIZE,
    };
    BufferId[1] writes = { harness.output };
    DispatchTexture[1] textures = { render::read_view_depth(view, asset::SAMPLER_NEAREST) };
    uint groups = TARGET_SIZE / LOD_TRACE_GROUP_SIZE;
    renderer.dispatch({
        .shader = kind == TraceKind.HARDWARE ? harness.hardware_shader : harness.software_shader,
        .root = ((char*)&root)[:LodTraceDepthRoot::size],
        .groups = { groups, groups, 1 },
        .writes = writes[..],
        .textures = textures[..],
    })!;
    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(harness.output).allocation)!,
        .dst = readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
}

fn void check_lod_trace_agreement(LodTraceDepthResult[] results, bool flat) @private {
    usz covered;
    usz mismatched;
    usz normals_off;
    foreach (&result : results) {
        bool raster = (result.flags & LOD_TRACE_RASTER_HIT) != 0;
        bool traced = (result.flags & LOD_TRACE_HIT) != 0;
        if (!raster && !traced) continue;
        if (traced) {
            Vec3 shading = { result.normal[0], result.normal[1], result.normal[2] };
            Vec3 geometric = { result.geometric_normal[0], result.geometric_normal[1], result.geometric_normal[2] };
            if (!(shading.dot(geometric) >= LOD_TRACE_NORMAL_AGREEMENT)) normals_off++;
        }
        if (raster != traced) {
            mismatched++;
            continue;
        }
        covered++;
        if (!(math::abs(result.traced - result.raster) / result.raster <= LOD_TRACE_DEPTH_TOLERANCE)) mismatched++;
    }
    assert(covered >= LOD_TRACE_COVERAGE_MINIMUM && mismatched <= LOD_TRACE_EDGE_BUDGET);
    if (flat) assert(normals_off == 0);
}

fn void? render_lod_trace(
    Fixture* fixture,
    LodTraceHarness* harness,
    TraceKind kind,
    bool flat = true,
    Node* second_camera = null,
) @private {
    Renderer* renderer = &fixture.renderer;
    Node*[2] cameras = { harness.camera, second_camera };
    ViewId[2] views = { fixture.view, fixture.second_view };
    uint count = second_camera ? 2 : 1;
    harness.scene.update_world();
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    for (uint index = 0; index < count; index++) {
        renderer.render_view(&harness.scene, cameras[index], views[index])!;
        record_lod_trace_probe(
            fixture: fixture,
            harness: harness,
            camera_node: cameras[index],
            view: views[index],
            kind: kind,
            readback: harness.readbacks[index],
        )!;
        renderer.finish_view(views[index])!;
    }
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    foreach (readback : harness.readbacks[:count]) {
        gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
        check_lod_trace_agreement(((LodTraceDepthResult*)readback.bytes.ptr)[:LOD_TRACE_PIXELS], flat);
    }
}

fn void run_lod_trace_mixed(TraceKind kind) @private {
    Fixture fixture;
    if (!create_lod_trace_fixture(&fixture, kind)) return;
    defer destroy_fixture(&fixture);
    LodTraceHarness harness;
    create_lod_trace_harness(&fixture, &harness)!!;
    defer destroy_lod_trace_harness(&fixture, &harness);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    Node* owner = model::instantiate(&fixture.assets, &harness.scene, parts.mixed)!!;
    owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
    Animator* animator = anim::add_animator(&harness.scene, owner);
    AnimationActionId action = animator.play(&fixture.assets, parts.posing)!!;
    animator.action(action).loop = false;
    animator.action(action).time = 1;
    anim::update(&fixture.assets, &harness.scene, 0);
    @pool() {
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &harness.scene,
            owner: owner,
            desc: animated_crowd_fixtures::parts_lod_desc(&fixture.assets, parts.mixed),
        )!!;
    };
    harness.scene.get(owner, LodGroup).state.effects.trace = true;
    Stats* stats = &fixture.renderer.stats;
    for (uint part = 0; part < animated_crowd_fixtures::PARTS_MESH_COUNT; part++) {
        Vec3 first = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part];
        Vec3 second = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part + 1];
        Vec3 third = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part + 2];
        harness.camera.local.position = (first + second + third) / 3 + (Vec3){ 0, 0, LOD_TRACE_CAMERA_DISTANCE };
        render_lod_trace(&fixture, &harness, kind)!!;
        assert(stats.trace_posed_instances == 4 && stats.trace_posed_overflow == 0);
        assert(stats.lod_objects_selected[0] == 1 && stats.trace_poses == (part == 0 ? 4u : 0u));
        check_crowd_native_validation(&fixture.renderer);
    }
}

fn void test_traced_animated_lod_native_mixed_software_matches_base_pose() @test {
    run_lod_trace_mixed(TraceKind.SOFTWARE);
}

fn void test_traced_animated_lod_native_mixed_hardware_matches_base_pose() @test {
    run_lod_trace_mixed(TraceKind.HARDWARE);
}

fn Vec3 lod_trace_crowd_centre(
    Node* owner,
    CrowdInstance* instance,
    uint part,
    float phase,
) @private {
    Vec3 centre;
    for (uint vertex = 0; vertex < 3; vertex++) {
        Vec3 rest = animated_crowd_fixtures::PARTS_REST_POINTS[3 * part + vertex];
        Vec3 posed = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part + vertex];
        centre += rest + (posed - rest) * phase - animated_crowd_fixtures::PARTS_ROOT_POSITION;
    }
    Mat4 world = owner.world.mul(instance.placement.to_mat4());
    return maths::transform_point(world, centre / 3);
}

fn void set_lod_trace_phases(
    Fixture* fixture,
    LodTraceHarness* harness,
    Node* owner,
    float[] phases,
) @private {
    AnimatedCrowd* crowd = harness.scene.get(owner, AnimatedCrowd);
    foreach (uint source, phase : phases) {
        CrowdInstanceId id = crowd.playback.instance_id(source)!!;
        crowd.playback.player(id)!!.base_action()!!.time = phase;
    }
    anim::crowd_update(&fixture.assets, &harness.scene, 0);
    harness.scene.update_world();
}

fn void run_lod_trace_crowd_lifecycle(TraceKind kind) @private {
    Fixture fixture;
    if (!create_lod_trace_fixture(&fixture, kind)) return;
    defer destroy_fixture(&fixture);
    LodTraceHarness harness;
    create_lod_trace_harness(&fixture, &harness)!!;
    defer destroy_lod_trace_harness(&fixture, &harness);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    CrowdInstance[CROWD_NATIVE_INSTANCES] instances;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        instances[source] = {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = parts.posing, .time = 0.25f * (float)(source + 1), .speed = 0, .loop = false },
            .color = { 1, 1, 1, 1 },
        };
        instances[source].placement.position.x = 30 * (float)source;
    }
    instances[1].placement.scale = { -1, 1.2f, 1 };
    instances[2].placement.scale = { 1.3f, 0.9f, 1.1f };
    Node* owner = model::add_crowd(
        assets: &fixture.assets,
        scene: &harness.scene,
        model: parts.mixed,
        capacity: CROWD_NATIVE_INSTANCES,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
    )!!;
    owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
    GeometryId coarse = fixture.assets.add_geometry(&fixture.assets.geometry(parts.geometries[1]).data)!!;
    @pool() {
        AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(&fixture.assets, parts.mixed);
        desc.parts[animated_crowd_fixtures::PARTS_MESH_COUNT + 1].draw.geometry = coarse;
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &harness.scene,
            owner: owner,
            desc: desc,
        )!!;
    };
    harness.scene.update_world();
    harness.scene.get(owner, LodGroup).state.effects.trace = true;
    Renderer* renderer = &fixture.renderer;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        for (uint part = 0; part < animated_crowd_fixtures::PARTS_MESH_COUNT; part++) {
            Vec3 centre = lod_trace_crowd_centre(
                owner: owner,
                instance: &instances[source],
                part: part,
                phase: instances[source].pose.time,
            );
            harness.camera.local.position = centre + (Vec3){ 0, 0, LOD_TRACE_CAMERA_DISTANCE };
            render_lod_trace(&fixture, &harness, kind)!!;
            assert(renderer.stats.trace_posed_instances == 12 && renderer.stats.trace_posed_overflow == 0);
            assert(renderer.stats.trace_poses == (!source && !part ? 10u : 0u));
        }
    }

    float[CROWD_NATIVE_INSTANCES] phases = { 0.4f, 0.5f, 0.75f };
    set_lod_trace_phases(
        fixture: &fixture,
        harness: &harness,
        owner: owner,
        phases: phases[..],
    );
    Node* second_camera = harness.scene.add_camera(
        camera: camera::perspective_deg(60, 0.1f),
        name: "second_lod_trace_camera",
    )!!;
    Vec3 first_centre = lod_trace_crowd_centre(
        owner: owner,
        instance: &instances[0],
        part: 2,
        phase: phases[0],
    );
    Vec3 second_centre = lod_trace_crowd_centre(
        owner: owner,
        instance: &instances[1],
        part: 0,
        phase: phases[1],
    );
    harness.camera.local.position = first_centre + (Vec3){ 0, 0, LOD_TRACE_CAMERA_DISTANCE };
    second_camera.local.position = second_centre + (Vec3){ 0, 0, LOD_TRACE_CAMERA_DISTANCE };
    render_lod_trace(
        fixture: &fixture,
        harness: &harness,
        kind: kind,
        second_camera: second_camera,
    )!!;
    assert(renderer.stats.trace_poses == 3);
    assert(renderer.stats.trace_refits == (kind == TraceKind.SOFTWARE ? 3u : 0u));
    ulong revision = renderer.scene_trace.revision;
    render_lod_trace(
        fixture: &fixture,
        harness: &harness,
        kind: kind,
        second_camera: second_camera,
    )!!;
    assert(renderer.stats.trace_poses == 0 && renderer.stats.trace_refits == 0);
    assert(renderer.scene_trace.revision == revision);

    phases[2] = 0.9f;
    set_lod_trace_phases(
        fixture: &fixture,
        harness: &harness,
        owner: owner,
        phases: phases[..],
    );
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!!;
    renderer.prepare_scene_trace(&harness.scene, kind)!!;
    assert(renderer.stats.trace_poses == 3);
    render::abort_frame(renderer);
    render_lod_trace(&fixture, &harness, kind)!!;
    assert(renderer.stats.trace_poses == 3);
    render_lod_trace(&fixture, &harness, kind)!!;
    assert(renderer.stats.trace_poses == 0);

    model::set_crowd(
        assets: &fixture.assets,
        scene: &harness.scene,
        node: owner,
        instances: instances[..],
    )!!;
    render_lod_trace(&fixture, &harness, kind)!!;
    assert(renderer.stats.trace_poses == 10);
    check_crowd_native_validation(renderer);
}

fn void test_traced_animated_lod_native_crowd_software_lifecycle_and_two_views() @test {
    run_lod_trace_crowd_lifecycle(TraceKind.SOFTWARE);
}

fn void test_traced_animated_lod_native_crowd_hardware_lifecycle_and_two_views() @test {
    run_lod_trace_crowd_lifecycle(TraceKind.HARDWARE);
}

fn void check_shared_pose_snapshot(SharedPoseSnapshot* snapshot, uint snapshot_index) @private {
    LodTraceDepthResult[] results = ((LodTraceDepthResult*)snapshot.readback.bytes.ptr)[:LOD_TRACE_PIXELS];
    foreach (pixel, &result : results) {
        if (!(result.flags & LOD_TRACE_HIT)) continue;
        Vec3 shading = { result.normal[0], result.normal[1], result.normal[2] };
        Vec3 geometric = { result.geometric_normal[0], result.geometric_normal[1], result.geometric_normal[2] };
        assert(shading.dot(geometric) >= LOD_TRACE_NORMAL_AGREEMENT,
            "snapshot %d pixel %d: shading %s geometric %s", snapshot_index, pixel, shading, geometric);
    }
    check_lod_trace_agreement(results, true);
    uint first = TARGET_SIZE / 2 - SHARED_POSE_PIXEL_RADIUS;
    uint end = TARGET_SIZE / 2 + SHARED_POSE_PIXEL_RADIUS;
    for (uint row = first; row < end; row++) {
        for (uint column = first; column < end; column++) {
            LodTraceDepthResult* result = &results[row * TARGET_SIZE + column];
            assert(result.flags == (LOD_TRACE_RASTER_HIT | LOD_TRACE_HIT));
            assert(result.primitive == 0);
            Vec2 uv = { ((float)column + 0.5f) / TARGET_SIZE, ((float)row + 0.5f) / TARGET_SIZE };
            Vec4 far_point = snapshot.camera.inv_view_proj * (Vec4){ 2 * uv.x - 1, 1 - 2 * uv.y, 0.5f, 1 };
            Vec3 direction = (far_point.xyz / far_point.w - snapshot.camera.position).normalize();
            Vec3 observed = snapshot.camera.position + direction * result.traced;
            Vec2 barycentrics = result.barycentrics;
            Vec3 expected = snapshot.triangle[0] * (1 - barycentrics.x - barycentrics.y)
              + snapshot.triangle[1] * barycentrics.x + snapshot.triangle[2] * barycentrics.y;
            assert((expected - observed).length() <= SHARED_POSE_POINT_TOLERANCE);
        }
    }
}

fn void run_shared_pose_queued_frames(TraceKind kind, bool compute_skinning = false) @private {
    Fixture fixture;
    if (catch excuse = create_fixture(
        allocator: mem,
        fixture: &fixture,
        ray_queries: kind == TraceKind.HARDWARE,
        max_posed_trace_instances: SHARED_POSE_CAPACITY,
    )) {
        assert(kind == TraceKind.HARDWARE && excuse == gpu::UNSUPPORTED_FEATURE);
        return;
    }
    defer destroy_fixture(&fixture);
    LodTraceHarness harness;
    create_lod_trace_harness(&fixture, &harness)!!;
    defer destroy_lod_trace_harness(&fixture, &harness);
    Renderer* renderer = &fixture.renderer;
    renderer.set_compute_skinning(compute_skinning);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    CrowdInstance[CROWD_NATIVE_INSTANCES] instances;
    foreach (source, &instance : instances) {
        *instance = {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = parts.posing, .time = SHARED_POSE_PHASES[0][source], .speed = 0, .loop = false },
            .color = { 1, 1, 1, 1 },
        };
        instance.placement.position.x = SHARED_POSE_INSTANCE_DISTANCE * (float)source;
    }
    Node* owner = model::add_crowd(
        assets: &fixture.assets,
        scene: &harness.scene,
        model: parts.mixed,
        capacity: CROWD_NATIVE_INSTANCES,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
        trace: true,
    )!!;
    owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
    if (!compute_skinning) {
        @pool() {
            model::attach_animated_lod(
                assets: &fixture.assets,
                scene: &harness.scene,
                owner: owner,
                desc: animated_crowd_fixtures::parts_lod_desc(&fixture.assets, parts.mixed),
            )!!;
        };
        harness.scene.get(owner, LodGroup).state.effects.trace = true;
    }
    Node*[SHARED_POSE_VIEWS] cameras = {
        harness.camera,
        harness.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "shared_pose_camera")!!,
    };
    ViewId[SHARED_POSE_VIEWS] views = { fixture.view, fixture.second_view };
    SharedPoseSnapshot[SHARED_POSE_FRAMES * SHARED_POSE_VIEWS] snapshots;
    defer {
        render::wait_frames(renderer)!!;
        foreach (&snapshot : snapshots) {
            gpu::GpuAllocation allocation = snapshot.readback.span.allocation();
            if (allocation.is_valid()) gpu::free_allocation(&renderer.device, &allocation)!!;
        }
    };
    gpu::AllocationDesc allocation_desc = {
        .size = LOD_TRACE_PIXELS * LodTraceDepthResult::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "shared_pose_snapshot",
    };
    foreach (&snapshot : snapshots) snapshot.readback = gpu::allocate_mapped_memory(&renderer.device, &allocation_desc)!!;

    Node* replacement_node;
    GeometryId recycled_geometry;
    bool reused_compute_pose;
    for (uint frame = 0; frame < SHARED_POSE_FRAMES; frame++) {
        float[CROWD_NATIVE_INSTANCES] phases = SHARED_POSE_PHASES[frame];
        if (frame == SHARED_POSE_REPLACE_FRAME) {
            model::set_crowd(
                assets: &fixture.assets,
                scene: &harness.scene,
                node: owner,
                instances: instances[..],
            )!!;
        }
        if (frame == SHARED_POSE_REVISION_FRAME) {
            GeometryId geometry_id = parts.geometries[SHARED_POSE_PART];
            ulong previous_revision = fixture.assets.geometry(geometry_id).header.revision;
            foreach (&position : fixture.assets.geometry(geometry_id).data.positions) {
                position.z += SHARED_POSE_REVISION_OFFSET;
            }
            fixture.assets.mark_geometry_dirty(geometry_id);
            assert(fixture.assets.geometry(geometry_id).header.revision == previous_revision + 1);
            if (!compute_skinning) {
                harness.scene.remove_component(owner, LodGroup);
                @pool() {
                    model::attach_animated_lod(
                        assets: &fixture.assets,
                        scene: &harness.scene,
                        owner: owner,
                        desc: animated_crowd_fixtures::parts_lod_desc(&fixture.assets, parts.mixed),
                    )!!;
                };
                harness.scene.get(owner, LodGroup).state.effects.trace = true;
            }
        }
        if (frame == SHARED_POSE_RECYCLE_FRAME) {
            GeometryId removed = parts.geometries[SHARED_POSE_PART];
            Vec3[3] points;
            foreach (vertex, &point : points) {
                *point = fixture.assets.geometry(removed).data.positions[vertex] * SHARED_POSE_RECYCLED_SCALE;
            }
            Vec3[3] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
            Geometry recycled = { .topology = Topology.TRIANGLES, .positions = points[..], .normals = normals[..] };
            recycled.finalize();
            harness.scene.remove(owner);
            fixture.assets.remove_geometry(removed);
            recycled_geometry = fixture.assets.add_geometry(&recycled)!!;
            assert(recycled_geometry.index == removed.index && recycled_geometry.generation != removed.generation);
            replacement_node = harness.scene.add_mesh(recycled_geometry, parts.material)!!;
            replacement_node.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
        } else {
            set_lod_trace_phases(
                fixture: &fixture,
                harness: &harness,
                owner: owner,
                phases: phases[..],
            );
        }
        foreach (uint source, camera_node : cameras) {
            Vec3 centre;
            if (frame == SHARED_POSE_RECYCLE_FRAME) {
                foreach (point : fixture.assets.geometry(recycled_geometry).data.positions) centre += point;
                centre = centre / 3 + replacement_node.local.position;
            } else {
                centre = lod_trace_crowd_centre(
                    owner: owner,
                    instance: &instances[source],
                    part: SHARED_POSE_PART,
                    phase: phases[source],
                );
                if (frame == SHARED_POSE_REVISION_FRAME) centre.z += SHARED_POSE_REVISION_OFFSET;
            }
            camera_node.local.position = centre + (Vec3){ 0, 0, LOD_TRACE_CAMERA_DISTANCE };
        }
        harness.scene.update_world();
        if (frame == SHARED_POSE_ABORT_FRAME) {
            renderer.begin_frame({ .time = 0.37, .delta = 0 })!!;
            renderer.prepare_scene_trace(&harness.scene, kind)!!;
            render::abort_frame(renderer);
        }
        renderer.begin_frame({ .time = 0.37, .delta = 0 })!!;
        foreach (uint source, camera_node : cameras) {
            SharedPoseSnapshot* snapshot = &snapshots[frame * SHARED_POSE_VIEWS + source];
            snapshot.camera = camera::derive_matrices(
                *harness.scene.get(camera_node, Camera),
                camera_node.world,
                { TARGET_SIZE, TARGET_SIZE },
            );
            for (uint vertex = 0; vertex < 3; vertex++) {
                if (frame == SHARED_POSE_RECYCLE_FRAME) {
                    snapshot.triangle[vertex] = maths::transform_point(
                        replacement_node.world,
                        fixture.assets.geometry(recycled_geometry).data.positions[vertex],
                    );
                } else {
                    Mat4 world = owner.world.mul(instances[source].placement.to_mat4());
                    Vec3 rest = animated_crowd_fixtures::PARTS_REST_POINTS[3 * SHARED_POSE_PART + vertex];
                    Vec3 posed = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * SHARED_POSE_PART + vertex];
                    Vec3 point = rest + (posed - rest) * phases[source] - animated_crowd_fixtures::PARTS_ROOT_POSITION;
                    if (frame == SHARED_POSE_REVISION_FRAME) point.z += SHARED_POSE_REVISION_OFFSET;
                    snapshot.triangle[vertex] = maths::transform_point(world, point);
                }
            }
            renderer.render_view(&harness.scene, camera_node, views[source])!!;
            record_lod_trace_probe(
                fixture: &fixture,
                harness: &harness,
                camera_node: camera_node,
                view: views[source],
                kind: kind,
                readback: snapshot.readback,
            )!!;
            gpu::Barrier output_reuse = { .before = { .transfer }, .after = { .all } };
            gpu::cmd_barrier(&renderer.commands, &output_reuse)!!;
            renderer.finish_view(views[source])!!;
        }
        renderer.end_frame()!!;
        assert(renderer.frame_submitted);
        uint expected_poses = frame == SHARED_POSE_RECYCLE_FRAME ? 0 : SHARED_POSE_PARTS * CROWD_NATIVE_INSTANCES;
        assert(renderer.stats.trace_posed_instances == expected_poses,
            "snapshot %d: posed %d, expected %d, shared %d, overflow %d",
            frame, renderer.stats.trace_posed_instances, expected_poses,
            renderer.stats.trace_posed_shared, renderer.stats.trace_posed_overflow);
        assert(renderer.stats.trace_posed_overflow == 0);
        assert(renderer.stats.trace_posed_shared == SHARED_POSE_FOLLOWERS[frame]);
        if (expected_poses && compute_skinning) assert(renderer.stats.compute_skinned > 0);
        if (!compute_skinning) assert(renderer.stats.trace_poses_reused == 0);
        reused_compute_pose |= renderer.stats.trace_poses_reused > 0;
    }
    assert(reused_compute_pose == compute_skinning);
    render::wait_frames(renderer)!!;
    foreach (uint snapshot_index, &snapshot : snapshots) {
        gpu::invalidate_mapped_span(&renderer.device, snapshot.readback.span)!!;
        check_shared_pose_snapshot(snapshot, snapshot_index);
    }
    check_crowd_native_validation(renderer);
}

fn void test_shared_crowd_pose_queued_software_snapshots() @test {
    run_shared_pose_queued_frames(TraceKind.SOFTWARE);
}

fn void test_shared_crowd_pose_queued_hardware_snapshots() @test {
    run_shared_pose_queued_frames(TraceKind.HARDWARE);
}

fn void test_shared_crowd_pose_queued_software_compute_snapshots() @test {
    run_shared_pose_queued_frames(TraceKind.SOFTWARE, true);
}

fn void test_shared_crowd_pose_queued_hardware_compute_snapshots() @test {
    run_shared_pose_queued_frames(TraceKind.HARDWARE, true);
}

fn void run_lod_trace_quaternius(TraceKind kind) @private {
    Fixture fixture;
    if (!create_lod_trace_fixture(&fixture, kind)) return;
    defer destroy_fixture(&fixture);
    LodTraceHarness harness;
    create_lod_trace_harness(&fixture, &harness)!!;
    defer destroy_lod_trace_harness(&fixture, &harness);
    AnimatedLodFixtures corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, "../../..")!!;
    crowd_native_flat_source_materials(&fixture, corpus.model);
    LodNativeSubject subject = quaternius_lod_subject(&fixture, &corpus);
    Node* owner = model::instantiate(&fixture.assets, &harness.scene, corpus.model)!!;
    Animator* animator = anim::add_animator(&harness.scene, owner);
    AnimationActionId action = animator.play(&fixture.assets, subject.clip)!!;
    animator.action(action).loop = false;
    animator.action(action).speed = 0;
    animator.action(action).time = 0.375f * fixture.assets.clip(subject.clip).data.duration;
    anim::update(&fixture.assets, &harness.scene, 0);
    LodNativeDescriptor descriptor;
    model::attach_animated_lod(
        assets: &fixture.assets,
        scene: &harness.scene,
        owner: owner,
        desc: lod_native_desc(
            fixture: &fixture,
            subject: &subject,
            descriptor: &descriptor,
            crowd: false,
        ),
    )!!;
    harness.scene.get(owner, LodGroup).state.effects.trace = true;
    ViewDesc view = fixture.renderer.views.get(fixture.view).desc;
    view.lod_bias = 16;
    render::configure_view(&fixture.renderer, fixture.view, view)!!;
    harness.camera.local.position = { 0, 1.1f, LOD_TRACE_CHARACTER_DISTANCE };
    render_lod_trace(
        fixture: &fixture,
        harness: &harness,
        kind: kind,
        flat: false,
    )!!;
    Renderer* renderer = &fixture.renderer;
    uint parts = animated_lod_fixtures::LOD_PRIMITIVES;
    assert(renderer.stats.trace_posed_instances == parts && renderer.stats.trace_posed_overflow == 0);
    assert(renderer.stats.trace_poses == parts && renderer.stats.lod_objects_selected[0] == 1);
    ulong revision = renderer.scene_trace.revision;
    render_lod_trace(
        fixture: &fixture,
        harness: &harness,
        kind: kind,
        flat: false,
    )!!;
    assert(renderer.scene_trace.revision == revision && renderer.stats.trace_poses == 0);
    check_crowd_native_validation(renderer);
}

fn void test_traced_animated_lod_native_quaternius_software_base_trace() @test {
    run_lod_trace_quaternius(TraceKind.SOFTWARE);
}

fn void test_traced_animated_lod_native_quaternius_hardware_base_trace() @test {
    run_lod_trace_quaternius(TraceKind.HARDWARE);
}
