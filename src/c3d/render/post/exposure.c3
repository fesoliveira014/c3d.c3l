module c3d::render::post;

import c3d;
import c3d::render @public;
import c3d::shader;
import gpu;
import std::math;

<*
 Linear mid-grey that adaptation maps the metered mean to.
*>
const float MID_GRAY = 0.18f; // mirrored as MID_GRAY in grade.glsl

<*
 State slots of a view's exposure; a rendering reads one and writes the other.
*>
const uint EXPOSURE_SLOTS = 2;

const usz EXPOSURE_SLOT_OFFSET @private = ExposureHistogramGpu::size;
const usz EXPOSURE_STATE_BYTES @private = EXPOSURE_SLOT_OFFSET + EXPOSURE_SLOTS * ExposureGpu::size;
const uint EXPOSURE_DISPATCHES @private = 2;
const uint EXPOSURE_METER_SPAN @private = shader::EXPOSURE_GROUP_SIZE * shader::EXPOSURE_METER_STRIDE;
const float EXPOSURE_BINS_PER_STOP @private = (float)shader::EXPOSURE_HISTOGRAM_BINS
  / (shader::EXPOSURE_LOG2_MAX - shader::EXPOSURE_LOG2_MIN); // mirrored as EXPOSURE_BINS_PER_STOP in exposure.glsl

$assert shader::EXPOSURE_GROUP_SIZE * shader::EXPOSURE_GROUP_SIZE == shader::EXPOSURE_HISTOGRAM_BINS;
$assert ExposureHistogramGpu::size == shader::EXPOSURE_HISTOGRAM_BINS * uint::size;

<*
 Percentile mean of one histogram in log2 luminance and the pixels it counted.
*>
struct MeteredLuminance {
    float log2_mean;
    uint  samples;
}

<*
 Committed adapted exposure of one view and the rendering pending publication.
*>
struct ExposureHistory {
    bool   valid;
    bool   snapped; // the committed value is a snap; renderings snap again until time advances
    bool   pending;
    bool   pending_snapped;
    uint   slot;
    double time;
    double pending_time;
    ulong  scene;
    ulong  pending_scene;
}

<*
 Slots, elapsed seconds and snap of one rendering's adaptation.
*>
struct ExposureStep {
    uint  read_slot;
    uint  write_slot;
    float elapsed;
    bool  snap;
}

<*
 Auto-exposure state a view owns from creation to destruction.
*>
struct ViewExposure {
    gpu::GpuAllocation              allocation;
    gpu::GpuSpan                    span;
    gpu::GpuAddress                 address;
    gpu::MappedGpuSpan              readback;
    ExposureHistory                 history;
    float[render::FRAMES_IN_FLIGHT] readback_camera_exposure;
    bool[render::FRAMES_IN_FLIGHT]  readback_pending;
}

<*
 Remember the rendering's time and scene, pending publication, and return its step.
 @param time : "FrameInfo.time of the rendering, in seconds."
 @param scene : "Identity of the metered scene."
*>
fn ExposureStep ExposureHistory.commit(&self, double time, ulong scene) {
    bool current = self.valid && self.scene == scene;
    double elapsed = current ? time - self.time : 0;
    bool snap = !current || (self.snapped && !(elapsed > 0));
    self.pending = true;
    self.pending_time = time;
    self.pending_scene = scene;
    self.pending_snapped = snap;
    return {
        .read_slot  = self.slot,
        .write_slot = (self.slot + 1) % EXPOSURE_SLOTS,
        .elapsed    = (float)elapsed,
        .snap       = snap,
    };
}

<*
 Make the pending rendering's value the committed one.
*>
fn void ExposureHistory.publish(&self) {
    if (!self.pending) return;
    self.valid = true;
    self.pending = false;
    self.snapped = self.pending_snapped;
    self.slot = (self.slot + 1) % EXPOSURE_SLOTS;
    self.time = self.pending_time;
    self.scene = self.pending_scene;
}

<*
 Drop the pending rendering; the committed value, slot and time stay.
*>
fn void ExposureHistory.discard(&self) {
    self.pending = false;
}

<*
 Forget the committed value and its time; the next rendering snaps.
*>
fn void ExposureHistory.invalidate(&self) {
    *self = {};
}

