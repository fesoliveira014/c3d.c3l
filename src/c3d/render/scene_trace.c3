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

const BvhBuildDesc TOP_LEVEL_BUILD @private = { .bins = 12, .leaf_size = 1 }; // an instance test walks a whole bottom level

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
    gpu::GpuAddress geometry_root;
    gpu::GpuAddress material_address;
    gpu::GpuAddress nodes;
    gpu::GpuAddress primitives;
}
// The dirty test compares records bytewise, so the record carries no padding.
$assert TraceInstance::size == 128;

struct SceneTrace @private {
    ulong              scene;
    TraceInstance[]    baseline;
    uint               baseline_count;
    uint               top_node_count;
    gpu::GpuAllocation allocation;
    gpu::GpuAddress    root;
    gpu::GpuAddress    top_nodes;
    gpu::GpuAddress    instances;
    ulong              prepared_frame; // frame_index + 1 of the last in-frame preparation
    List{GeometryId}   pending_builds;
}

<*
 Build or reuse the scene's trace data; completes without a window when no frame is open.
 @param [&inout] self : "Owns queued trace copies and their submission."
 @param [&in] scene : "Pose as left by the last update_world."
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
fn gpu::GpuAddress? Renderer.prepare_scene_trace(&self, Scene* scene) {
    SceneTrace* trace = &self.scene_trace;
    if (self.frame_open) {
        bool prepared = trace.prepared_frame == self.frame_index + 1 && trace.scene == scene.identity;
        if (!prepared) {
            @pool() {
                record_scene_trace(self, scene)!;
            };
            trace.prepared_frame = self.frame_index + 1;
        }
        return trace.root;
    }

    open_closed_frame_slot(self)!;
    defer catch discard_uploads(self);
    @pool() {
        record_scene_trace(self, scene)!;
    };
    submit_pending(self)!;
    return trace.root;
}

fn TraceSource trace_source(uint built_revision, uint revision, bool cpu_present) @private {
    if (built_revision != 0 && built_revision == revision) return TraceSource.REUSE;
    return cpu_present ? TraceSource.BUILD : TraceSource.SKIP;
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
            } else if (traceable(assets, mesh.geometry, mesh.material, skin != null, mesh.has_bounds_override)) {
                records[count++] = trace_record(
                    assets:   assets,
                    entity:   entity,
                    geometry: mesh.geometry,
                    material: mesh.material,
                    world:    node.world,
                );
            }
        }
    };
    scene.@each(InstancedMesh; Entity entity, InstancedMesh* batch) {
        Node* node = scene.node(entity);
        if (node.visible_effective && batch.trace && batch.count) {
            if (!spatial::instanced_mesh_is_live(assets, batch) || !material_shader_live(assets, batch.material)) {
                (*dangling)++;
            } else if (traceable(assets, batch.geometry, batch.material, false, batch.has_bounds_override)) {
                foreach (transform : batch.transforms[:batch.count]) {
                    records[count++] = trace_record(
                        assets:   assets,
                        entity:   entity,
                        geometry: batch.geometry,
                        material: batch.material,
                        world:    node.world.mul(transform.to_mat4()),
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
}

fn void free_scene_trace(Renderer* renderer) @private {
    SceneTrace* trace = &renderer.scene_trace;
    if (trace.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &trace.allocation);
    if (trace.baseline.len) alloc::free(renderer.allocator, trace.baseline.ptr);
    trace.pending_builds.free();
    *trace = {};
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
    bool unchanged = trace.scene == scene.identity && trace.baseline_count == records.len
        && mem::equals(trace.baseline.ptr, records.ptr, (sz)(records.len * TraceInstance::size));
    if (!unchanged) write_top_level(renderer, scene, records)!;
    renderer.stats.trace_instances = trace.baseline_count;
    renderer.stats.trace_nodes = trace.top_node_count;
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
}

fn TraceInstance[]? resolve_trace_instances(Renderer* renderer, TraceInstance[] records) @local {
    begin_material_scope(renderer);
    defer end_material_scope(renderer);
    usz kept;
    foreach (&record : records) {
        GeometryAsset* asset_record = renderer.assets.geometry(record.geometry);
        GpuGeometry* mirror = &renderer.geometries[record.geometry.index];
        bool same_asset = mirror.asset.index == record.geometry.index
            && mirror.asset.generation == record.geometry.generation;
        TraceSource source = trace_source(
            same_asset ? mirror.trace.revision : 0,
            asset_record.header.revision,
            asset_record.data.positions.len > 0,
        );
        if (source == TraceSource.SKIP) {
            renderer.stats.trace_skipped++;
            continue;
        }

        mirror = resolve_geometry(renderer, record.geometry)!;
        MaterialRes* material = resolve_material(renderer, record.material)!;
        if (source == TraceSource.BUILD) build_trace_geometry(renderer, mirror, asset_record)!;
        record.geometry_root = mirror.root;
        record.material_address = material.address;
        record.nodes = mirror.trace.nodes;
        record.primitives = mirror.trace.primitives;
        records[kept++] = *record;
    }
    return records[:kept];
}

fn void? build_trace_geometry(Renderer* renderer, GpuGeometry* mirror, GeometryAsset* record) @local {
    Bvh tree = bvh::build_triangle_bvh(tmem, record.data.positions, record.data.indices)!;
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
        renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = mirror.trace.allocation });
    }
    mirror.trace = {
        .allocation = allocation,
        .nodes      = address,
        .primitives = address + (gpu::GpuAddress)primitives_offset,
        .revision   = record.header.revision,
    };
    renderer.scene_trace.pending_builds.push(mirror.asset);
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)total_bytes;
}

fn void? write_top_level(Renderer* renderer, Scene* scene, TraceInstance[] records) @local {
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
    };
    mem::copy(&staging.bytes[SceneTraceRoot::size], top.nodes.ptr, (sz)node_bytes);
    TraceInstanceGpu* rows = (TraceInstanceGpu*)&staging.bytes[SceneTraceRoot::size + node_bytes];
    foreach (row, primitive : top.primitives) write_trace_instance(&rows[row], &records[primitive]);

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
    trace.scene = scene.identity;
}

fn void write_trace_instance(TraceInstanceGpu* row, TraceInstance* record) @local {
    Mat4 world = record.world;
    Mat4 inverse = maths::inverse_affine(world);
    *row = {
        .geometry         = record.geometry_root,
        .material         = record.material_address,
        .flags            = record.flags,
        .material_kind    = record.material_kind,
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
    };
}
