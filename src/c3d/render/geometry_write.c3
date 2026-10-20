module c3d::render;

import c3d;
import c3d::asset;
import c3d::maths;
import gpu;

const GeometryStreams GEOMETRY_WRITE_STREAMS @private = { .positions = true, .normals = true, .tangents = true };

<*
 One geometry a dispatch writes; the dispatch owns the named streams until it completes.
*>
struct GeometryWrite {
    GeometryId      geometry;
    GeometryStreams streams;      // positions, normals and tangents only
    Aabb            local_bounds; // conservative; replaces the geometry's bounds until the next CPU revision
}

<*
 Device address of one vertex stream of a resident geometry, valid for the current frame.
 Positions and normals are packed three-float vectors, tangents four-float vectors.
 @param [&inout] self : "Records a pending CPU revision of the geometry first."
 @require self.frame_open
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, Renderer.upload_geometry!
*>
fn gpu::GpuAddress? Renderer.geometry_stream_address(&self, GeometryId geometry, GeometryStream stream) {
    if (!self.assets.geometries.is_live(geometry)) return c3d::INVALID_ID~;
    if (!geometry_resident(self, geometry)) return c3d::INVALID_ARGUMENT~;

    GpuGeometry* mirror = &self.geometries[geometry.index];
    if (!stream_present(&mirror.layout, stream)) return c3d::INVALID_ARGUMENT~;
    if (!geometry_current(self, geometry)) resolve_geometry(self, geometry)!;
    return mirror.root + (gpu::GpuAddress)stream_offset(&mirror.layout, stream);
}

fn bool geometry_resident(Renderer* renderer, GeometryId geometry) @private {
    GpuGeometry* mirror = &renderer.geometries[geometry.index];
    return c3d::same_id(mirror.asset, geometry) && mirror.revision != 0;
}

fn bool stream_present(GeometryLayout* layout, GeometryStream stream) @private {
    switch (stream) {
        case POSITIONS: return true;
        case NORMALS: return layout.flags.has_normals;
        case TANGENTS: return layout.flags.has_tangents;
        case UV0: return layout.flags.has_uv0;
        case UV1: return layout.flags.has_uv1;
        case COLORS: return layout.flags.has_colors;
        case JOINTS:
        case WEIGHTS: return layout.flags.skinned;
        case CUSTOM: return layout.custom_stride != 0;
    }
}

fn usz stream_offset(GeometryLayout* layout, GeometryStream stream) @private {
    switch (stream) {
        case POSITIONS: return layout.positions;
        case NORMALS: return layout.normals;
        case TANGENTS: return layout.tangents;
        case UV0: return layout.uv0;
        case UV1: return layout.uv1;
        case COLORS: return layout.colors;
        case JOINTS: return layout.joints;
        case WEIGHTS: return layout.weights;
        case CUSTOM: return layout.custom_data;
    }
}

// Decides every fault before the dispatch records or stages anything.
fn void? check_geometry_writes(Renderer* renderer, GeometryWrite[] writes) @private {
    foreach (index, &write : writes) {
        if (!renderer.assets.geometries.is_live(write.geometry)) return c3d::INVALID_ID~;
        foreach (&earlier : writes[:index]) {
            if (c3d::same_id(earlier.geometry, write.geometry)) return c3d::INVALID_ARGUMENT~;
        }

        uint streams = (uint)write.streams;
        if (streams == 0 || (streams & ~(uint)GEOMETRY_WRITE_STREAMS) != 0) return c3d::INVALID_ARGUMENT~;
        if (!geometry_resident(renderer, write.geometry)) return c3d::INVALID_ARGUMENT~;

        GeometryLayout* layout = &renderer.geometries[write.geometry.index].layout;
        if (write.streams.normals && !layout.flags.has_normals) return c3d::INVALID_ARGUMENT~;
        if (write.streams.tangents && !layout.flags.has_tangents) return c3d::INVALID_ARGUMENT~;
    }
}

// A CPU revision still waiting for its upload would otherwise land after the write and overwrite it.
fn void? resolve_geometry_writes(Renderer* renderer, GeometryWrite[] writes) @private {
    foreach (&write : writes) {
        if (!geometry_current(renderer, write.geometry)) resolve_geometry(renderer, write.geometry)!;
    }
}

// The first write of a frame keeps the positions the previous frame ended with.
fn void? record_geometry_history(Renderer* renderer, GeometryWrite[] writes) @private {
    ulong frame = renderer.frame_index + 1;
    bool barriered;
    foreach (&write : writes) {
        if (!write.streams.positions) continue;

        GpuGeometry* mirror = &renderer.geometries[write.geometry.index];
        if (mirror.history_frame == frame) continue;

        if (!barriered) {
            gpu::Barrier before_copy = { .before = renderer.consumer_stages, .after = { .transfer } };
            before_copy.before.transfer = true;
            gpu::cmd_barrier(&renderer.commands, &before_copy)!;
            barriered = true;
        }
        acquire_previous_positions(renderer, mirror)!;

        usz bytes = PACKED_VEC3_BYTES * mirror.layout.vertex_count;
        gpu::GpuSpan previous = gpu::get_allocation_span(&renderer.device, mirror.previous)!;
        gpu::BufferCopyDesc copy = {
            .src = mirror.positions,
            .dst = previous.checked_subspan(0, bytes)!,
        };
        gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
        mirror.history_frame = frame;
    }
    if (barriered) {
        gpu::Barrier after_copy = { .before = { .transfer }, .after = renderer.consumer_stages };
        gpu::cmd_barrier(&renderer.commands, &after_copy)!;
    }
}

fn void? acquire_previous_positions(Renderer* renderer, GpuGeometry* mirror) @private {
    if (mirror.previous.is_valid()) return;

    gpu::AllocationDesc desc = {
        .size         = PACKED_VEC3_BYTES * mirror.layout.vertex_count,
        .alignment    = STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "geometry_previous_positions",
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
    defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
    gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, allocation)!;

    mirror.previous_positions = gpu::get_span_address(&renderer.device, span)!;
    mirror.previous = allocation;
}

// Bounds are the caller's from here on, and the block holds data the arrays no longer describe.
fn void note_geometry_writes(Renderer* renderer, GeometryWrite[] writes) @private {
    foreach (&write : writes) {
        GpuGeometry* mirror = &renderer.geometries[write.geometry.index];
        mirror.device_revision++;
        mirror.device_written = true;
        mirror.bounds = write.local_bounds;
        renderer.assets.override_geometry_bounds(write.geometry, write.local_bounds);
    }
}

// An abandoned recording never copied the history its stamp claims.
fn void forget_geometry_history(Renderer* renderer) @private {
    foreach (&mirror : renderer.geometries) mirror.history_frame = 0;
}
