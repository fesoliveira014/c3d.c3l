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
const usz POSED_POSITION_BYTES @private = 12; // a packed vec3 position
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

fn void posed_assert_agreement(PosedDepthResult[] results, ZString name) @private {
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

fn void test_posed_meshes_trace_at_the_raster_pose() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    TraceKind kind = TraceKind.SOFTWARE;
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
            posed_assert_agreement(harness.results, names[index]);
            assert(fixture.renderer.stats.trace_posed_instances == 1 && fixture.renderer.stats.trace_poses == 1);
            uint low = posed_root_low(&fixture, &harness, rig.mesh);
            foreach (&result : harness.results) {
                if (result.flags & POSED_TRACE_HIT) assert(result.geometry_low == low);
            }
        }
    }
    check_validation(&fixture.renderer);
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
    posed_assert_agreement(harness.results, "independent");
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

fn void test_morphed_mesh_outside_its_rest_box_is_hit() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    PosedRig rig = posed_add_rig(&fixture, &harness, posed_box(&fixture, false, { 3, 0, 0 })!!)!!;
    rig.mesh.local.position = { -3, 0, 0 };
    harness.scene.get(rig.mesh, Mesh).morph_weights[0] = 1;
    harness.scene.update_world();

    posed_render(&fixture, &harness, TraceKind.SOFTWARE)!!;
    posed_assert_agreement(harness.results, "morph outside the rest box");
    check_validation(&fixture.renderer);
}

fn PosedTraceRes* posed_slot_of(Fixture* fixture, PosedHarness* harness, Node* mesh) @private {
    foreach (&slot : fixture.renderer.posed_trace.slots) {
        if (slot.key.scene == harness.scene.identity && c3d::same_id(slot.key.node, mesh.id)) return slot;
    }
    unreachable("expected a posed slot for the mesh");
}

fn uint posed_root_low(Fixture* fixture, PosedHarness* harness, Node* mesh) @private {
    return (uint)(ulong)posed_slot_of(fixture, harness, mesh).root;
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
    posed_assert_agreement(harness.results, "after closed preparations");
    check_validation(renderer);
}

fn void posed_double_vertices_without_normals(Fixture* fixture, GeometryId geometry) @private {
    @pool() {
        Geometry shape = geometry::box(tmem, 1, 1, 1);
        sz doubled = (sz)shape.positions.len * 2;
        Allocator allocator = fixture.assets.allocator;
        GeometryAsset* record = fixture.assets.geometry(geometry);
        fixture.assets.release_geometry_cpu(geometry);
        record.data.positions = alloc::new_array(allocator, Vec3, doubled);
        record.data.joints = alloc::new_array(allocator, ushort[<4>], doubled);
        record.data.weights = alloc::new_array(allocator, Vec4, doubled);
        foreach (index, &position : record.data.positions) *position = shape.positions[index % shape.positions.len];
        foreach (&weight : record.data.weights) *weight = { 1, 0, 0, 0 };
        record.data.indices = alloc::new_array(allocator, uint, shape.indices.len);
        record.data.indices[..] = shape.indices[..];
        record.vertex_count = (uint)doubled;
    };
    fixture.assets.mark_geometry_dirty(geometry);
}

fn void test_posed_stream_reuse_follows_a_new_vertex_count() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PosedHarness harness;
    posed_create_harness(&fixture, &harness)!!;
    defer posed_destroy_harness(&fixture, &harness);
    GeometryId geometry = posed_box(&fixture, true)!!;
    PosedRig rig = posed_add_rig(&fixture, &harness, geometry)!!;
    posed_set_frame(&harness, &rig, 1);
    posed_trace_frame(&fixture, &harness.scene)!!;
    PosedTraceRes* slot = posed_slot_of(&fixture, &harness, rig.mesh);
    gpu::GpuAllocation allocation = slot.allocation;
    usz stream_bytes = slot.stream_bytes;
    usz vertex_count = fixture.assets.geometry(geometry).data.positions.len;
    assert(slot.positions.size == POSED_POSITION_BYTES * vertex_count);

    posed_double_vertices_without_normals(&fixture, geometry);
    posed_trace_frame(&fixture, &harness.scene)!!;
    assert(slot.stream_bytes == stream_bytes && mem::equals(&slot.allocation, &allocation, gpu::GpuAllocation::size));
    assert(slot.positions.size == POSED_POSITION_BYTES * 2 * vertex_count);
    check_validation(&fixture.renderer);
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
