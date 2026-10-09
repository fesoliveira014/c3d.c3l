module c3d::render::test_geometry_ranges;

import c3d::geometry;
import c3d::render @public;
import gpu;
import std::math;

fn Geometry range_geometry(Allocator allocator, uint vertices, bool wide_joints) @local {
    Geometry geometry = {
        .positions = alloc::new_array(allocator, Vec3, vertices),
        .normals = alloc::new_array(allocator, Vec3, vertices),
        .tangents = alloc::new_array(allocator, Vec4, vertices),
        .uv0 = alloc::new_array(allocator, Vec2, vertices),
        .uv1 = alloc::new_array(allocator, Vec2, vertices),
        .colors = alloc::new_array(allocator, Vec4, vertices),
        .joints = alloc::new_array(allocator, ushort[<4>], vertices),
        .weights = alloc::new_array(allocator, Vec4, vertices),
        .indices = alloc::new_array(allocator, uint, vertices),
        .targets = alloc::new_array(allocator, MorphTarget, 2),
        .custom_stride = 7,
        .custom_data = alloc::new_array(allocator, char, (sz)vertices * 7),
    };
    foreach (index, &position : geometry.positions) {
        *position = { (float)index, (float)(index % 7), -(float)index };
        geometry.normals[index] = { 0, 1, 0 };
        geometry.tangents[index] = { 1, 0, 0, -1 };
        geometry.uv0[index] = { (float)index, 0.25f };
        geometry.uv1[index] = { 0.75f, (float)index };
        geometry.colors[index] = { 1, 0.25f, 0.5f, 1 };
        geometry.joints[index] = wide_joints ? (ushort[<4>]){ 300, 1, 2, 65535 } : (ushort[<4>]){ 4, 3, 2, 255 };
        geometry.weights[index] = { 1, 0, 0, 0 };
        geometry.indices[index] = vertices - (uint)index - 1;
    }
    foreach (index, &value : geometry.custom_data) *value = (char)(index % 251);
    foreach (index, &target : geometry.targets) {
        target.position_deltas = alloc::new_array(allocator, Vec3, vertices);
        target.normal_deltas = alloc::new_array(allocator, Vec3, vertices);
        foreach (vertex, &delta : target.position_deltas) {
            *delta = { (float)vertex, (float)index, 0.125f };
            target.normal_deltas[vertex] = { 0.25f, (float)vertex, (float)index };
        }
    }
    return geometry;
}

fn void compare_geometry_ranges(Geometry* geometry, usz[] allowances) @local {
    GeometryLayout layout = render::geometry_layout(geometry);
    gpu::GpuAddress base = (gpu::GpuAddress)0x1234000;
    char[] expected = alloc::new_array(tmem, char, (sz)layout.total_bytes);
    render::write_geometry_block(
        block: expected,
        geometry: geometry,
        layout: &layout,
        base: base,
    );
    foreach (configured : allowances) {
        usz allowance = configured ? configured : usz::max;
        char[] actual = alloc::new_array(tmem, char, (sz)layout.total_bytes);
        usz offset;
        while (offset < layout.total_bytes) {
            GeometryPrepareRange range = render::geometry_prepare_range(&layout, offset, allowance);
            assert(range.offset == offset && range.bytes > 0 && range.bytes <= allowance);
            assert(range.bytes <= render::GEOMETRY_PREPARE_RANGE_BYTES);
            assert(range.bytes >= range.minimum);
            if (offset + range.bytes < layout.total_bytes) assert(range.bytes % render::STREAM_ALIGNMENT == 0);
            render::write_geometry_range(
                destination: actual[offset:range.bytes],
                geometry: geometry,
                layout: &layout,
                base: base,
                offset: offset,
            );
            offset += range.bytes;
        }
        assert(actual == expected);
    }
    usz[5] probes = { 1, layout.joints + 3, layout.indices + 1, layout.morph_deltas + 13, layout.custom_data + 3 };
    foreach (offset : probes) {
        usz bytes = math::min((usz)19, layout.total_bytes - offset);
        char[] actual = alloc::new_array(tmem, char, (sz)bytes);
        render::write_geometry_range(
            destination: actual,
            geometry: geometry,
            layout: &layout,
            base: base,
            offset: offset,
        );
        assert(actual == expected[offset:bytes]);
    }
}

fn void test_geometry_ranges_match_all_narrow_packed_streams() @test {
    @pool() {
        Geometry geometry = range_geometry(tmem, 23, false);
        usz[8] allowances = { 16, 31, 64, 65536, 1 << 20, 8 << 20, usz::max, 0 };
        compare_geometry_ranges(&geometry, allowances[..]);
    };
}

fn void test_geometry_ranges_match_wide_joints_and_indices() @test {
    @pool() {
        Geometry geometry = range_geometry(tmem, 70001, true);
        usz[6] allowances = { 65536, 65537, 1 << 20, 8 << 20, usz::max, 0 };
        GeometryLayout layout = render::geometry_layout(&geometry);
        assert(layout.flags.joints_u16 && !layout.flags.indices_u16);
        compare_geometry_ranges(&geometry, allowances[..]);
    };
}

fn void test_geometry_ranges_block_at_alignment_and_keep_final_tail() @test {
    Vec3[1] positions = { { 1, 2, 3 } };
    char[1] payload = { 17 };
    Geometry geometry = { .positions = positions[..], .custom_data = payload[..], .custom_stride = 1 };
    GeometryLayout layout = render::geometry_layout(&geometry);
    assert(layout.total_bytes % render::STREAM_ALIGNMENT == uint::size);
    GeometryPrepareRange blocked = render::geometry_prepare_range(&layout, 0, render::STREAM_ALIGNMENT - 1);
    assert(blocked.bytes == 0 && blocked.minimum == render::STREAM_ALIGNMENT);
    GeometryPrepareRange depleted = render::geometry_prepare_range(&layout, 0, 0);
    assert(depleted.bytes == 0 && depleted.minimum == render::STREAM_ALIGNMENT);
    usz offset = layout.total_bytes - uint::size;
    GeometryPrepareRange final_range = render::geometry_prepare_range(&layout, offset, uint::size);
    assert(final_range.bytes == uint::size && final_range.minimum == uint::size);
    GeometryPrepareRange completed = render::geometry_prepare_range(&layout, layout.total_bytes, 0);
    assert(completed.bytes == 0 && completed.minimum == 0);
}
