module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import c3d::spatial::bvh;
import gpu;
import std::collections::list;
import std::math;
import std::time;
import std::time::clock;

$assert bvh::BVH_MAX_DEPTH == shader::BVH_STACK_DEPTH;
$assert BvhNode::size == BvhNodeGpu::size;
$assert $reflect(BvhNode.min).offset == $reflect(BvhNodeGpu.min_x).offset;
$assert $reflect(BvhNode.left_or_first).offset == $reflect(BvhNodeGpu.left_or_first).offset;
$assert $reflect(BvhNode.max).offset == $reflect(BvhNodeGpu.max_x).offset;
$assert $reflect(BvhNode.count).offset == $reflect(BvhNodeGpu.count).offset;

<*
 Trace instances a renderer holds when RendererDesc leaves the count at zero.
*>
const uint DEFAULT_MAX_TRACE_INSTANCES = 4096; // 4096 x 144 B instances + 8191 x 32 B nodes: 0.81 MiB persistent

const BvhBuildDesc TOP_LEVEL_BUILD @private = { .bins = 12, .leaf_size = 1 }; // each instance test walks a bottom level

// The top level depends on a record only up to its software bottom level, which a later preparation may fill.
const usz TOP_LEVEL_PREFIX_BYTES @private = $reflect(TraceInstance.nodes).offset;

const ZString[FRAMES_IN_FLIGHT] TOP_LEVEL_NAMES @private = {
    "scene_tlas_0",
    "scene_tlas_1",
};

<*
 Acceleration structure a scene trace preparation builds.
*>
enum TraceKind {
    AUTO,
    SOFTWARE,
    HARDWARE,
}

enum TraceSource @private {
    REUSE,
    BUILD,
    SKIP,
}

struct TraceInstance @private {
    Entity          entity;
    uint            flags;
    uint            material_kind;
    GeometryId      geometry;
    MaterialId      material;
    Mat4            world;
    gpu::AccelerationStructureHandle bottom_level;
    uint            mask;
    uint            _pad0;
    gpu::GpuAddress geometry_root;
    gpu::GpuAddress material_address;
    gpu::GpuAddress nodes;
    gpu::GpuAddress primitives;
}
// The dirty tests compare records bytewise, so the record carries no padding.
$assert TraceInstance::size == 152;

struct SceneTrace @private {
    ulong              scene;
    TraceInstance[]    baseline;
    uint               baseline_count;
    uint               top_node_count;
    gpu::GpuAllocation allocation;
    gpu::GpuAddress    root;
    gpu::GpuAddress    top_nodes;
    gpu::GpuAddress    instances;
    uint[]             row_records;    // baseline record of each instance table row
    uint               tlas_index;     // as last written to the root
    ulong              prepared_frame; // frame_index + 1 of the last in-frame preparation
    bool               software_requested;
    bool               hardware_requested;
    List{GeometryId}   pending_builds;
}

struct RtTopLevel @private {
    gpu::AccelerationStructureHandle tlas;
    gpu::AccelerationStructureView   view;
}

struct RtScratch @private {
    gpu::GpuAllocation allocation;
    gpu::GpuSpan       span;
    usz                size;
}

// A frame reads at most one top level: a rebuild targets the one this frame already used, else the other,
// whose last reader precedes the frame the slot wait completed.
struct RtContext @private {
    RtTopLevel[FRAMES_IN_FLIGHT] top_levels;
    RtScratch[FRAMES_IN_FLIGHT]  scratch;   // per frame slot
    usz                          top_level_scratch_size;
    uint                         current;   // top level built last; FRAMES_IN_FLIGHT before the first build
    bool                         current_holds_set;
    ulong                        used_frame; // frame_index + 1 of the last frame that published current
    bool                         build_pending;
    bool                         build_after_reads;
    uint                         build_target;
    List{GeometryId}             pending_blas;
    usz                          recorded_blas;
}

