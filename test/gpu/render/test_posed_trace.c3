module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::maths;
import c3d::render @public;
import c3d::material;
import c3d::scene;
import c3d::shader;
import gpu;
import std::io;
import std::math;
import std::math::quaternion;

const char[*] POSED_DEPTH_SOURCE @private = $embed("posed_depth.comp.glsl");
const uint POSED_GROUP_SIZE @private = 8;              // mirrored as local_size_x and _y in posed_depth.comp.glsl
const uint POSED_RASTER_HIT @private = 1;              // mirrored as POSED_RASTER_HIT in posed_depth.comp.glsl
const uint POSED_TRACE_HIT @private = 2;               // mirrored as POSED_TRACE_HIT in posed_depth.comp.glsl
const float POSED_DEPTH_TOLERANCE @private = 1e-3f;    // relative; every pose here moves a surface by 5 % or more
const usz POSED_PIXELS @private = TARGET_SIZE * TARGET_SIZE;
const usz POSED_EDGE_BUDGET @private = POSED_PIXELS / 50; // silhouette pixels where coverage and the centre ray part
const usz POSED_COVERAGE_MINIMUM @private = POSED_PIXELS / 10;
const uint POSED_FRAMES @private = 4;
const usz POSED_RESULT_BYTES @private = POSED_PIXELS * PosedDepthResult::size;

struct PosedDepthRoot @private {
    Mat4f           inv_view_proj;
    Vec4f           camera;
    gpu::GpuAddress scene;
    gpu::GpuAddress output_address;
    uint            size;
    uint            _pad0;
    uint            _pad1;
    uint            _pad2;
}
$assert PosedDepthRoot::size == 112;

struct PosedDepthResult @private {
    float raster;
    float traced;
    uint  geometry_low;
    uint  flags;
    uint  primitive;
    uint  padding;
    Vec2  barycentrics;
}
$assert PosedDepthResult::size == 32;

struct PosedHarness @private {
    Scene              scene;
    Node*              camera;
    ComputeShaderId    walk_shader;
    ComputeShaderId    query_shader;
    BufferId           output;
    gpu::MappedGpuSpan readback;
    PosedDepthResult[] results;
}

struct PosedRig @private {
    Node* mesh;
    Node* joint;
}

struct PosedAgreement @private {
    usz   covered;    // pixels where raster and trace both hit
    usz   mismatched; // pixels where one hit alone, or the distances differ past the tolerance
    float worst;      // largest relative distance error over covered pixels
}

fn void? posed_create_harness(Fixture* fixture, PosedHarness* harness) @private {
    harness.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&harness.scene);
    harness.camera = harness.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    harness.camera.local.position = CAMERA_POSITION;
    String[1] walk = { "SCENE_TRACE_BVH" };
    harness.walk_shader = add_compute_shader(fixture, (String)POSED_DEPTH_SOURCE[..], walk[..])!;
    if (fixture.renderer.caps.ray_queries.enabled) {
        String[1] query = { "SCENE_TRACE_RAY_QUERY" };
        harness.query_shader = add_compute_shader(fixture, (String)POSED_DEPTH_SOURCE[..], query[..])!;
    }
    harness.output = fixture.renderer.create_buffer({ .size = POSED_RESULT_BYTES, .debug_name = "posed_depth" })!;
    gpu::AllocationDesc readback_desc = {
        .size         = POSED_RESULT_BYTES,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "posed_depth_readback",
    };
    harness.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!;
    harness.results = alloc::new_array(fixture.allocator, PosedDepthResult, POSED_PIXELS);
}

fn void posed_destroy_harness(Fixture* fixture, PosedHarness* harness) @private {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = harness.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    alloc::free(fixture.allocator, harness.results.ptr);
    scene::destroy_scene(&harness.scene);
}

fn GeometryId? posed_box(Fixture* fixture, bool skinned, Vec3 morph_offset = {}) @private {
    GeometryId box;
    @pool() {
        Geometry shape = geometry::box(tmem, 1, 1, 1);
        if (skinned) {
            shape.joints = alloc::new_array(tmem, ushort[<4>], shape.positions.len);
            shape.weights = alloc::new_array(tmem, Vec4, shape.positions.len);
            foreach (&weight : shape.weights) *weight = { 1, 0, 0, 0 };
        }
        if (morph_offset != (Vec3){}) {
            shape.targets = alloc::new_array(tmem, MorphTarget, 1);
            shape.targets[0] = {
                .position_deltas = alloc::new_array(tmem, Vec3, shape.positions.len),
                .normal_deltas   = alloc::new_array(tmem, Vec3, shape.positions.len),
            };
            foreach (&delta : shape.targets[0].position_deltas) *delta = morph_offset;
        }
        box = fixture.assets.add_geometry(&shape)!;
    };
    return box;
}

fn PosedRig? posed_add_rig(Fixture* fixture, PosedHarness* harness, GeometryId geometry) @private {
    bool skinned = fixture.assets.geometry(geometry).data.joints.len > 0;
    PosedRig rig = { .joint = harness.scene.add_node(name: "posed_joint")! };
    rig.mesh = harness.scene.add_mesh(geometry, fixture.plain, name: "posed_mesh")!;
    Mesh* mesh = harness.scene.get(rig.mesh, Mesh);
    if (fixture.assets.geometry(geometry).target_count) {
        mesh.morph_weights = alloc::new_array(harness.scene.allocator, float, 1);
    }
    if (skinned) {
        Node*[] joints = alloc::new_array(harness.scene.allocator, Node*, 1);
        joints[0] = rig.joint;
        harness.scene.add(rig.mesh, (SkinBinding){ .skeleton = fixture.skeleton, .joints = joints });
    }
    return rig;
}

fn void posed_set_frame(PosedHarness* harness, PosedRig* rig, uint frame) @private {
    rig.joint.local.position = { 0.3f * (float)frame - 0.45f, 0.1f * (float)frame, 0 };
    rig.joint.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(20.0f * (float)frame));
    Mesh* mesh = harness.scene.get(rig.mesh, Mesh);
    if (mesh.morph_weights.len) mesh.morph_weights[0] = 0.25f * (float)(frame + 1);
    harness.scene.update_world();
}

