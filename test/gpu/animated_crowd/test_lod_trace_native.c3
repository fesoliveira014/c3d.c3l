module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::test::animated_crowd_fixtures;
import c3d::test::animated_lod_fixtures;
import gpu;
import std::io;
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
    gpu::MappedGpuSpan readback;
    LodTraceDepthResult[] results;
}

fn bool create_lod_trace_fixture(Fixture* fixture, TraceKind kind, uint capacity = 0) @private {
    if (catch excuse = create_fixture(
        allocator: mem,
        fixture: fixture,
        ray_queries: kind == TraceKind.HARDWARE,
        max_posed_trace_instances: capacity,
    )) {
        if (kind == TraceKind.HARDWARE && excuse == gpu::UNSUPPORTED_FEATURE) {
            io::eprintfn("UNRUN animated LOD hardware trace: Vulkan ray queries are unsupported");
            return false;
        }
        io::eprintfn("Animated LOD trace fixture initialization fault: %s", excuse);
        unreachable("Animated LOD trace fixture initialization failed");
    }
    print_adapter(fixture);
    if (kind == TraceKind.HARDWARE) assert(fixture.renderer.caps.ray_queries.enabled);
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
    harness.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &desc)!;
    harness.results = alloc::new_array(fixture.allocator, LodTraceDepthResult, (sz)LOD_TRACE_PIXELS);
}

fn void destroy_lod_trace_harness(Fixture* fixture, LodTraceHarness* harness) @private {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = harness.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    alloc::free(fixture.allocator, harness.results.ptr);
    scene::destroy_scene(&harness.scene);
    *harness = {};
}

fn AnimatedLodDesc lod_trace_desc(AssetStore* assets, ModelId model_id) @private {
    ModelTemplate* template = &assets.model(model_id).data;
    uint count = (uint)template.meshes.len;
    LodLevel[] levels = alloc::new_array(tmem, LodLevel, 2);
    levels[0] = { .first_part = 0, .part_count = count, .min_screen_size = 0.2f };
    levels[1] = { .first_part = count, .part_count = count, .min_screen_size = 0 };
    AnimatedLodPart[] parts = alloc::new_array(tmem, AnimatedLodPart, (sz)count * 2);
    for (uint level = 0; level < 2; level++) {
        foreach (uint index, mesh : template.meshes) {
            ModelSkin skin;
            foreach (candidate : template.skins) {
                if (candidate.mesh_node == mesh.node) skin = candidate;
            }
            parts[level * count + index] = {
                .draw = { .geometry = mesh.geometry, .material = mesh.material, .local = matrix::IDENTITY4 },
                .mesh_index = index,
                .skin = skin,
                .default_morph_weights = mesh.default_morph_weights,
            };
        }
    }
    return { .levels = levels, .parts = parts };
}

fn void? record_lod_trace_probe(
    Fixture* fixture,
    LodTraceHarness* harness,
    ViewId view,
    TraceKind kind,
    gpu::MappedGpuSpan readback = {},
) @private {
    Renderer* renderer = &fixture.renderer;
    Camera* camera = harness.scene.get(harness.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, harness.camera.world, { TARGET_SIZE, TARGET_SIZE });
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
        .dst = readback.bytes.len ? readback.span : harness.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
}

fn void? render_lod_trace(Fixture* fixture, LodTraceHarness* harness, TraceKind kind) @private {
    Renderer* renderer = &fixture.renderer;
    harness.scene.update_world();
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&harness.scene, harness.camera, fixture.view)!;
    record_lod_trace_probe(
        fixture: fixture,
        harness: harness,
        view: fixture.view,
        kind: kind,
    )!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, harness.readback.span)!;
    mem::copy(harness.results.ptr, harness.readback.bytes.ptr, LOD_TRACE_PIXELS * LodTraceDepthResult::size);
}

fn void assert_lod_trace_agreement(LodTraceDepthResult[] results, ZString name, bool flat = true) @private {
    usz covered;
    usz mismatched;
    usz normals_off;
    float worst;
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
        } else {
            covered++;
            float error = math::abs(result.traced - result.raster) / result.raster;
            worst = math::max(worst, error);
            if (!(error <= LOD_TRACE_DEPTH_TOLERANCE)) mismatched++;
        }
    }
    io::eprintfn(
        "%s: covered=%s mismatched=%s worst_relative_depth=%s normals_off=%s",
        name,
        covered,
        mismatched,
        worst,
        normals_off,
    );
    assert(covered >= LOD_TRACE_COVERAGE_MINIMUM && mismatched <= LOD_TRACE_EDGE_BUDGET);
    if (flat) assert(normals_off == 0);
}