<*
 Build or reuse the scene's trace data; completes without a window when no frame is open.
 @param [&inout] self : "Owns queued trace copies, builds and their submission."
 @param [&in] scene : "Pose as left by the last update_world."
 @param kind : "AUTO selects HARDWARE when ray queries are enabled."
 @return "SceneTraceRoot address, stable for the renderer's life."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT, c3d::SHADER_NOT_FOUND
 @return? c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::UNSUPPORTED_FEATURE, gpu::COMMAND_RECORDING_ERROR, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::INVALID_RESOURCE_STATE, gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::WAIT_TIMEOUT
 @return? gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED
 @require !self.overlay_open
*>
fn gpu::GpuAddress? Renderer.prepare_scene_trace(&self, Scene* scene, TraceKind kind = TraceKind.AUTO) {
    bool hardware = resolve_trace_kind(kind, self.caps.ray_queries.enabled)! == TraceKind.HARDWARE;
    SceneTrace* trace = &self.scene_trace;
    if (self.frame_open) {
        bool same_frame = trace.prepared_frame == self.frame_index + 1 && trace.scene == scene.identity;
        if (!same_frame) {
            trace.software_requested = false;
            trace.hardware_requested = false;
        }
        bool requested = hardware ? trace.hardware_requested : trace.software_requested;
        if (same_frame && requested) return trace.root;

        if (hardware) {
            trace.hardware_requested = true;
        } else {
            trace.software_requested = true;
        }
        @pool() {
            record_scene_trace(self, scene)!;
        };
        trace.prepared_frame = self.frame_index + 1;
        if (trace.hardware_requested) {
            record_pending_copies(self, &self.commands)!;
            record_acceleration_builds(self, &self.commands)!;
        }
        return trace.root;
    }

    open_closed_frame_slot(self)!;
    defer catch discard_uploads(self);
    trace.software_requested = !hardware;
    trace.hardware_requested = hardware;
    @pool() {
        record_scene_trace(self, scene)!;
    };
    submit_pending(self)!;
    return trace.root;
}

fn TraceKind? resolve_trace_kind(TraceKind kind, bool ray_queries) @private {
    switch (kind) {
        case AUTO: return ray_queries ? TraceKind.HARDWARE : TraceKind.SOFTWARE;
        case SOFTWARE: return TraceKind.SOFTWARE;
        case HARDWARE:
            if (!ray_queries) return c3d::UNSUPPORTED~;
            return TraceKind.HARDWARE;
    }
}

fn TraceSource trace_source(uint built_revision, uint revision, bool cpu_present) @private {
    if (built_revision != 0 && built_revision == revision) return TraceSource.REUSE;
    return cpu_present ? TraceSource.BUILD : TraceSource.SKIP;
}

// Without CPU arrays only a software level of the same revision proves the list safe to build from.
fn TraceSource blas_source(uint built_revision, uint revision, uint software_revision, bool cpu_present) @private {
    if (built_revision != 0 && built_revision == revision) return TraceSource.REUSE;
    return cpu_present || software_revision == revision ? TraceSource.BUILD : TraceSource.SKIP;
}

fn uint blas_primitive_count(GeometryLayout* layout) @private {
    return layout.index_count ? layout.index_count / 3 : layout.vertex_count / 3;
}

fn gpu::AccelerationStructureGeometryDesc blas_geometry_desc(GeometryLayout* layout) @private {
    gpu::AccelerationStructureIndexType index_type = gpu::AccelerationStructureIndexType.NONE;
    if (layout.index_count) {
        index_type = layout.flags.indices_u16
          ? gpu::AccelerationStructureIndexType.U16
          : gpu::AccelerationStructureIndexType.U32;
    }
    return {
        .kind      = gpu::AccelerationStructureGeometryKind.TRIANGLES,
        .triangles = {
            .max_vertex_count    = layout.vertex_count,
            .max_primitive_count = blas_primitive_count(layout),
            .index_type          = index_type,
        },
    };
}

fn gpu::AccelerationStructureInstanceDesc tlas_instance_desc(TraceInstance* record, uint row) @private {
    Mat4 world = record.world;
    bool masked = (record.flags & shader::TRACE_INSTANCE_ALPHA_MASK) != 0;
    return {
        .transform_row_0 = { world.m00, world.m01, world.m02, world.m03 },
        .transform_row_1 = { world.m10, world.m11, world.m12, world.m13 },
        .transform_row_2 = { world.m20, world.m21, world.m22, world.m23 },
        .bottom_level    = record.bottom_level,
        .custom_index    = row,
        .mask            = record.mask,
        .flags           = { .triangle_cull_disable, .force_opaque = !masked, .force_non_opaque = masked },
    };
}

