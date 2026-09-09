module c3d::render;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::shader;
import gpu;
import std::math;

<*
 Byte alignment of every stream start inside a geometry block.
*>
const usz STREAM_ALIGNMENT = 16; // std430 vec4 alignment; keeps every stream readable by any reader

const usz PACKED_VEC3_BYTES @local = 12; // three floats, not a 16-byte std430 vec3; the BLAS reader wants this stride
$assert Vec3::size == PACKED_VEC3_BYTES;

<*
 Stages that read geometry blocks; the far side of every upload barrier.
*>
const gpu::StageMask CONSUMER_STAGES = { .vertex_shader, .fragment_shader, .compute }; // ray tracing adds a stage

<*
 Which streams a packed geometry carries; written to GeometryRoot.flags.
*>
bitstruct GeometryFlags : uint { // mirrored as GeometryRoot.flags in c3d_abi.glsl and GEOMETRY_HAS_* in vertex_pull.glsl
    bool has_normals  : 0;
    bool has_tangents : 1;
    bool has_uv0      : 2;
    bool has_uv1      : 3;
    bool has_colors   : 4;
    bool skinned      : 5;
    bool has_morphs   : 6;
    bool indices_u16  : 7;
}

<*
 Byte offsets and sizes of one packed geometry; equal layouts allow in-place reuse.
*>
struct GeometryLayout {
    usz           positions;
    usz           normals;
    usz           tangents;
    usz           uv0;
    usz           uv1;
    usz           colors;
    usz           joints;
    usz           weights;
    usz           morph_deltas;
    usz           custom_data;
    usz           indices;
    usz           total_bytes;
    uint          vertex_count;
    uint          index_count;
    uint          morph_count;
    uint          custom_stride;
    uint          index_stride;
    GeometryFlags flags;
}

<*
 Renderer-owned GPU mirror of one geometry record.
*>
struct GpuGeometry {
    GeometryId         asset;
    uint               revision;
    gpu::GpuAllocation allocation;
    gpu::GpuAddress    root;
    gpu::GpuSpan       positions;
    gpu::GpuSpan       indices;
    GeometryLayout     layout;
    Topology           topology;
    Aabb               bounds;
}

<*
 Upload the geometry now, or record its upload into the open frame.
 Completes without a window when no frame is open.
 @param [&inout] self : "Owns queued geometry copies and their submission."
 @return? c3d::INVALID_ID
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::UNSUPPORTED_FEATURE, gpu::COMMAND_RECORDING_ERROR, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::INVALID_RESOURCE_STATE, gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::WAIT_TIMEOUT
*>
fn void? Renderer.upload_geometry(&self, GeometryId geometry) {
    if (!self.assets.geometries.is_live(geometry)) return c3d::INVALID_ID~;
    if (self.frame_open) {
        ensure_geometry(self, geometry)!;
        return;
    }
    open_closed_frame_slot(self)!;
    defer catch discard_uploads(self);
    ensure_geometry(self, geometry)!;
    return submit_pending(self);
}

<*
 Offsets of every present stream, in stream order, each aligned after the root.
 @param [&in] geometry : "Positions present."
*>
fn GeometryLayout geometry_layout(Geometry* geometry) {
    uint vertex_count = (uint)geometry.positions.len;
    bool short_indices = vertex_count <= ushort::max;
    GeometryLayout layout = {
        .vertex_count  = vertex_count,
        .index_count   = (uint)geometry.indices.len,
        .morph_count   = (uint)geometry.targets.len,
        .custom_stride = geometry.custom_stride,
        .index_stride  = geometry.indices.len ? (short_indices ? (uint)ushort::size : (uint)uint::size) : 0,
        .flags         = {
            .has_normals  = geometry.normals.len > 0,
            .has_tangents = geometry.tangents.len > 0,
            .has_uv0      = geometry.uv0.len > 0,
            .has_uv1      = geometry.uv1.len > 0,
            .has_colors   = geometry.colors.len > 0,
            .skinned      = geometry.joints.len > 0,
            .has_morphs   = geometry.targets.len > 0,
            .indices_u16  = short_indices,
        },
    };
    usz cursor = align_up(GeometryRoot::size, STREAM_ALIGNMENT);
    layout.positions = place(&cursor, PACKED_VEC3_BYTES * vertex_count);
    if (layout.flags.has_normals) layout.normals = place(&cursor, PACKED_VEC3_BYTES * vertex_count);
    if (layout.flags.has_tangents) layout.tangents = place(&cursor, Vec4::size * vertex_count);
    if (layout.flags.has_uv0) layout.uv0 = place(&cursor, Vec2::size * vertex_count);
    if (layout.flags.has_uv1) layout.uv1 = place(&cursor, Vec2::size * vertex_count);
    if (layout.flags.has_colors) layout.colors = place(&cursor, Vec4::size * vertex_count);
    if (layout.flags.skinned) {
        layout.joints = place(&cursor, uint::size * vertex_count);
        layout.weights = place(&cursor, Vec4::size * vertex_count);
    }
    if (layout.flags.has_morphs) {
        layout.morph_deltas = place(&cursor, 2 * PACKED_VEC3_BYTES * vertex_count * layout.morph_count);
    }
    if (layout.custom_stride) layout.custom_data = place(&cursor, (usz)layout.custom_stride * vertex_count);
    if (layout.index_count) layout.indices = place(&cursor, (usz)layout.index_stride * layout.index_count);
    layout.total_bytes = cursor;
    return layout;
}