fn void assert_lod_trace_parts(Fixture* fixture, LodTraceHarness* harness, Node* owner) @private {
    Renderer* renderer = &fixture.renderer;
    assert(renderer.scene_trace.baseline_count == animated_crowd_fixtures::PARTS_MESH_COUNT);
    assert(renderer.stats.trace_posed_instances == 4 && renderer.stats.trace_posed_overflow == 0);
    LodGroupState* state = harness.scene.get(owner, LodGroup).state;
    uint[5] seen;
    gpu::GpuAddress[4] roots;
    uint posed;
    foreach (&record : renderer.scene_trace.baseline[:renderer.scene_trace.baseline_count]) {
        assert(c3d::same_id(record.entity, owner.id) && record.lod_identity == state.identity);
        assert(record.part_index < 5 && record.instance_index == 0);
        seen[record.part_index]++;
        if (record.part_index != 1) {
            assert(record.pose_serial > 0);
            foreach (root : roots[:posed]) assert(root != record.geometry_root);
            roots[posed++] = record.geometry_root;
        } else {
            assert(record.pose_serial == 0);
        }
    }
    foreach (count : seen) assert(count == 1);
    assert(posed == 4);
    uint live;
    foreach (&slot : renderer.posed_trace.slots) {
        if (slot.key.scene != harness.scene.identity || !c3d::same_id(slot.key.node, owner.id)) continue;
        assert(slot.key.lod_identity == state.identity && slot.key.source_identity == state.instance_epoch);
        assert(slot.key.slot_generation == 1 && slot.key.logical_part != 1);
        live++;
    }
    assert(live == 4);
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
            desc: lod_trace_desc(&fixture.assets, parts.mixed),
        )!!;
    };
    harness.scene.get(owner, LodGroup).state.effects.trace = true;
    for (uint part = 0; part < animated_crowd_fixtures::PARTS_MESH_COUNT; part++) {
        Vec3 first = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part];
        Vec3 second = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part + 1];
        Vec3 third = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part + 2];
        harness.camera.local.position = (first + second + third) / 3 + (Vec3){ 0, 0, LOD_TRACE_CAMERA_DISTANCE };
        render_lod_trace(&fixture, &harness, kind)!!;
        assert_lod_trace_agreement(harness.results, "Animated LOD mixed base part");
        assert_lod_trace_parts(&fixture, &harness, owner);
        assert(fixture.renderer.stats.lod_objects_selected[0] == 1);
        assert(fixture.renderer.stats.trace_poses == (part == 0 ? 4u : 0u));
        check_crowd_native_validation(&fixture.renderer);
    }
}

fn void test_traced_animated_lod_native_mixed_software_matches_base_pose() @test {
    run_lod_trace_mixed(TraceKind.SOFTWARE);
}

fn void test_traced_animated_lod_native_mixed_hardware_matches_base_pose() @test {
    run_lod_trace_mixed(TraceKind.HARDWARE);
}


fn CrowdInstance[3] lod_trace_crowd_instances(ClipId clip) @private {
    CrowdInstance[3] instances;
    for (uint source = 0; source < 3; source++) {
        instances[source] = {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = clip, .time = 0.25f * (float)(source + 1), .speed = 0, .loop = false },
            .color = { 1, 1, 1, 1 },
        };
        instances[source].placement.position.x = 30 * (float)source;
    }
    instances[1].placement.scale = { -1, 1.2f, 1 };
    instances[2].placement.scale = { 1.3f, 0.9f, 1.1f };
    return instances;
}

fn Node* add_lod_trace_crowd(
    Fixture* fixture,
    LodTraceHarness* harness,
    PartsFixture* parts,
    CrowdInstance[] instances,
    GeometryId* coarse = null,
) @private {
    Node* owner = model::add_crowd(
        assets: &fixture.assets,
        scene: &harness.scene,
        model: parts.mixed,
        capacity: 3,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances,
    )!!;
    owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
    @pool() {
        AnimatedLodDesc desc = lod_trace_desc(&fixture.assets, parts.mixed);
        if (coarse) {
            *coarse = fixture.assets.add_geometry(&fixture.assets.geometry(parts.geometries[1]).data)!!;
            desc.parts[6].draw.geometry = *coarse;
        }
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &harness.scene,
            owner: owner,
            desc: desc,
        )!!;
    };
    harness.scene.update_world();
    return owner;
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
        CrowdPlayer player = crowd.playback.player(id)!!;
        Action* action = player.base_action()!!;
        action.time = phase;
    }
    anim::crowd_update(&fixture.assets, &harness.scene, 0);
    harness.scene.update_world();
}