<*
 Restart the history when adaptation turns on; drop queued readbacks when it turns off.
 @param [&in] current : "Configuration the view has."
 @param [&in] next : "Configuration replacing it."
*>
fn void ViewExposure.reconfigure(&self, ViewDesc* current, ViewDesc* next) {
    bool was_active = auto_exposure_active(current);
    bool active = auto_exposure_active(next);
    if (!was_active && active) self.history.invalidate();
    if (was_active && !active) self.readback_pending = {};
}

<*
 Whether the view meters and adapts: auto exposure on a graded DISPLAY_LDR view.
 @param [&in] desc : "Read only."
*>
fn bool auto_exposure_active(ViewDesc* desc) {
    return desc.post.auto_exposure && desc.color == OutputMode.DISPLAY_LDR && !taa_debug_enabled(&desc.post);
}

<*
 Whether a pixel of this luminance counts toward the histogram.
 @pure
*>
fn bool exposure_metered(float luminance) {
    return !math::is_nan(luminance) && !math::is_inf(luminance) && luminance >= shader::EXPOSURE_LUMINANCE_EPSILON;
}

<*
 Histogram bin of a metered luminance; values past the range land in the edge bins.
 @require exposure_metered(luminance)
 @pure
*>
fn uint exposure_bin(float luminance) {
    float position = math::floor((math::log2(luminance) - shader::EXPOSURE_LOG2_MIN) * EXPOSURE_BINS_PER_STOP);
    return (uint)math::clamp(position, 0.0f, (float)(shader::EXPOSURE_HISTOGRAM_BINS - 1));
}

<*
 Log2 luminance at the centre of a histogram bin.
 @require bin < shader::EXPOSURE_HISTOGRAM_BINS
 @pure
*>
fn float exposure_bin_log2(uint bin) {
    return shader::EXPOSURE_LOG2_MIN + ((float)bin + 0.5f) / EXPOSURE_BINS_PER_STOP;
}

<*
 Mean log2 luminance of the samples between two percentiles; the twin of exposure_adapt.comp.
 @param bins : "One count per histogram bin."
 @require bins.len == shader::EXPOSURE_HISTOGRAM_BINS
 @require low_percentile >= 0 && low_percentile < high_percentile && high_percentile <= 1
 @pure
*>
fn MeteredLuminance meter_histogram(uint[] bins, float low_percentile, float high_percentile) {
    uint samples;
    foreach (count : bins) samples += count;
    if (!samples) return {};

    float low = low_percentile * (float)samples;
    float high = high_percentile * (float)samples;
    float weighted_log2;
    float weights;
    uint above;
    foreach (bin, count : bins) {
        float below = (float)above;
        above += count;
        float weight = math::max(math::min((float)above, high) - math::max(below, low), 0.0f);
        weighted_log2 += weight * exposure_bin_log2((uint)bin);
        weights += weight;
    }
    return { .log2_mean = weighted_log2 / weights, .samples = samples };
}

<*
 Stops that bring the metered mean to mid-grey after compensation, inside the bounds.
 @param [&in] params : "Validated settings."
 @pure
*>
fn float exposure_target_ev(AutoExposureParams* params, float metered_log2) {
    float target = math::log2(MID_GRAY) - metered_log2 + params.compensation_ev;
    return math::clamp(target, params.min_ev, params.max_ev);
}

<*
 Stops of the auto multiplier after one rendering; the twin of exposure_adapt.comp.
 A brighter scene lowers exposure over brightening_time, a darker one raises it over darkening_time.
 @param [&in] params : "Validated settings."
 @param current_ev : "Committed stops; ignored when snapping."
 @param current_samples : "Samples of the committed slot; zero snaps."
 @param elapsed : "Seconds since the committed value."
 @pure
*>
fn float adapt_exposure_ev(
    AutoExposureParams* params,
    float current_ev,
    uint current_samples,
    MeteredLuminance metered,
    float elapsed,
    bool snap,
) {
    bool snapping = snap || !current_samples;
    float held = math::clamp(snapping ? 0.0f : current_ev, params.min_ev, params.max_ev);
    if (!metered.samples) return held;
    float target = exposure_target_ev(params, metered.log2_mean);
    if (snapping) return target;

    float time = target < current_ev ? params.brightening_time : params.darkening_time;
    if (time == 0) return target;
    if (!(elapsed > 0)) return held;
    return math::clamp(target + (current_ev - target) * math::exp(-elapsed / time), params.min_ev, params.max_ev);
}