fn void? posed_render(Fixture* fixture, PosedHarness* harness, TraceKind kind) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&harness.scene, harness.camera, fixture.view)!;
    Camera* camera = harness.scene.get(harness.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, harness.camera.world, { TARGET_SIZE, TARGET_SIZE });
    PosedDepthRoot root = {
        .inv_view_proj  = bitcast(matrices.inv_view_proj, Mat4f),
        .camera         = { matrices.position.x, matrices.position.y, matrices.position.z, 1 },
        .scene          = renderer.prepare_scene_trace(&harness.scene, kind)!,
        .output_address = renderer.buffer_address(harness.output),
        .size           = TARGET_SIZE,
    };
    BufferId[1] writes = { harness.output };
    DispatchTexture[1] textures = { render::read_view_depth(fixture.view, asset::SAMPLER_NEAREST) };
    uint groups = TARGET_SIZE / POSED_GROUP_SIZE;
    renderer.dispatch({
        .shader   = kind == TraceKind.HARDWARE ? harness.query_shader : harness.walk_shader,
        .root     = ((char*)&root)[:PosedDepthRoot::size],
        .groups   = { groups, groups, 1 },
        .writes   = writes[..],
        .textures = textures[..],
    })!;
    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(harness.output).allocation)!,
        .dst = harness.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, harness.readback.span)!;
    mem::copy(harness.results.ptr, harness.readback.bytes.ptr, (sz)POSED_RESULT_BYTES);
}

fn PosedAgreement posed_agreement(PosedDepthResult[] results) @private {
    PosedAgreement agreement;
    foreach (&result : results) {
        bool raster = (result.flags & POSED_RASTER_HIT) != 0;
        bool traced = (result.flags & POSED_TRACE_HIT) != 0;
        if (!raster && !traced) continue;
        if (raster != traced) {
            agreement.mismatched++;
            continue;
        }
        agreement.covered++;
        float error = math::abs(result.traced - result.raster) / result.raster;
        agreement.worst = math::max(agreement.worst, error);
        if (error > POSED_DEPTH_TOLERANCE) agreement.mismatched++;
    }
    return agreement;
}

fn void assert_posed_agreement(PosedDepthResult[] results, ZString name) @private {
    PosedAgreement agreement = posed_agreement(results);
    io::eprintfn(
        "%s: %d covered, %d mismatched, worst %f",
        name,
        agreement.covered,
        agreement.mismatched,
        agreement.worst,
    );
    assert(agreement.covered >= POSED_COVERAGE_MINIMUM && agreement.mismatched <= POSED_EDGE_BUDGET);
}

fn uint posed_root_low(Fixture* fixture, PosedHarness* harness, Node* mesh) @private {
    PosedTraceTable* table = &fixture.renderer.posed_trace;
    foreach (&slot : table.slots) {
        if (slot.key.scene == harness.scene.identity && c3d::same_id(slot.key.node, mesh.id)) {
            return (uint)(ulong)slot.root;
        }
    }
    unreachable("the mesh holds no posed slot");
}

fn void test_posed_meshes_trace_at_the_raster_pose() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        print_adapter(&fixture);
        TraceKind kind = ray_queries ? TraceKind.HARDWARE : TraceKind.SOFTWARE;
        GeometryId skinned = posed_box(&fixture, true)!!;
        GeometryId morphed = posed_box(&fixture, false, { 0, 0.5f, 0 })!!;
        GeometryId[3] shapes = { skinned, morphed, fixture.deformed_box };
        ZString[3] names = { "skinned", "morphed", "combined" };
        foreach (index, shape : shapes) {
            PosedHarness harness;
            posed_create_harness(&fixture, &harness)!!;
            defer posed_destroy_harness(&fixture, &harness);
            PosedRig rig = posed_add_rig(&fixture, &harness, shape)!!;
            for (uint frame = 0; frame < POSED_FRAMES; frame++) {
                posed_set_frame(&harness, &rig, frame);
                posed_render(&fixture, &harness, kind)!!;
                assert_posed_agreement(harness.results, names[index]);
                assert(fixture.renderer.stats.trace_posed_instances == 1 && fixture.renderer.stats.trace_poses == 1);
                uint low = posed_root_low(&fixture, &harness, rig.mesh);
                foreach (&result : harness.results) {
                    if (result.flags & POSED_TRACE_HIT) assert(result.geometry_low == low);
                }
            }
        }
        check_validation(&fixture.renderer);
    }
}

fn void test_posed_instances_sharing_a_geometry_stay_independent() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    GeometryId skinned = posed_box(&fixture, true)!!;
    PosedRig left = posed_add_rig(&fixture, &harness, skinned)!!;
    PosedRig right = posed_add_rig(&fixture, &harness, skinned)!!;
    left.joint.local.position = { -0.8f, 0, 0 };
    right.joint.local.position = { 0.8f, 0.3f, 0 };
    right.joint.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(30.0f));
    Node* still = harness.scene.add_mesh(fixture.box, fixture.plain, name: "still")!!;
    still.local.position = { 0, -1.2f, 0 };
    still.local.scale = { 3, 0.2f, 1 };
    harness.scene.update_world();

    posed_render(&fixture, &harness, TraceKind.SOFTWARE)!!;
    assert_posed_agreement(harness.results, "independent");
    uint left_low = posed_root_low(&fixture, &harness, left.mesh);
    uint right_low = posed_root_low(&fixture, &harness, right.mesh);
    uint still_low = (uint)(ulong)fixture.renderer.geometries[fixture.box.index].root;
    assert(left_low != right_low);
    usz[3] hits;
    foreach (&result : harness.results) {
        if (!(result.flags & POSED_TRACE_HIT)) continue;
        if (result.geometry_low == left_low) hits[0]++;
        if (result.geometry_low == right_low) hits[1]++;
        if (result.geometry_low == still_low) hits[2]++;
    }
    assert(hits[0] > 0 && hits[1] > 0 && hits[2] > 0);
    assert(fixture.renderer.stats.trace_posed_instances == 2 && fixture.renderer.stats.trace_poses == 2);
    check_validation(&fixture.renderer);
}

fn void? posed_trace_frame(Fixture* fixture, Scene* scene, TraceKind kind = TraceKind.SOFTWARE) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.prepare_scene_trace(scene, kind)!;
    return renderer.end_frame();
}

fn void test_still_pose_keeps_the_trace_revision() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    PosedRig rig = posed_add_rig(&fixture, &harness, posed_box(&fixture, true)!!)!!;
    posed_set_frame(&harness, &rig, 1);
    Renderer* renderer = &fixture.renderer;

    posed_trace_frame(&fixture, &harness.scene)!!;
    assert(renderer.stats.trace_poses == 1 && renderer.stats.trace_refits == 1);
    ulong revision = renderer.scene_trace.revision;
    for (uint frame = 0; frame < POSED_FRAMES; frame++) {
        posed_trace_frame(&fixture, &harness.scene)!!;
        assert(renderer.stats.trace_poses == 0 && renderer.stats.trace_refits == 0);
        assert(renderer.scene_trace.revision == revision);
    }

    posed_set_frame(&harness, &rig, 2);
    posed_trace_frame(&fixture, &harness.scene)!!;
    assert(renderer.stats.trace_poses == 1 && renderer.scene_trace.revision == revision + 1);

    posed_set_frame(&harness, &rig, 3);
    renderer.begin_frame()!!;
    renderer.prepare_scene_trace(&harness.scene, TraceKind.SOFTWARE)!!;
    render::abort_frame(renderer);
    posed_trace_frame(&fixture, &harness.scene)!!;
    assert(renderer.stats.trace_poses == 1 && renderer.scene_trace.revision == revision + 3);
    posed_trace_frame(&fixture, &harness.scene)!!;
    assert(renderer.stats.trace_poses == 0 && renderer.scene_trace.revision == revision + 3);
    check_validation(renderer);
}

