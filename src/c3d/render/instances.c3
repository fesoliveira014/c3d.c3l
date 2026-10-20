module c3d::render;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::collections::map;
import std::hash::fnv32a;
import std::math;

$assert scene::INSTANCE_RECORD_BYTES == InstanceGpu::size;

<*
 Batch slots when RendererDesc.max_instance_batches is 0.
*>
const uint DEFAULT_MAX_INSTANCE_BATCHES = 1024; // 128 B CPU per slot; live plus recently unresolved batches

<*
 Frames a batch may go unresolved before its records retire.
*>
const ulong INSTANCE_ABSENCE_FRAMES = FRAMES_IN_FLIGHT + 1; // longer holds hidden records; shorter re-uploads on return

<*
 Identity of a batch node across the scenes a renderer serves.
*>
struct InstanceKey {
    ulong  scene;
    Entity node;
    ulong  kind;
}
$assert InstanceKey::size == 2 * ulong::size + Entity::size;

<*
 Persistent instance records of one batch node.
*>
struct GpuInstances {
    InstanceKey        key;
    uint               revision; // 0 forces an upload: InstancedMesh.revision is never 0
    uint               capacity;
    uint               count;    // live instances the records hold
    uint               mirrored; // mirrored records among them
    ulong              last_seen;
    Mat4               world; // billboard records bake the node world, so a moved node re-uploads them
    Vec3               origin;
    gpu::GpuAllocation allocation;
    gpu::GpuAddress    records;
    ulong              lod_identity;
    gpu::GpuAddress    lod_metadata;
    gpu::GpuAddress    lod_unmirrored_indices;
    gpu::GpuAddress    lod_mirrored_indices;
    uint               lod_unmirrored_count;
    gpu::GpuAllocation quadtree_allocation;
    gpu::GpuAddress    quadtree_nodes;
    gpu::GpuAddress    quadtree_leaves;
    gpu::GpuAddress    quadtree_depths;
    gpu::GpuAddress    quadtree_params;
    uint               quadtree_capacity;
    uint               quadtree_revision; // 0 forces an upload: a quadtree revision is never 0
    uint               quadtree_count;
    uint               quadtree_parameter_revision; // 0 forces an upload: a parameter revision is never 0
    float              quadtree_split_pixels; // the thresholds the block holds, which in-place edits change
    float              quadtree_hysteresis;
}

<*
 Fixed table of instance record slots, allocated on the first acquire.
*>
struct InstanceTable {
    Allocator                  allocator;
    uint                       capacity;
    GpuInstances[]             slots;
    HashMap{InstanceKey, uint} lookup;
}

<*
 Batch instance range drawn through one indirect command.
*>
struct CullRange {
    gpu::GpuSpan    args;
    uint            count;
    uint            first;
    gpu::GpuAddress visible;
    bool            culled;
    bool            indexed;
}

<*
 Hash of the scene identity and the full entity.
*>
fn uint InstanceKey.hash(self) => fnv32a::hash(@as_char_view(self));

<*
 Whether both keys name the same scene and entity generation.
 @pure
*>
fn bool InstanceKey.equals(self, InstanceKey other) @operator(==) {
    return self.scene == other.scene && c3d::same_id(self.node, other.node) && self.kind == other.kind;
}

<*
 Slot of the key, claiming the first free slot for a new key; marks it seen.
 @param frame_index : "Renderer frame being recorded."
 @return? c3d::CAPACITY_EXCEEDED
 @require key.scene != 0
*>
fn uint? InstanceTable.acquire(&self, InstanceKey key, ulong frame_index) {
    if (!self.slots.len) {
        self.slots = alloc::new_array(self.allocator, GpuInstances, (sz)self.capacity);
        self.lookup.init(self.allocator, (sz)self.capacity);
    }
    if (try index = self.lookup.get(key)) {
        self.slots[index].last_seen = frame_index;
        return index;
    }
    foreach (uint index, &slot : self.slots) {
        if (slot.key.scene) continue;
        *slot = { .key = key, .last_seen = frame_index };
        self.lookup.set(key, index);
        return index;
    }
    return c3d::CAPACITY_EXCEEDED~;
}

<*
 Free every slot unresolved for more than INSTANCE_ABSENCE_FRAMES frames.
 @param [&inout] retire : "Receives each freed slot's allocation."
*>
fn void InstanceTable.sweep(&self, ulong frame_index, RetireList* retire) {
    foreach (&slot : self.slots) {
        if (!slot.key.scene || frame_index - slot.last_seen <= INSTANCE_ABSENCE_FRAMES) continue;
        if (slot.allocation.is_valid()) retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = slot.allocation });
        if (slot.quadtree_allocation.is_valid()) {
            retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = slot.quadtree_allocation });
        }
        self.lookup.remove(slot.key);
        *slot = {};
    }
}

