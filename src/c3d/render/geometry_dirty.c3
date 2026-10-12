module c3d::render;

import c3d::asset;
import c3d::geometry;
import gpu;
import std::math;

struct StreamSource @local {
    usz    offset;
    usz    stride;
    char[] bytes; // as stored in the block; empty for joints, which are packed while staging
}

fn usz? stage_dirty_geometry(
    Renderer* renderer,
    Frame* slot,
    GpuGeometry* mirror,
    GeometryAsset* record,
) @private {
    gpu::GpuSpan block = gpu::get_allocation_span(&renderer.device, mirror.allocation)!;
    usz staged;
    foreach (stream : GeometryStream::values) {
        VertexRange range = record.dirty.ranges[stream.ordinal];
        if (range.is_empty()) continue;

        StreamSource source = stream_source(&record.data, &mirror.layout, stream);
        usz count = (usz)(range.end - range.first);
        usz bytes = count * source.stride;
        gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;

        if (stream == GeometryStream.JOINTS) {
            pack_joints(
                packed: (uint*)staging.bytes.ptr,
                joints: record.data.joints[range.first:count],
                wide:   mirror.layout.flags.joints_u16,
            );
        } else {
            mem::copy(staging.bytes.ptr, &source.bytes[range.first * source.stride], (sz)bytes);
        }

        renderer.pending_copies.push({
            .src = staging.span,
            .dst = block.checked_subspan(source.offset + range.first * source.stride, bytes)!,
        });
        staged += bytes;
    }
    return staged;
}

fn StreamSource stream_source(Geometry* geometry, GeometryLayout* layout, GeometryStream stream) @local {
    switch (stream) {
        case POSITIONS:
            return { .offset = layout.positions, .stride = PACKED_VEC3_BYTES, .bytes = raw_bytes(geometry.positions) };
        case NORMALS:
            return { .offset = layout.normals, .stride = PACKED_VEC3_BYTES, .bytes = raw_bytes(geometry.normals) };
        case TANGENTS:
            return { .offset = layout.tangents, .stride = Vec4::size, .bytes = raw_bytes(geometry.tangents) };
        case UV0:
            return { .offset = layout.uv0, .stride = Vec2::size, .bytes = raw_bytes(geometry.uv0) };
        case UV1:
            return { .offset = layout.uv1, .stride = Vec2::size, .bytes = raw_bytes(geometry.uv1) };
        case COLORS:
            return { .offset = layout.colors, .stride = Vec4::size, .bytes = raw_bytes(geometry.colors) };
        case JOINTS:
            return { .offset = layout.joints, .stride = (layout.flags.joints_u16 ? 2 : 1) * uint::size };
        case WEIGHTS:
            return { .offset = layout.weights, .stride = Vec4::size, .bytes = raw_bytes(geometry.weights) };
        case CUSTOM:
            return { .offset = layout.custom_data, .stride = layout.custom_stride, .bytes = geometry.custom_data };
    }
}

macro raw_bytes(slice) @local => ((char*)slice.ptr)[:slice.len * $Typeof(slice[0])::size];
