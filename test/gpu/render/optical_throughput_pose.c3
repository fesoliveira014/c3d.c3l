module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::io;
import std::math::vector;
import std::math::matrix;

const uint OPTICAL_POSE_SKIN @private = 1;
const uint OPTICAL_POSE_MORPH @private = 2;
const uint OPTICAL_POSE_WIDE @private = 4;
const uint OPTICAL_POSE_WIDE_JOINT @private = 256;
const float OPTICAL_POSE_MORPH_DELTA @private = 0.25f;
const float OPTICAL_POSE_MORPH_WEIGHT @private = 0.5f;

fn Node*? add_optical_pose_source(Fixture* fixture, OpticalTraceResources* trace, uint mode) @private {
    Node* mesh_node = trace.scene.root.first_child;
    Geometry source = fixture.assets.geometry(trace.geometries[0]).data;
    @pool() {
        if ((mode & OPTICAL_POSE_SKIN) != 0) {
            source.joints = alloc::new_array(tmem, ushort[<4>], 4);
            source.weights = alloc::new_array(tmem, Vec4, 4);
            ushort joint = (mode & OPTICAL_POSE_WIDE) != 0 ? (ushort)OPTICAL_POSE_WIDE_JOINT : 0;
            for (uint vertex = 0; vertex < 4; vertex++) {
                source.joints[vertex] = { joint, 0, 0, 0 };
                source.weights[vertex] = { 1, 0, 0, 0 };
            }
        }
        if ((mode & OPTICAL_POSE_MORPH) != 0) {
            source.targets = alloc::new_array(tmem, MorphTarget, 1);
            source.targets[0].position_deltas = alloc::new_array(tmem, Vec3, 4);
            source.targets[0].position_deltas[..] = { 0, 0, OPTICAL_POSE_MORPH_DELTA };
        }
        trace.geometries[0] = fixture.assets.add_geometry(&source)!;
    };
    Mesh* mesh = trace.scene.get(mesh_node, Mesh);
    mesh.geometry = trace.geometries[0];
    if ((mode & OPTICAL_POSE_MORPH) != 0) {
        mesh.morph_weights = alloc::new_array(trace.scene.allocator, float, 1);
        mesh.morph_weights[0] = OPTICAL_POSE_MORPH_WEIGHT;
    }
    Node* animated_joint;
    if ((mode & OPTICAL_POSE_SKIN) != 0) {
        uint count = (mode & OPTICAL_POSE_WIDE) != 0 ? OPTICAL_POSE_WIDE_JOINT + 1 : 1;
        Skeleton skeleton = {
            .joint_names = mem::new_array(String, count),
            .parents = mem::new_array(int, count),
            .rest_pose = mem::new_array(Transform, count),
            .inverse_bind = mem::new_array(Mat4, count),
        };
        defer catch asset::free_skeleton(mem, &skeleton);
        for (uint joint = 0; joint < count; joint++) {
            skeleton.parents[joint] = -1;
            skeleton.rest_pose[joint] = maths::TRANSFORM_IDENTITY;
            skeleton.inverse_bind[joint] = matrix::IDENTITY4;
        }
        SkeletonId id = fixture.assets.add_skeleton_owned(&skeleton)!;
        Node*[] joints = alloc::new_array(trace.scene.allocator, Node*, count);
        foreach (&joint : joints) *joint = trace.scene.add_node()!;
        animated_joint = joints[count - 1];
        trace.scene.add(mesh_node, (SkinBinding){ .skeleton = id, .joints = joints });
    }
    return animated_joint;
}