fn TraceInstance[] collect_trace_instances(
    Allocator allocator,
    Scene* scene,
    AssetStore* assets,
    uint* dangling,
) @private {
    usz capacity = scene.count(Mesh);
    scene.@each(InstancedMesh; Entity entity, InstancedMesh* batch) {
        capacity += batch.count;
    };
    TraceInstance[] records = alloc::new_array(allocator, TraceInstance, (sz)capacity);
    usz count;
    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        Node* node = scene.node(entity);
        if (node.visible_effective && mesh.trace) {
            SkinBinding* skin = scene.get(node, SkinBinding);
            if (!spatial::mesh_is_live(assets, mesh, skin) || !material_shader_live(assets, mesh.material)) {
                (*dangling)++;
            } else if (traceable(
                assets:              assets,
                geometry:            mesh.geometry,
                material:            mesh.material,
                skinned:             skin != null,
                has_bounds_override: mesh.has_bounds_override,
            )) {
                records[count++] = trace_record(
                    assets:      assets,
                    entity:      entity,
                    geometry:    mesh.geometry,
                    material:    mesh.material,
                    world:       node.world,
                    cast_shadow: mesh.cast_shadow,
                );
            }
        }
    };
    scene.@each(InstancedMesh; Entity entity, InstancedMesh* batch) {
        Node* node = scene.node(entity);
        if (node.visible_effective && batch.trace && batch.count) {
            if (!spatial::instanced_mesh_is_live(assets, batch) || !material_shader_live(assets, batch.material)) {
                (*dangling)++;
            } else if (traceable(
                assets:              assets,
                geometry:            batch.geometry,
                material:            batch.material,
                skinned:             false,
                has_bounds_override: batch.has_bounds_override,
            )) {
                foreach (transform : batch.transforms[:batch.count]) {
                    records[count++] = trace_record(
                        assets:      assets,
                        entity:      entity,
                        geometry:    batch.geometry,
                        material:    batch.material,
                        world:       node.world.mul(transform.to_mat4()),
                        cast_shadow: batch.cast_shadow,
                    );
                }
            }
        }
    };
    return records[:count];
}

fn void discard_scene_trace(Renderer* renderer) @private {
    SceneTrace* trace = &renderer.scene_trace;
    foreach (geometry : trace.pending_builds) renderer.geometries[geometry.index].trace.revision = 0;
    trace.pending_builds.clear();
    trace.prepared_frame = 0;
    trace.baseline_count = 0;
    trace.scene = 0;

    RtContext* rt = &renderer.rt;
    foreach (geometry : rt.pending_blas) renderer.geometries[geometry.index].blas.revision = 0;
    rt.pending_blas.clear();
    rt.recorded_blas = 0;
    rt.build_pending = false;
    rt.current_holds_set = false;
}

fn void free_scene_trace(Renderer* renderer) @private {
    SceneTrace* trace = &renderer.scene_trace;
    if (trace.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &trace.allocation);
    if (trace.baseline.len) alloc::free(renderer.allocator, trace.baseline.ptr);
    if (trace.row_records.len) alloc::free(renderer.allocator, trace.row_records.ptr);
    trace.pending_builds.free();
    *trace = {};
}

fn void free_rt(Renderer* renderer) @private {
    RtContext* rt = &renderer.rt;
    foreach (&top_level : rt.top_levels) {
        if (top_level.view.is_valid()) (void)gpu::destroy_acceleration_structure_view(&renderer.device, top_level.view);
        if (top_level.tlas.is_valid()) (void)gpu::destroy_acceleration_structure(&renderer.device, top_level.tlas);
    }
    foreach (&scratch : rt.scratch) {
        if (scratch.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &scratch.allocation);
    }
    rt.pending_blas.free();
    *rt = {};
}

