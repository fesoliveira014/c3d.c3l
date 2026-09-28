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

<*
 Batch slots when RendererDesc.max_instance_batches is 0.
*>
const uint DEFAULT_MAX_INSTANCE_BATCHES = 1024; // 120 B CPU per slot; live plus recently unresolved batch nodes

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
}
$assert InstanceKey::size == ulong::size + Entity::size;

<*
 Persistent instance records of one batch node.
*>
struct GpuInstances {
    InstanceKey        key;
    uint               revision; // 0 forces an upload: InstancedMesh.revision is never 0
    uint               capacity;
    ulong              last_seen;
    Mat4               world; // records bake the node world, so a moved node re-uploads
    gpu::GpuAllocation allocation;
    gpu::GpuAddress    records;
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
    return self.scene == other.scene && c3d::same_id(self.node, other.node);
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
        self.lookup.remove(slot.key);
        *slot = {};
    }
}

<*
 Write one instance record from its world matrix and color.
 @param [&out] record : "Overwritten whole."
 @param world : "Affine instance matrix."
*>
fn void write_instance(InstanceGpu* record, Mat4 world, Vec4 color) {
    Mat3 normal = maths::normal_matrix(world);
    *record = {
        .model    = bitcast(world, Mat4f),
        .normal_0 = { normal.m00, normal.m10, normal.m20, 0 },
        .normal_1 = { normal.m01, normal.m11, normal.m21, 0 },
        .normal_2 = { normal.m02, normal.m12, normal.m22, 0 },
        .color    = color,
    };
}

<*
 Pack the live instances, unmirrored first, each group in array order.
 @param [out] records : "At least batch.count long."
 @param [&in] batch : "Live count above zero."
 @return "Index of the first mirrored record."
*>
fn uint pack_instance_records(InstanceGpu[] records, Mat4 node_world, InstancedMesh* batch) {
    uint written;
    foreach (index, transform : batch.transforms[:batch.count]) {
        if (scene::transform_mirrored(transform)) continue;
        write_instance(&records[written++], node_world.mul(transform.to_mat4()), batch.colors[index]);
    }
    uint split = written;
    foreach (index, transform : batch.transforms[:batch.count]) {
        if (!scene::transform_mirrored(transform)) continue;
        write_instance(&records[written++], node_world.mul(transform.to_mat4()), batch.colors[index]);
    }
    return split;
}

<*
 World matrices of the live instances in draw order: unmirrored first, each group in array order.
 @param [out] worlds : "At least batch.count long."
 @param [&in] batch : "Live count above zero."
*>
fn void write_instance_worlds(Mat4f[] worlds, Mat4 node_world, InstancedMesh* batch) {
    uint written;
    foreach (transform : batch.transforms[:batch.count]) {
        if (scene::transform_mirrored(transform)) continue;
        worlds[written++] = bitcast(node_world.mul(transform.to_mat4()), Mat4f);
    }
    foreach (transform : batch.transforms[:batch.count]) {
        if (!scene::transform_mirrored(transform)) continue;
        worlds[written++] = bitcast(node_world.mul(transform.to_mat4()), Mat4f);
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
 @param world : "Batch node world matrix."
*>
fn bool needs_upload(
    GpuInstances* slot,
    InstanceKey key,
    InstancedMesh* batch,
    Mat4 world,
) {
    return slot.key != key || slot.capacity < batch.transforms.len || slot.revision != batch.revision
        || slot.world != world;
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

fn gpu::GpuAddress? resolve_instances(Renderer* renderer, MeshCandidate* candidate) @private {
    InstanceKey key = { .scene = candidate.scene_identity, .node = candidate.node.id };
    uint index = renderer.instances.acquire(key, renderer.frame_index)!;
    GpuInstances* slot = &renderer.instances.slots[index];
    if (needs_upload(slot, key, candidate.batch, candidate.node.world)) {
        upload_instance_records(
            renderer: renderer,
            index:    index,
            batch:    candidate.batch,
            world:    candidate.node.world,
        )!;
    }
    return slot.records;
}

fn void? upload_instance_records(
    Renderer* renderer,
    uint index,
    InstancedMesh* batch,
    Mat4 world,
) @private {
    GpuInstances* slot = &renderer.instances.slots[index];
    uint capacity = (uint)batch.transforms.len;
    if (slot.capacity < capacity) {
        gpu::AllocationDesc records_desc = {
            .size         = (usz)capacity * InstanceGpu::size,
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
        slot.records = address;
        slot.capacity = capacity;
        slot.revision = 0;
    } else {
        renderer.pending_overwrite = true;
    }

    usz bytes = (usz)batch.count * InstanceGpu::size;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
    pack_instance_records(((InstanceGpu*)staging.bytes.ptr)[:batch.count], world, batch);
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.allocation)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination.checked_subspan(0, bytes)! });

    renderer.pending_instance_uploads.push(index);
    slot.revision = batch.revision;
    slot.world = world;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)bytes;
}

fn void free_instance_buffers(Renderer* renderer) @private {
    foreach (&slot : renderer.instances.slots) {
        if (slot.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &slot.allocation);
    }
    destroy_instance_table(&renderer.instances);
}
