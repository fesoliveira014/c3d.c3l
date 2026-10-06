module c3d::test::posed_trace;

import c3d;
import c3d::geometry;
import c3d::render @public;
import c3d::shader;
import gpu;
import std::math;

const uint SLOT_CAPACITY @local = 2;
const ulong SCENE_IDENTITY @local = 7;
const usz POSE_BYTES @local = 2 * Mat4f::size;

fn PosedTraceKey key_of(uint node, ulong instance = 0) @local {
    return { .scene = SCENE_IDENTITY, .node = { .index = node, .generation = 1 }, .instance = instance };
}

fn PosedTraceTable make_table(RetireList* retire) @local {
    retire.init(mem);
    return render::create_posed_trace_table(mem, SLOT_CAPACITY);
}

fn void destroy_table(PosedTraceTable* table, RetireList* retire) @local {
    render::free_posed_trace_storage(table);
    retire.free();
}

fn void give_resources(PosedTraceRes* slot) @local {
    slot.allocation = { .owner = 1, .index = 3, .generation = 1 };
    slot.node_allocation = { .owner = 1, .index = 4, .generation = 1 };
    slot.blas = { .owner = 1, .index = 5, .generation = 1 };
    slot.pose = alloc::new_array(mem, char, POSE_BYTES);
}

fn void test_posed_slots_go_to_the_first_keys_of_each_epoch() @test {
    RetireList retire;
    PosedTraceTable table = make_table(&retire);
    defer destroy_table(&table, &retire);

    table.begin_epoch(1);
    assert(table.claim(key_of(0), 0, &retire)!! == 0);
    assert(table.claim(key_of(1), 0, &retire)!! == 1);
    if (catch excuse = table.claim(key_of(2), 0, &retire)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    give_resources(&table.slots[0]);

    table.begin_epoch(2);
    assert(table.claim(key_of(2), 1, &retire)!! == 0);
    assert(retire.len() == 3 && retire[0].kind == RetiredKind.ALLOCATION);
    assert(retire[2].kind == RetiredKind.ACCELERATION_STRUCTURE && table.slots[0].pose.len == 0);
    assert(table.claim(key_of(1), 1, &retire)!! == 1);
    if (catch excuse = table.claim(key_of(0), 1, &retire)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(!table.lookup.has_key(key_of(0)) && table.slots[0].key == key_of(2));
}

fn void test_posed_claims_repeat_within_an_open_frame() @test {
    RetireList retire;
    PosedTraceTable table = make_table(&retire);
    defer destroy_table(&table, &retire);

    table.begin_epoch(5);
    ulong epoch = table.epoch;
    assert(table.claim(key_of(0), 4, &retire)!! == 0);
    assert(table.claim(key_of(1), 4, &retire)!! == 1);
    table.begin_epoch(5);
    assert(table.epoch == epoch);
    assert(table.claim(key_of(1), 4, &retire)!! == 1 && table.claim(key_of(0), 4, &retire)!! == 0);
    if (catch excuse = table.claim(key_of(2), 4, &retire)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }

    table.begin_epoch(0);
    assert(table.epoch == epoch + 1);
    table.begin_epoch(0);
    assert(table.epoch == epoch + 2);
}

fn void test_posed_sweep_empties_slots_absent_past_the_window() @test {
    RetireList retire;
    PosedTraceTable table = make_table(&retire);
    defer destroy_table(&table, &retire);

    table.begin_epoch(11);
    uint index = table.claim(key_of(0, 3), 10, &retire)!!;
    give_resources(&table.slots[index]);
    table.slots[index].stream_bytes = 4096;
    table.slots[index].node_count = 8;
    table.slots[index].blas_bytes = 1024;
    table.bytes = 4096 + 8 * shader::BvhNodeGpu::size + 1024;

    table.sweep(10 + render::INSTANCE_ABSENCE_FRAMES, &retire);
    assert(table.slots[index].key == key_of(0, 3) && retire.len() == 0);
    table.sweep(11 + render::INSTANCE_ABSENCE_FRAMES, &retire);
    assert(table.slots[index].key.scene == 0 && !table.lookup.has_key(key_of(0, 3)));
    assert(retire.len() == 3 && table.bytes == 0 && table.slots[index].pose.len == 0);
}

fn void test_pose_serial_advances_only_on_changed_inputs() @test {
    RetireList retire;
    PosedTraceTable table = make_table(&retire);
    defer destroy_table(&table, &retire);
    table.begin_epoch(1);
    uint index = table.claim(key_of(0), 0, &retire)!!;
    PosedTraceRes* slot = &table.slots[index];
    slot.pose = alloc::new_array(mem, char, POSE_BYTES);
    Mat4 identity = matrix::IDENTITY4;
    Mat4f[2] palette = { bitcast(identity, Mat4f), bitcast(identity, Mat4f) };
    char[] inputs = ((char*)&palette)[:POSE_BYTES];

    assert(slot.update_pose(inputs) && slot.pose_serial == 1);
    for (uint frame = 0; frame < 4; frame++) assert(!slot.update_pose(inputs));
    assert(slot.pose_serial == 1);

    palette[1][3].x = 0.5f;
    assert(slot.update_pose(inputs) && slot.pose_serial == 2);
    assert(!slot.update_pose(inputs) && slot.pose_serial == 2);

    render::mark_posed_pending(&table, index);
    slot.refit_serial = slot.pose_serial;
    slot.blas_serial = slot.pose_serial;
    slot.built_revision = 3;
    render::discard_posed_trace(&table);
    assert(slot.built_revision == 0 && slot.refit_serial == 0 && slot.blas_serial == 0 && !slot.pending);
    assert(table.pending.len() == 0 && table.epoch_frame == 0);
    assert(slot.update_pose(inputs) && slot.pose_serial == 3);
    assert(!slot.update_pose(inputs) && slot.pose_serial == 3);

    slot.built_revision = 3;
    slot.pose_valid = true;
    slot.blas_serial = 3;
    render::mark_posed_pending(&table, index);
    render::mark_posed_pending(&table, index);
    assert(table.pending.len() == 1);
    render::commit_posed_trace(&table);
    assert(table.pending.len() == 0 && !slot.pending);
    assert(slot.built_revision == 3 && slot.pose_valid && slot.blas_serial == 3);
}

fn void test_posed_root_redirects_only_the_deformed_streams() @test {
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        box.joints = alloc::new_array(tmem, ushort[<4>], box.positions.len);
        box.weights = alloc::new_array(tmem, Vec4, box.positions.len);
        render::GeometryLayout layout = render::geometry_layout(&box);
        gpu::GpuAddress source = (gpu::GpuAddress)0x10000;
        gpu::GpuAddress posed = (gpu::GpuAddress)0x90000;
        render::PosedLayout posed_layout = render::posed_layout(&layout);
        shader::GeometryRoot rest = render::geometry_root(&layout, source);
        shader::GeometryRoot root = render::posed_geometry_root(&layout, source, posed);

        assert(posed_layout.positions == layout.positions && posed_layout.tangents == 0);
        assert(posed_layout.normals == posed_layout.positions + 12 * box.positions.len);
        assert(posed_layout.total_bytes == posed_layout.normals + 12 * box.positions.len);
        assert(root.positions == posed + (gpu::GpuAddress)posed_layout.positions);
        assert(root.normals == posed + (gpu::GpuAddress)posed_layout.normals && root.tangents == (gpu::GpuAddress)0);
        shader::GeometryRoot unchanged = root;
        unchanged.positions = rest.positions;
        unchanged.normals = rest.normals;
        assert(mem::equals(&unchanged, &rest, shader::GeometryRoot::size));
    };
}
