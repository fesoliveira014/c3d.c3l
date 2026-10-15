module c3d::render;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::collections::list;
import std::collections::map;
import std::hash::fnv32a;
import std::math;

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
    Entity node;            // mesh/batch node, or animated LOD owner
    uint   instance;        // logical source slot; 0 for an ordinary mesh
    uint   logical_part;    // base mesh index; 0 for an ordinary mesh
    ulong  lod_identity;    // descriptor incarnation; 0 without animated LOD
    ulong  source_identity; // crowd playback identity or animated source epoch; renewed by crowd replacement
}
$assert PosedTraceKey::size == 3 * ulong::size + Entity::size + 2 * uint::size;

<*
 Rest topology a vertex-motion slot was built for.
*>
struct PosedTopology {
    GeometryId    geometry;
    uint          vertex_count;
    uint          index_count;
    GeometryFlags flags;
}

<*
 Renderer-owned posed copy of one deformed trace instance.
*>
struct PosedTraceRes {
    PosedTraceKey                    key;
    ulong                            last_seen;           // frame_index of the last claim
    ulong                            claimed_epoch;       // epoch of the last claim
    ulong                            compared_epoch;      // epoch of the last pose compare
    GeometryId                       geometry;            // rest geometry the copy follows
    uint                             built_revision;      // header.revision of the root and BLAS; 0 rebuilds both
    PosedTopology                    topology;            // rest topology the streams, nodes and BLAS were sized for
    gpu::GpuAddress                  source_root;         // rest block the root points into
    gpu::GpuAllocation               allocation;          // posed root, then positions, normals and tangents
    gpu::GpuAddress                  root;
    gpu::GpuSpan                     positions;
    usz                              stream_bytes;
    gpu::GpuAllocation               node_allocation;
    gpu::GpuAddress                  nodes;               // 0 before the first software preparation
    uint                             node_count;
    gpu::AccelerationStructureHandle blas;                // invalid before the first hardware preparation
    gpu::AccelerationStructureTriangleGeometryDesc blas_layout; // counts and index type the BLAS was created for
    usz                              build_scratch_size;
    usz                              update_scratch_size;
    usz                              blas_bytes;
    char[]                           pose;                // inputs of the last recorded posing
    bool                             pose_valid;
    bool                             pending;             // touched by the current recording
    bool                             aliased;             // the root addresses a compute skinning binding's pose
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
    List{PosedDispatch}          dispatches;  // posing and refit work the current preparation queued
    List{PosedBuild}             builds;      // BLAS builds and updates the current preparation queued
    List{uint}                   motion_copies; // vertex-motion slots whose streams the mirror must refill
    gpu::PipelineHandle          pose_pipeline;
    gpu::PipelineHandle          pose_u16_pipeline;
    gpu::PipelineHandle          refit_pipeline;
}

struct PosedBuild @private {
    uint slot;
    bool update;
}

struct PosedDispatch @private {
    gpu::GpuAddress pose_root;  // TracePoseRoot in the frame ring; 0 when the pose is current
    gpu::GpuAddress refit_root; // TraceRefitRoot in the frame ring; 0 without a software refit
    uint            vertex_count;
    bool            joints_u16;
}

struct PosedGroupClaim @private {
    uint slot;
    bool shared; // the slot is an earlier placement's
}

struct PosedPoseGroup @private {
    PosedTraceKey batch;     // the leader's key with instance zero
    char[]        pose;      // the leader's inputs, live for the preparation
    uint          pose_hash;
    uint          slot;
    bool          occupied;
    bool          overflow;  // the leader found no slot, so its followers find none either
}

struct PosedPoseGroups @private {
    PosedPoseGroup[] entries;
    usz              mask;
}

<*
 Hash of the full source, part and incarnation identity.
*>
fn uint PosedTraceKey.hash(self) => fnv32a::hash(@as_char_view(self));

<*
 Whether both keys name the same source slot, logical part and incarnation.
 @pure
