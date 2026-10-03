module c3d::render;

import c3d;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const usz LOD_RECORD_BYTES @private = InstanceGpu::size + LodMetadataGpu::size + STREAM_ALIGNMENT;

fn uint pack_lod_records(
    InstanceGpu[] records,
    LodMetadataGpu[] metadata,
    uint[] unmirrored,
    uint[] mirrored,
    Mat4 world,
    LodGroupState* state,
) @private {
    uint unmirrored_count;
    uint mirrored_count;
    foreach (uint index, transform : state.transforms[:state.count]) {
        write_instance(
            record: &records[index],
            world: world.mul(transform.to_mat4()),
            color: state.colors[index],
            seed: instance_seed(transform.position),
        );
        bool reflected = scene::transform_mirrored(transform);
        metadata[index] = { .generation = state.slot_generations[index], .parity = reflected ? 1 : 0 };
        if (reflected) {
            mirrored[mirrored_count++] = index;
        } else {
            unmirrored[unmirrored_count++] = index;
        }
    }
    return unmirrored_count;
}

fn gpu::GpuAddress? resolve_lod_instances(Renderer* renderer, LodSelection* selection) @private {
    LodGroupState* state = selection.state;
    InstanceKey key = {
        .scene = selection.scene_identity,
        .node = selection.node.id,
        .kind = shader::INSTANCE_KIND_LOD,
    };
    uint index = renderer.instances.acquire(key, renderer.frame_index)!;
    GpuInstances* slot = &renderer.instances.slots[index];
    selection.instances = slot;
    if (slot.capacity < state.transforms.len || slot.revision != state.revision
      || slot.world != selection.node.world || slot.lod_identity != state.identity
      || slot.origin != renderer.frame_origin) {
        upload_lod_records(
            renderer: renderer,
            index: index,
            state: state,
            world: selection.node.world,
        )!;
    }
    return slot.records;
}

fn void? upload_lod_records(
    Renderer* renderer,
    uint index,
    LodGroupState* state,
    Mat4 world,
) @private {
    GpuInstances* slot = &renderer.instances.slots[index];
    acquire_instance_records(
        renderer: renderer,
        slot: slot,
        capacity: (uint)state.transforms.len,
        record_size: LOD_RECORD_BYTES,
    )!;
    usz records_bytes = (usz)state.count * InstanceGpu::size;
    usz metadata_bytes = (usz)state.count * LodMetadataGpu::size;
    usz indices_bytes = align_up((usz)state.count * uint::size, STREAM_ALIGNMENT);
    usz staging_bytes = records_bytes + metadata_bytes + 2 * indices_bytes;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, staging_bytes, STREAM_ALIGNMENT)!;
    usz metadata_at = (usz)slot.capacity * InstanceGpu::size;
    usz unmirrored_at = metadata_at + (usz)slot.capacity * LodMetadataGpu::size;
    InstanceGpu[] records = ((InstanceGpu*)staging.bytes.ptr)[:state.count];
    LodMetadataGpu[] metadata = ((LodMetadataGpu*)(staging.bytes.ptr + records_bytes))[:state.count];
    uint[] unmirrored = ((uint*)(staging.bytes.ptr + records_bytes + metadata_bytes))[:state.count];
    uint[] mirrored = ((uint*)(staging.bytes.ptr + records_bytes + metadata_bytes + indices_bytes))[:state.count];
    uint split = pack_lod_records(
        records: records,
        metadata: metadata,
        unmirrored: unmirrored,
        mirrored: mirrored,
        world: maths::rebase(world, renderer.frame_origin),
        state: state,
    );
    usz mirrored_at = unmirrored_at + align_up((usz)split * uint::size, STREAM_ALIGNMENT);
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.allocation)!;
    renderer.pending_copies.push({
        .src = staging.span.checked_subspan(0, records_bytes)!,
        .dst = destination.checked_subspan(0, records_bytes)!,
    });
    renderer.pending_copies.push({
        .src = staging.span.checked_subspan(records_bytes, metadata_bytes)!,
        .dst = destination.checked_subspan(metadata_at, metadata_bytes)!,
    });
    if (split) renderer.pending_copies.push({
        .src = staging.span.checked_subspan(records_bytes + metadata_bytes, (usz)split * uint::size)!,
        .dst = destination.checked_subspan(unmirrored_at, (usz)split * uint::size)!,
    });
    if (state.count > split) renderer.pending_copies.push({
        .src = staging.span.checked_subspan(records_bytes + metadata_bytes + indices_bytes, (usz)(state.count - split) * uint::size)!,
        .dst = destination.checked_subspan(mirrored_at, (usz)(state.count - split) * uint::size)!,
    });
    slot.lod_metadata = (gpu::GpuAddress)((ulong)slot.records + metadata_at);
    slot.lod_unmirrored_indices = (gpu::GpuAddress)((ulong)slot.records + unmirrored_at);
    slot.lod_mirrored_indices = (gpu::GpuAddress)((ulong)slot.records + mirrored_at);
    slot.lod_unmirrored_count = split;
    slot.lod_identity = state.identity;
    slot.revision = state.revision;
    slot.world = world;
    slot.origin = renderer.frame_origin;
    renderer.pending_instance_uploads.push(index);
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)(records_bytes + metadata_bytes + (usz)state.count * uint::size);
}
