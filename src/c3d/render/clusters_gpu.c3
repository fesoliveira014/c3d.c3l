module c3d::render;

import c3d;
import c3d::camera;
import c3d::shader;
import gpu;
import std::math;

<* Owned allocation containing one view's lighting and cluster lists. *>
struct ClusterBuffers {
    gpu::GpuAllocation allocation;
    gpu::GpuSpan span;
    gpu::GpuAddress address;
    ClusterLayout layout;
}

<* Borrowed lighting roots and depth mapping for one recorded view. *>
struct ClusterFrame {
    gpu::GpuAddress lights;
    gpu::GpuAddress clusters;
    ClusterDepth depth;
}

<* Owned frame-slot mapping and metadata for completed cluster statistics. *>
struct ClusterReadback {
    gpu::MappedGpuSpan mapped;
    ViewId view;
    uint cluster_count;
    bool pending;
}

fn ClusterBuffers? create_cluster_buffers(Renderer* renderer, ClusterLayout layout) @private {
    gpu::AllocationDesc desc = {
        .size = layout.size,
        .alignment = STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access = { .graphics },
        .debug_name = "view_clusters",
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
    defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
    gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, allocation)!;
    gpu::GpuAddress address = gpu::get_span_address(&renderer.device, span)!;
    return { .allocation = allocation, .span = span, .address = address, .layout = layout };
}

fn void retire_cluster_buffers(Renderer* renderer, ClusterBuffers* buffers) @private {
    if (buffers.allocation.is_valid()) {
        Frame* slot = &renderer.frames[(renderer.frame_index + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT];
        slot.retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = buffers.allocation });
    }
    *buffers = {};
}

fn void destroy_cluster_buffers(gpu::Device* device, ClusterBuffers* buffers) @private {
    if (buffers.allocation.is_valid()) (void)gpu::free_allocation(device, &buffers.allocation);
    *buffers = {};
}

fn ClusterFrame? prepare_cluster_frame(
    Renderer* renderer,
    ViewRecord* record,
    camera::Camera* camera,
    camera::CameraMatrices* matrices,
    LightGpu[] lights,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    ClusterFrame result = { .depth = cluster_depth(camera, record.desc.clusters) };
    bool active = result.depth.near < result.depth.far;
    begin_profile_pass(renderer, Pass.LIGHT_CULL)!;

    gpu::StageMask previous = CONSUMER_STAGES;
    previous.transfer = true;
    gpu::Barrier reuse = { .before = previous, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &reuse)!;
    if (lights.len) {
        usz bytes = lights.len * LightGpu::size;
        gpu::MappedGpuSpan staged = slot.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
        mem::copy(staged.bytes.ptr, lights.ptr, lights.len * LightGpu::size);
        gpu::BufferCopyDesc copy = {
            .src = staged.span,
            .dst = record.clusters.span.unchecked_subspan(0, bytes),
        };
        gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
        result.lights = record.clusters.address;
    }
    if (active) {
        gpu::GpuSpan counter = record.clusters.span.unchecked_subspan(
            record.clusters.layout.counter_offset, ClusterCounterGpu::size);
        gpu::cmd_fill_buffer(&renderer.commands, counter, 0)!;
    }
    gpu::Barrier uploaded = { .before = { .transfer }, .after = CONSUMER_STAGES };
    gpu::cmd_barrier(&renderer.commands, &uploaded)!;
    if (!active) return result;

    gpu::GpuAddress globals;
    uint global_count;
    if (lights.len) {
        gpu::MappedGpuSpan indices = slot.upload.take(&renderer.device, lights.len * uint::size, STREAM_ALIGNMENT)!;
        global_count = pack_global_light_indices(lights, ((uint*)indices.bytes.ptr)[:lights.len]);
        if (global_count) globals = indices.address;
    }
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, ClusterGpu::size, STREAM_ALIGNMENT)!;
    ClusterDesc desc = record.desc.clusters;
    *((ClusterGpu*)root.bytes.ptr) = {
        .ranges = (gpu::GpuAddress)((ulong)record.clusters.address + record.clusters.layout.ranges_offset),
        .indices = (gpu::GpuAddress)((ulong)record.clusters.address + record.clusters.layout.indices_offset),
        .globals = globals,
        .counter = (gpu::GpuAddress)((ulong)record.clusters.address + record.clusters.layout.counter_offset),
        .depth = { result.depth.near, result.depth.far, result.depth.scale, result.depth.bias },
        .tiles_x = desc.tiles_x,
        .tiles_y = desc.tiles_y,
        .depth_slices = desc.depth_slices,
        .lights_per_cluster = desc.lights_per_cluster,
        .global_count = global_count,
        .orthographic = camera.projection == camera::Projection.ORTHOGRAPHIC ? 1 : 0,
        .view_proj = bitcast(matrices.view_proj, Mat4f),
    };
    result.clusters = root.address;
    return result;
}