*>
fn bool PosedTraceKey.equals(self, PosedTraceKey other) @operator(==) {
    return self.scene == other.scene && c3d::same_id(self.node, other.node) && self.instance == other.instance
      && self.lod_identity == other.lod_identity && self.source_identity == other.source_identity
      && self.logical_part == other.logical_part;
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

// Slot of a crowd placement, shared by the batch rows with the same pose inputs.
<*
 @return? c3d::CAPACITY_EXCEEDED
 @require key.scene != 0
*>
fn PosedGroupClaim? PosedPoseGroups.claim(
    &self,
    PosedTraceTable* table,
    PosedTraceKey key,
    char[] pose,
    ulong frame_index,
    RetireList* retire,
) {
    PosedTraceKey batch = key;
    batch.instance = 0;
    uint pose_hash = fnv32a::hash(pose);
    usz index = (usz)(batch.hash() ^ pose_hash) & self.mask;
    while (self.entries[index].occupied) {
        PosedPoseGroup* entry = &self.entries[index];
        bool same_pose = entry.pose_hash == pose_hash && entry.batch == batch && entry.pose.len == pose.len
          && mem::equals(entry.pose.ptr, pose.ptr, (sz)pose.len);
        if (same_pose) {
            if (entry.overflow) return c3d::CAPACITY_EXCEEDED~;
            return { .slot = entry.slot, .shared = true };
        }
        index = (index + 1) & self.mask;
    }

    // A batch's rows arrive in placement order, so the slot key is the group's lowest placement.
    PosedPoseGroup* entry = &self.entries[index];
    *entry = {
        .batch     = batch,
        .pose      = pose,
        .pose_hash = pose_hash,
        .occupied  = true,
    };

    uint? slot = table.claim(key, frame_index, retire);
    if (catch excuse = slot) {
        entry.overflow = true;
        return excuse~;
    }
    entry.slot = slot;
    return { .slot = slot, .shared = false };
}

fn PosedTraceTable create_posed_trace_table(Allocator allocator, uint capacity) {
    PosedTraceTable table = { .allocator = allocator, .capacity = capacity };
    table.pending.init(allocator);
    table.dispatches.init(allocator);
    table.builds.init(allocator);
    table.motion_copies.init(allocator);
    return table;
}

// More entries than twice the rows keeps probes short and always leaves an empty entry to end one.
fn PosedPoseGroups create_posed_pose_groups(Allocator allocator, usz row_count) {
    usz capacity = 1;
    while (capacity <= 2 * row_count) capacity *= 2;
    return {
        .entries = alloc::new_array(allocator, PosedPoseGroup, (sz)capacity),
        .mask    = capacity - 1,
    };
}

fn void free_posed_trace(Renderer* renderer) {
    PosedTraceTable* table = &renderer.posed_trace;
    foreach (&slot : table.slots) {
        if (slot.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &slot.allocation);
        if (slot.node_allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &slot.node_allocation);
        if (slot.blas.is_valid()) (void)gpu::destroy_acceleration_structure(&renderer.device, slot.blas);
    }
    if (table.pose_pipeline.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, table.pose_pipeline);
    if (table.pose_u16_pipeline.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, table.pose_u16_pipeline);
    if (table.refit_pipeline.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, table.refit_pipeline);
    free_posed_trace_storage(table);
}

fn void free_posed_trace_storage(PosedTraceTable* table) {
    foreach (&slot : table.slots) {
        if (slot.pose.len) alloc::free(table.allocator, slot.pose.ptr);
    }
    if (table.slots.len) alloc::free(table.allocator, table.slots.ptr);
    table.lookup.free();
    table.pending.free();
    table.dispatches.free();
    table.builds.free();
    table.motion_copies.free();
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

fn void empty_posed_slot(PosedTraceTable* table, PosedTraceRes* slot, RetireList* retire) {
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

fn void mark_posed_pending(PosedTraceTable* table, uint index) {
    PosedTraceRes* slot = &table.slots[index];
    if (slot.pending) return;
    slot.pending = true;
    table.pending.push(index);
}

fn void commit_posed_trace(PosedTraceTable* table) {
    foreach (index : table.pending) table.slots[index].pending = false;
    table.pending.clear();
}

// An aborted recording never ran: its slots rebuild their root, pose, refit and BLAS from scratch.
fn void discard_posed_trace(PosedTraceTable* table) {
    foreach (index : table.pending) {
        PosedTraceRes* slot = &table.slots[index];
        slot.built_revision = 0;
        slot.topology = {};
        slot.pose_valid = false;
        slot.refit_serial = 0;
        slot.blas_serial = 0;
        slot.pending = false;
    }
    table.pending.clear();
    table.dispatches.clear();
    table.builds.clear();
    table.motion_copies.clear();
    table.epoch_frame = 0;
}

<*
 Whether a vertex-motion slot built for one topology still holds for another.
 A new revision with the same counts and stream layout refills the slot; anything else rebuilds it.
 @pure
*>
fn bool vertex_motion_slot_valid(PosedTopology recorded, PosedTopology current) {
    return c3d::same_id(recorded.geometry, current.geometry)
      && recorded.vertex_count == current.vertex_count
      && recorded.index_count == current.index_count
      && (uint)recorded.flags == (uint)current.flags;
}

fn PosedTopology posed_topology(GpuGeometry* mirror) {
    return {
        .geometry     = mirror.asset,
        .vertex_count = mirror.layout.vertex_count,
        .index_count  = mirror.layout.index_count,
        .flags        = mirror.layout.flags,
    };
}

// Whether the key's slot can follow the geometry's next revision with a refit and an update alone.
// A software request also needs the rest tree with its depth table, a hardware one the slot's bottom level.
fn bool vertex_motion_held(
    Renderer* renderer,
    PosedTraceKey key,
    GeometryId geometry,
    bool cpu_present,
    bool proven,
) {
    PosedTraceTable* table = &renderer.posed_trace;
    if (!table.slots.len) return false;
    uint? found = table.lookup.get(key);
    if (catch found) return false;
    PosedTraceRes* slot = &table.slots[found];
    GpuGeometry* mirror = &renderer.geometries[geometry.index];
    if (!slot.allocation.is_valid() || !c3d::same_id(mirror.asset, geometry)) return false;
    if (cpu_present && !proven) return false;
    GeometryAsset* record = renderer.assets.geometry(geometry);
    if (record.header.revision != slot.built_revision) {
        if (!cpu_present) return false;
        GeometryLayout layout = geometry_layout_from_width(&record.data, record.joints_u16);
        PosedTopology current = {
            .geometry     = geometry,
            .vertex_count = layout.vertex_count,
            .index_count  = layout.index_count,
            .flags        = layout.flags,
        };
        if (!vertex_motion_slot_valid(slot.topology, current)) return false;
    }
    SceneTrace* trace = &renderer.scene_trace;
    if (trace.software_requested && (!mirror.trace.revision || !mirror.trace.depth_starts)) return false;
    return !trace.hardware_requested || slot.blas.is_valid();
}

fn PosedTraceKey trace_pose_key(ulong scene, TracePoseSource* source, TraceInstance* record) {
    PosedTraceKey key = { .scene = scene, .node = source.node.id, .instance = record.instance_index };
    if (source.lod) {
        key.lod_identity = source.lod.identity;
        key.source_identity = source.lod.instance_epoch;
        key.logical_part = source.lod.animated.parts[source.part].mesh_index;
    } else if (source.kind == TracePose.CROWD) {
        key.source_identity = source.crowd.playback.identity;
        key.logical_part = source.part;
    }
    return key;
}

fn uint pose_input_bytes(TracePoseSource* source, AssetStore* assets) {
    switch (source.kind) {
        case REST:
        case VERTEX_MOTION:
            return 0;
        case MESH:
            uint palette = source.skin ? (uint)(source.skin.joints.len * Mat4f::size) : 0;
            return palette + (mesh_morphs(assets, source.mesh) ? (uint)MorphWeightsGpu::size : 0);
        case CROWD:
            uint palette = source.crowd.parts[source.part].skinned
              ? source.crowd.joint_count * (uint)Mat4f::size : 0;
            return palette + (source.crowd.parts[source.part].weight_count ? (uint)MorphWeightsGpu::size : 0);
        case ANIMATED_LOD:
            AnimatedLodPartBinding* part = &source.lod.animated.parts[source.part];
            uint palette = part.skinned ? (uint)(source.lod.animated.joint_nodes.len * Mat4f::size) : 0;
            bool morphs = assets.geometry(source.lod.desc.parts[source.part].geometry).target_count
              && part.weight_count;
            return palette + (morphs ? (uint)MorphWeightsGpu::size : 0);
    }
}

fn bool mesh_morphs(AssetStore* assets, Mesh* mesh) @local {
    return assets.geometry(mesh.geometry).target_count > 0 && mesh.morph_weights.len > 0;
}

// The bytes the posing pass consumes: the palette resolve_palette uploads, then the packed morph block.
fn char[] pose_inputs(Renderer* renderer, TracePoseSource* source, TraceInstance* record) {
    char[] inputs = alloc::new_array(tmem, char, pose_input_bytes(source, renderer.assets));
    usz palette_bytes;
    MorphWeightsGpu block;
    bool morphs;
    switch (source.kind) {
        case REST:
        case VERTEX_MOTION:
            return inputs;
        case MESH:
            if (source.skin) {
                palette_bytes = source.skin.joints.len * Mat4f::size;
                evaluate_palette(
                    palette:      ((Mat4f*)inputs.ptr)[:source.skin.joints.len],
                    mesh_node:    source.node,
                    binding:      source.skin,
                    inverse_bind: renderer.assets.skeleton(source.skin.skeleton).data.inverse_bind,
                    origin:       renderer.frame_origin,
                );
            }
            morphs = mesh_morphs(renderer.assets, source.mesh);
            if (morphs) {
                Geometry* data = &renderer.assets.geometry(record.geometry).data;
                block = pack_morph_selection(geometry::select_morph_targets(data.channels, source.mesh.morph_weights));
            }
        case CROWD:
            AnimatedCrowd* crowd = source.crowd;
            CrowdPart* part = &crowd.parts[source.part];
            if (part.skinned) {
                palette_bytes = (usz)crowd.joint_count * Mat4f::size;
                Mat4* palette = &crowd.palettes[(usz)record.instance_index * crowd.joint_count];
                mem::copy(inputs.ptr, palette, (sz)palette_bytes);
            }

            morphs = part.weight_count > 0;
            if (morphs) {
                usz first = (usz)record.instance_index * crowd.morph_stride + part.weight_offset;
                MorphChannel[] channels = renderer.assets.geometry(record.geometry).data.channels;
                block = pack_morph_selection(
                    geometry::select_morph_targets(channels, crowd.morph_weights[first:part.weight_count]),
                );
            }
        case ANIMATED_LOD:
            LodSelection selection;
            MeshCandidate candidate = trace_animated_lod_candidate(source, record, &selection);
            AnimatedLodPartBinding* part = candidate.animated_lod;

            if (part.skinned) {
                usz joints = source.lod.animated.joint_nodes.len;
                palette_bytes = joints * Mat4f::size;
                if (candidate.crowd) {
                    Mat4* palette = &candidate.crowd.palettes[(usz)record.instance_index * joints];
                    mem::copy(inputs.ptr, palette, (sz)palette_bytes);
                } else {
                    write_animated_lod_palette(
                        palette: ((Mat4f*)inputs.ptr)[:joints],
                        assets: renderer.assets,
                        candidate: &candidate,
                        origin: renderer.frame_origin,
                    );
                }
            }

            morphs = renderer.assets.geometry(record.geometry).target_count && part.weight_count;
            if (morphs) {
                float[] weights = animated_lod_weights(&candidate, part.mesh_index, record.instance_index);
                block = animated_lod_morph(renderer.assets, &candidate, weights);
            }
    }
    if (morphs) *(MorphWeightsGpu*)(inputs.ptr + palette_bytes) = block;
    return inputs;
}

fn void? acquire_trace_pose_pipelines(Renderer* renderer) {
    acquire_compute_slot(renderer, ComputeSlot.TRACE_POSE)!;
    acquire_compute_slot(renderer, ComputeSlot.TRACE_POSE_U16)!;
    acquire_compute_slot(renderer, ComputeSlot.TRACE_REFIT)!;
}

// Every stream a vertex-motion slot exposes is refilled from the geometry mirror the revision just uploaded.
// Both sides pack positions and normals at PACKED_VEC3_BYTES and tangents at Vec4::size, so each copy is one range.
fn void? record_vertex_motion_copies(Renderer* renderer, gpu::CommandList* commands) {
    PosedTraceTable* table = &renderer.posed_trace;
    if (!table.motion_copies.len()) return;
    // The mirror upload is a transfer write, and trace readers still read the slot's earlier streams.
    gpu::Barrier writes_done = { .before = renderer.consumer_stages, .after = { .transfer } };
    writes_done.before.transfer = true;
    gpu::cmd_barrier(commands, &writes_done)!;
    foreach (index : table.motion_copies) {
        PosedTraceRes* slot = &table.slots[index];
        GpuGeometry* mirror = &renderer.geometries[slot.topology.geometry.index];
        gpu::GpuSpan source = gpu::get_allocation_span(&renderer.device, mirror.allocation)!;
        gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.allocation)!;
        PosedLayout posed = posed_layout(&mirror.layout);
        usz vec3_bytes = PACKED_VEC3_BYTES * mirror.layout.vertex_count;
        gpu::BufferCopyDesc positions = {
            .src = source.checked_subspan(mirror.layout.positions, vec3_bytes)!,
            .dst = destination.checked_subspan(posed.positions, vec3_bytes)!,
        };
        gpu::cmd_copy_buffer(commands, &positions)!;
        if (mirror.layout.flags.has_normals) {
            gpu::BufferCopyDesc normals = {
                .src = source.checked_subspan(mirror.layout.normals, vec3_bytes)!,
                .dst = destination.checked_subspan(posed.normals, vec3_bytes)!,
            };
            gpu::cmd_copy_buffer(commands, &normals)!;
        }
        if (mirror.layout.flags.has_tangents) {
            usz tangent_bytes = Vec4::size * mirror.layout.vertex_count;
            gpu::BufferCopyDesc tangents = {
                .src = source.checked_subspan(mirror.layout.tangents, tangent_bytes)!,
                .dst = destination.checked_subspan(posed.tangents, tangent_bytes)!,
            };
            gpu::cmd_copy_buffer(commands, &tangents)!;
        }
    }
    gpu::Barrier copied = { .before = { .transfer }, .after = renderer.consumer_stages };
    gpu::cmd_barrier(commands, &copied)!;
    table.motion_copies.clear();
    renderer.work_recorded = true;
}

// Every posing dispatch, then every refit, so three barriers serve any number of slots.
fn void? record_trace_poses(Renderer* renderer, gpu::CommandList* commands) {
    PosedTraceTable* table = &renderer.posed_trace;
    record_vertex_motion_copies(renderer, commands)!;
    if (!table.dispatches.len()) return;
    acquire_trace_pose_pipelines(renderer)!;
    bool profiled = renderer.frame_open;
    if (profiled) begin_profile_pass(renderer, Pass.TRACE_POSE)!;

    // Trace readers of this frame and of the frame in flight still read the streams and node copies;
    // consumer_stages names the acceleration-structure stage only on renderers with ray queries.
    gpu::Barrier readers_done = { .before = renderer.consumer_stages, .after = { .compute } };
    gpu::cmd_barrier(commands, &readers_done)!;
    foreach (&dispatch : table.dispatches) {
        if (!dispatch.pose_root) continue;
        gpu::cmd_bind_pipeline(commands, dispatch.joints_u16 ? table.pose_u16_pipeline : table.pose_pipeline)!;
        uint groups = (dispatch.vertex_count + shader::TRACE_POSE_GROUP_SIZE - 1) / shader::TRACE_POSE_GROUP_SIZE;
        gpu::cmd_dispatch(commands, dispatch.pose_root, { groups, 1, 1 })!;
        renderer.stats.trace_poses++;
    }
    gpu::Barrier posed = { .before = { .compute }, .after = { .compute } };
    gpu::cmd_barrier(commands, &posed)!;
    gpu::cmd_bind_pipeline(commands, table.refit_pipeline)!;
    foreach (&dispatch : table.dispatches) {
        if (!dispatch.refit_root) continue;
        gpu::cmd_dispatch(commands, dispatch.refit_root, { 1, 1, 1 })!;
        renderer.stats.trace_refits++;
    }
    gpu::Barrier written = { .before = { .compute }, .after = renderer.consumer_stages };
    gpu::cmd_barrier(commands, &written)!;
    table.dispatches.clear();
    renderer.work_recorded = true;
    if (profiled) end_profile_pass(renderer, Pass.TRACE_POSE)!;
}

// A slot follows one geometry revision: a new revision, a moved rest block or another geometry rebuild it.
// A vertex-motion slot follows the rest topology instead, and a new revision only refills its streams.
fn void? acquire_posed_streams(
    Renderer* renderer,
    uint index,
    GpuGeometry* mirror,
    usz pose_bytes,
    bool vertex_motion,
    bool aliased,
) {
    PosedTraceTable* table = &renderer.posed_trace;
    PosedTraceRes* slot = &table.slots[index];
    PosedTopology topology = posed_topology(mirror);
    bool same_geometry = c3d::same_id(slot.geometry, mirror.asset);
    if (vertex_motion) {
        bool held = slot.allocation.is_valid() && slot.source_root == mirror.root && slot.pose.len == 0
          && vertex_motion_slot_valid(slot.topology, topology);
        if (held) {
            if (slot.built_revision == mirror.revision) return;
            slot.built_revision = mirror.revision;
            slot.pose_serial++;
            table.motion_copies.push(index);
            mark_posed_pending(table, index);
            return;
        }
    } else if (same_geometry && slot.built_revision == mirror.revision && slot.source_root == mirror.root
        && slot.pose.len == pose_bytes) {
        return;
    }

    PosedLayout layout = posed_layout(&mirror.layout);
    bool reuse = same_geometry && slot.allocation.is_valid() && slot.stream_bytes == layout.total_bytes;
    if (!reuse) {
        gpu::AllocationDesc desc = {
            .size         = layout.total_bytes,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access       = { .graphics },
            .debug_name   = "posed_geometry",
        };
        gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
        defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
        gpu::GpuSpan block = gpu::get_allocation_span(&renderer.device, allocation)!;
        gpu::GpuAddress address = gpu::get_span_address(&renderer.device, block)!;
        if (slot.allocation.is_valid()) {
            renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = slot.allocation });
        }
        table.bytes += layout.total_bytes;
        table.bytes -= slot.stream_bytes;
        slot.allocation = allocation;
        slot.root = address;
        slot.stream_bytes = layout.total_bytes;
    } else {
        renderer.pending_overwrite = true;
    }
    if (slot.pose.len != pose_bytes) {
        if (slot.pose.len) alloc::free(table.allocator, slot.pose.ptr);
        slot.pose = pose_bytes ? alloc::new_array(table.allocator, char, (sz)pose_bytes) : (char[]){};
    }

    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.allocation)!;
    slot.positions = destination.checked_subspan(layout.positions, PACKED_VEC3_BYTES * mirror.layout.vertex_count)!;
    if (!aliased) write_posed_root(renderer, slot, posed_geometry_root(&mirror.layout, mirror.root, slot.root))!;

    slot.geometry = mirror.asset;
    slot.topology = topology;
    slot.built_revision = mirror.revision;
    slot.source_root = mirror.root;
    if (vertex_motion) table.motion_copies.push(index);
    slot.pose_valid = false;
    slot.compared_epoch = 0;
    slot.refit_serial = 0;
    slot.blas_serial = 0;
    mark_posed_pending(table, index);
}