<*
 Write one instance record from its matrix, color and seed.
 @param [&out] record : "Overwritten whole."
 @param model : "Affine instance matrix."
 @param seed : "Instance seed in [0, 1), carried in normal_0.w."
*>
fn void write_instance(
    InstanceGpu* record,
    Mat4 model,
    Vec4 color,
    float seed,
) {
    Mat3 normal = maths::normal_matrix(model);
    *record = {
        .model    = bitcast(model, Mat4f),
        .normal_0 = { normal.m00, normal.m10, normal.m20, seed },
        .normal_1 = { normal.m01, normal.m11, normal.m21, 0 },
        .normal_2 = { normal.m02, normal.m12, normal.m22, 0 },
        .color    = color,
    };
}

<*
 Pack the live instances relative to their node, unmirrored first, each group in array order.
 @param [out] records : "At least batch.count long."
 @param [&in] batch : "Live count above zero."
 @param [in] crowd : "Null selects ordinary batch transforms."
 @param part : "Logical crowd mesh; ignored for ordinary batches."
 @return "Index of the first mirrored record."
*>
fn uint pack_instance_records(
    InstanceGpu[] records,
    InstancedMesh* batch,
    AnimatedCrowd* crowd = null,
    uint part = 0,
) {
    // The first half collects unmirrored sources, the second half mirrored ones.
    uint[] order = alloc::new_array(tmem, uint, 2 * (usz)batch.count);
    uint split;
    uint mirrored;

    for (uint index = 0; index < batch.count; index++) {
        if (instance_mirrored(batch, crowd, part, index)) {
            order[batch.count + mirrored++] = index;
        } else {
            order[split++] = index;
        }
    }

    order[split:mirrored] = order[batch.count:mirrored];

    foreach (slot, index : order[:batch.count]) {
        write_batch_instance(
            record: &records[slot],
            local:  instance_local(batch, crowd, part, index),
            batch:  batch,
            index:  index,
            crowd:  crowd,
        );
    }

    return split;
}

fn void pack_instance_span(
    InstanceGpu[] records,
    InstancedMesh* batch,
    InstanceSpan span,
    AnimatedCrowd* crowd = null,
    uint part = 0,
) @private {
    for (uint index = span.first; index < span.end; index++) {
        write_batch_instance(
            record: &records[index - span.first],
            local:  instance_local(batch, crowd, part, index),
            batch:  batch,
            index:  index,
            crowd:  crowd,
        );
    }
}

fn Mat4 instance_local(InstancedMesh* batch, AnimatedCrowd* crowd, uint part, uint index) @local {
    return crowd ? crowd.part_transform(index, part) : batch.transforms[index].to_mat4();
}

fn bool instance_mirrored(InstancedMesh* batch, AnimatedCrowd* crowd, uint part, uint index) @local {
    return crowd ? crowd.part_mirrored(index, part) : scene::transform_mirrored(batch.transforms[index]);
}

fn void write_batch_instance(
    InstanceGpu* record,
    Mat4 local,
    InstancedMesh* batch,
    uint index,
    AnimatedCrowd* crowd,
) @local {
    write_instance(
        record: record,
        model:  local,
        color:  batch.colors[index],
        seed:   instance_seed(batch.transforms[index].position),
    );
    if (crowd) record.normal_2.w = (float)index;
}

<*
 Node-local matrices of the live instances in draw order: unmirrored first, each group in array order.
 @param [out] locals : "At least batch.count long."
 @param [&in] batch : "Live count above zero."
*>
fn void write_instance_locals(Mat4f[] locals, InstancedMesh* batch) {
    uint written;
    foreach (transform : batch.transforms[:batch.count]) {
        if (scene::transform_mirrored(transform)) continue;

        locals[written++] = bitcast(transform.to_mat4(), Mat4f);
    }

    foreach (transform : batch.transforms[:batch.count]) {
        if (!scene::transform_mirrored(transform)) continue;

        locals[written++] = bitcast(transform.to_mat4(), Mat4f);
    }
}

<*
 Table of capacity slots; nothing is allocated until the first acquire.
 @require capacity > 0
*>
fn InstanceTable create_instance_table(Allocator allocator, uint capacity) {
    return { .allocator = allocator, .capacity = capacity };
}

<*
 Release the table's CPU storage; slot allocations are the caller's to free first.
 @param [&inout] table : "Left zeroed."
*>
fn void destroy_instance_table(InstanceTable* table) {
    alloc::free(table.allocator, table.slots.ptr);
    table.lookup.free();
    *table = {};
}

<*
 Whether the slot must upload the batch's records.
 @param [&in] slot
 @param [&in] batch
