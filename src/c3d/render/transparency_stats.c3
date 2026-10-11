module c3d::render;

import c3d;
import c3d::shader;
import gpu;

const usz TRANSPARENCY_COUNTER_BYTES @private = 2 * uint::size; // Shader pixel count and flag.
const uint TRANSPARENCY_OVERFLOW_GROUP_SIZE @private = 8; // Matches transparency_overflow.comp.glsl local size.

enum TransparencyWork @private {
    CAPTURE,
    RETAINED,
    REMAINDER,
    RESOLVE,
    FILTER,
}

<*
 Recorded transparency work and frame-tagged completed overflow.
*>
struct TransparencyStats {
    uint capture_passes;
    uint retained_passes;
    uint remainder_passes;
    uint resolve_passes;
    uint filter_passes;
    uint filter_dispatches;
    uint filtered_mips;
    uint fallback_draws;
    uint overflow_dispatches;
    uint overflow_pixels;
    bool overflow;
    ulong overflow_frame_index;
    bool overflow_valid;
    usz payload_bytes;
}

struct TransparencyReadback @private {
    gpu::MappedGpuSpan mapped;
    ulong frame_index;
    bool recorded;
    bool submitted;
}

struct TransparencyReadbacks @private {
    TransparencyReadback[FRAMES_IN_FLIGHT] slots;
}

fn TransparencyReadbacks? create_transparency_readbacks(Renderer* renderer) @private {
    TransparencyReadbacks readbacks;
    defer catch release_transparency_readbacks(&renderer.device, &readbacks);

    gpu::AllocationDesc desc = {
        .size = TRANSPARENCY_COUNTER_BYTES,
        .alignment = uint::alignment,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "transparency_overflow_readback",
    };
    foreach (&slot : readbacks.slots) {
        slot.mapped = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    }

    return readbacks;
}

fn void release_transparency_readbacks(gpu::Device* device, TransparencyReadbacks* readbacks) @private {
    foreach (&slot : readbacks.slots) {
        if (!slot.mapped.bytes.len) continue;

        gpu::GpuAllocation allocation = slot.mapped.span.allocation();
        (void)gpu::free_allocation(device, &allocation);
    }

    *readbacks = {};
}

fn void retire_transparency_readbacks(RetireList* retire, TransparencyReadbacks* readbacks) @private {
    foreach (slot : readbacks.slots) {
        if (!slot.mapped.bytes.len) continue;

        retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = slot.mapped.span.allocation() });
    }

    *readbacks = {};
}

fn void reset_transparency_stats(TransparencyStats* stats) @private {
    TransparencyStats previous = *stats;
    *stats = {};
    stats.overflow_pixels = previous.overflow_pixels;
    stats.overflow = previous.overflow;
    stats.overflow_frame_index = previous.overflow_frame_index;
    stats.overflow_valid = previous.overflow_valid;
    stats.payload_bytes = previous.payload_bytes;
}

fn Pass transparency_work_pass(TransparencyWork work) @private {
    switch (work) {
        case CAPTURE: return Pass.TRANSPARENCY_CAPTURE;
        case RETAINED: return Pass.TRANSPARENCY_RETAINED;
        case REMAINDER: return Pass.TRANSPARENCY_REMAINDER;
        case RESOLVE: return Pass.TRANSPARENCY_RESOLVE;
        case FILTER: return Pass.TRANSPARENCY_FILTER;
    }
}

fn void count_transparency_work(
    Renderer* renderer,
    TransparencyStats* stats,
    TransparencyWork work,
    uint passes = 1,
) @private {
    switch (work) {
        case CAPTURE:
            stats.capture_passes += passes;
            renderer.stats.transparency_capture_passes += passes;
        case RETAINED:
            stats.retained_passes += passes;
            renderer.stats.transparency_retained_passes += passes;
        case REMAINDER:
            stats.remainder_passes += passes;
            renderer.stats.transparency_remainder_passes += passes;
        case RESOLVE:
            stats.resolve_passes += passes;
            renderer.stats.transparency_resolve_passes += passes;
        case FILTER:
            stats.filter_passes += passes;
            renderer.stats.transparency_filter_passes += passes;
    }
}

fn void count_transparency_filter(Renderer* renderer, TransparencyStats* stats, uint mip_count) @private {
    count_transparency_work(renderer, stats, TransparencyWork.FILTER);
    stats.filter_dispatches += mip_count;
    stats.filtered_mips += mip_count - 1;
    renderer.stats.transparency_filter_dispatches += mip_count;
    renderer.stats.transparency_filtered_mips += mip_count - 1;
}

fn void count_transparency_fallback(Renderer* renderer, TransparencyStats* stats, uint draws) @private {
    stats.fallback_draws += draws;
    renderer.stats.transparency_fallback_draws += draws;
}