fn void? check_optical_pose_positions(Fixture* fixture, OpticalTraceResources* trace, float shift) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::GpuSpan source;
    gpu::GpuAddress root;
    foreach (record : renderer.scene_trace.baseline[:renderer.scene_trace.baseline_count]) {
        if (c3d::same_id(record.geometry, trace.geometries[0])) root = record.geometry_root;
    }
    foreach (slot : renderer.posed_trace.slots) {
        if (slot.root == root) source = slot.positions;
    }
    assert(source.size == 4 * render::PACKED_VEC3_BYTES && root != renderer.geometries[trace.geometries[0].index].root,
        "The optical trace must use the posed root and its position span.");
    gpu::AllocationDesc desc = {
        .size = 4 * render::PACKED_VEC3_BYTES,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "optical_pose_positions",
    };
    gpu::MappedGpuSpan output = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    defer {
        gpu::GpuAllocation allocation = output.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::Barrier ready = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &ready)!;
    gpu::BufferCopyDesc copy = { .src = source, .dst = output.span };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, output.span)!;
    Vec3* actual = (Vec3*)output.bytes.ptr;
    Vec3[] rest = fixture.assets.geometry(trace.geometries[0]).data.positions;
    for (uint vertex = 0; vertex < 4; vertex++) {
        assert(bitcast(actual[vertex].x, uint) == bitcast(rest[vertex].x, uint));
        assert(bitcast(actual[vertex].y, uint) == bitcast(rest[vertex].y, uint));
        assert(bitcast(actual[vertex].z, uint) == bitcast(rest[vertex].z + shift, uint),
            "The dyadic pose must be exact before optical traversal.");
    }
}

fn void test_optical_throughput_skin_morph_and_wide_joints_use_current_positions_in_both_tracers() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    assert(fixture.renderer.caps.ray_queries.enabled);
    OpticalStack stack;
    create_optical_stack(&fixture.renderer, &stack)!!;
    defer destroy_optical_stack(&fixture.renderer, &stack);
    foreach (mode : (uint[4]){ OPTICAL_POSE_SKIN, OPTICAL_POSE_MORPH,
        OPTICAL_POSE_SKIN | OPTICAL_POSE_MORPH, OPTICAL_POSE_SKIN | OPTICAL_POSE_WIDE }) {
        OpticalSurface[1] surfaces = { optical_default_surface() };
        OpticalTraceResources trace;
        create_optical_trace(&fixture, &trace, surfaces[..])!!;
        defer destroy_optical_trace(&fixture, &trace);
        Node* joint = add_optical_pose_source(&fixture, &trace, mode)!!;
        foreach (translation : (float[2]){ 0.25f, 0.5f }) {
            if (joint) joint.local.position.z = translation;
            float shift = (mode & OPTICAL_POSE_SKIN) != 0 ? translation : 0;
            if ((mode & OPTICAL_POSE_MORPH) != 0) shift += OPTICAL_POSE_MORPH_DELTA * OPTICAL_POSE_MORPH_WEIGHT;
            surfaces[0].model_scale.w = 0.5f + shift / 8;
            trace.scene.update_world();
            fixture.renderer.prepare_scene_trace(&trace.scene, TraceKind.SOFTWARE)!!;
            check_optical_pose_positions(&fixture, &trace, shift)!!;
            run_optical_stack(
                renderer: &fixture.renderer,
                stack: &stack,
                surfaces: surfaces[..],
                capacity: 1,
            )!!;
            check_optical_stack(&stack, surfaces[..], 1);
            Vec4[] software = mem::new_array(Vec4, OPTICAL_EXTENT * OPTICAL_EXTENT);
            defer free(software.ptr);
            foreach (hardware : (bool[2]){ false, true }) {
                run_optical_trace(
                    fixture: &fixture,
                    trace: &trace,
                    surfaces: surfaces[..],
                    capacity: 1,
                    hardware: hardware,
                )!!;
                if (!hardware) {
                    mem::copy(software.ptr, trace.output.bytes.ptr, (sz)trace.output.bytes.len);
                } else {
                    check_optical_trace_pair(software, ((Vec4*)trace.output.bytes.ptr)[:software.len]);
                }
                check_optical_face_interiors(&stack, &trace, false);
            }
            io::printfn("optical pose mode=%s shift=%s positions=4 exact samples=1024 branches=atlas,hardware,software",
                mode, shift);
        }
    }
    check_validation(&fixture.renderer);
}