fn void test_untraced_frames_record_no_posed_work() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    PosedRig rig = posed_add_rig(&fixture, &harness, fixture.deformed_box)!!;
    Renderer* renderer = &fixture.renderer;
    for (uint frame = 0; frame < POSED_FRAMES; frame++) {
        posed_set_frame(&harness, &rig, frame);
        renderer.begin_frame()!!;
        renderer.render_view(&harness.scene, harness.camera, fixture.view)!!;
        renderer.finish_view(fixture.view)!!;
        renderer.end_frame()!!;
        assert(renderer.stats.trace_poses == 0 && renderer.stats.trace_posed_bytes == 0);
    }
    assert(renderer.posed_trace.slots.len == 0 && renderer.posed_trace.bytes == 0);
    check_validation(renderer);
}

fn void test_posed_capacity_leaves_later_meshes_out() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, max_posed_trace_instances: 1)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    GeometryId skinned = posed_box(&fixture, true)!!;
    PosedRig first = posed_add_rig(&fixture, &harness, skinned)!!;
    PosedRig second = posed_add_rig(&fixture, &harness, skinned)!!;
    first.joint.local.position = { -0.8f, 0, 0 };
    second.joint.local.position = { 0.8f, 0, 0 };
    harness.scene.update_world();
    Renderer* renderer = &fixture.renderer;

    for (uint frame = 0; frame < 2; frame++) {
        posed_trace_frame(&fixture, &harness.scene)!!;
        assert(renderer.stats.trace_posed_instances == 1 && renderer.stats.trace_posed_overflow == 1);
        assert(renderer.scene_trace.baseline_count == 1);
        assert(c3d::same_id(renderer.scene_trace.baseline[0].entity, first.mesh.id));
    }
    harness.scene.remove(first.mesh);
    posed_trace_frame(&fixture, &harness.scene)!!;
    assert(renderer.stats.trace_posed_instances == 1 && renderer.stats.trace_posed_overflow == 0);
    assert(c3d::same_id(renderer.scene_trace.baseline[0].entity, second.mesh.id));
    check_validation(renderer);
}

fn void test_morphed_mesh_outside_its_rest_box_is_hit() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        PosedHarness harness;
        posed_create_harness(&fixture, &harness)!!;
        defer posed_destroy_harness(&fixture, &harness);
        PosedRig rig = posed_add_rig(&fixture, &harness, posed_box(&fixture, false, { 3, 0, 0 })!!)!!;
        rig.mesh.local.position = { -3, 0, 0 };
        harness.scene.get(rig.mesh, Mesh).morph_weights[0] = 1;
        harness.scene.update_world();

        posed_render(&fixture, &harness, ray_queries ? TraceKind.HARDWARE : TraceKind.SOFTWARE)!!;
        assert_posed_agreement(harness.results, "morph outside the rest box");
        check_validation(&fixture.renderer);
    }
}

fn void test_two_tracing_views_pose_once_per_frame() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        PosedHarness harness;
        posed_create_harness(&fixture, &harness)!!;
        defer posed_destroy_harness(&fixture, &harness);
        PosedRig rig = posed_add_rig(&fixture, &harness, fixture.deformed_box)!!;
        Light sun = light::directional({ 1, 1, 1 }, 3);
        sun.shadow.ray_traced = true;
        harness.scene.add_light(sun, name: "sun")!!;
        Renderer* renderer = &fixture.renderer;
        foreach (view : (ViewId[2]){ fixture.view, fixture.second_view }) {
            ViewDesc desc = renderer.views.get(view).desc;
            desc.ray_tracing.shadows = true;
            render::configure_view(renderer, view, desc)!!;
        }
        for (uint frame = 0; frame < 2; frame++) {
            posed_set_frame(&harness, &rig, frame);
            renderer.begin_frame()!!;
            foreach (view : (ViewId[2]){ fixture.view, fixture.second_view }) {
                renderer.render_view(&harness.scene, harness.camera, view)!!;
                renderer.finish_view(view)!!;
            }
            renderer.end_frame()!!;
            assert(renderer.stats.trace_poses == 1);
            assert(ray_queries ? renderer.stats.trace_refits == 0 : renderer.stats.trace_refits == 1);
            assert(ray_queries ? renderer.stats.blas_updates + renderer.stats.blas_builds >= 1 : true);
        }
        check_validation(renderer);
    }
}

fn PosedTraceRes* posed_slot_of(Fixture* fixture, PosedHarness* harness, Node* mesh) @private {
    foreach (&slot : fixture.renderer.posed_trace.slots) {
        if (slot.key.scene == harness.scene.identity && c3d::same_id(slot.key.node, mesh.id)) return slot;
    }
    unreachable("the mesh holds no posed slot");
}

fn void test_posed_bottom_level_updates_in_place() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    PosedRig rig = posed_add_rig(&fixture, &harness, fixture.deformed_box)!!;
    harness.scene.add_mesh(fixture.box, fixture.plain, name: "still")!!.local.position = { 0, -2, 0 };
    posed_set_frame(&harness, &rig, 0);
    Renderer* renderer = &fixture.renderer;

    posed_trace_frame(&fixture, &harness.scene, TraceKind.HARDWARE)!!;
    assert(renderer.stats.blas_builds == 2 && renderer.stats.blas_updates == 0 && renderer.stats.tlas_builds == 1);
    gpu::AccelerationStructureHandle blas = posed_slot_of(&fixture, &harness, rig.mesh).blas;
    posed_set_frame(&harness, &rig, 1);
    posed_trace_frame(&fixture, &harness.scene, TraceKind.HARDWARE)!!;
    assert(renderer.stats.blas_builds == 0 && renderer.stats.blas_updates == 1 && renderer.stats.tlas_builds == 1);
    assert(posed_slot_of(&fixture, &harness, rig.mesh).blas == blas);
    posed_trace_frame(&fixture, &harness.scene, TraceKind.HARDWARE)!!;
    assert(renderer.stats.blas_builds == 0 && renderer.stats.blas_updates == 0 && renderer.stats.tlas_builds == 0);

    posed_set_frame(&harness, &rig, 2);
    renderer.begin_frame()!!;
    renderer.prepare_scene_trace(&harness.scene, TraceKind.HARDWARE)!!;
    render::abort_frame(renderer);
    posed_trace_frame(&fixture, &harness.scene, TraceKind.HARDWARE)!!;
    assert(renderer.stats.blas_builds == 1 && renderer.stats.blas_updates == 0 && renderer.stats.tlas_builds == 1);
    posed_render(&fixture, &harness, TraceKind.HARDWARE)!!;
    assert_posed_agreement(harness.results, "after an aborted update");
    check_validation(renderer);
}