fn void? acquire_posed_nodes(Renderer* renderer, uint index, GpuGeometry* mirror) {
    PosedTraceTable* table = &renderer.posed_trace;
    PosedTraceRes* slot = &table.slots[index];
    if (slot.node_allocation.is_valid() && slot.node_count == mirror.trace.node_count) return;

    gpu::AllocationDesc desc = {
        .size         = (usz)mirror.trace.node_count * BvhNodeGpu::size,
        .alignment    = STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "posed_trace_nodes",
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
    defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
    gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, allocation)!;
    gpu::GpuAddress address = gpu::get_span_address(&renderer.device, span)!;
    if (slot.node_allocation.is_valid()) {
        renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = slot.node_allocation });
    }
    table.bytes += desc.size;
    table.bytes -= (usz)slot.node_count * BvhNodeGpu::size;
    slot.node_allocation = allocation;
    slot.nodes = address;
    slot.node_count = mirror.trace.node_count;
    slot.refit_serial = 0;
}

// A BLAS is sized by its creation counts, so another geometry or another revision's counts replace it.
fn void? acquire_posed_blas(Renderer* renderer, uint index, GpuGeometry* mirror) {
    PosedTraceTable* table = &renderer.posed_trace;
    PosedTraceRes* slot = &table.slots[index];
    gpu::AccelerationStructureGeometryDesc[1] geometries = { blas_geometry_desc(&mirror.layout) };
    gpu::AccelerationStructureTriangleGeometryDesc* wanted = &geometries[0].triangles;
    bool same_layout = slot.blas_layout.max_vertex_count == wanted.max_vertex_count
      && slot.blas_layout.max_primitive_count == wanted.max_primitive_count
      && slot.blas_layout.index_type == wanted.index_type;
    if (slot.blas.is_valid() && same_layout) return;
    if (slot.blas.is_valid()) {
        renderer.pending_upload_retire.push({
            .kind                   = RetiredKind.ACCELERATION_STRUCTURE,
            .acceleration_structure = slot.blas,
        });
        table.bytes -= slot.blas_bytes;
        slot.blas_bytes = 0;
        slot.blas = {};
    }

    gpu::AccelerationStructureDesc desc = {
        .kind       = gpu::AccelerationStructureKind.BOTTOM_LEVEL,
        .geometries = geometries[..],
        .flags      = { .allow_update, .prefer_fast_trace },
        .debug_name = "posed_blas",
    };
    gpu::AccelerationStructureRequirements requirements = gpu::get_acceleration_structure_requirements(
        &renderer.device,
        &desc,
    )!;
    slot.blas = gpu::create_acceleration_structure(&renderer.device, &desc)!;
    slot.blas_layout = *wanted;
    slot.build_scratch_size = requirements.build_scratch_size;
    slot.update_scratch_size = requirements.update_scratch_size;
    slot.blas_bytes = requirements.storage_size;
    slot.blas_serial = 0;
    table.bytes += requirements.storage_size;
}