*>
fn bool needs_upload(
    GpuInstances* slot,
    InstanceKey key,
    InstancedMesh* batch,
) {
    return slot.key != key || slot.capacity < batch.transforms.len || slot.revision != batch.revision;
}

fn InstanceSpan patchable_span(
    GpuInstances* slot,
    InstancedMesh* batch,
    AnimatedCrowd* crowd,
    uint part,
) @private {
    if (slot.capacity < batch.transforms.len) return {};
    if (slot.count != batch.count || slot.mirrored) return {};

    InstanceSpan span = batch.ranges.span_since(slot.revision);
    for (uint index = span.first; index < span.end; index++) {
        if (instance_mirrored(batch, crowd, part, index)) return {};
    }

    return span;
}

<*
 Indirect command bytes the geometry's draws take.
 @param [&in] layout
*>
fn usz indirect_args_bytes(GeometryLayout* layout) {
    return layout.index_count ? gpu::DrawIndexedIndirectCommand::size : gpu::DrawIndirectCommand::size;
}

<*
 Write one indexed or non-indexed indirect command drawing count instances.
 @param [out] args : "Overwritten."
 @param [&in] layout
 @require args.len >= indirect_args_bytes(layout)
 @require (uptr)args.ptr % uint::alignment == 0
*>
fn void write_indirect_args(char[] args, GeometryLayout* layout, uint count) {
    if (layout.index_count) {
        *(gpu::DrawIndexedIndirectCommand*)args.ptr = { .index_count = layout.index_count, .instance_count = count };
        return;
    }
    *(gpu::DrawIndirectCommand*)args.ptr = { .vertex_count = layout.vertex_count, .instance_count = count };
}

fn CullRange? prepare_cull_range(Renderer* renderer, MeshCandidate* candidate, GpuGeometry* geometry) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    usz bytes = indirect_args_bytes(&geometry.layout);
    gpu::MappedGpuSpan args = slot.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
    write_indirect_args(args.bytes, &geometry.layout, candidate.instance_count);
    return { .args = args.span, .count = candidate.instance_count, .first = candidate.instance_first };
}

fn void? issue_batch_draw(
    Renderer* renderer,
    gpu::GpuAddress root,
    GpuGeometry* geometry,
    CullRange range,
) @private {
    GeometryLayout* layout = &geometry.layout;
    if (layout.index_count) {
        gpu::cmd_draw_indexed_indirect(
            commands:      &renderer.commands,
            vertex_root:   root,
            fragment_root: root,
            args:          range.args,
            draw_count:    1,
            index_span:    geometry.indices,
            index_type:    layout.flags.indices_u16 ? gpu::IndexType.U16 : gpu::IndexType.U32,
        )!;
    } else {
        gpu::cmd_draw_indirect(
            commands:      &renderer.commands,
            vertex_root:   root,
            fragment_root: root,
            args:          range.args,
            draw_count:    1,
        )!;
    }
    renderer.stats.indirect_draws++;
}

fn void? record_batch_draw(
    Renderer* renderer,
    gpu::GpuAddress root,
    GpuGeometry* geometry,
    CullRange range,
) @private {
    issue_batch_draw(
        renderer: renderer,
        root:     root,
        geometry: geometry,
        range:    range,
    )!;
    count_draw(renderer, geometry, range.culled ? 0 : range.count);
}

fn bool candidate_device_instances(MeshCandidate* candidate) @private {
    return candidate.batch && candidate.batch.source == InstanceSource.DEVICE;
}

fn bool device_instances_lost(Renderer* renderer, MeshCandidate* candidate) @private {
    return candidate_device_instances(candidate) && !renderer.buffers.is_live(candidate.batch.device.buffer);
}

fn gpu::GpuAddress device_instance_records(Renderer* renderer, InstancedMesh* batch) @private {
    return (gpu::GpuAddress)((ulong)renderer.buffer_address(batch.device.buffer) + batch.device.records_offset);
}

fn gpu::GpuAddress device_instance_count(Renderer* renderer, MeshCandidate* candidate) @private {
    if (!candidate_device_instances(candidate)) return (gpu::GpuAddress)0;

    InstanceDevice* device = &candidate.batch.device;
    return (gpu::GpuAddress)((ulong)renderer.buffer_address(device.buffer) + device.count_offset);
}

