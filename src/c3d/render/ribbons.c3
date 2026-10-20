module c3d::render;

import c3d::asset;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import gpu;
import std::math;

$assert scene::RIBBON_BREAK == shader::RIBBON_POINT_BREAK;

<*
 Pack world-space ribbon points in source order, then the terminating break point.
 @param [out] records : "At least batch.count + 1 records."
 @param node_world : "Published affine node transform."
 @param [&in] batch : "Valid ribbon points."
 @require records.len > batch.count
*>
fn void pack_ribbon_records(RibbonPointGpu[] records, Mat4 node_world, RibbonBatch* batch) {
    foreach (index, point : batch.points[:batch.count]) {
        RibbonPoint world = scene::world_ribbon_point(node_world, point);
        records[index] = {
            .position_width = { world.position.x, world.position.y, world.position.z, world.width },
            .color = world.color,
            .v = world.v,
            .flags = world.flags,
        };
    }
    records[batch.count] = { .flags = shader::RIBBON_POINT_BREAK };
}

fn void? upload_ribbon_records(
    Renderer* renderer,
    uint index,
    RibbonBatch* batch,
    Mat4 world,
) @private {
    GpuInstances* slot = &renderer.instances.slots[index];
    acquire_instance_records(
        renderer: renderer,
        slot: slot,
        capacity: (uint)batch.points.len + 1,
        record_size: RibbonPointGpu::size,
    )!;
    usz bytes = (usz)(batch.count + 1) * RibbonPointGpu::size;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
    RibbonPointGpu[] records = ((RibbonPointGpu*)staging.bytes.ptr)[:batch.count + 1];
    pack_ribbon_records(records, maths::rebase(world, renderer.frame_origin), batch);
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.allocation)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination.checked_subspan(0, bytes)! });
    renderer.pending_instance_uploads.push(index);
    slot.revision = batch.revision;
    slot.world = world;
    slot.origin = renderer.frame_origin;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)bytes;
}

fn MeshPreparation? prepare_ribbons(Renderer* renderer, RibbonBatch* batch) @private {
    if (!spatial::ribbon_batch_is_live(renderer.assets, batch)) {
        renderer.stats.dangling_refs++;
        return {};
    }
    GpuGeometry* geometry = acquire_billboard_geometry(renderer)!;
    Material* data = &renderer.assets.material(batch.material).data;
    MaterialRes*? resolved = resolve_material(renderer, batch.material);
    if (catch excuse = resolved) {
        if (!custom_material_unavailable(data, excuse)) return excuse~;
        renderer.stats.dangling_refs++;
        return {};
    }
    MaterialRes* material = resolved;
    validate_normal_geometry(
        geometry: geometry,
        material: data,
        bindings: &material.bindings,
        line_polygon_mode: renderer.caps.line_polygon_mode,
    )!;
    if (catch excuse = pipeline_for(renderer, data, { .shader = RIBBON_VERTEX })) {
        if (!custom_pipeline_rejected(renderer, data, excuse)) return excuse~;
        return {};
    }

    MsaaCounts msaa = live_msaa_counts(renderer);
    foreach (samples : msaa.items[:msaa.len]) {
        pipeline_for(
            renderer: renderer,
            material: data,
            vertex:   { .shader = RIBBON_VERTEX },
            samples:  samples,
        )!;
    }

    return {
        .sheen = material_uses_sheen(data),
        .scene_reads = material_scene_reads(data, custom_scene_reads(renderer, data)!),
    };
}
