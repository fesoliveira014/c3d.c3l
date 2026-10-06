module c3d::render;

import c3d;
import c3d::shader;
import gpu;
import std::collections::list;
import std::collections::map;
import std::hash::fnv32a;

<*
 Posed trace slots a renderer holds when RendererDesc leaves the count at zero.
 Zero never disables posing; Mesh.trace = false keeps a mesh out.
*>
const uint DEFAULT_MAX_POSED_TRACE_INSTANCES = 64; // 32 two-part characters; a slot: 24-40 B/vertex, 32 B/node, a BLAS

<*
 Identity of one posed trace instance across the scenes a renderer serves.
*>
struct PosedTraceKey {
    ulong  scene;
    Entity node;     // the mesh node, or a crowd part's batch node
    ulong  instance; // crowd placement index; 0 for a mesh
}
$assert PosedTraceKey::size == 2 * ulong::size + Entity::size;

<*
 Renderer-owned posed copy of one deformed trace instance.
*>
struct PosedTraceRes {
    PosedTraceKey                    key;
    ulong                            last_seen;           // frame_index of the last claim
    ulong                            claimed_epoch;       // epoch of the last claim
    ulong                            compared_epoch;      // epoch of the last pose compare
    uint                             built_revision;      // header.revision of the root and BLAS; 0 rebuilds both
    gpu::GpuAllocation               allocation;          // posed root, then positions, normals and tangents
    usz                              stream_bytes;
    gpu::GpuAllocation               node_allocation;
    uint                             node_count;
    gpu::AccelerationStructureHandle blas;                // invalid before the first hardware preparation
    usz                              blas_bytes;
    char[]                           pose;                // inputs of the last recorded posing
    bool                             pose_valid;
    bool                             pending;             // touched by the current recording
    ulong                            pose_serial;         // advances with every recorded posing
    ulong                            refit_serial;        // pose_serial the node copy holds; 0 when stale
    ulong                            blas_serial;         // pose_serial the BLAS holds; 0 builds it in full
}

<*
 Fixed table of posed trace slots, allocated on the first claim.
*>
struct PosedTraceTable {
    Allocator                    allocator;
    uint                         capacity;
    PosedTraceRes[]              slots;
    HashMap{PosedTraceKey, uint} lookup;
    List{uint}                   pending;     // slots the current recording staged, posed or built
    ulong                        epoch;       // one per recording: an open frame, or a closed preparation
    ulong                        epoch_frame; // frame_index + 1 of the epoch's open frame; 0 when closed
    usz                          bytes;       // GPU bytes of every live slot
}

<*
 Hash of the scene identity, the full entity and the instance.
*>
fn uint PosedTraceKey.hash(self) => fnv32a::hash(@as_char_view(self));

<*
 Whether both keys name the same scene, entity generation and instance.
 @pure
*>
fn bool PosedTraceKey.equals(self, PosedTraceKey other) @operator(==) {
    return self.scene == other.scene && c3d::same_id(self.node, other.node) && self.instance == other.instance;
}

<*
 Keep the inputs as the slot's pose; true when they differ from the last recorded pose.
 @param inputs : "Palette bytes, then the morph block when the slot has one."
 @require inputs.len == self.pose.len
*>
fn bool PosedTraceRes.update_pose(&self, char[] inputs) {
    if (self.pose_valid && mem::equals(self.pose.ptr, inputs.ptr, (sz)inputs.len)) return false;
    mem::copy(self.pose.ptr, inputs.ptr, (sz)inputs.len);
    self.pose_valid = true;
    self.pose_serial++;
    return true;
}

<*
 Open a recording epoch unless this open frame already opened one.
 @param frame_marker : "frame_index + 1 of the open frame; 0 when no frame is open."
*>
fn void PosedTraceTable.begin_epoch(&self, ulong frame_marker) {
    if (frame_marker && frame_marker == self.epoch_frame) return;
    self.epoch++;
    self.epoch_frame = frame_marker;
}

<*
 Slot of the key: its own, else a free one, else one this epoch has not claimed.
 A slot taken from another key is emptied first.
 @param frame_index : "Renderer frame being recorded."
 @param [&inout] retire : "Receives a taken slot's GPU objects."
 @return? c3d::CAPACITY_EXCEEDED
 @require key.scene != 0 && self.epoch != 0
