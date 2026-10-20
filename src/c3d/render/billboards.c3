module c3d::render;

import c3d::geometry;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const uint BILLBOARD_VERTICES @private = 6;
const usz BILLBOARD_ATLAS_BYTES @private = BillboardAtlasGpu::size; // precedes the records in the slot allocation
$assert BILLBOARD_ATLAS_BYTES % STREAM_ALIGNMENT == 0;

$assert BillboardFacing.CAMERA.ordinal == shader::BILLBOARD_CAMERA;
$assert BillboardFacing.DIRECTIONAL.ordinal == shader::BILLBOARD_DIRECTIONAL;

$assert BillboardRecord::size == BillboardGpu::size;
$assert $reflect(BillboardRecord.position_width).offset == $reflect(BillboardGpu.position_width).offset;
$assert $reflect(BillboardRecord.direction_height).offset == $reflect(BillboardGpu.direction_height).offset;
$assert $reflect(BillboardRecord.color).offset == $reflect(BillboardGpu.color).offset;
$assert $reflect(BillboardRecord.rotation).offset == $reflect(BillboardGpu.rotation).offset;
$assert $reflect(BillboardRecord.facing).offset == $reflect(BillboardGpu.facing).offset;
$assert $reflect(BillboardRecord.frame).offset == $reflect(BillboardGpu.frame).offset;

<*
 Pack world-space billboard records in source-array order.
 @param [out] records : "At least batch.count records."
 @param node_world : "Published affine node transform."
 @param [&in] batch : "A BILLBOARDS batch with valid records."
 @require records.len >= batch.count
 @require batch.source == BillboardSource.BILLBOARDS
*>
fn void pack_billboard_records(BillboardGpu[] records, Mat4 node_world, BillboardBatch* batch) {
    foreach (index, billboard : batch.billboards[:batch.count]) {
        Billboard world = scene::world_billboard(node_world, billboard);
        records[index] = {
            .position_width = { world.position.x, world.position.y, world.position.z, world.size.x },
            .direction_height = { world.direction.x, world.direction.y, world.direction.z, world.size.y },
            .color = world.color,
            .rotation = world.rotation,
            .facing = (uint)batch.facing.ordinal,
            .frame = world.frame,
        };
    }
}

<*
 Copy a RECORDS batch's live records relative to the frame origin.
 @param [out] records : "At least batch.count records."
 @param [&in] batch : "A RECORDS batch."
 @require records.len >= batch.count
 @require batch.source == BillboardSource.RECORDS
*>
fn void copy_billboard_records(BillboardGpu[] records, BillboardBatch* batch, Vec3 origin) {
    foreach (index, &record : batch.records[:batch.count]) {
        Vec4 position = record.position_width;
        records[index] = {
            .position_width = { position.x - origin.x, position.y - origin.y, position.z - origin.z, position.w },
            .direction_height = record.direction_height,
            .color = record.color,
            .rotation = record.rotation,
            .facing = record.facing,
            .frame = record.frame,
        };
    }
}

fn BillboardAtlasGpu pack_billboard_atlas(BillboardAtlas atlas) @private {
    return {
        .columns = atlas.columns,
        .rows = atlas.rows,
        .frame_count = atlas.frame_count,
        .inset = { atlas.inset.x, atlas.inset.y },
    };
}

fn gpu::GpuAddress? billboard_atlas_address(
    Renderer* renderer,
    BillboardBatch* batch,
    gpu::GpuAddress records,
) @private {
    if (batch.atlas.columns == 0) return (gpu::GpuAddress)0;
    if (batch.source != BillboardSource.DEVICE) return (gpu::GpuAddress)((ulong)records - BILLBOARD_ATLAS_BYTES);

    // The application's buffer has no room before its records, so the header rides the frame's ring.
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan header = frame.upload.take(&renderer.device, BILLBOARD_ATLAS_BYTES, STREAM_ALIGNMENT)!;
    *(BillboardAtlasGpu*)header.bytes.ptr = pack_billboard_atlas(batch.atlas);
    return header.address;
}

fn bool candidate_device_billboards(MeshCandidate* candidate) @private {
    return candidate.billboards && candidate.billboards.source == BillboardSource.DEVICE;
}

fn bool device_billboards_lost(Renderer* renderer, MeshCandidate* candidate) @private {
    return candidate_device_billboards(candidate) && !renderer.buffers.is_live(candidate.billboards.device.buffer);
}

fn gpu::GpuAddress device_billboard_records(Renderer* renderer, BillboardBatch* batch) @private {
    return (gpu::GpuAddress)((ulong)renderer.buffer_address(batch.device.buffer) + batch.device.records_offset);
}