fn void? record_scene_trace(Renderer* renderer, Scene* scene) @local {
    time::Clock started = clock::now();
    defer renderer.stats.trace_build_ms += elapsed_ms(started);
    acquire_scene_trace(renderer)!;

    uint dangling;
    TraceInstance[] records = collect_trace_instances(tmem, scene, renderer.assets, &dangling);
    renderer.stats.dangling_refs += dangling;
    if (records.len > renderer.max_trace_instances) return c3d::CAPACITY_EXCEEDED~;
    records = resolve_trace_instances(renderer, records)!;

    SceneTrace* trace = &renderer.scene_trace;
    RtContext* rt = &renderer.rt;
    bool same_set = trace.scene == scene.identity && trace.baseline_count == records.len;
    bool rows_unchanged = same_set && records_equal(trace.baseline[:records.len], records, TraceInstance::size);
    bool top_level_unchanged = same_set && rt.current_holds_set
        && records_equal(trace.baseline[:records.len], records, TOP_LEVEL_PREFIX_BYTES);

    uint tlas_index;
    if (trace.hardware_requested && records.len) {
        if (!top_level_unchanged) {
            acquire_rt_top_levels(renderer)!;
            bool used_this_frame = rt.used_frame == renderer.frame_index + 1;
            rt.build_target = used_this_frame ? rt.current : (rt.current + 1) % FRAMES_IN_FLIGHT;
            rt.build_after_reads = used_this_frame;
            rt.build_pending = true;
        }
        uint published = rt.build_pending ? rt.build_target : rt.current;
        tlas_index = (uint)rt.top_levels[published].view.index;
        rt.used_frame = renderer.frame_index + 1;
    } else if (!top_level_unchanged) {
        rt.current_holds_set = false;
    }

    if (!rows_unchanged) {
        write_top_level(renderer, scene, records, tlas_index)!;
    } else if (tlas_index != trace.tlas_index) {
        write_trace_root(renderer, tlas_index)!;
    }
    renderer.stats.trace_instances = trace.baseline_count;
    renderer.stats.trace_nodes = trace.top_node_count;
}

fn bool records_equal(TraceInstance[] baseline, TraceInstance[] records, usz prefix_bytes) @local {
    foreach (index, &record : records) {
        if (!mem::equals(&baseline[index], record, (sz)prefix_bytes)) return false;
    }
    return true;
}