fn void test_posed_hardware_and_software_hits_agree() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    PosedRig combined = posed_add_rig(&fixture, &harness, fixture.deformed_box)!!;
    PosedRig morphed = posed_add_rig(&fixture, &harness, posed_box(&fixture, false, { 0, 0.4f, 0 })!!)!!;
    posed_set_frame(&harness, &combined, 3);
    harness.scene.get(morphed.mesh, Mesh).morph_weights[0] = 0.8f;
    morphed.mesh.local.position = { -1, -0.6f, -0.5f };
    harness.scene.update_world();
    PosedDepthResult[] walked = alloc::new_array(mem, PosedDepthResult, POSED_PIXELS);
    defer alloc::free(mem, walked.ptr);

    posed_render(&fixture, &harness, TraceKind.SOFTWARE)!!;
    walked[..] = harness.results[..];
    posed_render(&fixture, &harness, TraceKind.HARDWARE)!!;
    assert(fixture.renderer.stats.trace_poses == 0);
    usz edges;
    foreach (index, &walk : walked) {
        PosedDepthResult* query = &harness.results[index];
        bool walk_hit = (walk.flags & POSED_TRACE_HIT) != 0;
        bool agree = walk_hit == ((query.flags & POSED_TRACE_HIT) != 0);
        if (agree && walk_hit) {
            agree = walk.geometry_low == query.geometry_low && walk.primitive == query.primitive
                && math::abs(walk.traced - query.traced) <= TRACE_DISTANCE_TOLERANCE * math::max(1.0f, walk.traced)
                && (walk.barycentrics - query.barycentrics).length() <= PARITY_BARYCENTRIC_TOLERANCE;
        }
        if (agree) continue;
        Vec3 weights = { 1 - walk.barycentrics.x - walk.barycentrics.y, walk.barycentrics.x, walk.barycentrics.y };
        assert(min_weight(weights) < TRACE_EDGE_WEIGHT);
        edges++;
    }
    io::eprintfn("Posed parity: %d edge mismatches", edges);
    assert(edges <= POSED_PIXELS / 100);
    check_validation(&fixture.renderer);
}

fn void test_source_revision_rebuilds_the_posed_slot() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        PosedHarness harness;
        posed_create_harness(&fixture, &harness)!!;
        defer posed_destroy_harness(&fixture, &harness);
        GeometryId skinned = posed_box(&fixture, true)!!;
        PosedRig rig = posed_add_rig(&fixture, &harness, skinned)!!;
        posed_set_frame(&harness, &rig, 1);
        TraceKind kind = ray_queries ? TraceKind.HARDWARE : TraceKind.SOFTWARE;
        posed_render(&fixture, &harness, kind)!!;

        foreach (&position : fixture.assets.geometry(skinned).data.positions) *position *= 1.5f;
        fixture.assets.mark_geometry_dirty(skinned);
        posed_render(&fixture, &harness, kind)!!;
        assert_posed_agreement(harness.results, "after a revision");
        assert(fixture.renderer.stats.trace_poses == 1);
        if (ray_queries) assert(fixture.renderer.stats.blas_builds == 1 && fixture.renderer.stats.blas_updates == 0);

        if (ray_queries) {
            Renderer* renderer = &fixture.renderer;
            posed_set_frame(&harness, &rig, 2);
            renderer.begin_frame()!!;
            renderer.prepare_scene_trace(&harness.scene, TraceKind.SOFTWARE)!!;
            foreach (&position : fixture.assets.geometry(skinned).data.positions) *position *= 0.8f;
            fixture.assets.mark_geometry_dirty(skinned);
            renderer.prepare_scene_trace(&harness.scene, TraceKind.HARDWARE)!!;
            renderer.end_frame()!!;
            assert(renderer.stats.trace_poses == 2);
            posed_render(&fixture, &harness, kind)!!;
            assert_posed_agreement(harness.results, "after a revision between two preparations");
        }
        check_validation(&fixture.renderer);
    }
}

fn GeometryId? posed_sphere(Fixture* fixture) @private {
    GeometryId sphere;
    @pool() {
        Geometry shape = geometry::sphere(tmem, 0.8f);
        shape.joints = alloc::new_array(tmem, ushort[<4>], shape.positions.len);
        shape.weights = alloc::new_array(tmem, Vec4, shape.positions.len);
        foreach (&weight : shape.weights) *weight = { 1, 0, 0, 0 };
        sphere = fixture.assets.add_geometry(&shape)!;
    };
    return sphere;
}

fn void test_posed_slot_follows_a_new_geometry() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        PosedHarness harness;
        posed_create_harness(&fixture, &harness)!!;
        defer posed_destroy_harness(&fixture, &harness);
        PosedRig rig = posed_add_rig(&fixture, &harness, posed_box(&fixture, true)!!)!!;
        posed_set_frame(&harness, &rig, 1);
        TraceKind kind = ray_queries ? TraceKind.HARDWARE : TraceKind.SOFTWARE;
        posed_render(&fixture, &harness, kind)!!;
        PosedTraceRes* slot = posed_slot_of(&fixture, &harness, rig.mesh);
        gpu::AccelerationStructureHandle blas = slot.blas;
        uint nodes = slot.node_count;

        harness.scene.get(rig.mesh, Mesh).geometry = posed_sphere(&fixture)!!;
        posed_set_frame(&harness, &rig, 2);
        posed_render(&fixture, &harness, kind)!!;
        assert_posed_agreement(harness.results, "after a geometry swap");
        slot = posed_slot_of(&fixture, &harness, rig.mesh);
        if (ray_queries) {
            assert(slot.blas != blas && fixture.renderer.stats.blas_builds == 1);
        } else {
            assert(slot.node_count != nodes);
        }
        check_validation(&fixture.renderer);
    }
}