fn void point_at_posed_slot(TraceInstance* record, PosedTraceRes* slot, GpuGeometry* mirror) {
    record.geometry_root = slot.root;
    record.bottom_level = slot.blas;
    record.nodes = slot.nodes;
    record.primitives = mirror.trace.primitives;
    record.pose_serial = slot.pose_serial;
}

// Bring the row's posed slot to the current pose and point the row at it; empty inputs gather here.
<*
 @require source.kind != TracePose.REST
*>
fn void? resolve_posed_instance(
    Renderer* renderer,
    uint index,
    TraceInstance* record,
    TracePoseSource* source,
    GpuGeometry* mirror,
    ulong scene,
    char[] inputs,
) {
    PosedTraceTable* table = &renderer.posed_trace;
    bool software = renderer.scene_trace.software_requested;
    bool hardware = renderer.scene_trace.hardware_requested;
    PosedDraw posed = claim_trace_pose(renderer, source, record, mirror, scene)!;
    PosedTraceRes* slot = &table.slots[index];

    // The slot's own streams went stale while it followed the compute pass.
    if (slot.aliased && !posed.active) slot.built_revision = 0;

    acquire_posed_streams(
        renderer:      renderer,
        index:         index,
        mirror:        mirror,
        pose_bytes:    pose_input_bytes(source, renderer.assets),
        vertex_motion: source.kind == TracePose.VERTEX_MOTION,
        aliased:       posed.active,
    )!;
    if (software) acquire_posed_nodes(renderer, index, mirror)!;
    if (hardware) acquire_posed_blas(renderer, index, mirror)!;
    slot.aliased = posed.active;

    PosedDispatch dispatch = {
        .vertex_count = mirror.layout.vertex_count,
        .joints_u16   = mirror.layout.flags.joints_u16,
    };
    if (source.kind == TracePose.VERTEX_MOTION) {
        if (!slot.pose_valid) {
            slot.pose_valid = true;
            slot.pose_serial++;
        }
    } else if (slot.compared_epoch != table.epoch) {
        slot.compared_epoch = table.epoch;
        bool changed = slot.update_pose(inputs.len ? inputs : pose_inputs(renderer, source, record));
        if (posed.active) {
            alias_posed_pose(renderer, slot, &posed, mirror, source, record)!;
            if (changed) renderer.stats.trace_poses_reused++;
        } else if (changed) {
            dispatch.pose_root = write_pose_root(
                renderer: renderer,
                source:   source,
                record:   record,
                mirror:   mirror,
                slot:     slot,
                scene:    scene,
            )!;
        }
    }
    if (software && slot.refit_serial != slot.pose_serial) {
        dispatch.refit_root = write_refit_root(renderer, mirror, slot)!;
        slot.refit_serial = slot.pose_serial;
    }
    if (dispatch.pose_root || dispatch.refit_root) {
        table.dispatches.push(dispatch);
        mark_posed_pending(table, index);
    }

    if (hardware && slot.blas_serial != slot.pose_serial) {
        table.builds.push({ .slot = index, .update = slot.blas_serial != 0 });
        slot.blas_serial = slot.pose_serial;
        mark_posed_pending(table, index);
    }

    point_at_posed_slot(record, slot, mirror);
}