<*
 Write the root and every packed stream of the geometry into the block.
 @param block : "At least layout.total_bytes long."
 @param [&in] geometry : "The geometry the layout was computed from."
 @param [&in] layout : "Computed from the same geometry."
 @param base : "GPU address of the block's first byte."
*>
fn void write_geometry_block(char[] block, Geometry* geometry, GeometryLayout* layout, gpu::GpuAddress base) {
    GeometryRoot* root = (GeometryRoot*)block.ptr;
    *root = {
        .positions          = address_of(base, layout.positions),
        .normals            = address_of(base, layout.normals),
        .tangents           = address_of(base, layout.tangents),
        .uv0                = address_of(base, layout.uv0),
        .uv1                = address_of(base, layout.uv1),
        .colors             = address_of(base, layout.colors),
        .joints             = address_of(base, layout.joints),
        .weights            = address_of(base, layout.weights),
        .morph_deltas       = address_of(base, layout.morph_deltas),
        .custom_data        = address_of(base, layout.custom_data),
        .custom_stride      = layout.custom_stride,
        .vertex_count       = layout.vertex_count,
        .morph_target_count = layout.morph_count,
        .flags              = (uint)layout.flags,
    };
    copy_stream(block, layout.positions, geometry.positions);
    copy_stream(block, layout.normals, geometry.normals);
    copy_stream(block, layout.tangents, geometry.tangents);
    copy_stream(block, layout.uv0, geometry.uv0);
    copy_stream(block, layout.uv1, geometry.uv1);
    copy_stream(block, layout.colors, geometry.colors);
    copy_stream(block, layout.weights, geometry.weights);
    copy_stream(block, layout.custom_data, geometry.custom_data);
    if (layout.flags.skinned) {
        uint* packed = (uint*)&block[layout.joints];
        foreach (index, joints : geometry.joints) {
            packed[index] = (uint)joints.x | (uint)joints.y << 8 | (uint)joints.z << 16 | (uint)joints.w << 24;
        }
    }
    if (layout.flags.has_morphs) {
        usz target_bytes = PACKED_VEC3_BYTES * layout.vertex_count;
        usz offset = layout.morph_deltas;
        foreach (&target : geometry.targets) {
            copy_stream(block, offset, target.position_deltas);
            offset += target_bytes;
        }
        foreach (&target : geometry.targets) {
            copy_stream(block, offset, target.normal_deltas);
            offset += target_bytes;
        }
    }
    if (layout.index_count && layout.flags.indices_u16) {
        ushort* narrow = (ushort*)&block[layout.indices];
        foreach (index, value : geometry.indices) narrow[index] = (ushort)value;
    } else if (layout.index_count) {
        copy_stream(block, layout.indices, geometry.indices);
    }
}