fn void test_closed_frame_trace_reads_the_current_pose() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    PosedRig rig = posed_add_rig(&fixture, &harness, posed_box(&fixture, true)!!)!!;
    posed_set_frame(&harness, &rig, 0);
    Renderer* renderer = &fixture.renderer;
    posed_render(&fixture, &harness, TraceKind.SOFTWARE)!!;
    ulong revision = renderer.scene_trace.revision;

    posed_set_frame(&harness, &rig, 2);
    uint poses = renderer.stats.trace_poses;
    renderer.prepare_scene_trace(&harness.scene, TraceKind.SOFTWARE)!!;
    assert(renderer.stats.trace_poses == poses + 1 && renderer.scene_trace.revision == revision + 1);
    renderer.prepare_scene_trace(&harness.scene, TraceKind.SOFTWARE)!!;
    renderer.prepare_scene_trace(&harness.scene, TraceKind.SOFTWARE)!!;
    assert(renderer.stats.trace_poses == poses + 1 && renderer.scene_trace.revision == revision + 1);
    posed_render(&fixture, &harness, TraceKind.SOFTWARE)!!;
    assert(renderer.stats.trace_poses == 0);
    assert_posed_agreement(harness.results, "after closed preparations");
    check_validation(renderer);
}

fn void test_absent_posed_slots_retire_and_return_fresh() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    GeometryId skinned = posed_box(&fixture, true)!!;
    PosedRig first = posed_add_rig(&fixture, &harness, skinned)!!;
    posed_set_frame(&harness, &first, 1);
    Renderer* renderer = &fixture.renderer;
    posed_trace_frame(&fixture, &harness.scene)!!;
    assert(renderer.posed_trace.bytes > 0);

    harness.scene.remove(first.mesh);
    for (uint frame = 0; frame < render::INSTANCE_ABSENCE_FRAMES + 2; frame++) {
        posed_trace_frame(&fixture, &harness.scene)!!;
    }
    assert(renderer.posed_trace.bytes == 0);
    foreach (&slot : renderer.posed_trace.slots) assert(slot.key.scene == 0);

    PosedRig second = posed_add_rig(&fixture, &harness, skinned)!!;
    posed_set_frame(&harness, &second, 2);
    posed_render(&fixture, &harness, TraceKind.SOFTWARE)!!;
    assert_posed_agreement(harness.results, "a fresh slot");
    check_validation(renderer);
}

fn void test_rest_refit_reproduces_the_rest_tree() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    GeometryId skinned;
    @pool() {
        Geometry sphere = geometry::sphere(tmem, 1);
        sphere.joints = alloc::new_array(tmem, ushort[<4>], sphere.positions.len);
        sphere.weights = alloc::new_array(tmem, Vec4, sphere.positions.len);
        foreach (&weight : sphere.weights) *weight = { 1, 0, 0, 0 };
        skinned = fixture.assets.add_geometry(&sphere)!!;
    };
    PosedRig rig = posed_add_rig(&fixture, &harness, skinned)!!;
    harness.scene.update_world();
    posed_trace_frame(&fixture, &harness.scene)!!;

    Renderer* renderer = &fixture.renderer;
    PosedTraceRes* slot = posed_slot_of(&fixture, &harness, rig.mesh);
    usz bytes = (usz)slot.node_count * shader::BvhNodeGpu::size;
    gpu::AllocationDesc readback_desc = {
        .size         = 2 * bytes,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "posed_nodes_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!!;
    defer {
        gpu::GpuAllocation allocation = readback.span.allocation();
        (void)gpu::free_allocation(&renderer.device, &allocation);
    }
    renderer.begin_frame()!!;
    gpu::GpuSpan posed_nodes = gpu::get_allocation_span(&renderer.device, slot.node_allocation)!!;
    gpu::GpuAllocation rest_allocation = renderer.geometries[skinned.index].trace.allocation;
    gpu::GpuSpan rest_nodes = gpu::get_allocation_span(&renderer.device, rest_allocation)!!;
    gpu::BufferCopyDesc[2] copies = {
        { .src = posed_nodes.checked_subspan(0, bytes)!!, .dst = readback.span.checked_subspan(0, bytes)!! },
        { .src = rest_nodes.checked_subspan(0, bytes)!!, .dst = readback.span.checked_subspan(bytes, bytes)!! },
    };
    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!!;
    foreach (&copy : copies) gpu::cmd_copy_buffer(&renderer.commands, copy)!!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!!;
    renderer.work_recorded = true;
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!!;

    shader::BvhNodeGpu[] refit = ((shader::BvhNodeGpu*)readback.bytes.ptr)[:slot.node_count];
    shader::BvhNodeGpu[] rest = ((shader::BvhNodeGpu*)(readback.bytes.ptr + bytes))[:slot.node_count];
    foreach (index, &node : refit) {
        shader::BvhNodeGpu* expected = &rest[index];
        assert(node.left_or_first == expected.left_or_first && node.count == expected.count);
        assert(node.min_x == expected.min_x && node.min_y == expected.min_y && node.min_z == expected.min_z);
        assert(node.max_x == expected.max_x && node.max_y == expected.max_y && node.max_z == expected.max_z);
    }
    check_validation(renderer);
}

fn void test_deferred_bottom_level_update_rebuilds_the_top_level() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    PosedRig rig = posed_add_rig(&fixture, &harness, posed_box(&fixture, true)!!)!!;
    posed_set_frame(&harness, &rig, 0);
    Renderer* renderer = &fixture.renderer;
    posed_trace_frame(&fixture, &harness.scene, TraceKind.HARDWARE)!!;

    posed_set_frame(&harness, &rig, 3);
    posed_trace_frame(&fixture, &harness.scene, TraceKind.SOFTWARE)!!;
    assert(renderer.stats.trace_poses == 1 && renderer.stats.blas_updates == 0);
    posed_render(&fixture, &harness, TraceKind.HARDWARE)!!;
    assert(renderer.stats.trace_poses == 0 && renderer.stats.blas_updates == 1 && renderer.stats.tlas_builds == 1);
    assert_posed_agreement(harness.results, "deferred bottom-level update");
    check_validation(renderer);
}

const Vec3 POSED_SHADOWED_AT_REST @private = { 0.9f, 0, 0 };  // in the posed box's traced shadow at joint x = 0
const Vec3 POSED_SHADOWED_MOVED @private = { -1.6f, 0, 0 };   // in its shadow at joint x = -2.5, in the camera's sight

