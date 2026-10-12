module c3d::render;

import c3d;
import c3d::scene;
import c3d::shader;
import gpu;
import std::collections::list;
import std::collections::map;
import std::hash::fnv32a;

<*
 Crowd slots when RendererDesc.max_resident_crowds is 0.
*>
const uint DEFAULT_MAX_RESIDENT_CROWDS = 64; // 2 * capacity * (joints * 64 + morph_parts * 80) B of device memory each

const uint MAX_RESIDENT_STREAMS @private = 16; // palette plus morph streams per part; 2 KiB of CPU state per crowd
const uint RESIDENT_PALETTE @private = uint::max; // stream identity of the palette
const uint RESIDENT_LOD_MORPH @private = 0x8000_0000; // stream identity bit of an animated LOD part's morph blocks

struct ResidentKey @private {
    ulong  scene;
    Entity node;
}
$assert ResidentKey::size == ulong::size + Entity::size;

struct ResidentStream @private {
    uint                  part;
    uint                  stride;
    uint                  current;
    bool                  resolved;
    bool                  staged;
    ulong                 committed; // submitted frame whose pose the other buffer holds; 0 before the first
    GeometryId            geometry;
    uint                  revision;
    ulong                 source;
    uint                  source_revision;
    gpu::GpuAllocation[2] allocations;
    gpu::GpuAddress[2]    addresses;
    uint[][2]             uploaded; // pose revision of each instance as last staged into the buffer; 0 none
}

struct ResidentCrowd @private {
    ResidentKey                           key;
    ulong                                 last_seen;
    ulong                                 identity;
    uint                                  capacity;
    uint                                  stream_count;
    bool                                  listed;
    ResidentStream[MAX_RESIDENT_STREAMS]  streams;
}

struct ResidentCrowdTable @private {
    Allocator                    allocator;
    uint                         capacity;
    ResidentCrowd[]              slots;
    HashMap{ResidentKey, uint}   lookup;
    List{uint}                   listed;
}

struct ResidentRef @private {
    gpu::GpuAddress current;
    gpu::GpuAddress previous;
    ulong           committed;
}

<*
 Hash of the scene identity and the full entity.
*>
fn uint ResidentKey.hash(self) => fnv32a::hash(@as_char_view(self));

<*
 Whether both keys name the same scene and entity generation.
 @pure
*>
fn bool ResidentKey.equals(self, ResidentKey other) @operator(==) {
    return self.scene == other.scene && c3d::same_id(self.node, other.node);
}

<*
 Slot of the key, claiming the first free slot for a new key; marks it seen.
 @param frame_index : "Renderer frame being recorded."
 @return? c3d::CAPACITY_EXCEEDED
 @require key.scene != 0
*>
fn uint? ResidentCrowdTable.acquire(&self, ResidentKey key, ulong frame_index) {
    if (!self.slots.len) {
        self.slots = alloc::new_array(self.allocator, ResidentCrowd, (sz)self.capacity);
        self.lookup.init(self.allocator, (sz)self.capacity);
        self.listed.init(self.allocator, (sz)self.capacity);
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
 Release every crowd unresolved for more than INSTANCE_ABSENCE_FRAMES frames.
 @param [&inout] retire : "Receives each released buffer."
*>
fn void ResidentCrowdTable.sweep(&self, ulong frame_index, RetireList* retire) {
    foreach (&slot : self.slots) {
        if (!slot.key.scene || frame_index - slot.last_seen <= INSTANCE_ABSENCE_FRAMES) continue;
        release_resident_streams(self.allocator, slot, retire);
        self.lookup.remove(slot.key);
        *slot = {};
    }
}

fn ResidentCrowdTable create_resident_crowd_table(Allocator allocator, uint capacity) @private {
    return { .allocator = allocator, .capacity = capacity };
}

fn void destroy_resident_crowd_table(ResidentCrowdTable* table) @private {
    if (table.slots.len) {
        foreach (&crowd : table.slots) {
            foreach (&stream : crowd.streams[:crowd.stream_count]) {
                alloc::free(table.allocator, stream.uploaded[0].ptr);
                alloc::free(table.allocator, stream.uploaded[1].ptr);
            }
        }
        alloc::free(table.allocator, table.slots.ptr);
        table.lookup.free();
        table.listed.free();
    }
    *table = {};
}

fn void release_resident_streams(Allocator allocator, ResidentCrowd* crowd, RetireList* retire) @local {
    foreach (&stream : crowd.streams[:crowd.stream_count]) {
        foreach (allocation : stream.allocations) {
            if (allocation.is_valid()) retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = allocation });
        }
        alloc::free(allocator, stream.uploaded[0].ptr);
        alloc::free(allocator, stream.uploaded[1].ptr);
        *stream = {};
    }
    crowd.stream_count = 0;
}

