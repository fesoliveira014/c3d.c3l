module c3d::test::inertial_storage;

import c3d;
import c3d::anim @public;
import c3d::maths;
import std::io;
import std::math;

struct InertialAllocationProbe (Allocator) @local {
    Allocator backing;
    void* pointer;
    sz bytes;
    sz alignment;
    uint acquisitions;
    uint resizes;
    uint releases;
    uint outstanding;
    bool fail;
}

struct InertialStorageCase @local {
    uint nodes;
    uint morphs;
    uint capacity;
}

fn void*? InertialAllocationProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.acquisitions++;
    self.bytes = size;
    self.alignment = alignment;
    if (self.fail) return mem::OUT_OF_MEMORY~;

    self.pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return self.pointer;
}

fn void*? InertialAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.resizes++;
    return self.backing.resize(pointer, size, alignment);
}

fn void InertialAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    assert(pointer == self.pointer && aligned && self.outstanding == 1);
    self.backing.release(pointer, aligned);
    self.pointer = null;
    self.outstanding--;
    self.releases++;
}

fn usz independent_inertial_align(usz value, usz alignment) @local {
    usz remainder = value % alignment;
    return remainder ? value + alignment - remainder : value;
}

fn usz independent_inertial_row_bytes(uint nodes, uint morphs) @local {
    usz pose_bytes = (usz)nodes * Transform::size;
    usz velocity_start = independent_inertial_align(pose_bytes, PoseVelocity::alignment);
    usz morph_start = velocity_start + 3 * (usz)nodes * PoseVelocity::size;
    usz rates_start = independent_inertial_align(morph_start + (usz)morphs * float::size, double::alignment);
    return independent_inertial_align(rates_start + 3 * (usz)morphs * double::size, InertialRow::alignment);
}

fn usz check_inertial_region(
    void* block,
    usz bytes,
    usz prior_end,
    void* pointer,
    usz region_bytes,
    usz alignment,
) @local {
    usz start = (usz)pointer;
    assert(start % alignment == 0 && start >= prior_end);
    assert(start >= (usz)block && start - (usz)block <= bytes);
    assert(region_bytes <= bytes - (start - (usz)block));
    return start + region_bytes;
}

fn void test_animation_inertial_storage_single_block_cost_alignment_and_separate_capacity_rows() @test {
    InertialStorageCase[5] cases = {
        { .nodes = 0, .morphs = 0, .capacity = 1 },
        { .nodes = 4, .morphs = 2, .capacity = 1 },
        { .nodes = 57, .morphs = 0, .capacity = 4 },
        { .nodes = 4, .morphs = 5, .capacity = 16 },
        { .nodes = 520, .morphs = 9, .capacity = 16 },
    };
    io::printfn("PoseVelocity bytes=%s align=%s", PoseVelocity::size, PoseVelocity::alignment);
    io::printfn("InertialRow bytes=%s align=%s", InertialRow::size, InertialRow::alignment);
    io::printfn("RootInertialState bytes=%s InertialControl bytes=%s", RootInertialState::size, InertialControl::size);
    foreach (sample : cases) {
        InertialAllocationProbe allocator = { .backing = mem };
        {
            InertialStorage* storage = anim::create_inertial_storage(
                allocator: &allocator,
                nodes: sample.nodes,
                morphs: sample.morphs,
                capacity: sample.capacity,
            )!!;
            defer anim::destroy_inertial_storage(storage);
            usz row_bytes = independent_inertial_row_bytes(sample.nodes, sample.morphs);
            usz rows_start = independent_inertial_align(InertialStorage::size, InertialRow::alignment);
            usz payload_start = rows_start + (usz)sample.capacity * InertialRow::size;
            usz expected_bytes = payload_start + (usz)sample.capacity * row_bytes;
            assert((void*)storage == allocator.pointer && allocator.acquisitions == 1 && allocator.outstanding == 1);
            assert(allocator.resizes == 0 && allocator.releases == 0);
            assert(allocator.bytes == expected_bytes && storage.bytes == expected_bytes
              && storage.row_bytes == row_bytes);
            assert(allocator.alignment == InertialRow::alignment && storage.rows.len == sample.capacity);
            assert(storage.nodes == sample.nodes && storage.morphs == sample.morphs);
            usz previous_end = (usz)storage + rows_start + (usz)sample.capacity * InertialRow::size;
            foreach (row : storage.rows) {
                assert(row.previous_pose.len == sample.nodes && row.velocity.len == sample.nodes);
                assert(row.offset.len == sample.nodes && row.offset_velocity.len == sample.nodes);
                assert(row.previous_morph.len == sample.morphs && row.morph_velocity.len == sample.morphs);
                assert(row.morph_offset.len == sample.morphs && row.morph_offset_velocity.len == sample.morphs);
                previous_end = check_inertial_region(
                    block: storage,
                    bytes: storage.bytes,
                    prior_end: previous_end,
                    pointer: row.previous_pose.ptr,
                    region_bytes: (usz)row.previous_pose.len * Transform::size,
                    alignment: Transform::alignment,
                );
                foreach (values : (PoseVelocity[][3]){ row.velocity, row.offset, row.offset_velocity }) {
                    previous_end = check_inertial_region(
                        block: storage,
                        bytes: storage.bytes,
                        prior_end: previous_end,
                        pointer: values.ptr,
                        region_bytes: (usz)values.len * PoseVelocity::size,
                        alignment: PoseVelocity::alignment,
                    );
                }
                previous_end = check_inertial_region(
                    block: storage,
                    bytes: storage.bytes,
                    prior_end: previous_end,
                    pointer: row.previous_morph.ptr,
                    region_bytes: (usz)row.previous_morph.len * float::size,
                    alignment: float::alignment,
                );
                foreach (values : (double[][3]){ row.morph_velocity, row.morph_offset, row.morph_offset_velocity }) {
                    previous_end = check_inertial_region(
                        block: storage,
                        bytes: storage.bytes,
                        prior_end: previous_end,
                        pointer: values.ptr,
                        region_bytes: (usz)values.len * double::size,
                        alignment: double::alignment,
                    );
                }
                assert(!row.control.history_valid && !row.control.active && !row.root.target_rate_pending);
            }
            io::printfn(
                "inertial nodes=%s morphs=%s capacity=%s bytes=%s row_payload=%s",
                sample.nodes,
                sample.morphs,
                sample.capacity,
                storage.bytes,
                storage.row_bytes,
            );
        }
        assert(allocator.outstanding == 0 && allocator.releases == 1);
    }
}