<*
 Allocate the view's exposure state and readback; done once per view.
 @param [&inout] renderer : "Owns the device."
 @param [&inout] record : "Receives the allocations."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::UNSUPPORTED_FEATURE, gpu::SLOT_TABLE_FULL
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? acquire_view_exposure(Renderer* renderer, ViewRecord* record) {
    ViewExposure* exposure = &record.auto_exposure;
    gpu::AllocationDesc state_desc = {
        .size         = EXPOSURE_STATE_BYTES,
        .alignment    = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "view_exposure",
    };
    exposure.allocation = gpu::allocate_memory(&renderer.device, &state_desc)!;
    defer catch release_view_exposure(&renderer.device, record);
    exposure.span = gpu::get_allocation_span(&renderer.device, exposure.allocation)!;
    exposure.address = gpu::get_span_address(&renderer.device, exposure.span)!;

    gpu::AllocationDesc readback_desc = {
        .size         = render::FRAMES_IN_FLIGHT * ExposureGpu::size,
        .alignment    = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "view_exposure_readback",
    };
    exposure.readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!;
}

<*
 Free the view's exposure state; every frame that used it has completed.
 @param [&inout] device : "Owner of the allocations."
 @param [&inout] record : "Its exposure state is left zeroed."
*>
fn void release_view_exposure(gpu::Device* device, ViewRecord* record) {
    ViewExposure* exposure = &record.auto_exposure;
    if (exposure.allocation.is_valid()) (void)gpu::free_allocation(device, &exposure.allocation);
    gpu::GpuAllocation readback = exposure.readback.span.allocation();
    if (readback.is_valid()) (void)gpu::free_allocation(device, &readback);
    *exposure = {};
}

<*
 Meter the view's scene image, adapt its exposure and queue the delayed readback.
 Records nothing unless auto_exposure_active holds.
 @param [&inout] renderer : "Open frame; FrameInfo.time is the adaptation clock."
 @param [&inout] record : "hdr_color holds the scene image before debug lines and temporal passes."
 @param scene : "Identity of the rendered scene; another scene restarts the history."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? record_exposure(Renderer* renderer, ViewRecord* record, ulong scene) {
    if (!auto_exposure_active(&record.desc)) return;
    acquire_exposure_pipelines(renderer)!;
    ViewExposure* exposure = &record.auto_exposure;
    ExposureStep step = exposure.history.commit(renderer.info.time, scene);
    uint frame_slot = (uint)(renderer.frame_index % render::FRAMES_IN_FLIGHT);
    Frame* slot = &renderer.frames[frame_slot];
    AutoExposureParams* params = &record.desc.post.auto_exposure_params;
    gpu::StageMask readers = render::CONSUMER_STAGES;
    readers.transfer = true;

    gpu::GpuSpan histogram = exposure.span.unchecked_subspan(0, ExposureHistogramGpu::size);

    render::@profile_pass(renderer, Pass.EXPOSURE) {
        gpu::Barrier reuse = { .before = readers, .after = { .transfer } };
        gpu::cmd_barrier(&renderer.commands, &reuse)!;
        gpu::cmd_fill_buffer(&renderer.commands, histogram, 0)!;
        gpu::Barrier cleared = { .before = { .transfer }, .after = { .compute } };
        gpu::cmd_barrier(&renderer.commands, &cleared)!;
        record.hdr_color.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;

        gpu::MappedGpuSpan meter = slot.upload.take(&renderer.device, ExposureMeterRoot::size)!;
        *(ExposureMeterRoot*)meter.bytes.ptr = {
            .histogram     = exposure.address,
            .input_texture = record.hdr_color.view.index,
            .width         = record.hdr_color.width,
            .height        = record.hdr_color.height,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.exposure_histogram)!;
        gpu::cmd_dispatch(&renderer.commands, meter.address, exposure_meter_groups(&record.hdr_color))!;
        gpu::Barrier metered = { .before = { .compute }, .after = { .compute } };
        gpu::cmd_barrier(&renderer.commands, &metered)!;

        gpu::MappedGpuSpan adapt = slot.upload.take(&renderer.device, ExposureAdaptRoot::size)!;
        *(ExposureAdaptRoot*)adapt.bytes.ptr = {
            .histogram        = exposure.address,
            .previous         = exposure_slot_address(exposure, step.read_slot),
            .current          = exposure_slot_address(exposure, step.write_slot),
            .elapsed          = step.elapsed,
            .snap             = step.snap ? 1 : 0,
            .compensation_ev  = params.compensation_ev,
            .min_ev           = params.min_ev,
            .max_ev           = params.max_ev,
            .brightening_time = params.brightening_time,
            .darkening_time   = params.darkening_time,
            .low_percentile   = params.low_percentile,
            .high_percentile  = params.high_percentile,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.exposure_adapt)!;
        gpu::cmd_dispatch(&renderer.commands, adapt.address, { 1, 1, 1 })!;
        gpu::Barrier adapted = { .before = { .compute }, .after = readers };
        gpu::cmd_barrier(&renderer.commands, &adapted)!;

        gpu::BufferCopyDesc copy = {
            .src = exposure.span.unchecked_subspan(exposure_slot_offset(step.write_slot), ExposureGpu::size),
            .dst = exposure.readback.span.unchecked_subspan(frame_slot * ExposureGpu::size, ExposureGpu::size),
        };
        gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
        gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
        gpu::cmd_barrier(&renderer.commands, &copied)!;
    }!;
    exposure.readback_camera_exposure[frame_slot] = record.exposure;
    exposure.readback_pending[frame_slot] = true;
    renderer.stats.post_dispatches += EXPOSURE_DISPATCHES;
}