fn void assert_lod_trace_crowd_rows(Fixture* fixture, LodTraceHarness* harness, Node* owner) @private {
    Renderer* renderer = &fixture.renderer;
    LodGroupState* state = harness.scene.get(owner, LodGroup).state;
    assert(renderer.scene_trace.baseline_count == 15);
    assert(renderer.stats.trace_posed_instances == 12 && renderer.stats.trace_posed_overflow == 0);
    uint[15] seen;
    gpu::GpuAddress[12] roots;
    uint posed;
    foreach (&record : renderer.scene_trace.baseline[:renderer.scene_trace.baseline_count]) {
        assert(c3d::same_id(record.entity, owner.id) && record.lod_identity == state.identity);
        assert(record.instance_index < 3 && record.part_index < 5);
        seen[5 * record.instance_index + record.part_index]++;
        if (record.part_index == 1) {
            assert(record.pose_serial == 0);
        } else {
            PosedTraceKey key = {
                .scene = harness.scene.identity,
                .node = owner.id,
                .instance = record.instance_index,
                .lod_identity = state.identity,
                .source_identity = state.instance_epoch,
                .slot_generation = state.slot_generations[record.instance_index],
                .logical_part = record.part_index,
            };
            uint index = renderer.posed_trace.lookup.get(key)!!;
            PosedTraceRes* slot = &renderer.posed_trace.slots[index];
            assert(slot.root == record.geometry_root && slot.pose_serial == record.pose_serial);
            assert(slot.pose_valid && !slot.pending && record.pose_serial > 0);
            foreach (root : roots[:posed]) assert(root != record.geometry_root);
            roots[posed++] = record.geometry_root;
        }
    }
    foreach (count : seen) assert(count == 1);
    assert(posed == 12);
}

fn void? lod_trace_only(Fixture* fixture, LodTraceHarness* harness, TraceKind kind) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    renderer.prepare_scene_trace(&harness.scene, kind)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
}

fn void? lod_trace_two_views(
    Fixture* fixture,
    LodTraceHarness* harness,
    Node* second_camera,
    TraceKind kind,
) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::AllocationDesc desc = {
        .size = LOD_TRACE_PIXELS * LodTraceDepthResult::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "animated_lod_second_trace_readback",
    };
    gpu::MappedGpuSpan second = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    defer {
        gpu::GpuAllocation allocation = second.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    Node* first_camera = harness.camera;
    harness.scene.update_world();
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    foreach (uint index, view : (ViewId[2]){ fixture.view, fixture.second_view }) {
        harness.camera = index ? second_camera : first_camera;
        renderer.render_view(&harness.scene, harness.camera, view)!;
        record_lod_trace_probe(
            fixture: fixture,
            harness: harness,
            view: view,
            kind: kind,
            readback: index ? second : (gpu::MappedGpuSpan){},
        )!;
        renderer.finish_view(view)!;
    }
    harness.camera = first_camera;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, harness.readback.span)!;
    gpu::invalidate_mapped_span(&renderer.device, second.span)!;
    mem::copy(harness.results.ptr, harness.readback.bytes.ptr, LOD_TRACE_PIXELS * LodTraceDepthResult::size);
    assert_lod_trace_agreement(harness.results, "Animated LOD first tracing view");
    LodTraceDepthResult[] results = ((LodTraceDepthResult*)second.bytes.ptr)[:LOD_TRACE_PIXELS];
    assert_lod_trace_agreement(results, "Animated LOD second tracing view");
}

