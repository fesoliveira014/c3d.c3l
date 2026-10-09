module c3d::render;

import c3d::geometry;
import c3d::shader;
import gpu;
import std::math;

const usz GEOMETRY_PREPARE_RANGE_BYTES @private = 64 << 10; // caps packing spans between cooperative time checks

struct GeometryPrepareRange @private {
    usz offset;
    usz bytes;
    usz minimum;
}

struct GeometryElementRange @local {
    usz first;
    usz end;
}

fn GeometryPrepareRange geometry_prepare_range(GeometryLayout* layout, usz offset, usz allowance) @private {
    usz remaining = layout.total_bytes - offset;
    usz minimum = math::min(remaining, STREAM_ALIGNMENT);
    if (allowance < minimum) return { .offset = offset, .minimum = minimum };
    usz bytes = math::min(math::min(remaining, allowance), GEOMETRY_PREPARE_RANGE_BYTES);
    if (bytes < remaining) bytes -= bytes % STREAM_ALIGNMENT;
    return { .offset = offset, .bytes = bytes, .minimum = minimum };
}

<*
 Pack only the specified byte range, including zero padding and partial converted elements.
 @param [&in] geometry : "Borrowed source streams."
 @param [&in] layout : "Offsets and widths of the packed source."
 @require offset + destination.len <= layout.total_bytes
*>
fn void write_geometry_range(
    char[] destination,
    Geometry* geometry,
    GeometryLayout* layout,
    gpu::GpuAddress base,
    usz offset,
) @private {
    destination[..] = (char)0;
    GeometryRoot root = geometry_root(layout, base);
    copy_geometry_range_bytes(
        destination: destination,
        offset: offset,
        stream_offset: 0,
        source: ((char*)&root)[:GeometryRoot::size],
    );
    copy_geometry_range_stream(
        destination: destination,
        offset: offset,
        stream_offset: layout.positions,
        stream: geometry.positions,
    );
    copy_geometry_range_stream(
        destination: destination,
        offset: offset,
        stream_offset: layout.normals,
        stream: geometry.normals,
    );
    copy_geometry_range_stream(
        destination: destination,
        offset: offset,
        stream_offset: layout.tangents,
        stream: geometry.tangents,
    );
    copy_geometry_range_stream(
        destination: destination,
        offset: offset,
        stream_offset: layout.uv0,
        stream: geometry.uv0,
    );
    copy_geometry_range_stream(
        destination: destination,
        offset: offset,
        stream_offset: layout.uv1,
        stream: geometry.uv1,
    );
    copy_geometry_range_stream(
        destination: destination,
        offset: offset,
        stream_offset: layout.colors,
        stream: geometry.colors,
    );
    copy_geometry_range_stream(
        destination: destination,
        offset: offset,
        stream_offset: layout.weights,
        stream: geometry.weights,
    );
    copy_geometry_range_stream(
        destination: destination,
        offset: offset,
        stream_offset: layout.custom_data,
        stream: geometry.custom_data,
    );

    if (layout.flags.skinned) {
        usz joint_bytes = layout.flags.joints_u16 ? 2 * uint::size : uint::size;
        GeometryElementRange range = geometry_range_elements(
            offset: offset,
            bytes: destination.len,
            stream_offset: layout.joints,
            count: geometry.joints.len,
            stride: joint_bytes,
        );
        for (usz index = range.first; index < range.end; index++) {
            ushort[<4>] joints = geometry.joints[index];
            uint[2] packed;
            if (layout.flags.joints_u16) {
                packed[0] = (uint)joints.x | (uint)joints.y << 16;
                packed[1] = (uint)joints.z | (uint)joints.w << 16;
            } else {
                packed[0] = (uint)joints.x | (uint)joints.y << 8 | (uint)joints.z << 16 | (uint)joints.w << 24;
            }
            copy_geometry_range_bytes(
                destination: destination,
                offset: offset,
                stream_offset: layout.joints + index * joint_bytes,
                source: ((char*)&packed)[:joint_bytes],
            );
        }
    }

    if (layout.flags.has_morphs) {
        usz target_bytes = Vec3::size * layout.vertex_count;
        GeometryElementRange range = geometry_range_elements(
            offset: offset,
            bytes: destination.len,
            stream_offset: layout.morph_deltas,
            count: 2 * (usz)layout.morph_count,
            stride: target_bytes,
        );
        for (usz index = range.first; index < range.end; index++) {
            bool normals = index >= layout.morph_count;
            MorphTarget* target = &geometry.targets[normals ? index - layout.morph_count : index];
            Vec3[] deltas = normals ? target.normal_deltas : target.position_deltas;
            copy_geometry_range_stream(
                destination: destination,
                offset: offset,
                stream_offset: layout.morph_deltas + index * target_bytes,
                stream: deltas,
            );
        }
    }

    if (layout.index_count && layout.flags.indices_u16) {
        GeometryElementRange range = geometry_range_elements(
            offset: offset,
            bytes: destination.len,
            stream_offset: layout.indices,
            count: geometry.indices.len,
            stride: ushort::size,
        );
        for (usz index = range.first; index < range.end; index++) {
            ushort value = (ushort)geometry.indices[index];
            copy_geometry_range_bytes(
                destination: destination,
                offset: offset,
                stream_offset: layout.indices + index * ushort::size,
                source: ((char*)&value)[:ushort::size],
            );
        }
    } else if (layout.index_count) {
        copy_geometry_range_stream(
            destination: destination,
            offset: offset,
            stream_offset: layout.indices,
            stream: geometry.indices,
        );
    }
}

fn GeometryElementRange geometry_range_elements(
    usz offset,
    usz bytes,
    usz stream_offset,
    usz count,
    usz stride,
) @local {
    if (!count || offset + bytes <= stream_offset || offset >= stream_offset + count * stride) return {};
    usz first = math::max(offset, stream_offset) - stream_offset;
    usz end = math::min(offset + bytes, stream_offset + count * stride) - stream_offset;
    return { .first = first / stride, .end = (end + stride - 1) / stride };
}

fn void copy_geometry_range_bytes(
    char[] destination,
    usz offset,
    usz stream_offset,
    char[] source,
) @local {
    usz first = math::max(offset, stream_offset);
    usz end = math::min(offset + destination.len, stream_offset + source.len);
    if (first >= end) return;
    mem::copy(destination.ptr + (sz)(first - offset), source.ptr + (sz)(first - stream_offset), (sz)(end - first));
}

macro copy_geometry_range_stream(
    char[] destination,
    usz offset,
    usz stream_offset,
    stream,
) @local {
    if (stream.len) copy_geometry_range_bytes(
        destination: destination,
        offset: offset,
        stream_offset: stream_offset,
        source: ((char*)stream.ptr)[:stream.len * $Typeof(stream[0])::size],
    );
}