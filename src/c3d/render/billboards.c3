module c3d::render;

import c3d::geometry;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const uint BILLBOARD_VERTICES @private = 6;

$assert BillboardFacing.CAMERA.ordinal == shader::BILLBOARD_CAMERA;
$assert BillboardFacing.DIRECTIONAL.ordinal == shader::BILLBOARD_DIRECTIONAL;

<*
 Pack world-space billboard records in source-array order.
 @param [out] records : "At least batch.count records."
 @param node_world : "Published affine node transform."
 @param [&in] batch : "Valid billboard records."
 @require records.len >= batch.count
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
        };
    }
}

fn GpuGeometry*? acquire_billboard_geometry(Renderer* renderer) @private {
    GpuGeometry* mirror = &renderer.billboard_geometry;
    if (mirror.revision) return mirror;
    Vec3[BILLBOARD_VERTICES] positions = {
        { -0.5f, -0.5f, 0 }, { 0.5f, -0.5f, 0 }, { 0.5f, 0.5f, 0 },
        { -0.5f, -0.5f, 0 }, { 0.5f, 0.5f, 0 }, { -0.5f, 0.5f, 0 },
    };
    Vec2[BILLBOARD_VERTICES] coordinates = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 0 }, { 1, 1 }, { 0, 1 } };
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
        capacity: (uint)batch.billboards.len,
        record_size: BillboardGpu::size,
    )!;
    usz bytes = (usz)batch.count * BillboardGpu::size;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
    pack_billboard_records(((BillboardGpu*)staging.bytes.ptr)[:batch.count], world, batch);
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.allocation)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination.checked_subspan(0, bytes)! });
    renderer.pending_instance_uploads.push(index);
    slot.revision = batch.revision;
    slot.world = world;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)bytes;
}