fn void run_lod_trace_crowd_lifecycle(TraceKind kind) @private {
    Fixture fixture;
    if (!create_lod_trace_fixture(&fixture, kind)) return;
    defer destroy_fixture(&fixture);
    LodTraceHarness harness;
    create_lod_trace_harness(&fixture, &harness)!!;
    defer destroy_lod_trace_harness(&fixture, &harness);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    CrowdInstance[3] instances = lod_trace_crowd_instances(parts.posing);
    GeometryId coarse;
    Node* owner = add_lod_trace_crowd(
        fixture: &fixture,
        harness: &harness,
        parts: &parts,
        instances: instances[..],
        coarse: &coarse,
    );
    LodGroupState* state = harness.scene.get(owner, LodGroup).state;
    assert(!state.effects.trace);
    state.effects.trace = true;
    Renderer* renderer = &fixture.renderer;
    for (uint source = 0; source < 3; source++) {
        for (uint part = 0; part < 5; part++) {
            Vec3 centre = lod_trace_crowd_centre(
                owner: owner,
                instance: &instances[source],
                part: part,
                phase: instances[source].pose.time,
            );
            harness.camera.local.position = centre + (Vec3){ 0, 0, LOD_TRACE_CAMERA_DISTANCE };
            render_lod_trace(&fixture, &harness, kind)!!;
            assert_lod_trace_agreement(harness.results, "Animated LOD crowd logical source/part");
            assert_lod_trace_crowd_rows(&fixture, &harness, owner);
            assert(renderer.stats.trace_poses == (!source && !part ? 12u : 0u));
        }
    }
    float[3] phases = { 0.4f, 0.5f, 0.75f };
    set_lod_trace_phases(
        fixture: &fixture,
        harness: &harness,
        owner: owner,
        phases: phases[..],
    );
    Node* second_camera = harness.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "second_lod_trace_camera")!!;
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
    lod_trace_two_views(
        fixture: &fixture,
        harness: &harness,
        second_camera: second_camera,
        kind: kind,
    )!!;
    assert_lod_trace_crowd_rows(&fixture, &harness, owner);
    assert(renderer.stats.trace_poses == 3);
    assert(renderer.stats.trace_refits == (kind == TraceKind.SOFTWARE ? 3u : 0u));
    ulong revision = renderer.scene_trace.revision;
    lod_trace_two_views(
        fixture: &fixture,
        harness: &harness,
        second_camera: second_camera,
        kind: kind,
    )!!;
    assert(renderer.stats.trace_poses == 0 && renderer.stats.trace_refits == 0);
    assert(renderer.scene_trace.revision == revision);
    fixture.assets.geometry(coarse).data.positions[0].x += 0.125f;
    fixture.assets.mark_geometry_dirty(coarse);
    render_lod_trace(&fixture, &harness, kind)!!;
    assert_lod_trace_agreement(harness.results, "Animated LOD unchanged base after coarse edit");
    assert(renderer.scene_trace.revision == revision && renderer.stats.trace_poses == 0);
    phases[2] = 0.9f;
    set_lod_trace_phases(
        fixture: &fixture,
        harness: &harness,
        owner: owner,
        phases: phases[..],
    );
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!!;
    renderer.prepare_scene_trace(&harness.scene, kind)!!;
    assert(renderer.stats.trace_poses == 3 && renderer.posed_trace.pending.len() == 3);
    render::abort_frame(renderer);
    assert(renderer.posed_trace.pending.len() == 0 && renderer.scene_trace.baseline_count == 0);
    render_lod_trace(&fixture, &harness, kind)!!;
    assert_lod_trace_agreement(harness.results, "Animated LOD trace abort retry");
    assert_lod_trace_crowd_rows(&fixture, &harness, owner);
    assert(renderer.stats.trace_poses == 3);
    render_lod_trace(&fixture, &harness, kind)!!;
    assert(renderer.stats.trace_poses == 0);
    uint generation = state.slot_generations[0];
    model::set_crowd(
        assets: &fixture.assets,
        scene: &harness.scene,
        node: owner,
        instances: instances[..],
    )!!;
    render_lod_trace(&fixture, &harness, kind)!!;
    assert_lod_trace_agreement(harness.results, "Animated LOD trace replaced source slots");
    assert_lod_trace_crowd_rows(&fixture, &harness, owner);
    assert(state.slot_generations[0] != generation && renderer.stats.trace_poses == 12);
    check_crowd_native_validation(renderer);
}