fn void? acquire_scene_trace(Renderer* renderer) @local {
    SceneTrace* trace = &renderer.scene_trace;
    if (trace.allocation.is_valid()) return;

    usz capacity = renderer.max_trace_instances;
    usz nodes_offset = SceneTraceRoot::size;
    usz instances_offset = nodes_offset + (2 * capacity - 1) * BvhNodeGpu::size;
    gpu::AllocationDesc desc = {
        .size         = instances_offset + capacity * TraceInstanceGpu::size,
        .alignment    = STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "scene_trace",
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
    defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
    gpu::GpuSpan block = gpu::get_allocation_span(&renderer.device, allocation)!;
    gpu::GpuAddress address = gpu::get_span_address(&renderer.device, block)!;

    trace.allocation = allocation;
    trace.root = address;
    trace.top_nodes = address + (gpu::GpuAddress)nodes_offset;
    trace.instances = address + (gpu::GpuAddress)instances_offset;
    trace.baseline = alloc::alloc_array(renderer.allocator, TraceInstance, (sz)capacity);
    trace.row_records = alloc::alloc_array(renderer.allocator, uint, (sz)capacity);
}

fn TraceInstance[]? resolve_trace_instances(Renderer* renderer, TraceInstance[] records) @local {
    begin_material_scope(renderer);
    defer end_material_scope(renderer);
    bool software = renderer.scene_trace.software_requested;
    bool hardware = renderer.scene_trace.hardware_requested;
    usz kept;
    foreach (&record : records) {
        GeometryAsset* asset_record = renderer.assets.geometry(record.geometry);
        GpuGeometry* mirror = &renderer.geometries[record.geometry.index];
        uint revision = asset_record.header.revision;
        bool cpu_present = asset_record.data.positions.len > 0;
        bool same_asset = mirror.asset.index == record.geometry.index
            && mirror.asset.generation == record.geometry.generation;
        uint software_revision = same_asset ? mirror.trace.revision : 0;
        TraceSource source = trace_source(software_revision, revision, cpu_present);
        TraceSource hardware_source = blas_source(
            built_revision:    same_asset ? mirror.blas.revision : 0,
            revision:          revision,
            software_revision: software_revision,
            cpu_present:       cpu_present,
        );
        bool rejected = same_asset && mirror.trace.rejected_revision == revision;
        bool unavailable = (software && source == TraceSource.SKIP) || (hardware && hardware_source == TraceSource.SKIP);
        if (unavailable || rejected) {
            renderer.stats.trace_skipped++;
            continue;
        }

        mirror = resolve_geometry(renderer, record.geometry)!;
        MaterialRes* material = resolve_material(renderer, record.material)!;
        if (hardware && hardware_source == TraceSource.BUILD && !resolve_blas(renderer, mirror, asset_record)!) {
            renderer.stats.trace_skipped++;
            continue;
        }
        if (software && source == TraceSource.BUILD) {
            Bvh? tree = bvh::build_triangle_bvh(tmem, asset_record.data.positions, asset_record.data.indices);
            // The builder faults only on arrays that form no triangle list, which raster still draws.
            if (catch excuse = tree) {
                mirror.trace.rejected_revision = asset_record.header.revision;
                renderer.stats.trace_skipped++;
                continue;
            }
            upload_trace_geometry(renderer, mirror, &tree)!;
            mirror.trace.revision = asset_record.header.revision;
        }
        record.geometry_root = mirror.root;
        record.material_address = material.address;
        record.bottom_level = mirror.blas.handle;
        record.nodes = mirror.trace.nodes;
        record.primitives = mirror.trace.primitives;
        records[kept++] = *record;
    }
    return records[:kept];
}

// The backend checks no index range, so an unproven list never reaches a build.
fn bool? resolve_blas(Renderer* renderer, GpuGeometry* mirror, GeometryAsset* asset_record) @local {
    Geometry* data = &asset_record.data;
    if (data.positions.len && !bvh::triangle_list_valid(data.positions, data.indices)) {
        mirror.trace.rejected_revision = asset_record.header.revision;
        return false;
    }

    gpu::AccelerationStructureGeometryDesc[1] geometries = { blas_geometry_desc(&mirror.layout) };
    gpu::AccelerationStructureDesc desc = {
        .kind       = gpu::AccelerationStructureKind.BOTTOM_LEVEL,
        .geometries = geometries[..],
        .flags      = { .prefer_fast_trace },
        .debug_name = "geometry_blas",
    };
    gpu::AccelerationStructureRequirements requirements = gpu::get_acceleration_structure_requirements(
        &renderer.device,
        &desc,
    )!;
    gpu::AccelerationStructureHandle handle = gpu::create_acceleration_structure(&renderer.device, &desc)!;
    if (mirror.blas.handle.is_valid()) {
        renderer.pending_upload_retire.push({
            .kind                   = RetiredKind.ACCELERATION_STRUCTURE,
            .acceleration_structure = mirror.blas.handle,
        });
    }
    mirror.blas = {
        .handle       = handle,
        .revision     = asset_record.header.revision,
        .scratch_size = requirements.build_scratch_size,
    };
    renderer.rt.pending_blas.push(mirror.asset);
    renderer.stats.blas_builds++;
    return true;
}

fn void? acquire_rt_top_levels(Renderer* renderer) @local {
    RtContext* rt = &renderer.rt;
    if (rt.top_levels[0].tlas.is_valid()) return;

    gpu::AccelerationStructureDesc desc = {
        .kind               = gpu::AccelerationStructureKind.TOP_LEVEL,
        .max_instance_count = renderer.max_trace_instances,
        .flags              = { .prefer_fast_trace },
    };
    RtTopLevel[FRAMES_IN_FLIGHT] created;
    defer catch {
        foreach (&top_level : created) {
            if (top_level.view.is_valid()) (void)gpu::destroy_acceleration_structure_view(&renderer.device, top_level.view);
            if (top_level.tlas.is_valid()) (void)gpu::destroy_acceleration_structure(&renderer.device, top_level.tlas);
        }
    }
    foreach (index, &top_level : created) {
        desc.debug_name = TOP_LEVEL_NAMES[index];
        top_level.tlas = gpu::create_acceleration_structure(&renderer.device, &desc)!;
        top_level.view = gpu::create_acceleration_structure_view(&renderer.device, top_level.tlas)!;
    }
    rt.top_level_scratch_size = gpu::get_acceleration_structure_requirements(&renderer.device, &desc)!.build_scratch_size;
    rt.top_levels = created;
}

fn void? acquire_rt_scratch(Renderer* renderer, RtScratch* scratch, usz size) @local {
    if (size <= scratch.size) return;

    gpu::AllocationDesc desc = {
        .size         = size,
        .alignment    = renderer.caps.acceleration_structures.scratch_alignment,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "acceleration_scratch",
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
    defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
    gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, allocation)!;
    if (scratch.allocation.is_valid()) {
        renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = scratch.allocation });
    }
    *scratch = { .allocation = allocation, .span = span, .size = size };
}