<*
 Copy a completed slot's adapted exposures into the views' stats.
 @param [&inout] renderer : "The slot's completion point has been waited."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? read_exposure_stats(Renderer* renderer, uint slot_index) {
    foreach (&record : renderer.views.items) {
        ViewExposure* exposure = &record.auto_exposure;
        if (!record.live || !exposure.readback_pending[slot_index]) continue;
        gpu::invalidate_mapped_span(&renderer.device, exposure.readback.span)!;
        ExposureGpu* adapted = &((ExposureGpu*)exposure.readback.bytes.ptr)[slot_index];
        record.stats.exposure = exposure.readback_camera_exposure[slot_index] * adapted.scale;
        exposure.readback_pending[slot_index] = false;
    }
}

<*
 Drop the readbacks an unsubmitted frame queued in its slot.
 @param [&inout] renderer : "Its views' readback flags change."
*>
fn void clear_exposure_readback(Renderer* renderer, uint slot_index) {
    foreach (&record : renderer.views.items) {
        if (record.live) record.auto_exposure.readback_pending[slot_index] = false;
    }
}

fn gpu::GpuAddress adapted_exposure(ViewRecord* record) @private {
    ViewExposure* exposure = &record.auto_exposure;
    if (!auto_exposure_active(&record.desc) || !exposure.history.pending) return (gpu::GpuAddress)0;
    return exposure_slot_address(exposure, (exposure.history.slot + 1) % EXPOSURE_SLOTS);
}

fn void? acquire_exposure_pipelines(Renderer* renderer) @private {
    render::acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.exposure_histogram,
        shader:     ShaderName.EXPOSURE_HISTOGRAM,
        debug_name: "post_exposure_histogram",
    )!;
    render::acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.exposure_adapt,
        shader:     ShaderName.EXPOSURE_ADAPT,
        debug_name: "post_exposure_adapt",
    )!;
}

fn gpu::Vec3u exposure_meter_groups(Target* image) @private {
    return {
        .x = (image.width + EXPOSURE_METER_SPAN - 1) / EXPOSURE_METER_SPAN,
        .y = (image.height + EXPOSURE_METER_SPAN - 1) / EXPOSURE_METER_SPAN,
        .z = 1,
    };
}

fn usz exposure_slot_offset(uint slot) @private {
    return EXPOSURE_SLOT_OFFSET + slot * ExposureGpu::size;
}

fn gpu::GpuAddress exposure_slot_address(ViewExposure* exposure, uint slot) @private {
    return (gpu::GpuAddress)((ulong)exposure.address + exposure_slot_offset(slot));
}
