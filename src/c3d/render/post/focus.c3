module c3d::render::post;

import c3d;
import c3d::render @public;
import c3d::shader;
import gpu;
import std::math;

<*
 Committed adapted focus of one view and the rendering pending publication; the rules of ExposureHistory.
*>
alias FocusHistory = ExposureHistory;

const uint FOCUS_SLOTS @private = EXPOSURE_SLOTS;
const usz FOCUS_SLOT_OFFSET @private = FocusHistogramGpu::size;
const usz FOCUS_STATE_BYTES @private = FOCUS_SLOT_OFFSET + FOCUS_SLOTS * FocusGpu::size;
const uint FOCUS_DISPATCHES @private = 2;

$assert shader::FOCUS_GROUP_SIZE * shader::FOCUS_GROUP_SIZE == shader::FOCUS_HISTOGRAM_BINS;
$assert FocusHistogramGpu::size == 2 * shader::FOCUS_HISTOGRAM_BINS * uint::size;

<*
 Auto-focus state a view owns from its first automatic rendering to its destruction.
*>
struct ViewFocus {
    gpu::GpuAllocation             allocation;
    gpu::GpuSpan                   span;
    gpu::GpuAddress                address;
    gpu::MappedGpuSpan             readback;
    FocusHistory                   history;
    bool[render::FRAMES_IN_FLIGHT] readback_pending;
}

<*
 Restart the history when automatic focus turns on; drop queued readbacks when it turns off.
 @param [&in] current : "Configuration the view has."
 @param [&in] next : "Configuration replacing it."
*>
fn void ViewFocus.reconfigure(&self, ViewDesc* current, ViewDesc* next) {
    bool was_active = auto_focus_active(current);
    bool active = auto_focus_active(next);
    if (!was_active && active) self.history.invalidate();
    if (was_active && !active) self.readback_pending = {};
}

<*
 Whether the view meters its focus: depth of field in AUTO mode, with no TAA debug image shown.
 @param [&in] desc : "Read only."
*>
fn bool auto_focus_active(ViewDesc* desc) {
    return desc.post.depth_of_field && desc.post.dof_params.focus_mode == FocusMode.AUTO
      && !taa_debug_enabled(&desc.post);
}

<*
 Free the view's focus state; every frame that used it has completed.
 @param [&inout] device : "Owner of the allocations."
 @param [&inout] record : "Its focus state is left zeroed."
*>
fn void release_view_focus(gpu::Device* device, ViewRecord* record) {
    ViewFocus* focus = &record.focus;
    if (focus.allocation.is_valid()) (void)gpu::free_allocation(device, &focus.allocation);
    gpu::GpuAllocation readback = focus.readback.span.allocation();
    if (readback.is_valid()) (void)gpu::free_allocation(device, &readback);
    *focus = {};
}

<*
 Copy a completed slot's adapted focus distances into the views' stats.
 @param [&inout] renderer : "The slot's completion point has been waited."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? read_focus_stats(Renderer* renderer, uint slot_index) {
    foreach (&record : renderer.views.items) {
        ViewFocus* focus = &record.focus;
        if (!record.live || !focus.readback_pending[slot_index]) continue;

        gpu::invalidate_mapped_span(&renderer.device, focus.readback.span)!;
        FocusGpu* adapted = &((FocusGpu*)focus.readback.bytes.ptr)[slot_index];
        record.stats.focus_distance = adapted.distance;
        focus.readback_pending[slot_index] = false;
    }
}

<*
 Drop the readbacks an unsubmitted frame queued in its slot.
 @param [&inout] renderer : "Its views' readback flags change."
*>
fn void clear_focus_readback(Renderer* renderer, uint slot_index) {
    foreach (&record : renderer.views.items) {
        if (record.live) record.focus.readback_pending[slot_index] = false;
    }
}

fn void? acquire_view_focus(Renderer* renderer, ViewRecord* record) @private {
    ViewFocus* focus = &record.focus;
    gpu::AllocationDesc state_desc = {
        .size         = FOCUS_STATE_BYTES,
        .alignment    = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "view_focus",
    };

    focus.allocation = gpu::allocate_memory(&renderer.device, &state_desc)!;
    defer catch release_view_focus(&renderer.device, record);
    focus.span = gpu::get_allocation_span(&renderer.device, focus.allocation)!;
    focus.address = gpu::get_span_address(&renderer.device, focus.span)!;

    gpu::AllocationDesc readback_desc = {
        .size         = render::FRAMES_IN_FLIGHT * FocusGpu::size,
        .alignment    = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "view_focus_readback",
    };

    focus.readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!;
}

fn void? acquire_focus_pipelines(Renderer* renderer) @private {
    render::acquire_compute_slot(renderer, ComputeSlot.FOCUS_HISTOGRAM)!;
    render::acquire_compute_slot(renderer, ComputeSlot.FOCUS_ADAPT)!;
}

fn usz focus_slot_offset(uint slot) @private {
    return FOCUS_SLOT_OFFSET + slot * FocusGpu::size;
}

