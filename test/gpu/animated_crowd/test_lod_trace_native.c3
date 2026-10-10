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
        .dst = harness.readback.span,
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
        if (traced && flat) {
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