fn ResidentStream*? resident_stream(ResidentCrowd* crowd, uint part) @local {
    foreach (&stream : crowd.streams[:crowd.stream_count]) {
        if (stream.part == part) return stream;
    }
    if (crowd.stream_count == MAX_RESIDENT_STREAMS) return c3d::CAPACITY_EXCEEDED~;

    ResidentStream* stream = &crowd.streams[crowd.stream_count++];
    stream.part = part;
    return stream;
}

fn void? allocate_resident_stream(
    Renderer* renderer,
    ResidentStream* stream,
    uint capacity,
    uint stride,
) @local {
    foreach (allocation : stream.allocations) {
        if (allocation.is_valid()) {
            renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = allocation });
        }
    }
    alloc::free(renderer.allocator, stream.uploaded[0].ptr);
    alloc::free(renderer.allocator, stream.uploaded[1].ptr);
    stream.allocations = {};
    stream.uploaded = {};
    stream.committed = 0;
    stream.stride = 0;

    defer catch {
        foreach (&allocation : stream.allocations) {
            if (allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, allocation);
        }
        alloc::free(renderer.allocator, stream.uploaded[0].ptr);
        alloc::free(renderer.allocator, stream.uploaded[1].ptr);
        stream.allocations = {};
        stream.uploaded = {};
    }

    foreach (buffer, &allocation : stream.allocations) {
        gpu::AllocationDesc desc = {
            .size         = (usz)capacity * stride,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access       = { .graphics },
            .debug_name   = stream.part == RESIDENT_PALETTE ? "crowd_palette" : "crowd_morph",
        };
        *allocation = gpu::allocate_memory(&renderer.device, &desc)!;
        gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, *allocation)!;
        stream.addresses[buffer] = gpu::get_span_address(&renderer.device, span)!;
        stream.uploaded[buffer] = alloc::new_array(renderer.allocator, uint, (sz)capacity);
    }
    stream.stride = stride;
}

fn void write_resident_row(
    char[] row,
    AssetStore* assets,
    MeshCandidate* candidate,
    uint part,
    uint instance,
) @local {
    AnimatedCrowd* crowd = candidate.crowd;
    if (part == RESIDENT_PALETTE) {
        Mat4f* matrices = (Mat4f*)row.ptr;
        foreach (joint, matrix : crowd.palettes[(usz)instance * crowd.joint_count:crowd.joint_count]) {
            matrices[joint] = bitcast(matrix, Mat4f);
        }
        return;
    }

    if (candidate.animated_lod) {
        float[] weights = animated_lod_weights(candidate, candidate.animated_lod.mesh_index, instance);
        *(MorphWeightsGpu*)row.ptr = animated_lod_morph(assets, candidate, weights);
        return;
    }

    *(MorphWeightsGpu*)row.ptr = crowd_part_morph(
        crowd: crowd,
        part: candidate.crowd_part,
        instance: instance,
        channels: assets.geometry(candidate.geometry).data.channels,
    );
}

fn void? stage_resident_stream(Renderer* renderer, ResidentStream* stream, MeshCandidate* candidate) @local {
    AnimatedCrowd* crowd = candidate.crowd;
    uint[] uploaded = stream.uploaded[stream.current];
    uint[] revisions = crowd.pose_revisions;
    uint changed;
    for (uint instance = 0; instance < crowd.count; instance++) {
        if (uploaded[instance] != revisions[instance]) changed++;
    }
    if (!changed) return;

    usz stride = stream.stride;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, (usz)changed * stride, STREAM_ALIGNMENT)!;
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, stream.allocations[stream.current])!;

    uint staged_rows;
    uint first;
    while (first < crowd.count) {
        if (uploaded[first] == revisions[first]) {
            first++;
            continue;
        }

        uint end = first;
        while (end < crowd.count && uploaded[end] != revisions[end]) {
            write_resident_row(
                row: staging.bytes[(usz)(staged_rows + end - first) * stride:stride],
                assets: renderer.assets,
                candidate: candidate,
                part: stream.part,
                instance: end,
            );
            uploaded[end] = revisions[end];
            end++;
        }

        usz run_bytes = (usz)(end - first) * stride;
        renderer.pending_copies.push({
            .src = staging.span.checked_subspan((usz)staged_rows * stride, run_bytes)!,
            .dst = destination.checked_subspan((usz)first * stride, run_bytes)!,
        });
        staged_rows += end - first;
        first = end;
    }

    stream.staged = true;
    renderer.pending_overwrite = true;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)((usz)changed * stride);
}