// A mesh or crowd part compute skinning poses this frame answers its posed binding, which the slot then follows.
// Closed preparations record no frame, so they pose on their own.
fn PosedDraw? claim_trace_pose(
    Renderer* renderer,
    TracePoseSource* source,
    TraceInstance* record,
    GpuGeometry* mirror,
    ulong scene,
) @local {
    PosedDraw rest = { .root = mirror.root };
    if (!renderer.frame_open) return rest;

    MeshCandidate candidate = {
        .node           = source.node,
        .geometry       = record.geometry,
        .material       = record.material,
        .scene_identity = scene,
    };
    switch (source.kind) {
        case MESH:
            candidate.skin = source.skin;
            if (mesh_morphs(renderer.assets, source.mesh)) candidate.morph_weights = source.mesh.morph_weights;
            candidate.morph_channels = renderer.assets.geometry(record.geometry).data.channels;
            candidate.vertex_motion = source.mesh.vertex_motion;
        case CROWD:
            candidate.batch = source.batch;
            candidate.crowd = source.crowd;
            candidate.crowd_part = source.part;
        default:
            return rest;
    }
    return claim_posed_draw(renderer, &candidate, mirror);
}

// The slot's root is rewritten each frame to address the binding's current block, which swaps with every
// submitted frame, so the slot keeps no pointer into the binding.
fn void? alias_posed_pose(
    Renderer* renderer,
    PosedTraceRes* slot,
    PosedDraw* posed,
    GpuGeometry* mirror,
    TracePoseSource* source,
    TraceInstance* record,
) @local {
    bool crowd = source.kind == TracePose.CROWD;
    PosedSource pose = posed_source(
        renderer: renderer,
        posed:    posed,
        geometry: mirror,
        sources:  crowd ? (uint)source.crowd.placements.len : 1,
        source:   crowd ? record.instance_index : 0,
    )!;

    write_posed_root(renderer, slot, pose.root)!;
    renderer.pending_overwrite = true;
    slot.positions = pose.positions;
}