fn GpuGeometry*? ensure_geometry(Renderer* renderer, GeometryId geometry) @private {
    GeometryAsset* record = renderer.assets.geometry(geometry);
    GpuGeometry* mirror = &renderer.geometries[geometry.index];
    bool same_asset = mirror.asset.index == geometry.index && mirror.asset.generation == geometry.generation;
    if (same_asset && mirror.revision == record.header.revision) return mirror;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    GeometryLayout layout = geometry_layout(&record.data);
    bool reuse = same_asset && mem::equals(&layout, &mirror.layout, GeometryLayout::size);
    if (reuse) {
        renderer.pending_overwrite = true;
    } else {
        gpu::AllocationDesc block_desc = {
            .size         = layout.total_bytes,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access       = { .graphics },
            .debug_name   = "geometry",
        };
        gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &block_desc)!;
        defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
        gpu::GpuSpan block = gpu::get_allocation_span(&renderer.device, allocation)!;
        gpu::GpuAddress address = gpu::get_span_address(&renderer.device, block)!;
        gpu::GpuSpan positions = block.checked_subspan(layout.positions, PACKED_VEC3_BYTES * layout.vertex_count)!;
        gpu::GpuSpan indices = layout.index_count
            ? block.checked_subspan(layout.indices, (usz)layout.index_stride * layout.index_count)!
            : (gpu::GpuSpan){};

        if (mirror.allocation.is_valid()) {
            renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = mirror.allocation });
        }
        mirror.allocation = allocation;
        mirror.root = address;
        mirror.positions = positions;
        mirror.indices = indices;
        mirror.asset = geometry;
        mirror.layout = layout;
        mirror.revision = 0;
    }

    gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, layout.total_bytes, STREAM_ALIGNMENT)!;
    write_geometry_block(
        block:    staging.bytes,
        geometry: &record.data,
        layout:   &layout,
        base:     mirror.root,
    );
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, mirror.allocation)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination.checked_subspan(0, layout.total_bytes)! });

    renderer.pending_geometry_uploads.push(geometry);
    mirror.asset = geometry;
    mirror.revision = record.header.revision;
    mirror.layout = layout;
    mirror.topology = record.data.topology;
    mirror.bounds = record.data.bounds;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)layout.total_bytes;
    return mirror;
}

fn void? record_pending_copies(Renderer* renderer, gpu::CommandList* commands) @private {
    if (renderer.pending_copies.len() || renderer.pending_texture_uploads.len()) renderer.uploads_recorded = true;
    record_texture_uploads(renderer, commands)!;
    if (!renderer.pending_copies.len()) return;
    if (renderer.pending_overwrite) {
        gpu::Barrier before_overwrite = { .before = CONSUMER_STAGES, .after = { .transfer } };
        gpu::cmd_barrier(commands, &before_overwrite)!;
        renderer.pending_overwrite = false;
    }
    foreach (&copy : renderer.pending_copies) gpu::cmd_copy_buffer(commands, copy)!;
    gpu::Barrier to_consumers = { .before = { .transfer }, .after = CONSUMER_STAGES };
    gpu::cmd_barrier(commands, &to_consumers)!;
    renderer.pending_copies.clear();
}

fn void? open_closed_frame_slot(Renderer* renderer) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    if (slot.done.is_valid()) gpu::wait_completion(slot.done)!;
    drain_retired(&renderer.device, &slot.retire);
    return reset_upload_ring(renderer, slot);
}

fn void? submit_pending(Renderer* renderer) @private {
    defer catch discard_uploads(renderer);
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::CommandList commands = gpu::begin_commands(&slot.allocator)!;
    defer catch (void)gpu::discard_commands(&commands);
    record_pending_copies(renderer, &commands)!;
    slot.upload.flush(&renderer.device)!;

    gpu::ExecutableCommandList[1] executable = { gpu::end_commands(&commands)! };
    defer catch (void)gpu::discard_executable_commands(&executable[0]);
    gpu::SubmitDesc submit = { .command_lists = executable[..] };
    slot.done = gpu::submit(renderer.graphics, &submit)!;
    commit_uploads(renderer, slot);
    return gpu::wait_completion(slot.done);
}

fn void sweep_geometries(Renderer* renderer) @private {
    foreach (&mirror : renderer.geometries) {
        if (!mirror.allocation.is_valid() || renderer.assets.geometries.is_live(mirror.asset)) continue;
        renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = mirror.allocation });
        *mirror = {};
    }
}

fn void free_geometries(Renderer* renderer) @private {
    foreach (&mirror : renderer.geometries) {
        if (mirror.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &mirror.allocation);
    }
    alloc::free(renderer.allocator, renderer.geometries.ptr);
    renderer.pending_copies.free();
}

fn usz place(usz* cursor, usz bytes) @local {
    usz offset = align_up(*cursor, STREAM_ALIGNMENT);
    *cursor = offset + bytes;
    return offset;
}

fn gpu::GpuAddress address_of(gpu::GpuAddress base, usz offset) @local {
    return offset ? base + (gpu::GpuAddress)offset : (gpu::GpuAddress)0;
}

macro copy_stream(char[] block, usz offset, slice) @local {
    if (slice.len) mem::copy(&block[offset], slice.ptr, slice.len * $Typeof(slice[0])::size);
}