*>
fn uint? PosedTraceTable.claim(
    &self,
    PosedTraceKey key,
    ulong frame_index,
    RetireList* retire,
) {
    if (!self.slots.len) {
        self.slots = alloc::new_array(self.allocator, PosedTraceRes, (sz)self.capacity);
        self.lookup.init(self.allocator, (sz)self.capacity);
    }
    uint index;
    if (try found = self.lookup.get(key)) {
        index = found;
    } else {
        index = vacant_posed_slot(self)!;
        PosedTraceRes* taken = &self.slots[index];
        if (taken.key.scene) {
            self.lookup.remove(taken.key);
            empty_posed_slot(self, taken, retire);
        }
        taken.key = key;
        self.lookup.set(key, index);
    }
    self.slots[index].claimed_epoch = self.epoch;
    self.slots[index].last_seen = frame_index;
    return index;
}

<*
 Empty every slot no preparation claimed for more than INSTANCE_ABSENCE_FRAMES frames.
 @param [&inout] retire : "Receives each emptied slot's GPU objects."
*>
fn void PosedTraceTable.sweep(&self, ulong frame_index, RetireList* retire) {
    foreach (&slot : self.slots) {
        if (!slot.key.scene || frame_index - slot.last_seen <= INSTANCE_ABSENCE_FRAMES) continue;
        self.lookup.remove(slot.key);
        empty_posed_slot(self, slot, retire);
    }
}

fn PosedTraceTable create_posed_trace_table(Allocator allocator, uint capacity) @private {
    PosedTraceTable table = { .allocator = allocator, .capacity = capacity };
    table.pending.init(allocator);
    return table;
}

fn void free_posed_trace(Renderer* renderer) @private {
    PosedTraceTable* table = &renderer.posed_trace;
    foreach (&slot : table.slots) {
        if (slot.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &slot.allocation);
        if (slot.node_allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &slot.node_allocation);
        if (slot.blas.is_valid()) (void)gpu::destroy_acceleration_structure(&renderer.device, slot.blas);
    }
    free_posed_trace_storage(table);
}

fn void free_posed_trace_storage(PosedTraceTable* table) @private {
    foreach (&slot : table.slots) {
        if (slot.pose.len) alloc::free(table.allocator, slot.pose.ptr);
    }
    if (table.slots.len) alloc::free(table.allocator, table.slots.ptr);
    table.lookup.free();
    table.pending.free();
    *table = {};
}

fn uint? vacant_posed_slot(PosedTraceTable* table) @local {
    foreach (uint index, &slot : table.slots) {
        if (!slot.key.scene) return index;
    }
    foreach (uint index, &slot : table.slots) {
        if (slot.claimed_epoch != table.epoch) return index;
    }
    return c3d::CAPACITY_EXCEEDED~;
}

fn void empty_posed_slot(PosedTraceTable* table, PosedTraceRes* slot, RetireList* retire) @private {
    if (slot.allocation.is_valid()) retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = slot.allocation });
    if (slot.node_allocation.is_valid()) {
        retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = slot.node_allocation });
    }
    if (slot.blas.is_valid()) {
        retire.push({ .kind = RetiredKind.ACCELERATION_STRUCTURE, .acceleration_structure = slot.blas });
    }
    if (slot.pose.len) alloc::free(table.allocator, slot.pose.ptr);
    table.bytes -= slot.stream_bytes + (usz)slot.node_count * BvhNodeGpu::size + slot.blas_bytes;
    *slot = {};
}

fn void mark_posed_pending(PosedTraceTable* table, uint index) @private {
    PosedTraceRes* slot = &table.slots[index];
    if (slot.pending) return;
    slot.pending = true;
    table.pending.push(index);
}

fn void commit_posed_trace(PosedTraceTable* table) @private {
    foreach (index : table.pending) table.slots[index].pending = false;
    table.pending.clear();
}

// An aborted recording never ran: its slots rebuild their root, pose, refit and BLAS from scratch.
fn void discard_posed_trace(PosedTraceTable* table) @private {
    foreach (index : table.pending) {
        PosedTraceRes* slot = &table.slots[index];
        slot.built_revision = 0;
        slot.pose_valid = false;
        slot.refit_serial = 0;
        slot.blas_serial = 0;
        slot.pending = false;
    }
    table.pending.clear();
    table.epoch_frame = 0;
}
