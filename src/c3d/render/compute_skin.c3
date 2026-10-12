module c3d::render;

import c3d;
import c3d::scene;
import c3d::shader;
import gpu;
import std::collections::list;
import std::collections::map;

<*
 Resident bytes of posed buffers above which a deformed mesh keeps vertex skinning.
*>
const usz MAX_COMPUTE_SKINNING_BYTES = 512 * 1024 * 1024; // vertex_count * 52 B a mesh; the example character 0.31 MB

<*
 Meshes compute skinning poses at once; one past it keeps vertex skinning.
*>
const uint MAX_COMPUTE_SKINNING_MESHES = 2048; // one device allocation slot per mesh, of the 4,096 the renderer shares

const uint POSED_BLOCKS @private = 2; // current and previous pose of one mesh

struct PosedDraw @private {
    gpu::GpuAddress root;      // posed block when active, else the rest block
    gpu::GpuAddress previous;  // positions of the pose before this one; 0 without history
    ulong           committed; // submitted frame whose pose previous holds; 0 before the first
    bool            active;
}

struct SkinDispatch @private {
    gpu::GpuAddress root;
    uint            vertex_count;
    bool            joints_u16;
}

struct ComputeSkinBinding @private {
    PosedTraceKey                 key;
    ulong                         last_seen;    // frame_index of the last claim
    GeometryId                    geometry;
    gpu::GpuAddress               source_root;  // rest block the posed roots point into
    usz                           bytes;
    ulong                         committed;
    uint                          current;      // block this frame's pose is written to
    bool                          roots_staged; // false re-copies the roots into the blocks
    bool                          resolved;
    gpu::GpuAllocation            allocation;   // both blocks: a device allocation slot per mesh
    gpu::GpuAddress[POSED_BLOCKS] roots;
    PosedDraw                     draw;         // this frame's answer
}

struct ComputeSkinTable @private {
    Allocator                      allocator;
    ComputeSkinBinding[]           bindings;   // MAX_COMPUTE_SKINNING_MESHES, allocated on the first claim
    uint                           used;       // bindings ever claimed
    HashMap{PosedTraceKey, uint}   lookup;
    List{uint}                     vacant;
    List{uint}                     resolved;   // bindings claimed by the open frame
    List{SkinDispatch}             dispatches; // poses staged and not yet recorded
    usz                            bytes;
}

<*
 Choose whether deformed meshes pose in a compute pass; applies from the next frame.
*>
fn void Renderer.set_compute_skinning(&self, bool enabled) {
    self.compute_skinning = enabled;
}

fn ComputeSkinTable create_compute_skin_table(Allocator allocator) @private {
    ComputeSkinTable table = { .allocator = allocator };
    table.vacant.init(allocator);
    table.resolved.init(allocator);
    table.dispatches.init(allocator);
    return table;
}

fn void free_compute_skin(Renderer* renderer) @private {
    ComputeSkinTable* table = &renderer.compute_skin;
    foreach (&binding : table.bindings) {
        if (binding.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &binding.allocation);
    }
    if (table.bindings.len) alloc::free(table.allocator, table.bindings.ptr);
    table.lookup.free();
    table.vacant.free();
    table.resolved.free();
    table.dispatches.free();
    *table = {};
}

<*
 Release every binding unclaimed for more than INSTANCE_ABSENCE_FRAMES frames.
 @param [&inout] retire : "Receives each released block."
*>
fn void ComputeSkinTable.sweep(&self, ulong frame_index, RetireList* retire) {
    foreach (index, &binding : self.bindings) {
        if (!binding.key.scene || frame_index - binding.last_seen <= INSTANCE_ABSENCE_FRAMES) continue;
        retire_skin_blocks(self, binding, retire);
        self.lookup.remove(binding.key);
        *binding = {};
        self.vacant.push((uint)index);
    }
}

fn void retire_skin_blocks(ComputeSkinTable* table, ComputeSkinBinding* binding, RetireList* retire) @local {
    if (binding.allocation.is_valid()) {
        retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = binding.allocation });
    }
    table.bytes -= binding.bytes;
    binding.allocation = {};
    binding.bytes = 0;
}

<*
 Binding index of a new key, reusing a released one first.
 @return? c3d::CAPACITY_EXCEEDED