fn ResidentRef? resolve_resident_stream(
    Renderer* renderer,
    MeshCandidate* candidate,
    Node* owner,
    uint part,
    uint stride,
) @local {
    AnimatedCrowd* crowd = candidate.crowd;
    ResidentCrowdTable* table = &renderer.crowds;
    uint index = table.acquire({ .scene = candidate.scene_identity, .node = owner.id }, renderer.frame_index)!;
    ResidentCrowd* resident = &table.slots[index];
    uint capacity = (uint)crowd.placements.len;
    if (resident.identity != crowd.playback.identity || resident.capacity != capacity) {
        release_resident_streams(renderer.allocator, resident, &renderer.pending_upload_retire);
        resident.identity = crowd.playback.identity;
        resident.capacity = capacity;
    }

    ResidentStream* stream = resident_stream(resident, part)!;
    if (stream.stride != stride) allocate_resident_stream(renderer, stream, capacity, stride)!;

    if (part != RESIDENT_PALETTE) {
        ulong source;
        uint source_revision;
        if (candidate.animated_lod) {
            source = candidate.lod.state.identity;
            source_revision = candidate.lod.state.descriptor_revision;
        }
        uint revision = renderer.assets.geometry(candidate.geometry).header.revision;
        if (!c3d::same_id(stream.geometry, candidate.geometry) || stream.revision != revision
          || stream.source != source || stream.source_revision != source_revision) {
            stream.uploaded[0][..] = 0;
            stream.uploaded[1][..] = 0;
            stream.geometry = candidate.geometry;
            stream.revision = revision;
            stream.source = source;
            stream.source_revision = source_revision;
        }
    }

    if (!stream.resolved) {
        stage_resident_stream(renderer, stream, candidate)!;
        stream.resolved = true;
        if (!resident.listed) {
            resident.listed = true;
            table.listed.push(index);
        }
    }

    return {
        .current = stream.addresses[stream.current],
        .previous = stream.addresses[stream.current ^ 1],
        .committed = stream.committed,
    };
}

fn ResidentRef? resolve_crowd_palette(Renderer* renderer, MeshCandidate* candidate) @private {
    return resolve_resident_stream(
        renderer: renderer,
        candidate: candidate,
        owner: crowd_owner(candidate),
        part: RESIDENT_PALETTE,
        stride: candidate.crowd.joint_count * (uint)Mat4f::size,
    );
}

fn ResidentRef? resolve_crowd_morph(Renderer* renderer, MeshCandidate* candidate) @private {
    return resolve_resident_stream(
        renderer: renderer,
        candidate: candidate,
        owner: crowd_owner(candidate),
        part: candidate.animated_lod ? RESIDENT_LOD_MORPH | candidate.lod_part : candidate.crowd_part,
        stride: (uint)MorphWeightsGpu::size,
    );
}

fn Node* crowd_owner(MeshCandidate* candidate) @local {
    return candidate.animated_lod ? candidate.node : candidate.node.parent;
}

fn bool? crowd_deformation_history(
    Renderer* renderer,
    MeshCandidate* candidate,
    bool skinned,
    bool morphed,
    ulong frame,
) @private {
    if (!frame) return false;
    if (skinned && resolve_crowd_palette(renderer, candidate)!.committed != frame) return false;
    if (morphed && resolve_crowd_morph(renderer, candidate)!.committed != frame) return false;
    return true;
}

fn void commit_resident_crowds(Renderer* renderer, ulong frame) @private {
    ResidentCrowdTable* table = &renderer.crowds;
    foreach (index : table.listed) {
        ResidentCrowd* resident = &table.slots[index];
        resident.listed = false;
        foreach (&stream : resident.streams[:resident.stream_count]) {
            if (frame && stream.resolved) {
                stream.current ^= 1;
                stream.committed = frame;
            }
            stream.resolved = false;
            stream.staged = false;
        }
    }
    table.listed.clear();
}

fn void discard_resident_crowds(Renderer* renderer) @private {
    ResidentCrowdTable* table = &renderer.crowds;
    foreach (index : table.listed) {
        ResidentCrowd* resident = &table.slots[index];
        resident.listed = false;
        foreach (&stream : resident.streams[:resident.stream_count]) {
            if (stream.staged) stream.uploaded[stream.current][..] = 0;
            stream.resolved = false;
            stream.staged = false;
        }
    }
    table.listed.clear();
}

fn void free_resident_crowds(Renderer* renderer) @private {
    foreach (&resident : renderer.crowds.slots) {
        foreach (&stream : resident.streams[:resident.stream_count]) {
            foreach (&allocation : stream.allocations) {
                if (allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, allocation);
            }
        }
    }
    destroy_resident_crowd_table(&renderer.crowds);
}