fn void run_lod_trace_capacity(TraceKind kind) @private {
    Fixture fixture;
    if (!create_lod_trace_fixture(&fixture, kind, 2)) return;
    defer destroy_fixture(&fixture);
    LodTraceHarness harness;
    create_lod_trace_harness(&fixture, &harness)!!;
    defer destroy_lod_trace_harness(&fixture, &harness);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    CrowdInstance[3] instances = lod_trace_crowd_instances(parts.posing);
    Node* owner = add_lod_trace_crowd(
        fixture: &fixture,
        harness: &harness,
        parts: &parts,
        instances: instances[..],
    );
    Renderer* renderer = &fixture.renderer;
    LodGroupState* state = harness.scene.get(owner, LodGroup).state;
    assert(!state.effects.trace && !harness.scene.get(owner, AnimatedCrowd).trace);
    Vec3 centre = lod_trace_crowd_centre(
        owner: owner,
        instance: &instances[0],
        part: 0,
        phase: instances[0].pose.time,
    );
    harness.camera.local.position = centre + (Vec3){ 0, 0, LOD_TRACE_CAMERA_DISTANCE };
    harness.scene.update_world();
    for (uint frame = 0; frame < 2; frame++) {
        renderer.begin_frame({ .time = 0.37, .delta = 0 })!!;
        renderer.render_view(&harness.scene, harness.camera, fixture.view)!!;
        renderer.finish_view(fixture.view)!!;
        renderer.end_frame()!!;
        assert(renderer.stats.trace_poses == 0 && renderer.stats.trace_posed_bytes == 0);
        assert(renderer.posed_trace.slots.len == 0 && renderer.posed_trace.bytes == 0);
    }
    lod_trace_only(&fixture, &harness, kind)!!;
    assert(renderer.scene_trace.baseline_count == 0 && renderer.posed_trace.slots.len == 0);
    assert(renderer.stats.trace_poses == 0 && renderer.stats.trace_posed_instances == 0);
    state.effects.trace = true;
    for (uint frame = 0; frame < 2; frame++) {
        render_lod_trace(&fixture, &harness, kind)!!;
        assert_lod_trace_agreement(harness.results, "Animated LOD admitted overflow prefix");
        assert(renderer.stats.trace_posed_instances == 2 && renderer.stats.trace_posed_overflow == 10);
        assert(renderer.scene_trace.baseline_count == 5 && renderer.posed_trace.slots.len == 2);
        assert(renderer.stats.trace_poses == (frame ? 0u : 2u));
        uint skinned;
        uint rigid;
        foreach (record : renderer.scene_trace.baseline[:renderer.scene_trace.baseline_count]) {
            assert(c3d::same_id(record.entity, owner.id) && record.part_index < 2);
            if (record.part_index == 0) {
                assert(record.instance_index == skinned && record.pose_serial > 0);
                skinned++;
            } else {
                assert(record.part_index == 1 && record.pose_serial == 0);
                rigid++;
            }
        }
        assert(skinned == 2 && rigid == 3);
        assert(!(renderer.posed_trace.slots[0].key == renderer.posed_trace.slots[1].key));
    }
    centre = lod_trace_crowd_centre(
        owner: owner,
        instance: &instances[2],
        part: 0,
        phase: instances[2].pose.time,
    );
    harness.camera.local.position = centre + (Vec3){ 0, 0, LOD_TRACE_CAMERA_DISTANCE };
    render_lod_trace(&fixture, &harness, kind)!!;
    usz missing;
    foreach (result : harness.results) {
        if ((result.flags & LOD_TRACE_RASTER_HIT) && !(result.flags & LOD_TRACE_HIT)) missing++;
    }
    io::eprintfn("Animated LOD explicit posed overflow: admitted=2 omitted=10 omitted_source_pixels=%s", missing);
    assert(missing >= LOD_TRACE_COVERAGE_MINIMUM);
    assert(renderer.stats.trace_posed_overflow == 10);
    check_crowd_native_validation(renderer);
}