fn void test_animation_inertial_storage_reset_clears_one_incarnation_without_touching_other_rows_or_allocating() @test {
    InertialAllocationProbe allocator = { .backing = mem };
    InertialStorage* storage = anim::create_inertial_storage(
        allocator: &allocator,
        nodes: 4,
        morphs: 5,
        capacity: 4,
    )!!;
    defer anim::destroy_inertial_storage(storage);
    foreach (index, &row : storage.rows) {
        row.previous_pose[..] = maths::TRANSFORM_IDENTITY;
        row.previous_pose[0].position = { (float)index + 1, 2, 3 };
        PoseVelocity values = {
            .translation = { (double)index + 1, -2, 3 },
            .angular = { 4, (double)index + 5, -6 },
            .scale = { 7, 8, (double)index + 9 },
        };
        row.velocity[..] = values;
        row.offset[..] = values;
        row.offset_velocity[..] = values;
        row.previous_morph[..] = (float)index + 1;
        row.morph_velocity[..] = (double)float::max * 2;
        row.morph_offset[..] = -(double)float::max * 2;
        row.morph_offset_velocity[..] = 0x1p-140;
        row.control = {
            .generation = (uint)index + 7, .history_valid = true, .active = true,
            .previous_dt = 0.125, .duration = 3, .elapsed = 1,
        };
        row.root = {
            .published_translation = { 1, 2, 3 }, .published_twist = 0.5,
            .translation_rate = { 4, 5, 6 }, .twist_rate = 0.25,
            .source_translation_rate = { 7, 8, 9 }, .source_twist_rate = 0.125,
            .residual_translation_rate = { -1, -2, -3 }, .residual_twist_rate = -0.5,
            .anchor_translation = { 9, 8, 7 }, .anchor_rotation = { .l = 1 },
            .pivot = { 3, 0, 2 }, .target_rate_pending = true,
        };
    }
    InertialRow[3] neighbors = { storage.rows[0], storage.rows[2], storage.rows[3] };
    char[][3] payloads;
    for (uint neighbor = 0; neighbor < 3; neighbor++) {
        char[] bytes = ((char*)neighbors[neighbor].previous_pose.ptr)[:storage.row_bytes];
        payloads[neighbor] = alloc::clone_slice(mem, bytes);
    }
    defer {
        foreach (bytes : payloads) alloc::free(mem, bytes.ptr);
    }
    for (uint reset = 0; reset < 100; reset++) anim::reset_inertial_row(storage, 1, reset + 10);
    InertialRow* cleared = &storage.rows[1];
    assert(cleared.control.generation == 109 && !cleared.control.history_valid && !cleared.control.active);
    assert(cleared.control.previous_dt == 0 && cleared.control.duration == 0 && cleared.control.elapsed == 0);
    foreach (pose : cleared.previous_pose) {
        assert(pose.position == (Vec3){} && pose.scale == (Vec3){ 1, 1, 1 });
        assert(pose.rotation.l == 1);
    }
    foreach (values : (PoseVelocity[][3]){ cleared.velocity, cleared.offset, cleared.offset_velocity }) {
        foreach (value : values) {
            assert(value.translation == (double[<3>]){} && value.angular == (double[<3>]){});
            assert(value.scale == (double[<3>]){});
        }
    }
    foreach (value : cleared.previous_morph) assert(value == 0);
    foreach (values : (double[][3]){ cleared.morph_velocity, cleared.morph_offset, cleared.morph_offset_velocity }) {
        foreach (value : values) assert(value == 0);
    }
    RootInertialState empty = { .anchor_rotation = { .l = 1 } };
    assert(mem::equals(&cleared.root, &empty, RootInertialState::size));
    for (uint neighbor = 0; neighbor < 3; neighbor++) {
        uint index = neighbor == 0 ? 0 : neighbor + 1;
        assert(mem::equals(&neighbors[neighbor], &storage.rows[index], InertialRow::size));
        assert(mem::equals((char*)storage.rows[index].previous_pose.ptr, payloads[neighbor].ptr, (sz)storage.row_bytes));
    }
    assert(allocator.acquisitions == 1 && allocator.resizes == 0 && allocator.releases == 0);
}

fn void test_animation_inertial_storage_failed_acquisition_and_overflow_leave_no_owner() @test {
    InertialAllocationProbe failing = { .backing = mem, .fail = true };
    assert(@catch(anim::create_inertial_storage(
        allocator: &failing,
        nodes: 57,
        morphs: 9,
        capacity: 16,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(failing.acquisitions == 1 && failing.outstanding == 0 && failing.releases == 0);
    InertialAllocationProbe overflow = { .backing = mem };
    assert(@catch(anim::create_inertial_storage(
        allocator: &overflow,
        nodes: uint::max,
        morphs: uint::max,
        capacity: uint::max,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(overflow.acquisitions == 0 && overflow.resizes == 0 && overflow.releases == 0);
}