fn void? write_posed_root(Renderer* renderer, PosedTraceRes* slot, GeometryRoot root) @local {
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, GeometryRoot::size, STREAM_ALIGNMENT)!;
    *(GeometryRoot*)staging.bytes.ptr = root;
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.allocation)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination.checked_subspan(0, GeometryRoot::size)! });
}

fn gpu::GpuAddress? write_pose_root(
    Renderer* renderer,
    TracePoseSource* source,
    TraceInstance* record,
    GpuGeometry* mirror,
    PosedTraceRes* slot,
    ulong scene,
) @local {
    gpu::GpuAddress palette;
    gpu::GpuAddress morph;
    switch (source.kind) {
        case REST:
        case VERTEX_MOTION:
            unreachable("only skinned, morphed and crowd rows pose on the GPU");
        case MESH:
            if (source.skin) palette = resolve_palette(renderer, source.node, source.skin)!;
            if (mesh_morphs(renderer.assets, source.mesh)) {
                morph = resolve_morph_block(
                    renderer:  renderer,
                    mesh_node: source.node,
                    channels:  renderer.assets.geometry(record.geometry).data.channels,
                    weights:   source.mesh.morph_weights,
                )!;
            }
        case CROWD:
            AnimatedCrowd* crowd = source.crowd;
            MeshCandidate candidate = {
                .node = source.node,
                .geometry = record.geometry,
                .scene_identity = scene,
                .crowd = crowd,
                .crowd_part = source.part,
            };
            if (crowd.parts[source.part].skinned) {
                palette = resolve_crowd_palette(renderer, &candidate)!.current
                  + (gpu::GpuAddress)((usz)record.instance_index * crowd.joint_count * Mat4f::size);
            }

            if (crowd.parts[source.part].weight_count) {
                morph = resolve_crowd_morph(renderer, &candidate)!.current
                  + (gpu::GpuAddress)((usz)record.instance_index * MorphWeightsGpu::size);
            }
        case ANIMATED_LOD:
            LodSelection selection;
            MeshCandidate candidate = trace_animated_lod_candidate(source, record, &selection);
            AnimatedLodPartBinding* part = candidate.animated_lod;

            if (part.skinned) {
                palette = resolve_animated_lod_palette(renderer, &candidate)!
                  + (gpu::GpuAddress)((usz)record.instance_index * source.lod.animated.joint_nodes.len * Mat4f::size);
            }

            if (renderer.assets.geometry(record.geometry).target_count && part.weight_count) {
                morph = resolve_animated_lod_morph(renderer, &candidate)!
                  + (gpu::GpuAddress)((usz)record.instance_index * MorphWeightsGpu::size);
            }
    }
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = frame.upload.take(&renderer.device, TracePoseRoot::size, STREAM_ALIGNMENT)!;
    *(TracePoseRoot*)root.bytes.ptr = {
        .source  = mirror.root,
        .posed   = slot.root,
        .palette = palette,
        .morph   = morph,
    };
    return root.address;
}