fn void account_transparency_payload(
    Renderer* renderer,
    TransparencyStats* stats,
    TransparencyReadbacks* readbacks,
    usz image_bytes,
) @private {
    usz bytes = image_bytes;
    foreach (slot : readbacks.slots) bytes += slot.mapped.bytes.len;

    stats.payload_bytes = bytes;
    refresh_transparency_payload(renderer);
}

fn void refresh_transparency_payload(Renderer* renderer) @private {
    renderer.stats.transparency_payload_bytes = 0;
    foreach (&record : renderer.views.items) {
        if (!record.live) continue;

        usz bytes = record.transparency.texel_bytes + record.scene_pyramid.texel_bytes;
        foreach (slot : record.transparency_readbacks.slots) bytes += slot.mapped.bytes.len;
        record.stats.transparency.payload_bytes = bytes;
        renderer.stats.transparency_payload_bytes += bytes;
    }
}

fn void retire_disabled_transparency_readbacks(Renderer* renderer, ViewRecord* record) @private {
    if (record.desc.transparency.mode == TransparencyMode.LAYERED
      && record.desc.shading != ShadingPath.PATH_TRACED) return;

    retire_transparency_readbacks(last_submitted_retire(renderer), &record.transparency_readbacks);
    record.stats.transparency = {};
}

fn void? record_transparency_overflow(
    Renderer* renderer,
    TransparencyReadbacks* readbacks,
    TransparencyStats* stats,
    Target* depth,
) @private {
    if (!readbacks.slots[0].mapped.bytes.len) *readbacks = create_transparency_readbacks(renderer)!;

    acquire_compute_pipeline(
        renderer: renderer,
        pipeline: &renderer.transparency_overflow_pipeline,
        shader: TRANSPARENCY_OVERFLOW,
        debug_name: "transparency_overflow",
    )!;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan counters = frame.upload.take(&renderer.device, TRANSPARENCY_COUNTER_BYTES, uint::alignment)!;
    *(uint[2]*)counters.bytes.ptr = {};
    TransparencyOverflowRoot root = {
        .counters = counters.address,
        .depth = depth.view.index,
        .width = depth.width,
        .height = depth.height,
    };
    gpu::GpuAddress address = upload_bytes(renderer, &root, TransparencyOverflowRoot::size)!;
    gpu::TextureState previous = depth.state;
    depth.transition(&renderer.commands, { .layout = gpu::TextureLayout.SAMPLED,
        .stages = { .compute }, .access = { .read } })!;

    gpu::Barrier host_to_compute = { .before = { .host }, .after = { .compute } };
    gpu::cmd_barrier(&renderer.commands, &host_to_compute)!;
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.transparency_overflow_pipeline)!;
    gpu::cmd_dispatch(&renderer.commands, address, {
        (depth.width + TRANSPARENCY_OVERFLOW_GROUP_SIZE - 1) / TRANSPARENCY_OVERFLOW_GROUP_SIZE,
        (depth.height + TRANSPARENCY_OVERFLOW_GROUP_SIZE - 1) / TRANSPARENCY_OVERFLOW_GROUP_SIZE,
        1,
    })!;
    gpu::Barrier compute_to_copy = { .before = { .compute }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &compute_to_copy)!;
    TransparencyReadback* slot = &readbacks.slots[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::BufferCopyDesc copy = { .src = counters.span, .dst = slot.mapped.span };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier copy_to_host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &copy_to_host)!;
    depth.transition(&renderer.commands, previous)!;

    slot.recorded = true;
    slot.frame_index = renderer.frame_index;
    stats.overflow_dispatches++;
    renderer.stats.transparency_overflow_dispatches++;
    renderer.work_recorded = true;
}

fn void publish_transparency_readbacks(TransparencyReadbacks* readbacks, uint slot_index) @private {
    TransparencyReadback* slot = &readbacks.slots[slot_index];
    if (!slot.recorded) return;

    slot.submitted = true;
    slot.recorded = false;
}

fn void discard_transparency_readbacks(TransparencyReadbacks* readbacks, uint slot_index) @private {
    readbacks.slots[slot_index].recorded = false;
}

fn void? read_transparency_stats(Renderer* renderer, uint slot_index) @private {
    foreach (&record : renderer.views.items) {
        if (!record.live) continue;

        TransparencyStats* stats = &record.stats.transparency;
        TransparencyReadback* slot = &record.transparency_readbacks.slots[slot_index];
        if (!slot.submitted) continue;

        gpu::invalidate_mapped_span(&renderer.device, slot.mapped.span)!;
        uint* counters = (uint*)slot.mapped.bytes.ptr;
        stats.overflow_pixels = counters[0];
        stats.overflow = counters[1] != 0;
        stats.overflow_frame_index = slot.frame_index;
        stats.overflow_valid = true;
        renderer.stats.transparency_overflow_pixels += counters[0];
        renderer.stats.transparency_overflow |= counters[1] != 0;
        renderer.stats.transparency_overflow_frame_index = slot.frame_index;
        renderer.stats.transparency_overflow_results++;
        slot.submitted = false;
    }

    refresh_transparency_payload(renderer);
}