fn void test_posed_caster_casts_traced_shadows_at_its_pose() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        ShadowScene shadow = create_shadow_scene(&fixture)!!;
        defer scene::destroy_scene(&shadow.scene);
        shadow.scene.remove(shadow.box);
        Node* joint = shadow.scene.add_node(name: "posed_joint")!!;
        Node* caster = shadow.scene.add_mesh(posed_box(&fixture, true)!!, shadow.opaque, name: "posed_caster")!!;
        Node*[] joints = alloc::new_array(shadow.scene.allocator, Node*, 1);
        joints[0] = joint;
        shadow.scene.add(caster, (SkinBinding){ .skeleton = fixture.skeleton, .joints = joints });
        set_ray_traced_shadows(&fixture, true)!!;

        joint.local.position = { 0, 0.5f, 0 };
        shadow.scene.update_world();
        assert(shade(render_and_sample(&fixture, &shadow, POSED_SHADOWED_AT_REST)!!) == 0);
        assert(shade(render_and_sample(&fixture, &shadow, POSED_SHADOWED_MOVED)!!) > 0);
        joint.local.position = { -2.5f, 0.5f, 0 };
        shadow.scene.update_world();
        assert(shade(render_and_sample(&fixture, &shadow, POSED_SHADOWED_AT_REST)!!) > 0);
        assert(shade(render_and_sample(&fixture, &shadow, POSED_SHADOWED_MOVED)!!) == 0);
        check_validation(&fixture.renderer);
    }
}

fn void test_path_tracer_accumulates_on_a_still_pose() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);
    PathScene room = create_lit_room(&fixture)!!;
    defer scene::destroy_scene(&room.scene);
    Node* joint = room.scene.add_node(name: "posed_joint")!!;
    MaterialId material = room.scene.get(room.subject, Mesh).material;
    Node* posed = room.scene.add_mesh(fixture.deformed_box, material, name: "posed")!!;
    Node*[] joints = alloc::new_array(room.scene.allocator, Node*, 1);
    joints[0] = joint;
    room.scene.add(posed, (SkinBinding){ .skeleton = fixture.skeleton, .joints = joints });
    Mesh* mesh = room.scene.get(posed, Mesh);
    mesh.morph_weights = alloc::new_array(room.scene.allocator, float, 1);
    mesh.morph_weights[0] = 0.5f;
    joint.local.position = { 0.8f, 0.5f, -2 };
    room.scene.update_world();

    RenderTargetId target = float_target(&fixture)!!;
    ViewId view = create_path_view(&fixture, target, { .max_bounces = 2, .samples_per_frame = 2 })!!;
    PathRun run = { .fixture = &fixture, .path_scene = &room, .view = view };
    expect_accumulation(&run, 2, 2)!!;
    expect_accumulation(&run, 4, 2)!!;
    expect_accumulation(&run, 6, 2)!!;
    joint.local.position.y += 0.1f;
    room.scene.update_world();
    expect_accumulation(&run, 2, 2)!!;
    mesh.morph_weights[0] = 0.75f;
    expect_accumulation(&run, 2, 2)!!;
    expect_accumulation(&run, 4, 2)!!;
    assert(fixture.renderer.stats.trace_posed_instances == 1);
    check_validation(&fixture.renderer);
}

fn void test_strong_pose_refit_encloses_every_posed_triangle() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    GeometryId skinned;
    uint[] indices;
    @pool() {
        Geometry sphere = geometry::sphere(tmem, 1);
        sphere.joints = alloc::new_array(tmem, ushort[<4>], sphere.positions.len);
        sphere.weights = alloc::new_array(tmem, Vec4, sphere.positions.len);
        foreach (&weight : sphere.weights) *weight = { 1, 0, 0, 0 };
        skinned = fixture.assets.add_geometry(&sphere)!!;
        indices = alloc::new_array(mem, uint, sphere.indices.len);
        indices[..] = sphere.indices[..];
    };
    defer alloc::free(mem, indices.ptr);
    PosedRig rig = posed_add_rig(&fixture, &harness, skinned)!!;
    rig.joint.local.position = { 0.4f, 1, 0 };
    rig.joint.local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
    rig.joint.local.scale = { 2, 0.5f, 1 };
    harness.scene.update_world();
    posed_trace_frame(&fixture, &harness.scene)!!;

    Renderer* renderer = &fixture.renderer;
    PosedTraceRes* slot = posed_slot_of(&fixture, &harness, rig.mesh);
    GpuGeometry* mirror = &renderer.geometries[skinned.index];
    usz node_bytes = (usz)slot.node_count * shader::BvhNodeGpu::size;
    usz position_bytes = slot.positions.size;
    usz primitive_bytes = (usz)indices.len / 3 * uint::size;
    gpu::AllocationDesc readback_desc = {
        .size         = node_bytes + position_bytes + primitive_bytes,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "posed_refit_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!!;
    defer {
        gpu::GpuAllocation allocation = readback.span.allocation();
        (void)gpu::free_allocation(&renderer.device, &allocation);
    }
    renderer.begin_frame()!!;
    gpu::GpuSpan nodes = gpu::get_allocation_span(&renderer.device, slot.node_allocation)!!;
    gpu::GpuSpan trace = gpu::get_allocation_span(&renderer.device, mirror.trace.allocation)!!;
    usz primitives_offset = (usz)(mirror.trace.primitives - mirror.trace.nodes);
    gpu::BufferCopyDesc[3] copies = {
        { .src = nodes.checked_subspan(0, node_bytes)!!, .dst = readback.span.checked_subspan(0, node_bytes)!! },
        { .src = slot.positions, .dst = readback.span.checked_subspan(node_bytes, position_bytes)!! },
        {
            .src = trace.checked_subspan(primitives_offset, primitive_bytes)!!,
            .dst = readback.span.checked_subspan(node_bytes + position_bytes, primitive_bytes)!!,
        },
    };
    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!!;
    foreach (&copy : copies) gpu::cmd_copy_buffer(&renderer.commands, copy)!!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!!;
    renderer.work_recorded = true;
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!!;

    shader::BvhNodeGpu[] tree = ((shader::BvhNodeGpu*)readback.bytes.ptr)[:slot.node_count];
    Vec3[] positions = ((Vec3*)(readback.bytes.ptr + node_bytes))[:mirror.layout.vertex_count];
    uint[] primitives = ((uint*)(readback.bytes.ptr + node_bytes + position_bytes))[:indices.len / 3];
    foreach (&node : tree) {
        Aabb box = { .min = { node.min_x, node.min_y, node.min_z }, .max = { node.max_x, node.max_y, node.max_z } };
        if (node.count == 0) {
            foreach (child : (uint[2]){ node.left_or_first, node.left_or_first + 1 }) {
                shader::BvhNodeGpu* inner = &tree[child];
                assert(box.min.x <= inner.min_x && box.min.y <= inner.min_y && box.min.z <= inner.min_z);
                assert(box.max.x >= inner.max_x && box.max.y >= inner.max_y && box.max.z >= inner.max_z);
            }
            continue;
        }
        foreach (primitive : primitives[node.left_or_first:node.count]) {
            for (usz corner = 0; corner < 3; corner++) {
                Vec3 point = positions[indices[(usz)primitive * 3 + corner]];
                assert(point.x >= box.min.x && point.y >= box.min.y && point.z >= box.min.z);
                assert(point.x <= box.max.x && point.y <= box.max.y && point.z <= box.max.z);
            }
        }
    }
    assert(tree[0].max_y - tree[0].min_y > 3.9f && tree[0].max_x - tree[0].min_x < 1.1f);
    check_validation(renderer);
}