*>
fn uint? ComputeSkinTable.bind(&self, PosedTraceKey key) {
    if (!self.bindings.len) {
        self.bindings = alloc::new_array(self.allocator, ComputeSkinBinding, MAX_COMPUTE_SKINNING_MESHES);
        self.lookup.init(self.allocator, (sz)MAX_COMPUTE_SKINNING_MESHES * 2);
    }

    uint index;
    if (try reused = self.vacant.pop()) {
        index = reused;
    } else if (self.used < MAX_COMPUTE_SKINNING_MESHES) {
        index = self.used++;
    } else {
        return c3d::CAPACITY_EXCEEDED~;
    }

    self.bindings[index].key = key;
    self.lookup.set(key, index);
    return index;
}

// A mesh outside compute skinning, or past either cap, answers its rest root; each such claim counts a fallback.
fn PosedDraw? claim_posed_draw(Renderer* renderer, MeshCandidate* candidate, GpuGeometry* geometry) @private {
    PosedDraw rest = { .root = geometry.root };
    if (!renderer.frame_compute_skinning || candidate_instanced(candidate) || candidate.animated_lod
      || candidate.crowd || candidate.impostor || candidate.vertex_motion) return rest;

    ShaderVariant deformed = candidate_vertex_variant(geometry.layout.flags, candidate);
    uint deformation = shader::SHADER_FLAG_SKINNED | shader::SHADER_FLAG_SKINNED_U16 | shader::SHADER_FLAG_MORPH;
    if (!(deformed.flags & deformation)) return rest;

    ComputeSkinTable* table = &renderer.compute_skin;
    PosedTraceKey key = { .scene = candidate.scene_identity, .node = candidate.node.id };
    uint? index = table.lookup.get(key) ?? table.bind(key);
    if (catch index) {
        renderer.stats.compute_skinning_fallbacks++;
        return rest;
    }

    ComputeSkinBinding* binding = &table.bindings[index];
    if (!binding.resolved) {
        binding.resolved = true;
        binding.last_seen = renderer.frame_index;
        table.resolved.push(index);
        binding.draw = stage_posed_draw(renderer, binding, candidate, geometry, deformed)!;
    }
    if (!binding.draw.active) renderer.stats.compute_skinning_fallbacks++;
    return binding.draw;
}

fn PosedDraw? stage_posed_draw(
    Renderer* renderer,
    ComputeSkinBinding* binding,
    MeshCandidate* candidate,
    GpuGeometry* geometry,
    ShaderVariant deformed,
) @local {
    ComputeSkinTable* table = &renderer.compute_skin;
    PosedLayout layout = posed_layout(&geometry.layout);
    usz second_block = align_up(layout.total_bytes, STREAM_ALIGNMENT);
    usz needed = second_block + layout.positions + PACKED_VEC3_BYTES * geometry.layout.vertex_count;
    if (binding.bytes != needed) {
        retire_skin_blocks(table, binding, &renderer.pending_upload_retire);
        if (table.bytes + needed > MAX_COMPUTE_SKINNING_BYTES) return { .root = geometry.root };

        gpu::AllocationDesc desc = {
            .size         = needed,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access       = { .graphics },
            .debug_name   = "compute_skin",
        };
        binding.allocation = gpu::allocate_memory(&renderer.device, &desc)!;
        gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, binding.allocation)!;
        binding.roots[0] = gpu::get_span_address(&renderer.device, span)!;
        binding.roots[1] = binding.roots[0] + (gpu::GpuAddress)second_block;

        table.bytes += needed;
        binding.bytes = needed;
        binding.roots_staged = false;
        binding.committed = 0;
        binding.current = 0;
    }

    bool rest_moved = binding.source_root != geometry.root || !c3d::same_id(binding.geometry, geometry.asset);
    if (!binding.roots_staged || rest_moved) stage_posed_roots(renderer, binding, geometry, layout)!;

    gpu::GpuAddress palette = deformed.flags & (shader::SHADER_FLAG_SKINNED | shader::SHADER_FLAG_SKINNED_U16)
      ? resolve_candidate_skin(renderer, candidate)! : (gpu::GpuAddress)0;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan pose = frame.upload.take(&renderer.device, TracePoseRoot::size, STREAM_ALIGNMENT)!;
    *(TracePoseRoot*)pose.bytes.ptr = {
        .source  = geometry.root,
        .posed   = binding.roots[binding.current],
        .palette = palette,
        .morph   = resolve_candidate_morph(renderer, candidate, deformed)!,
    };

    table.dispatches.push({
        .root         = pose.address,
        .vertex_count = geometry.layout.vertex_count,
        .joints_u16   = geometry.layout.flags.joints_u16,
    });
    renderer.stats.compute_skinned++;
    gpu::GpuAddress previous = binding.roots[binding.current ^ 1] + (gpu::GpuAddress)layout.positions;
    return {
        .root      = binding.roots[binding.current],
        .previous  = binding.committed ? previous : (gpu::GpuAddress)0,
        .committed = binding.committed,
        .active    = true,
    };
}