fn gpu::GpuAddress device_billboard_count(Renderer* renderer, MeshCandidate* candidate) @private {
    if (!candidate_device_billboards(candidate)) return (gpu::GpuAddress)0;

    BillboardDevice* device = &candidate.billboards.device;
    return (gpu::GpuAddress)((ulong)renderer.buffer_address(device.buffer) + device.count_offset);
}

fn GpuGeometry*? acquire_billboard_geometry(Renderer* renderer) @private {
    GpuGeometry* mirror = &renderer.billboard_geometry;
    if (mirror.revision) return mirror;
    Vec3[BILLBOARD_VERTICES] positions = {
        { -0.5f, -0.5f, 0 }, { 0.5f, -0.5f, 0 }, { 0.5f, 0.5f, 0 },
        { -0.5f, -0.5f, 0 }, { 0.5f, 0.5f, 0 }, { -0.5f, 0.5f, 0 },
    };
    Vec2[BILLBOARD_VERTICES] coordinates = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 1 }, { 1, 0 }, { 0, 0 } };
    Vec3[BILLBOARD_VERTICES] normals;
    Vec4[BILLBOARD_VERTICES] tangents;
    Vec4[BILLBOARD_VERTICES] colors;
    normals[..] = { 0, 0, 1 };
    tangents[..] = { 1, 0, 0, 1 };
    colors[..] = { 1, 1, 1, 1 };
    Geometry geometry = {
        .topology = Topology.TRIANGLES,
        .positions = positions[..],
        .normals = normals[..],
        .tangents = tangents[..],
        .uv0 = coordinates[..],
        .uv1 = coordinates[..],
        .colors = colors[..],
        .bounds = { .min = { -0.5f, -0.5f, 0 }, .max = { 0.5f, 0.5f, 0 } },
    };
    GeometryLayout layout = geometry_layout(&geometry);
    if (!mirror.allocation.is_valid()) {
        gpu::AllocationDesc desc = {
            .size = layout.total_bytes,
            .alignment = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access = { .graphics },
            .debug_name = "billboard_quad",
        };
        gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
        defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
        gpu::GpuSpan block = gpu::get_allocation_span(&renderer.device, allocation)!;
        gpu::GpuAddress address = gpu::get_span_address(&renderer.device, block)!;
        mirror.positions = block.checked_subspan(layout.positions, BILLBOARD_VERTICES * Vec3::size)!;
        mirror.allocation = allocation;
        mirror.root = address;
    } else {
        renderer.pending_overwrite = true;
    }
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, layout.total_bytes, STREAM_ALIGNMENT)!;
    write_geometry_block(
        block: staging.bytes,
        geometry: &geometry,
        layout: &layout,
        base: mirror.root,
    );
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, mirror.allocation)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination });
    mirror.layout = layout;
    mirror.topology = geometry.topology;
    mirror.bounds = geometry.bounds;
    mirror.revision = 1;
    renderer.billboard_geometry_pending = true;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)layout.total_bytes;
    return mirror;
}

fn void free_billboard_geometry(Renderer* renderer) @private {
    if (renderer.billboard_geometry.allocation.is_valid()) {
        (void)gpu::free_allocation(&renderer.device, &renderer.billboard_geometry.allocation);
    }
    renderer.billboard_geometry = {};
}

fn void? upload_billboard_records(
    Renderer* renderer,
    uint index,
    BillboardBatch* batch,
    Mat4 world,
) @private {
    GpuInstances* slot = &renderer.instances.slots[index];
    acquire_instance_records(
        renderer: renderer,
        slot: slot,
        capacity: batch.capacity(),
        record_size: BillboardGpu::size,
        header_size: BILLBOARD_ATLAS_BYTES,
    )!;
    usz bytes = BILLBOARD_ATLAS_BYTES + (usz)batch.count * BillboardGpu::size;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
    *(BillboardAtlasGpu*)staging.bytes.ptr = pack_billboard_atlas(batch.atlas);
    BillboardGpu[] records = ((BillboardGpu*)(staging.bytes.ptr + BILLBOARD_ATLAS_BYTES))[:batch.count];
    if (batch.source == BillboardSource.RECORDS) {
        copy_billboard_records(records, batch, renderer.frame_origin);
    } else {
        pack_billboard_records(records, maths::rebase(world, renderer.frame_origin), batch);
    }
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.allocation)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination.checked_subspan(0, bytes)! });
    renderer.pending_instance_uploads.push(index);
    slot.revision = batch.revision;
    slot.world = world;
    slot.origin = renderer.frame_origin;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)bytes;
}
