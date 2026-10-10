module c3d::test::animation_storage;

import c3d;
import c3d::anim @public;
import std::io;
import std::math;

struct AnimationStorageProbe (Allocator) @local {
    Allocator backing;
    void* pointer;
    sz requested_bytes;
    sz requested_alignment;
    uint acquire_calls;
    uint resize_calls;
    uint outstanding;
    uint release_calls;
}

struct AnimationStorageCase @local {
    uint capacity;
    usz expected_bytes;
}

fn void*? AnimationStorageProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.acquire_calls++;
    self.requested_bytes = size;
    self.requested_alignment = alignment;
    self.pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return self.pointer;
}

fn void*? AnimationStorageProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.resize_calls++;
    return self.backing.resize(pointer, size, alignment);
}

fn void AnimationStorageProbe.release(&self, void* pointer, bool aligned) @dynamic {
    assert(pointer == self.pointer && self.outstanding == 1);
    self.backing.release(pointer, aligned);
    self.pointer = null;
    self.outstanding--;
    self.release_calls++;
}

fn usz animation_storage_payload(uint capacity) @local {
    uint triangles = capacity < 3 ? 0 : 2 * capacity - 5;
    return (usz)capacity * (AnimationActionId::size + Vec2::size + BlendHullIndices::size)
      + (usz)triangles * BlendTriangleIndices::size;
}

fn usz animation_storage_expected(uint capacity) @local {
    usz payload = animation_storage_payload(capacity);
    usz row_alignment = math::max(AnimationActionId::alignment, Vec2::alignment);
    usz row_padding = (row_alignment - payload % row_alignment) % row_alignment;
    return 2 * BlendSpace2D::size + 2 * (payload + row_padding);
}

fn usz animation_storage_region_end(
    usz base,
    usz block_bytes,
    usz prior_end,
    void* pointer,
    usz bytes,
    usz alignment,
) @local {
    usz address = (usz)pointer;
    assert(address >= prior_end && address >= base && address % alignment == 0);
    assert(bytes <= block_bytes && address - base <= block_bytes - bytes);
    return address + bytes;
}

fn void test_animation_authoring_storage_two_prepared_rows_match_measured_cost_and_alignment() @test {
    io::printfn("Action bytes=%s PlayDesc bytes=%s", Action::size, PlayDesc::size);
    io::printfn("BlendSpace2D bytes=%s alignment=%s", BlendSpace2D::size, BlendSpace2D::alignment);
    assert(BlendSpace2D::size == 128 && BlendSpace2D::alignment == 8);
    assert(AnimationActionId::size == 8 && Vec2::size == 8);
    assert(BlendTriangleIndices::size == 3 && BlendHullIndices::size == 2);
    AnimationStorageCase[8] cases = {
        { .capacity = 1, .expected_bytes = animation_storage_expected(1) },
        { .capacity = 2, .expected_bytes = animation_storage_expected(2) },
        { .capacity = 3, .expected_bytes = 384 },
        { .capacity = 4, .expected_bytes = 432 },
        { .capacity = 8, .expected_bytes = 624 },
        { .capacity = 9, .expected_bytes = 672 },
        { .capacity = 15, .expected_bytes = 960 },
        { .capacity = 16, .expected_bytes = 1008 },
    };
    foreach (sample : cases) {
        AnimationStorageProbe allocator = { .backing = mem };
        assert(animation_storage_expected(sample.capacity) == sample.expected_bytes);
        {
            BlendSpace2D[] spaces = anim::create_blend_spaces_2d(&allocator, sample.capacity)!!;
            defer anim::destroy_blend_spaces_2d(&allocator, spaces);

            assert(spaces.len == 2 && allocator.acquire_calls == 1 && allocator.resize_calls == 0);
            assert(allocator.requested_bytes == sample.expected_bytes && allocator.outstanding == 1);
            assert(allocator.requested_alignment == BlendSpace2D::alignment);
            assert((void*)spaces.ptr == allocator.pointer);
            usz base = (usz)allocator.pointer;
            usz previous_end = base + 2 * BlendSpace2D::size;
            uint triangles = sample.capacity < 3 ? 0 : 2 * sample.capacity - 5;
            foreach (space : spaces) {
                assert(space.count == 0 && space.triangle_count == 0 && space.hull_count == 0);
                assert(space.actions.len == sample.capacity && space.points.len == sample.capacity);
                assert(space.triangles.len == triangles && space.hull.len == sample.capacity);
                previous_end = animation_storage_region_end(
                    base: base,
                    block_bytes: sample.expected_bytes,
                    prior_end: previous_end,
                    pointer: space.actions.ptr,
                    bytes: (usz)space.actions.len * AnimationActionId::size,
                    alignment: AnimationActionId::alignment,
                );
                previous_end = animation_storage_region_end(
                    base: base,
                    block_bytes: sample.expected_bytes,
                    prior_end: previous_end,
                    pointer: space.points.ptr,
                    bytes: (usz)space.points.len * Vec2::size,
                    alignment: Vec2::alignment,
                );
                previous_end = animation_storage_region_end(
                    base: base,
                    block_bytes: sample.expected_bytes,
                    prior_end: previous_end,
                    pointer: space.triangles.ptr,
                    bytes: (usz)space.triangles.len * BlendTriangleIndices::size,
                    alignment: BlendTriangleIndices::alignment,
                );
                previous_end = animation_storage_region_end(
                    base: base,
                    block_bytes: sample.expected_bytes,
                    prior_end: previous_end,
                    pointer: space.hull.ptr,
                    bytes: (usz)space.hull.len * BlendHullIndices::size,
                    alignment: BlendHullIndices::alignment,
                );
            }
            assert(base + sample.expected_bytes - previous_end < BlendSpace2D::alignment);
            io::printfn("capacity=%s payload=%s", sample.capacity, animation_storage_payload(sample.capacity));
            io::printfn("retained=%s align=%s", allocator.requested_bytes, allocator.requested_alignment);
        }
        assert(allocator.release_calls == 1 && allocator.outstanding == 0 && allocator.resize_calls == 0);
        assert(allocator.pointer == null);
    }
}