const Vec3 POSED_BONE_OFFSET @private = { 0, 1, 0 };
const Vec3 POSED_CROWD_CAMERA @private = { 0, 0.65f, 2.6f };

fn Geometry posed_crowd_part(Allocator allocator, ushort joint, Vec3 offset) @private {
    Geometry box = geometry::box(allocator, 0.6f, 0.6f, 0.6f);
    box.joints = alloc::new_array(allocator, ushort[<4>], box.positions.len);
    box.weights = alloc::new_array(allocator, Vec4, box.positions.len);
    foreach (index, &position : box.positions) {
        *position += offset;
        box.joints[index] = { joint, 0, 0, 0 };
        box.weights[index] = { 1, 0, 0, 0 };
    }
    box.bounds = { .min = box.bounds.min + offset, .max = box.bounds.max + offset };
    return box;
}

fn NodeTemplate posed_template_node(String name, int parent, Vec3 position) @private {
    return {
        .parent  = parent,
        .name    = name.copy(mem),
        .local   = { .position = position, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
        .layers  = scene::DEFAULT_LAYERS,
        .visible = true,
    };
}

fn ModelId? posed_crowd_model(Fixture* fixture, MaterialId material, ClipId* swing) @private {
    AssetStore* assets = &fixture.assets;
    GeometryId[2] parts;
    @pool() {
        Geometry lower = posed_crowd_part(tmem, 0, {});
        parts[0] = assets.add_geometry(&lower)!;
        Geometry upper = posed_crowd_part(tmem, 1, { 0, 1.3f, 0 });
        parts[1] = assets.add_geometry(&upper)!;
    };
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(mem, String, 2),
        .parents      = alloc::new_array(mem, int, 2),
        .rest_pose    = alloc::new_array(mem, Transform, 2),
        .inverse_bind = alloc::new_array(mem, Mat4, 2),
    };
    skeleton.parents[0] = -1;
    skeleton.parents[1] = 0;
    skeleton.rest_pose[..] = maths::TRANSFORM_IDENTITY;
    skeleton.inverse_bind[0] = matrix::IDENTITY4;
    skeleton.inverse_bind[1] = matrix::IDENTITY4.translate(-POSED_BONE_OFFSET);
    SkeletonId skeleton_id = assets.add_skeleton_owned(&skeleton)!;

    Quat bent = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
    AnimationClip clip = {
        .name     = "swing".copy(mem),
        .duration = 1,
        .tracks   = alloc::new_array(mem, Track, 1),
        .targets  = alloc::new_array(mem, uint, 1),
    };
    clip.targets[0] = 2;
    clip.tracks[0] = {
        .target        = 0,
        .path          = TargetPath.ROTATION,
        .interpolation = Interpolation.LINEAR,
        .times         = alloc::new_array(mem, float, 2),
        .values        = alloc::new_array(mem, float, 8),
    };
    float[2] times = { 0, 1 };
    float[8] values = { 0, 0, 0, 1, bent.i, bent.j, bent.k, bent.l };
    clip.tracks[0].times[..] = times[..];
    clip.tracks[0].values[..] = values[..];
    *swing = assets.add_clip_owned(&clip)!;

    ModelTemplate template = {
        .nodes  = alloc::new_array(mem, NodeTemplate, 5),
        .meshes = alloc::new_array(mem, ModelMesh, 2),
        .skins  = alloc::new_array(mem, ModelSkin, 2),
        .clips  = alloc::new_array(mem, ClipId, 1),
    };
    template.nodes[0] = posed_template_node("root", -1, {});
    template.nodes[1] = posed_template_node("bone0", 0, {});
    template.nodes[2] = posed_template_node("bone1", 1, POSED_BONE_OFFSET);
    template.nodes[3] = posed_template_node("lower", 0, {});
    template.nodes[4] = posed_template_node("upper", 1, {});
    foreach (index, &skin : template.skins) {
        template.meshes[index] = { .node = (uint)index + 3, .geometry = parts[index], .material = material };
        skin.mesh_node = (uint)index + 3;
        skin.skeleton = skeleton_id;
        skin.joint_nodes = alloc::new_array(mem, uint, 2);
        skin.joint_nodes[0] = 1;
        skin.joint_nodes[1] = 2;
    }
    template.clips[0] = *swing;
    return assets.add_model_owned(&template);
}

fn void test_traced_crowd_instances_match_raster() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        PosedHarness harness;
        posed_create_harness(&fixture, &harness)!!;
        defer posed_destroy_harness(&fixture, &harness);
        harness.camera.local.position = POSED_CROWD_CAMERA;
        ClipId swing;
        ModelId model = posed_crowd_model(&fixture, fixture.plain, &swing)!!;
        Transform mirrored = maths::TRANSFORM_IDENTITY;
        mirrored.position = { 0.6f, 0, 0 };
        mirrored.scale = { -1, 1, 1 };
        Transform plain = maths::TRANSFORM_IDENTITY;
        plain.position = { -0.6f, 0, 0 };
        CrowdInstance[2] instances = {
            { .placement = mirrored, .pose = { .clip = swing, .time = 0.5f, .speed = 1 }, .color = { 1, 1, 1, 1 } },
            { .placement = plain, .pose = { .clip = swing, .time = 0.25f, .speed = 1 }, .color = { 1, 1, 1, 1 } },
        };
        model::add_crowd(
            assets:      &fixture.assets,
            scene:       &harness.scene,
            model:       model,
            capacity:    2,
            pose_bounds: { .min = { -1, -1, -1 }, .max = { 1, 2.5f, 1 } },
            instances:   instances[..],
            trace:       true,
        )!!;
        anim::crowd_update(&fixture.assets, &harness.scene, 0);
        harness.scene.update_world();

        posed_render(&fixture, &harness, ray_queries ? TraceKind.HARDWARE : TraceKind.SOFTWARE)!!;
        assert_posed_agreement(harness.results, "crowd");
        assert(fixture.renderer.stats.trace_posed_instances == 4 && fixture.renderer.stats.trace_poses == 4);
        check_validation(&fixture.renderer);
    }
}