fn void? record_acceleration_builds(Renderer* renderer, gpu::CommandList* commands) @private {
    RtContext* rt = &renderer.rt;
    GeometryId[] pending = rt.pending_blas.array_view()[rt.recorded_blas..];
    if (!pending.len && !rt.build_pending) return;

    bool profiled = renderer.frame_open;
    if (profiled) begin_profile_pass(renderer, Pass.ACCELERATION_BUILD)!;
    usz scratch_size = rt.build_pending ? rt.top_level_scratch_size : 0;
    foreach (geometry : pending) {
        scratch_size = math::max(scratch_size, renderer.geometries[geometry.index].blas.scratch_size);
    }
    RtScratch* scratch = &rt.scratch[renderer.frame_index % FRAMES_IN_FLIGHT];
    acquire_rt_scratch(renderer, scratch, scratch_size)!;

    gpu::Barrier builds_ordered = { .before = { .acceleration_structure_build }, .after = { .acceleration_structure_build } };
    foreach (geometry : pending) {
        GpuGeometry* mirror = &renderer.geometries[geometry.index];
        gpu::AccelerationStructureGeometryBuildDesc[1] geometries = {{
            .kind      = gpu::AccelerationStructureGeometryKind.TRIANGLES,
            .triangles = {
                .vertices        = mirror.positions,
                .vertex_stride   = PACKED_VEC3_BYTES,
                .vertex_count    = mirror.layout.vertex_count,
                .indices         = mirror.indices,
                .primitive_count = blas_primitive_count(&mirror.layout),
            },
        }};
        gpu::AccelerationStructureBuildDesc build = {
            .destination = mirror.blas.handle,
            .geometries  = geometries[..],
            .scratch     = scratch.span,
        };
        gpu::cmd_build_acceleration_structure(commands, &build)!;
        gpu::cmd_barrier(commands, &builds_ordered)!;
    }
    rt.recorded_blas = (usz)rt.pending_blas.len();

    if (rt.build_pending) {
        if (rt.build_after_reads) {
            gpu::Barrier reads_done = {
                .before = { .fragment_shader, .compute, .acceleration_structure_build },
                .after  = { .acceleration_structure_build },
            };
            gpu::cmd_barrier(commands, &reads_done)!;
        }
        record_top_level_build(renderer, commands, scratch.span)!;
        rt.current = rt.build_target;
        rt.current_holds_set = true;
        rt.build_pending = false;
        renderer.stats.tlas_builds++;
    }
    gpu::Barrier built = { .before = { .acceleration_structure_build }, .after = { .fragment_shader, .compute } };
    gpu::cmd_barrier(commands, &built)!;
    renderer.work_recorded = true;
    if (profiled) end_profile_pass(renderer, Pass.ACCELERATION_BUILD)!;
}