fn void? record_clusters(
    Renderer* renderer,
    ViewRecord* record,
    ViewId view,
    gpu::MappedGpuSpan frame,
) @private {
    FrameRoot* root = (FrameRoot*)frame.bytes.ptr;
    if (root.clusters != (gpu::GpuAddress)0) {
        acquire_environment_pipeline(renderer, &renderer.cluster_pipeline, LIGHT_CULL)!;
        ClusterReadback* readback = &record.cluster_readback[renderer.frame_index % FRAMES_IN_FLIGHT];
        if (!readback.mapped.span.allocation().is_valid()) {
            gpu::AllocationDesc desc = {
                .size = ClusterCounterGpu::size,
                .alignment = STREAM_ALIGNMENT,
                .memory_class = gpu::MemoryClass.CPU_READ,
                .access = { .graphics },
                .debug_name = "cluster_readback",
            };
            readback.mapped = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
        }
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.cluster_pipeline)!;
        ClusterDesc desc = record.desc.clusters;
        gpu::cmd_dispatch(&renderer.commands, frame.address, { desc.tiles_x, desc.tiles_y, desc.depth_slices })!;
        gpu::StageMask consumers = CONSUMER_STAGES;
        consumers.transfer = true;
        gpu::Barrier assigned = { .before = { .compute }, .after = consumers };
        gpu::cmd_barrier(&renderer.commands, &assigned)!;
        gpu::BufferCopyDesc copy = {
            .src = record.clusters.span.unchecked_subspan(
                offset: record.clusters.layout.counter_offset,
                size: ClusterCounterGpu::size,
            ),
            .dst = readback.mapped.span,
        };
        gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
        gpu::Barrier completed = { .before = { .transfer }, .after = { .host } };
        gpu::cmd_barrier(&renderer.commands, &completed)!;
        readback.view = view;
        readback.cluster_count = record.clusters.layout.cluster_count;
        readback.pending = true;
    }
    end_profile_pass(renderer, Pass.LIGHT_CULL)!;
}

fn void clear_cluster_readback(Renderer* renderer, uint slot_index) @private {
    foreach (&record : renderer.views.items) {
        if (record.live) record.cluster_readback[slot_index].pending = false;
    }
}

fn void? reset_cluster_recording(Renderer* renderer) @private {
    clear_cluster_readback(renderer, (uint)(renderer.frame_index % FRAMES_IN_FLIGHT));
}

fn void? read_cluster_stats(Renderer* renderer, uint slot_index) @private {
    foreach (&record : renderer.views.items) {
        ClusterReadback* readback = &record.cluster_readback[slot_index];
        if (!record.live || !readback.pending) continue;
        gpu::invalidate_mapped_span(&renderer.device, readback.mapped.span)!;
        ClusterCounterGpu* counter = (ClusterCounterGpu*)readback.mapped.bytes.ptr;
        record.stats.cluster_count = readback.cluster_count;
        record.stats.cluster_overflows = counter.overflows;
        renderer.stats.cluster_view = readback.view;
        renderer.stats.cluster_count = readback.cluster_count;
        renderer.stats.cluster_overflows = counter.overflows;
        readback.pending = false;
    }
}

fn void release_cluster_readback(gpu::Device* device, ViewRecord* record) @private {
    foreach (&readback : record.cluster_readback) {
        gpu::GpuAllocation allocation = readback.mapped.span.allocation();
        if (allocation.is_valid()) (void)gpu::free_allocation(device, &allocation);
        *readback = {};
    }
}

fn void release_cluster_resources(Renderer* renderer) @private {
    foreach (&record : renderer.views.items) {
        if (record.live) release_cluster_readback(&renderer.device, record);
    }
    if (renderer.cluster_pipeline.is_valid()) {
        (void)gpu::destroy_pipeline(&renderer.device, renderer.cluster_pipeline);
        renderer.cluster_pipeline = {};
    }
}