fn gpu::GpuAddress? resolve_instances(Renderer* renderer, MeshCandidate* candidate) @private {
    if (candidate.lod) return resolve_lod_instances(renderer, candidate.lod);
    if (candidate_device_billboards(candidate)) return device_billboard_records(renderer, candidate.billboards);
    if (candidate_device_ribbons(candidate)) return device_ribbon_records(renderer, candidate.ribbons);
    if (candidate_device_instances(candidate)) return device_instance_records(renderer, candidate.batch);

    InstanceKey key = {
        .scene = candidate.scene_identity,
        .node = candidate.node.id,
        .kind = candidate.billboards ? shader::INSTANCE_KIND_BILLBOARD
          : candidate.ribbons ? shader::INSTANCE_KIND_RIBBON : shader::INSTANCE_KIND_MESH,
    };
    uint index = renderer.instances.acquire(key, renderer.frame_index)!;
    GpuInstances* slot = &renderer.instances.slots[index];
    if (BillboardBatch* billboards = candidate.billboards) {
        if (slot.capacity < billboards.capacity() || slot.revision != billboards.revision
            || slot.world != candidate.node.world || slot.origin != renderer.frame_origin) {
            upload_billboard_records(
                renderer: renderer,
                index: index,
                batch: billboards,
                world: candidate.node.world,
            )!;
        }
        return slot.records;
    }
    if (RibbonBatch* ribbons = candidate.ribbons) {
        if (slot.capacity <= ribbons.points.len || slot.revision != ribbons.revision
            || slot.world != candidate.node.world || slot.origin != renderer.frame_origin) {
            upload_ribbon_records(
                renderer: renderer,
                index: index,
                batch: ribbons,
                world: candidate.node.world,
            )!;
        }
        return slot.records;
    }
    bool stale = needs_upload(
        slot: slot,
        key: key,
        batch: candidate.batch,
    );
    bool quadtree = candidate.batch.quadtree.parents.len != 0;
    if (quadtree && (stale || quadtree_stale(slot, candidate.batch))) candidate.batch.validate_quadtree();

    if (stale) {
        upload_instance_records(
            renderer: renderer,
            index:    index,
            batch:    candidate.batch,
            crowd:    candidate.crowd,
            part:     candidate.crowd_part,
        )!;
    }
    if (quadtree && quadtree_nodes_stale(slot, candidate.batch)) {
        resolve_quadtree_nodes(renderer, index, candidate.batch)!;
    } else if (quadtree && quadtree_parameters_stale(slot, candidate.batch)) {
        upload_quadtree_parameters(renderer, index, candidate.batch)!;
        renderer.stats.uploads++;
    }
    return slot.records;
}

fn void? acquire_instance_records(
    Renderer* renderer,
    GpuInstances* slot,
    uint capacity,
    usz record_size,
    usz header_size = 0,
) @private {
    if (slot.capacity < capacity) {
        gpu::AllocationDesc records_desc = {
            .size         = header_size + (usz)capacity * record_size,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access       = { .graphics },
            .debug_name   = "instance_records",
        };
        gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &records_desc)!;
        defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
        gpu::GpuSpan block = gpu::get_allocation_span(&renderer.device, allocation)!;
        gpu::GpuAddress address = gpu::get_span_address(&renderer.device, block)!;
        if (slot.allocation.is_valid()) {
            renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = slot.allocation });
        }
        slot.allocation = allocation;
        slot.records = (gpu::GpuAddress)((ulong)address + header_size);
        slot.capacity = capacity;
        slot.revision = 0;
    } else {
        renderer.pending_overwrite = true;
    }
}

fn void? upload_instance_records(
    Renderer* renderer,
    uint index,
    InstancedMesh* batch,
    AnimatedCrowd* crowd,
    uint part,
) @private {
    GpuInstances* slot = &renderer.instances.slots[index];
    uint capacity = (uint)batch.transforms.len;
    InstanceSpan patch = patchable_span(slot, batch, crowd, part);
    bool patched = patch.end > patch.first;
    if (!patched) patch = { .end = batch.count };

    acquire_instance_records(
        renderer: renderer,
        slot: slot,
        capacity: capacity,
        record_size: InstanceGpu::size,
    )!;

    uint patch_count = patch.end - patch.first;
    usz bytes = (usz)patch_count * InstanceGpu::size;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
    InstanceGpu[] records = ((InstanceGpu*)staging.bytes.ptr)[:patch_count];

    if (patched) {
        pack_instance_span(
            records: records,
            batch: batch,
            span: patch,
            crowd: crowd,
            part: part,
        );
    } else {
        uint split = pack_instance_records(
            records: records,
            batch: batch,
            crowd: crowd,
            part: part,
        );
        slot.mirrored = batch.count - split;
    }

    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.allocation)!;
    renderer.pending_copies.push({
        .src = staging.span,
        .dst = destination.checked_subspan((usz)patch.first * InstanceGpu::size, bytes)!,
    });

    renderer.pending_instance_uploads.push(index);
    slot.revision = batch.revision;
    slot.count = batch.count;

    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)bytes;
}

fn void free_instance_buffers(Renderer* renderer) @private {
    foreach (&slot : renderer.instances.slots) {
        if (slot.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &slot.allocation);
        if (slot.quadtree_allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &slot.quadtree_allocation);
    }
    destroy_instance_table(&renderer.instances);
}