fn void test_traced_crowd_pose_outside_its_rest_geometry_is_hit() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    harness.camera.local.position = POSED_CROWD_CAMERA;
    ClipId swing;
    ModelId model = posed_crowd_model(&fixture, fixture.plain, &swing)!!;
    CrowdInstance[1] instances = {{
        .placement = maths::TRANSFORM_IDENTITY,
        .pose      = { .clip = swing, .time = 1, .speed = 0 },
        .color     = { 1, 1, 1, 1 },
    }};
    model::add_crowd(
        assets:      &fixture.assets,
        scene:       &harness.scene,
        model:       model,
        capacity:    1,
        pose_bounds: { .min = { -1.5f, -1, -1 }, .max = { 1, 2.5f, 1 } },
        instances:   instances[..],
        trace:       true,
    )!!;
    anim::crowd_update(&fixture.assets, &harness.scene, 0);
    harness.scene.update_world();

    posed_render(&fixture, &harness, TraceKind.SOFTWARE)!!;
    assert_posed_agreement(harness.results, "crowd outside its rest geometry");
    usz beside;
    foreach (index, &result : harness.results) {
        uint column = (uint)index % TARGET_SIZE;
        if ((result.flags & POSED_TRACE_HIT) && column < TARGET_SIZE / 3) beside++;
    }
    assert(beside > 0);
    check_validation(&fixture.renderer);
}

const Vec3 POSED_OCCLUDER_NEAR @private = { 0, 0.5f, -1 };       // cube resting on the floor, its front face at z = -0.5
const Vec3 POSED_OCCLUDER_AWAY @private = { 3, 0.5f, -1 };       // the same cube 3 m to the side
const Vec3 POSED_CREASE_POINT @private = { 0, 0, -0.45f };       // on the floor 5 cm from the cube's front face

fn Node* posed_attach_joint(Fixture* fixture, Scene* scene, GeometryId geometry, MaterialId material) @private {
    Node* joint = scene.add_node(name: "posed_joint")!!;
    Node* mesh = scene.add_mesh(geometry, material, name: "posed_mesh")!!;
    Node*[] joints = alloc::new_array(scene.allocator, Node*, 1);
    joints[0] = joint;
    scene.add(mesh, (SkinBinding){ .skeleton = fixture.skeleton, .joints = joints });
    return joint;
}

fn void test_posed_occluder_darkens_ray_traced_ao() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        print_adapter(&fixture);
        CreaseScene crease = create_crease_scene(&fixture)!!;
        defer scene::destroy_scene(&crease.scene);
        MaterialId surface = crease.scene.get(crease.floor, Mesh).material;
        Node* joint = posed_attach_joint(&fixture, &crease.scene, posed_box(&fixture, true)!!, surface);
        AoView ao_view = create_ao_view(&fixture, ShadingPath.FORWARD)!!;
        defer destroy_ao_view(&fixture, &ao_view);
        crease.view = ao_view.view;
        AmbientOcclusionDesc ray_traced = render::AMBIENT_OCCLUSION_DEFAULT;
        ray_traced.kind = AoKind.RAY_TRACED;

        joint.local.position = POSED_OCCLUDER_NEAR;
        crease.scene.update_world();
        int floor_none = red(render_and_read(&fixture, &crease, POSED_CREASE_POINT)!!);
        set_ambient_occlusion(&fixture, ao_view.view, ray_traced)!!;
        int near_ao = red(render_and_read(&fixture, &crease, POSED_CREASE_POINT)!!);
        assert(fixture.renderer.stats.trace_posed_instances == 1);
        joint.local.position = POSED_OCCLUDER_AWAY;
        crease.scene.update_world();
        int away_ao = red(render_and_read(&fixture, &crease, POSED_CREASE_POINT)!!);
        io::eprintfn(
            "%s, posed occluder: floor %d, occluded %d, away %d",
            trace_name(ray_queries),
            floor_none,
            near_ao,
            away_ao,
        );

        assert((float)near_ao < CREASE_RATIO_MAXIMUM * (float)floor_none);
        assert(math::abs(away_ao - floor_none) <= UNOCCLUDED_TOLERANCE);
        check_validation(&fixture.renderer);
    }
}

fn void test_posed_emitter_shows_in_reflections() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        print_adapter(&fixture);
        MirrorScene mirror = create_mirror_scene(&fixture, false)!!;
        defer scene::destroy_scene(&mirror.scene);
        mirror.emitter.visible = false;
        MaterialId glow = fixture.assets.add_material(material::standard(mirror.glow))!!;
        Node* joint = posed_attach_joint(&fixture, &mirror.scene, posed_box(&fixture, true)!!, glow);
        AoView mirror_view = create_ao_view(&fixture, ShadingPath.DEFERRED)!!;
        defer destroy_ao_view(&fixture, &mirror_view);
        set_reflections(&fixture, mirror_view.view, true)!!;

        joint.local.position = EMITTER_POSITION;
        mirror.scene.update_world();
        uint held = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        assert(fixture.renderer.stats.trace_posed_instances == 1);
        joint.local.position = EMITTER_POSITION + (Vec3){ 3, 0, 0 };
        mirror.scene.update_world();
        uint moved = render_mirror(&fixture, &mirror, mirror_view.view, EMITTER_IMAGE_POINT)!!;
        io::eprintfn("%s, posed emitter image: held %06x, moved %06x", trace_name(ray_queries), held, moved);

        assert(red(held) > EMITTER_MINIMUM && green(held) < DARK_MAXIMUM);
        assert(red(moved) < DARK_MAXIMUM);
        check_validation(&fixture.renderer);
    }
}

fn void test_probe_update_sees_a_posed_wall() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        print_adapter(&fixture);
        ProbeRoom room = create_probe_room(&fixture)!!;
        defer scene::destroy_scene(&room.scene);
        room.roof.visible = false;
        MaterialId surface = room.scene.get(room.roof, Mesh).material;
        Node* joint = posed_attach_joint(&fixture, &room.scene, posed_box(&fixture, true)!!, surface);
        joint.local.position = room.roof.local.position;
        joint.local.scale = room.roof.local.scale;
        room.scene.update_world();
        ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
        defer destroy_probe_view(&fixture, &probe_view);

        render_room_frames(&fixture, &room, probe_view.view, OPEN_ROOM_UPDATES)!!;
        float closed = interior_irradiance(&fixture, &room);
        assert(fixture.renderer.posed_trace.bytes > 0);
        joint.local.position.y += 10;
        room.scene.update_world();
        render_room_frames(&fixture, &room, probe_view.view, OPEN_ROOM_UPDATES)!!;
        float open = interior_irradiance(&fixture, &room);
        io::eprintfn("%s: posed roof closed %f, posed away %f", trace_name(ray_queries), closed, open);

        assert(open > LIT_IRRADIANCE);
        assert(closed < DARK_SHARE * open);
        check_validation(&fixture.renderer);
    }
}