// The second block carries only positions; its root borrows the first block's normals and tangents,
// which are rewritten each frame behind the consumer-stage barrier because no reader needs their history.
fn void? stage_posed_roots(
    Renderer* renderer,
    ComputeSkinBinding* binding,
    GpuGeometry* geometry,
    PosedLayout layout,
) @local {
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(
        &renderer.device,
        POSED_BLOCKS * GeometryRoot::size,
        STREAM_ALIGNMENT,
    )!;

    GeometryRoot* roots = (GeometryRoot*)staging.bytes.ptr;
    roots[0] = posed_geometry_root(&geometry.layout, geometry.root, binding.roots[0]);
    roots[1] = roots[0];
    roots[1].positions = binding.roots[1] + (gpu::GpuAddress)layout.positions;

    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, binding.allocation)!;
    foreach (block, root : binding.roots) {
        renderer.pending_copies.push({
            .src = staging.span.checked_subspan((usz)block * GeometryRoot::size, GeometryRoot::size)!,
            .dst = destination.checked_subspan((usz)(root - binding.roots[0]), GeometryRoot::size)!,
        });
    }

    renderer.pending_overwrite = true;
    binding.geometry = geometry.asset;
    binding.source_root = geometry.root;
    binding.roots_staged = true;
}

// Compute writes go behind the readers of frames in flight; the vertex stage reads them in every raster pass.
fn void? record_compute_skin(Renderer* renderer, gpu::CommandList* commands) @private {
    ComputeSkinTable* table = &renderer.compute_skin;
    if (!table.dispatches.len()) return;

    acquire_compute_slot(renderer, ComputeSlot.TRACE_POSE)!;
    acquire_compute_slot(renderer, ComputeSlot.TRACE_POSE_U16)!;
    bool profiled = renderer.frame_open;
    if (profiled) begin_profile_pass(renderer, Pass.COMPUTE_SKIN)!;

    gpu::Barrier readers_done = { .before = renderer.consumer_stages, .after = { .compute } };
    gpu::cmd_barrier(commands, &readers_done)!;

    foreach (&dispatch : table.dispatches) {
        PosedTraceTable* pipelines = &renderer.posed_trace;
        gpu::cmd_bind_pipeline(commands, dispatch.joints_u16 ? pipelines.pose_u16_pipeline : pipelines.pose_pipeline)!;
        uint groups = (dispatch.vertex_count + shader::TRACE_POSE_GROUP_SIZE - 1) / shader::TRACE_POSE_GROUP_SIZE;
        gpu::cmd_dispatch(commands, dispatch.root, { groups, 1, 1 })!;
    }

    gpu::Barrier posed = { .before = { .compute }, .after = { .vertex_shader } };
    gpu::cmd_barrier(commands, &posed)!;

    table.dispatches.clear();
    renderer.work_recorded = true;
    if (profiled) end_profile_pass(renderer, Pass.COMPUTE_SKIN)!;
}

fn void commit_compute_skin(Renderer* renderer, ulong frame) @private {
    ComputeSkinTable* table = &renderer.compute_skin;
    foreach (index : table.resolved) {
        ComputeSkinBinding* binding = &table.bindings[index];
        binding.resolved = false;
        if (!binding.draw.active) continue;
        binding.current ^= 1;
        binding.committed = frame;
    }
    table.resolved.clear();
    renderer.stats.compute_skinning_bytes = table.bytes;
}

// An aborted frame neither swaps nor commits; its root copies were dropped with the pending copies.
fn void discard_compute_skin(Renderer* renderer) @private {
    ComputeSkinTable* table = &renderer.compute_skin;
    foreach (index : table.resolved) {
        ComputeSkinBinding* binding = &table.bindings[index];
        binding.resolved = false;
        binding.roots_staged = false;
    }
    table.resolved.clear();
    table.dispatches.clear();
}