fn void? record_top_level_build(Renderer* renderer, gpu::CommandList* commands, gpu::GpuSpan scratch) @local {
    SceneTrace* trace = &renderer.scene_trace;
    RtContext* rt = &renderer.rt;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    usz bytes = trace.baseline_count * gpu::AccelerationStructureInstance::size;
    gpu::MappedGpuSpan instances = slot.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
    gpu::AccelerationStructureInstance* packed = (gpu::AccelerationStructureInstance*)instances.bytes.ptr;
    for (uint row = 0; row < trace.baseline_count; row++) {
        gpu::AccelerationStructureInstanceDesc desc = tlas_instance_desc(&trace.baseline[trace.row_records[row]], row);
        packed[row] = gpu::make_acceleration_structure_instance(&renderer.device, &desc)!;
    }
    gpu::AccelerationStructureBuildDesc build = {
        .destination    = rt.top_levels[rt.build_target].tlas,
        .instances      = instances.span,
        .instance_count = trace.baseline_count,
        .scratch        = scratch,
    };
    gpu::cmd_build_acceleration_structure(commands, &build)!;
}

fn void? upload_trace_geometry(Renderer* renderer, GpuGeometry* mirror, Bvh* tree) @local {
    usz node_bytes = tree.nodes.len * BvhNodeGpu::size;
    usz primitives_offset = align_up(node_bytes, STREAM_ALIGNMENT);
    usz total_bytes = primitives_offset + tree.primitives.len * uint::size;

    gpu::AllocationDesc desc = {
        .size         = total_bytes,
        .alignment    = STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "trace_geometry",
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
    defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
    gpu::GpuSpan block = gpu::get_allocation_span(&renderer.device, allocation)!;
    gpu::GpuAddress address = gpu::get_span_address(&renderer.device, block)!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, total_bytes, STREAM_ALIGNMENT)!;
    mem::copy(staging.bytes.ptr, tree.nodes.ptr, (sz)node_bytes);
    mem::copy(&staging.bytes[primitives_offset], tree.primitives.ptr, (sz)(tree.primitives.len * uint::size));
    renderer.pending_copies.push({ .src = staging.span, .dst = block.checked_subspan(0, total_bytes)! });

    if (mirror.trace.allocation.is_valid()) {
        renderer.pending_upload_retire.push({
            .kind       = RetiredKind.ALLOCATION,
            .allocation = mirror.trace.allocation,
        });
    }
    mirror.trace = {
        .allocation = allocation,
        .nodes      = address,
        .primitives = address + (gpu::GpuAddress)primitives_offset,
    };
    renderer.scene_trace.pending_builds.push(mirror.asset);
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)total_bytes;
}

fn void? write_top_level(Renderer* renderer, Scene* scene, TraceInstance[] records, uint tlas_index) @local {
    SceneTrace* trace = &renderer.scene_trace;
    Bvh top;
    if (records.len) {
        Aabb[] boxes = alloc::alloc_array(tmem, Aabb, (sz)records.len);
        foreach (index, &record : records) {
            boxes[index] = maths::aabb_transform(renderer.assets.geometry(record.geometry).data.bounds, record.world);
        }
        top = bvh::build_box_bvh(tmem, boxes, TOP_LEVEL_BUILD)!;
    }

    usz node_bytes = top.nodes.len * BvhNodeGpu::size;
    usz instance_bytes = records.len * TraceInstanceGpu::size;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = slot.upload.take(
        device:    &renderer.device,
        size:      SceneTraceRoot::size + node_bytes + instance_bytes,
        alignment: STREAM_ALIGNMENT,
    )!;
    *(SceneTraceRoot*)staging.bytes.ptr = {
        .top_nodes      = trace.top_nodes,
        .instances      = trace.instances,
        .instance_count = (uint)records.len,
        .top_node_count = (uint)top.nodes.len,
        .tlas_index     = tlas_index,
    };
    mem::copy(&staging.bytes[SceneTraceRoot::size], top.nodes.ptr, (sz)node_bytes);
    TraceInstanceGpu* rows = (TraceInstanceGpu*)&staging.bytes[SceneTraceRoot::size + node_bytes];
    foreach (row, primitive : top.primitives) {
        write_trace_instance(&rows[row], &records[primitive]);
        trace.row_records[row] = primitive;
    }

    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, trace.allocation)!;
    renderer.pending_copies.push({
        .src = staging.span.checked_subspan(0, SceneTraceRoot::size)!,
        .dst = destination.checked_subspan(0, SceneTraceRoot::size)!,
    });
    if (records.len) {
        renderer.pending_copies.push({
            .src = staging.span.checked_subspan(SceneTraceRoot::size, node_bytes)!,
            .dst = destination.checked_subspan((usz)(trace.top_nodes - trace.root), node_bytes)!,
        });
        renderer.pending_copies.push({
            .src = staging.span.checked_subspan(SceneTraceRoot::size + node_bytes, instance_bytes)!,
            .dst = destination.checked_subspan((usz)(trace.instances - trace.root), instance_bytes)!,
        });
    }
    renderer.pending_overwrite = true;

    trace.baseline[:records.len] = records[..];
    trace.baseline_count = (uint)records.len;
    trace.top_node_count = (uint)top.nodes.len;
    trace.tlas_index = tlas_index;
    trace.scene = scene.identity;
}