fn void run_lod_trace_real(TraceKind kind, bool quaternius) @private {
    Fixture fixture;
    if (!create_lod_trace_fixture(&fixture, kind)) return;
    defer destroy_fixture(&fixture);
    LodTraceHarness harness;
    create_lod_trace_harness(&fixture, &harness)!!;
    defer destroy_lod_trace_harness(&fixture, &harness);
    ModelId model;
    AnimatedLodFixtures corpus;
    if (quaternius) {
        corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, "../../..")!!;
        model = corpus.model;
    } else {
        model = load_crowd_native_cc0(&fixture, CROWD_NATIVE_MORPH_CUBE, CROWD_NATIVE_MORPH_CUBE_SHA)!!;
    }
    crowd_native_flat_source_materials(&fixture, model);
    ClipId clip = quaternius
      ? crowd_native_clip_named(&fixture, model, "Walk_Loop")!!
      : fixture.assets.model(model).data.clips[0];
    Node* owner = model::instantiate(&fixture.assets, &harness.scene, model)!!;
    Animator* animator = anim::add_animator(&harness.scene, owner);
    AnimationActionId action = animator.play(&fixture.assets, clip)!!;
    animator.action(action).loop = false;
    animator.action(action).speed = 0;
    animator.action(action).time = 0.375f * fixture.assets.clip(clip).data.duration;
    anim::update(&fixture.assets, &harness.scene, 0);
    @pool() {
        AnimatedLodDesc desc;
        CrowdLodNativeDescriptor descriptor;
        if (quaternius) {
            fill_crowd_lod_native_descriptor(
                fixture: &fixture,
                corpus: &corpus,
                descriptor: &descriptor,
                material: {},
            );
            desc = crowd_lod_native_desc(&descriptor);
        } else {
            desc = lod_trace_desc(&fixture.assets, model);
        }
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &harness.scene,
            owner: owner,
            desc: desc,
        )!!;
    };
    harness.scene.get(owner, LodGroup).state.effects.trace = true;
    ViewDesc view = fixture.renderer.views.get(fixture.view).desc;
    view.lod_bias = 16;
    render::configure_view(&fixture.renderer, fixture.view, view)!!;
    harness.camera.local.position = quaternius ? (Vec3){ 0, 1.1f, LOD_TRACE_CHARACTER_DISTANCE } : (Vec3){ 0, 0, 3 };
    render_lod_trace(&fixture, &harness, kind)!!;
    assert_lod_trace_agreement(harness.results, quaternius ? "Quaternius base trace" : "AnimatedMorphCube base trace", false);
    Renderer* renderer = &fixture.renderer;
    uint expected = quaternius ? 2u : 1u;
    assert(renderer.scene_trace.baseline_count == expected);
    assert(renderer.stats.trace_posed_instances == expected && renderer.stats.trace_posed_overflow == 0);
    assert(renderer.stats.trace_poses == expected && renderer.stats.lod_objects_selected[0] == 1);
    ModelTemplate* template = &fixture.assets.model(model).data;
    foreach (record : renderer.scene_trace.baseline[:renderer.scene_trace.baseline_count]) {
        assert(c3d::same_id(record.entity, owner.id) && record.instance_index == 0);
        assert(record.part_index < expected);
        assert(c3d::same_id(record.geometry, template.meshes[record.part_index].geometry));
    }
    ulong revision = renderer.scene_trace.revision;
    render_lod_trace(&fixture, &harness, kind)!!;
    assert_lod_trace_agreement(harness.results, "Still real-source base trace", false);
    assert(renderer.scene_trace.revision == revision && renderer.stats.trace_poses == 0);
    if (quaternius) {
        GeometryId coarse = corpus.levels[0][1];
        fixture.assets.geometry(coarse).data.positions[0].x += 0.01f;
        fixture.assets.mark_geometry_dirty(coarse);
        render_lod_trace(&fixture, &harness, kind)!!;
        assert_lod_trace_agreement(harness.results, "Real base trace after coarse-only edit", false);
        assert(renderer.scene_trace.revision == revision && renderer.stats.trace_poses == 0);
    }
    io::eprintfn("Real-source trace normals reported as observations; flat-face normal gate does not apply");
    check_crowd_native_validation(renderer);
}

fn void test_traced_animated_lod_native_crowd_software_lifecycle_and_two_views() @test {
    run_lod_trace_crowd_lifecycle(TraceKind.SOFTWARE);
}

fn void test_traced_animated_lod_native_crowd_hardware_lifecycle_and_two_views() @test {
    run_lod_trace_crowd_lifecycle(TraceKind.HARDWARE);
}

fn void test_traced_animated_lod_native_software_opt_in_and_overflow() @test {
    run_lod_trace_capacity(TraceKind.SOFTWARE);
}

fn void test_traced_animated_lod_native_hardware_opt_in_and_overflow() @test {
    run_lod_trace_capacity(TraceKind.HARDWARE);
}

fn void test_traced_animated_lod_native_quaternius_software_base_trace() @test {
    run_lod_trace_real(TraceKind.SOFTWARE, true);
}

fn void test_traced_animated_lod_native_quaternius_hardware_base_trace() @test {
    run_lod_trace_real(TraceKind.HARDWARE, true);
}

fn void test_traced_animated_lod_native_morph_cube_software_base_trace() @test {
    run_lod_trace_real(TraceKind.SOFTWARE, false);
}

fn void test_traced_animated_lod_native_morph_cube_hardware_base_trace() @test {
    run_lod_trace_real(TraceKind.HARDWARE, false);
}