fn gpu::GpuAddress? write_refit_root(Renderer* renderer, GpuGeometry* mirror, PosedTraceRes* slot) @local {
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = frame.upload.take(&renderer.device, TraceRefitRoot::size, STREAM_ALIGNMENT)!;
    *(TraceRefitRoot*)root.bytes.ptr = {
        .geometry     = slot.root,
        .source_nodes = mirror.trace.nodes,
        .nodes        = slot.nodes,
        .primitives   = mirror.trace.primitives,
        .depth_starts = mirror.trace.depth_starts,
        .depth_order  = mirror.trace.depth_order,
    };
    return root.address;
}

fn void? record_posed_builds(
    Renderer* renderer,
    gpu::CommandList* commands,
    gpu::GpuSpan scratch,
    BuildBatch* batch,
    gpu::Barrier* builds_ordered,
) {
    PosedTraceTable* table = &renderer.posed_trace;
    if (!table.builds.len()) return;
    // Ray queries and top-level builds of earlier frames still read the bottom levels updated in place.
    gpu::Barrier readers_done = { .before = renderer.trace_stages, .after = { .acceleration_structure_build } };
    gpu::cmd_barrier(commands, &readers_done)!;
    foreach (&build : table.builds) {
        PosedTraceRes* slot = &table.slots[build.slot];
        GpuGeometry* mirror = &renderer.geometries[slot.geometry.index];
        gpu::AccelerationStructureGeometryBuildDesc[1] geometries = {{
            .kind      = gpu::AccelerationStructureGeometryKind.TRIANGLES,
            .triangles = {
                .vertices        = slot.positions,
                .vertex_stride   = PACKED_VEC3_BYTES,
                .vertex_count    = mirror.layout.vertex_count,
                .indices         = mirror.indices,
                .primitive_count = blas_primitive_count(&mirror.layout),
            },
        }};
        usz scratch_size = posed_build_scratch_size(table, build);
        BuildRange range = batch.place(scratch_size);
        if (range.closes_batch) gpu::cmd_barrier(commands, builds_ordered)!;
        gpu::AccelerationStructureBuildDesc desc = {
            .destination = slot.blas,
            .geometries  = geometries[..],
            .scratch     = scratch.checked_subspan(range.offset, scratch_size)!,
        };
        if (build.update) {
            gpu::cmd_update_acceleration_structure(commands, &desc)!;
            renderer.stats.blas_updates++;
        } else {
            gpu::cmd_build_acceleration_structure(commands, &desc)!;
            renderer.stats.blas_builds++;
        }
    }
    table.builds.clear();
}

fn usz posed_build_scratch_size(PosedTraceTable* table, PosedBuild* build) {
    PosedTraceRes* slot = &table.slots[build.slot];
    return build.update ? slot.update_scratch_size : slot.build_scratch_size;
}