fn void? write_trace_root(Renderer* renderer, uint tlas_index) @local {
    SceneTrace* trace = &renderer.scene_trace;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, SceneTraceRoot::size, STREAM_ALIGNMENT)!;
    *(SceneTraceRoot*)staging.bytes.ptr = {
        .top_nodes      = trace.top_nodes,
        .instances      = trace.instances,
        .instance_count = trace.baseline_count,
        .top_node_count = trace.top_node_count,
        .tlas_index     = tlas_index,
    };
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, trace.allocation)!;
    renderer.pending_copies.push({
        .src = staging.span,
        .dst = destination.checked_subspan(0, SceneTraceRoot::size)!,
    });
    renderer.pending_overwrite = true;
    trace.tlas_index = tlas_index;
}

fn void write_trace_instance(TraceInstanceGpu* row, TraceInstance* record) @local {
    Mat4 world = record.world;
    Mat4 inverse = maths::inverse_affine(world);
    *row = {
        .geometry         = record.geometry_root,
        .material         = record.material_address,
        .flags            = record.flags,
        .material_kind    = record.material_kind,
        .mask             = record.mask,
        .world_to_local_0 = { inverse.m00, inverse.m01, inverse.m02, inverse.m03 },
        .world_to_local_1 = { inverse.m10, inverse.m11, inverse.m12, inverse.m13 },
        .world_to_local_2 = { inverse.m20, inverse.m21, inverse.m22, inverse.m23 },
        .local_to_world_0 = { world.m00, world.m01, world.m02, world.m03 },
        .local_to_world_1 = { world.m10, world.m11, world.m12, world.m13 },
        .local_to_world_2 = { world.m20, world.m21, world.m22, world.m23 },
        .nodes            = record.nodes,
        .primitives       = record.primitives,
    };
}

fn bool material_shader_live(AssetStore* assets, MaterialId material) @local {
    Material* data = &assets.material(material).data;
    return data.kind != MaterialKind.CUSTOM || assets.shaders.is_live(data.custom.shader);
}

fn bool traceable(
    AssetStore* assets,
    GeometryId geometry,
    MaterialId material,
    bool skinned,
    bool has_bounds_override,
) @local {
    return spatial::triangles_are_static(assets.geometry(geometry), skinned, has_bounds_override)
        && assets.material(material).data.common.alpha_mode != AlphaMode.BLEND;
}

fn TraceInstance trace_record(
    AssetStore* assets,
    Entity entity,
    GeometryId geometry,
    MaterialId material,
    Mat4 world,
    bool cast_shadow,
) @local {
    Material* data = &assets.material(material).data;
    uint flags = data.common.alpha_mode == AlphaMode.MASK ? shader::TRACE_INSTANCE_ALPHA_MASK : 0;
    if (data.common.double_sided) flags |= shader::TRACE_INSTANCE_DOUBLE_SIDED;
    return {
        .entity        = entity,
        .flags         = flags,
        .material_kind = (uint)data.kind.ordinal,
        .geometry      = geometry,
        .material      = material,
        .world         = world,
        .mask          = shader::TRACE_MASK_ALL | (cast_shadow ? shader::TRACE_MASK_SHADOW_CASTER : 0),
    };
}