fn gpu::GpuAddress focus_slot_address(ViewFocus* focus, uint slot) @private {
    return (gpu::GpuAddress)((ulong)focus.address + focus_slot_offset(slot));
}

fn gpu::GpuAddress adapted_focus(ViewRecord* record) @private {
    ViewFocus* focus = &record.focus;
    if (!auto_focus_active(&record.desc) || !focus.history.pending) return (gpu::GpuAddress)0;

    return focus_slot_address(focus, (focus.history.slot + 1) % FOCUS_SLOTS);
}

fn float focus_lens_scale(DofParams* params, uint half_height) @private {
    return 0.5f * params.focal_length * params.focal_length / params.aperture * (float)half_height / SENSOR_HEIGHT;
}

fn uint focus_groups(uint extent) @private {
    return (extent + shader::FOCUS_GROUP_SIZE - 1) / shader::FOCUS_GROUP_SIZE;
}

fn void? record_focus(Renderer* renderer, ViewRecord* record) @private {
    acquire_focus_pipelines(renderer)!;
    if (!record.focus.allocation.is_valid()) acquire_view_focus(renderer, record)!;

    ViewFocus* focus = &record.focus;
    DofParams* params = &record.desc.post.dof_params;
    ExposureStep step = focus.history.commit(renderer.info.time, record.last_scene);
    uint frame_slot = (uint)(renderer.frame_index % render::FRAMES_IN_FLIGHT);
    Frame* slot = &renderer.frames[frame_slot];
    gpu::StageMask readers = render::CONSUMER_STAGES;
    readers.transfer = true;

    uint width = record.depth.width;
    uint height = record.depth.height;
    uint center_x = math::min((uint)(params.focus_point.x * (float)width), width - 1);
    uint center_y = math::min((uint)(params.focus_point.y * (float)height), height - 1);
    float radius = math::min(params.focus_radius, (float)math::max(width, height));
    uint reach = (uint)radius;
    uint origin_x = center_x - math::min(center_x, reach);
    uint origin_y = center_y - math::min(center_y, reach);
    gpu::Vec3u groups = {
        .x = focus_groups(math::min(center_x + reach, width - 1) - origin_x + 1),
        .y = focus_groups(math::min(center_y + reach, height - 1) - origin_y + 1),
        .z = 1,
    };

    gpu::GpuSpan histogram = focus.span.unchecked_subspan(0, FocusHistogramGpu::size);

    gpu::Barrier reuse = { .before = readers, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &reuse)!;
    gpu::cmd_fill_buffer(&renderer.commands, histogram, 0)!;
    gpu::Barrier cleared = { .before = { .transfer }, .after = { .compute } };
    gpu::cmd_barrier(&renderer.commands, &cleared)!;
    record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;

    gpu::MappedGpuSpan meter = slot.upload.take(&renderer.device, FocusMeterRoot::size)!;
    *(FocusMeterRoot*)meter.bytes.ptr = {
        .histogram     = focus.address,
        .depth_texture = record.depth.view.index,
        .width         = width,
        .height        = height,
        .center_x      = center_x,
        .center_y      = center_y,
        .radius        = radius,
        .origin_x      = origin_x,
        .origin_y      = origin_y,
        .orthographic  = record.projection_terms.orthographic ? 1 : 0,
        .proj_22       = record.projection_terms.m22,
        .proj_23       = record.projection_terms.m23,
    };

    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.focus_histogram)!;
    gpu::cmd_dispatch(&renderer.commands, meter.address, groups)!;
    gpu::Barrier metered = { .before = { .compute }, .after = { .compute } };
    gpu::cmd_barrier(&renderer.commands, &metered)!;

    gpu::MappedGpuSpan adapt = slot.upload.take(&renderer.device, FocusAdaptRoot::size)!;
    *(FocusAdaptRoot*)adapt.bytes.ptr = {
        .histogram         = focus.address,
        .previous          = focus_slot_address(focus, step.read_slot),
        .current           = focus_slot_address(focus, step.write_slot),
        .elapsed           = step.elapsed,
        .snap              = step.snap ? 1 : 0,
        .focus_time        = params.focus_time,
        .fallback_distance = params.focus_distance,
        .focal_length      = params.focal_length,
        .lens_scale        = focus_lens_scale(params, record.dof_near.height),
    };

    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.focus_adapt)!;
    gpu::cmd_dispatch(&renderer.commands, adapt.address, { 1, 1, 1 })!;
    gpu::Barrier adapted = { .before = { .compute }, .after = readers };
    gpu::cmd_barrier(&renderer.commands, &adapted)!;

    gpu::BufferCopyDesc copy = {
        .src = focus.span.unchecked_subspan(focus_slot_offset(step.write_slot), FocusGpu::size),
        .dst = focus.readback.span.unchecked_subspan(frame_slot * FocusGpu::size, FocusGpu::size),
    };

    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &copied)!;

    focus.readback_pending[frame_slot] = true;
    renderer.stats.post_dispatches += FOCUS_DISPATCHES;
}
