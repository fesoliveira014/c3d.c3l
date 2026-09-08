module c3d::render;

import c3d;
import c3d::asset;
import c3d::pool;
import c3d::shader;
import gpu;
import std::collections::list;
import std::math;
import std::time;
import std::time::clock;

<*
 Supplies the presentation surface once the renderer's runtime exists.
*>
alias SurfaceFn = fn gpu::Surface? (gpu::Runtime* runtime, void* user);

<*
 Frame slots the renderer records into in rotation.
*>
const uint FRAMES_IN_FLIGHT = 2;

const uint COMMAND_BUFFERS_PER_FRAME @private = 4; // one list per frame, with room for the ordered views of later work
const ulong ACQUIRE_TIMEOUT_NS @private = 1_000_000_000; // the vsync wait; a stalled compositor costs one frame, not a hang
const ulong RETIRE_TIMEOUT_NS @private = 1_000_000; // one bounded presentation wait per frame, so recovery never blocks the loop
const uint TEARDOWN_RETIRE_ATTEMPTS @private = 64; // teardown cannot pump events, so its presentation wait is bounded

const ZString[FRAMES_IN_FLIGHT] FRAME_ALLOCATOR_NAMES @private = {
    "frame_allocator_0",
    "frame_allocator_1",
};

const ZString[FRAMES_IN_FLIGHT] UPLOAD_RING_NAMES @private = {
    "upload_ring_0",
    "upload_ring_1",
};

const usz RETIRE_INITIAL_CAPACITY @private = 16; // a frame retiring more than this grows once and keeps the storage
const uint FULLSCREEN_VERTEX_COUNT @private = 3; // one clipped triangle covers the area without a vertex buffer
const uint TIMESTAMP_BEGIN @private = 0;
const uint TIMESTAMP_END @private = 1;
const double NANOSECONDS_PER_MILLISECOND @private = 1_000_000.0;

<*
 How a renderer is created. A null surface factory selects headless.
*>
struct RendererDesc {
    bool             validation;
    bool             gpu_timings;
    SurfaceFn        surface_fn;
    void*            surface_user;
    uint             output_width;
    uint             output_height;
    gpu::PresentMode present_mode;
    ZString          application_name;
    usz              upload_ring_bytes;
}

<*
 Application time for the frame being recorded.
*>
struct FrameInfo {
    double time;
    float  delta;
}

<*
 One frame slot's command units and the completion point covering its last submission.
*>
struct Frame {
    gpu::CommandAllocator allocator;
    gpu::CompletionPoint  done;
    UploadRing            upload;
    RetireList            retire;
    bool[PASS_COUNT]      timed;
}

<*
 Device, window output, and frame ring.
*>
struct Renderer {
    Allocator               allocator;
    gpu::Runtime            runtime;
    gpu::Surface            surface;
    gpu::Device             device;
    gpu::DeviceCaps         caps;
    gpu::Queue              graphics;
    gpu::SwapchainHandle    swapchain;
    gpu::SwapchainInfo      swapchain_info;
    Frame[FRAMES_IN_FLIGHT] frames;
    ulong                   frame_index;

    AssetStore*             assets;
    GpuGeometry[]           geometries;
    List{gpu::BufferCopyDesc} pending_copies;
    bool                    pending_overwrite;
    MaterialRes[]           materials;
    gpu::GpuAllocation      material_heap;
    gpu::GpuSpan            material_heap_span;

    TargetPool              targets;
    PipelineCache           pipelines;
    gpu::SamplerIndex       linear_clamp_sampler;

    DebugLog*                log;
    gpu::TimestampPoolHandle timestamps;
    bool                     timestamps_enabled;
    Stats                    stats;

    uint                    output_width;
    uint                    output_height;
    bool                    output_dormant;
    bool                    output_dirty;

    gpu::CommandList        commands;
    gpu::AcquiredImage      acquired;
    Target                  window_target;
    Target                  hdr_color;
    Target                  depth;
    FrameInfo               info;
    time::Clock             frame_started;
    bool                    frame_open;
    bool                    has_output;
}

<*
 Record the window output's pixel size and dormancy for the next frame.
 @param [&inout] self : "Recovery is deferred to begin_frame."
*>
fn void Renderer.set_window_output(&self, uint width, uint height, bool dormant) {
    if (width != self.output_width
        || height != self.output_height
        || dormant != self.output_dormant) {
        self.output_dirty = true;
    }
    self.output_width = width;
    self.output_height = height;
    self.output_dormant = dormant;
}

<*
 Upload the asset now, or record its upload into the open frame.
 Completes without a window when no frame is open.
 @return? c3d::INVALID_ID
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::UNSUPPORTED_FEATURE, gpu::COMMAND_RECORDING_ERROR, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
macro void? Renderer.upload(&self, id) {
    $switch $Typeof(id):
        $case GeometryId: return self.upload_geometry(id);
        $case MaterialId: return self.upload_material(id);
        $default: $error("upload takes a GeometryId or a MaterialId");
    $endswitch
}

<*
 Open a frame slot and acquire the window image when one is available.
 @param [&inout] self : "Reuses the slot whose completion point has been waited."
 @require !self.frame_open
 @return? gpu::DEVICE_BUSY, gpu::INVALID_HANDLE, gpu::INVALID_ARGUMENT
 @return? gpu::INVALID_RESOURCE_STATE, gpu::COMMAND_RECORDING_ERROR, gpu::RESOURCE_IN_USE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::UNSUPPORTED_FEATURE
 @return? gpu::SURFACE_LOST, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? Renderer.begin_frame(&self, FrameInfo info = {}) {
    Frame* slot = &self.frames[self.frame_index % FRAMES_IN_FLIGHT];
    if (slot.done.is_valid()) gpu::wait_completion(slot.done)!;

    self.stats = {};
    read_pass_timings(self, slot, self.frame_index)!;
    slot.timed = {};
    drain_retired(&self.device, &slot.retire);
    sweep_geometries(self, slot);
    sweep_materials(self);
    reset_upload_ring(self, slot)!;
    self.frame_started = clock::now();

    self.has_output = false;
    if (self.swapchain.is_valid()) {
        if (self.output_dirty) recover_window_output(self)!;
        acquire_window_output(self)!;
    }

    self.commands = gpu::begin_commands(&slot.allocator)!;
    if (self.timestamps_enabled) {
        gpu::cmd_reset_timestamps(
            commands: &self.commands,
            pool:     self.timestamps,
            first:    pass_timestamp_slot(self.frame_index, 0),
            count:    (uint)PASS_COUNT * TIMESTAMPS_PER_PASS,
        )!;
    }
    if (self.has_output) self.window_target.transition(&self.commands, COLOR_ATTACHMENT_STATE)!;

    self.info = info;
    self.frame_open = true;
}

<*
 Record a clear of the frame's window output. Records nothing without one.
 @param [&inout] self : "Records into the open frame's command list."
 @require self.frame_open
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::DEVICE_LOST
 @return? gpu::BACKEND_ERROR
*>
fn void? Renderer.clear(&self, Vec4 color) {
    if (!self.has_output) return;

    gpu::ColorTargetDesc[1] colors = {{
        .view     = self.window_target.attachment,
        .load_op  = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear    = { .rgba = { color.r, color.g, color.b, color.a } },
    }};
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .width  = self.window_target.width,
        .height = self.window_target.height,
    };
    gpu::cmd_begin_render_pass(&self.commands, &pass)!;
    gpu::cmd_end_render_pass(&self.commands)!;
}

<*
 Submit the frame and present its window output. Submits nothing without one.
 @param [&inout] self : "Closes the frame and advances to the next slot."
 @require self.frame_open
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::INVALID_HANDLE, gpu::INVALID_ARGUMENT
 @return? gpu::INVALID_RESOURCE_STATE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::SURFACE_LOST, gpu::BACKEND_ERROR
*>
fn void? Renderer.end_frame(&self) {
    ulong frame = self.frame_index;
    Frame* slot = &self.frames[frame % FRAMES_IN_FLIGHT];
    self.frame_open = false;
    self.frame_index++;

    if (!self.has_output) {
        abort_frame(self);
        self.stats.frame_ms = elapsed_ms(self.frame_started);
        return;
    }
    self.has_output = false;

    defer catch (void)gpu::discard_commands(&self.commands);
    record_pending_copies(self, &self.commands)!;
    self.window_target.transition(&self.commands, PRESENT_STATE)!;
    slot.upload.flush(&self.device)!;

    gpu::ExecutableCommandList[1] executable = { gpu::end_commands(&self.commands)! };
    defer catch (void)gpu::discard_executable_commands(&executable[0]);

    gpu::SubmitDesc submit = {
        .command_lists    = executable[..],
        .readiness        = self.acquired.readiness,
        .readiness_before = { .color_output },
    };
    slot.done = gpu::submit(self.graphics, &submit)!;
    self.stats.cpu_record_ms = elapsed_ms(self.frame_started);

    present_window_output(self, slot.done)!;
    self.stats.frame_ms = elapsed_ms(self.frame_started);
}

<*
 Record one registry fragment stage over the whole target.
 @require self.frame_open
 @return? c3d::INVALID_ID, c3d::SHADER_NOT_FOUND
 @return? gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? Renderer.draw_fullscreen(&self, RenderTargetId target, ShaderVariant fragment) {
    TargetRecord* record = self.targets.try_get(target)!;
    record.target.transition(&self.commands, COLOR_ATTACHMENT_STATE)!;

    PipelineKey key = {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = fragment,
        .color_formats = { [0] = record.target.format },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
    gpu::PipelineHandle pipeline = self.pipelines.get(&self.device, key)!;
    record_fullscreen_pass(
        renderer:      self,
        target:        &record.target,
        pipeline:      pipeline,
        fragment_root: (gpu::GpuAddress)0,
    )!;
}

<*
 Sample the target into the frame's window output. Records nothing without one.
 @require self.frame_open
 @return? c3d::INVALID_ID, c3d::SHADER_NOT_FOUND
 @return? gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? Renderer.composite(&self, RenderTargetId target) {
    TargetRecord* record = self.targets.try_get(target)!;
    if (!self.has_output) return;
    return composite_target(self, &record.target);
}

fn void? composite_target(Renderer* renderer, Target* target) @private {
    target.transition(&renderer.commands, FRAGMENT_READ_STATE)!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, CompositeRoot::size)!;
    *(CompositeRoot*)root.bytes.ptr = {
        .source_texture = target.view.index,
        .source_sampler = renderer.linear_clamp_sampler,
    };

    PipelineKey key = {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = COMPOSITE },
        .color_formats = { [0] = renderer.window_target.format },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, key)!;

    write_pass_timestamp(
        renderer:    renderer,
        frame_index: renderer.frame_index,
        pass:        Pass.COMPOSITE,
        half:        TIMESTAMP_BEGIN,
    )!;
    record_fullscreen_pass(
        renderer:      renderer,
        target:        &renderer.window_target,
        pipeline:      pipeline,
        fragment_root: root.address,
    )!;
    write_pass_timestamp(
        renderer:    renderer,
        frame_index: renderer.frame_index,
        pass:        Pass.COMPOSITE,
        half:        TIMESTAMP_END,
    )!;
    slot.timed[Pass.COMPOSITE.ordinal] = true;
}

fn void? record_fullscreen_pass(Renderer* renderer, Target* target, gpu::PipelineHandle pipeline,
  gpu::GpuAddress fragment_root) @private {
    gpu::ColorTargetDesc[1] colors = {{
        .view     = target.attachment,
        .load_op  = gpu::LoadOp.DONT_CARE,
        .store_op = gpu::StoreOp.STORE,
    }};
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .width  = target.width,
        .height = target.height,
    };
    gpu::ColorTargetState[1] color_targets = { gpu::color_blend_disabled() };
    gpu::GraphicsState state = fullscreen_state(target.width, target.height, color_targets[..])!;

    // Bound before the pass begins: the backend checks the bound pipeline against the pass formats at begin.
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
    gpu::cmd_draw(
        commands:       &renderer.commands,
        vertex_root:    (gpu::GpuAddress)0,
        fragment_root:  fragment_root,
        vertex_count:   FULLSCREEN_VERTEX_COUNT,
        instance_count: 1,
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
    renderer.stats.draws++;
}

fn void? acquire_window_output(Renderer* renderer) @private {
    if (renderer.output_dormant || renderer.output_dirty || renderer.swapchain_info.dormant) return;

    gpu::AcquiredImage? acquired = gpu::acquire_next_image(
        device:     &renderer.device,
        swapchain:  renderer.swapchain,
        timeout_ns: ACQUIRE_TIMEOUT_NS,
    );
    if (catch excuse = acquired) {
        if (excuse == gpu::SWAPCHAIN_OUT_OF_DATE) renderer.output_dirty = true;
        if (excuse == gpu::SWAPCHAIN_OUT_OF_DATE || excuse == gpu::WAIT_TIMEOUT) return;
        return excuse~;
    }

    renderer.acquired = acquired;
    renderer.window_target = {
        .texture    = acquired.texture,
        .attachment = acquired.attachment_view,
        .view       = gpu::TEXTURE_VIEW_INVALID,
        .state      = acquired.prior_state,
        .format     = renderer.swapchain_info.format,
        .width      = renderer.swapchain_info.width,
        .height     = renderer.swapchain_info.height,
    };
    renderer.has_output = true;
}

fn void? present_window_output(Renderer* renderer, gpu::CompletionPoint rendered) @private {
    while (catch excuse = gpu::present(&renderer.device, &renderer.acquired, rendered)) {
        if (excuse == gpu::SWAPCHAIN_OUT_OF_DATE) {
            renderer.output_dirty = true;
            return;
        }
        if (excuse != gpu::WAIT_TIMEOUT) return excuse~;
    }
}

<*
 Create the renderer, its device, and the window output the descriptor's factory supplies.
 @param [&in] assets : "Borrowed for the renderer's lifetime; never released by it."
 @require desc.surface_fn == null || (desc.output_width > 0 && desc.output_height > 0)
 @return? c3d::UNSUPPORTED, gpu::UNSUPPORTED_BACKEND, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::SLOT_TABLE_FULL
 @return? gpu::DESCRIPTOR_HEAP_FULL, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED
 @return? gpu::DEVICE_LOST, gpu::DEVICE_BUSY, gpu::SURFACE_LOST, gpu::BACKEND_ERROR
*>
fn Renderer? create_renderer(Allocator allocator, AssetStore* assets, RendererDesc desc = {}) {
    // The callback's user pointer is fixed when the runtime is created and a returned-by-value
    // Renderer has no stable address, so the log lives on the heap for the renderer's lifetime.
    DebugLog* log = alloc::new(allocator, DebugLog);
    defer catch alloc::free(allocator, log);

    gpu::RuntimeDesc runtime_desc = desc.validation
        ? gpu::full_validation_runtime_desc()
        : (gpu::RuntimeDesc){};
    runtime_desc.application_name = desc.application_name;
    runtime_desc.debug_callback = &record_debug_message;
    runtime_desc.debug_user_data = log;
    runtime_desc.enable_debug_names = true;

    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer catch (void)gpu::destroy_runtime(&runtime);

    gpu::Surface surface;
    if (desc.surface_fn) surface = desc.surface_fn(&runtime, desc.surface_user)!;
    defer catch {
        if (surface.is_valid()) (void)gpu::destroy_surface(&surface);
    }

    gpu::DeviceDesc device_desc = { .surface = surface };
    gpu::Adapter adapter = select_adapter(&runtime, &device_desc)!;
    gpu::Device device = gpu::create_device(&adapter, &device_desc)!;
    defer catch (void)gpu::destroy_device(&device);

    gpu::Queue graphics = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;
    gpu::DeviceCaps caps = gpu::get_device_caps(&device)!;

    bool timestamps_enabled = desc.gpu_timings && caps.timestamps.queues.graphics;
    gpu::TimestampPoolHandle timestamps;
    if (timestamps_enabled) {
        gpu::TimestampPoolDesc timestamp_desc = {
            .capacity   = FRAMES_IN_FLIGHT * (uint)PASS_COUNT * TIMESTAMPS_PER_PASS,
            .debug_name = "frame_timestamps",
        };
        timestamps = gpu::create_timestamp_pool(&device, &timestamp_desc)!;
    }
    defer catch {
        if (timestamps.is_valid()) (void)gpu::destroy_timestamp_pool(&device, timestamps);
    }

    gpu::SwapchainHandle swapchain;
    gpu::SwapchainInfo swapchain_info;
    if (surface.is_valid()) {
        gpu::SwapchainDesc swapchain_desc = {
            .width            = desc.output_width,
            .height           = desc.output_height,
            .preferred_format = gpu::Format.BGRA8_UNORM,
            .present_mode     = desc.present_mode,
            .srgb             = true,
            .debug_name       = "window_output",
        };
        swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
        swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    }
    defer catch {
        if (swapchain.is_valid()) (void)gpu::destroy_swapchain(&device, swapchain);
    }

    usz ring_bytes = desc.upload_ring_bytes ? desc.upload_ring_bytes : UPLOAD_RING_BYTES;
    Frame[FRAMES_IN_FLIGHT] frames;
    usz slots_created = 0;
    defer catch {
        for (usz slot = 0; slot < slots_created; slot++) {
            (void)gpu::destroy_command_allocator(&frames[slot].allocator);
            free_upload_ring(&device, &frames[slot].upload);
            frames[slot].retire.free();
        }
    }
    for (usz slot = 0; slot < FRAMES_IN_FLIGHT; slot++) {
        gpu::CommandAllocatorDesc allocator_desc = {
            .command_buffer_capacity = COMMAND_BUFFERS_PER_FRAME,
            .debug_name              = FRAME_ALLOCATOR_NAMES[slot],
        };
        frames[slot].allocator = gpu::create_command_allocator(&device, graphics, &allocator_desc)!;
        frames[slot].retire.init(allocator, RETIRE_INITIAL_CAPACITY);
        frames[slot].upload.overflow.init(allocator, RETIRE_INITIAL_CAPACITY);
        allocate_upload_ring(
            device:     &device,
            ring:       &frames[slot].upload,
            bytes:      ring_bytes,
            debug_name: UPLOAD_RING_NAMES[slot],
        )!;
        slots_created++;
    }

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .mip_filter = gpu::Filter.LINEAR,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
        .debug_name = "linear_clamp",
    };
    gpu::SamplerIndex linear_clamp_sampler = gpu::intern_sampler(&device, &sampler_desc)!;

    gpu::GpuAllocation material_heap = allocate_material_heap(&device, assets.materials.items.len)!;
    defer catch (void)gpu::free_allocation(&device, &material_heap);
    gpu::GpuSpan material_heap_span = gpu::get_allocation_span(&device, material_heap)!;

    Target hdr_color;
    Target depth;
    if (surface.is_valid()) {
        allocate_view_targets(
            device:    &device,
            width:     desc.output_width,
            height:    desc.output_height,
            hdr_color: &hdr_color,
            depth:     &depth,
        )!;
    }
    defer catch release_view_targets(&device, &hdr_color, &depth);

    Renderer renderer = {
        .allocator            = allocator,
        .assets               = assets,
        .geometries           = alloc::new_array(allocator, GpuGeometry, assets.geometries.items.len),
        .materials            = alloc::new_array(allocator, MaterialRes, assets.materials.items.len),
        .material_heap        = material_heap,
        .material_heap_span   = material_heap_span,
        .hdr_color            = hdr_color,
        .depth                = depth,
        .runtime              = runtime,
        .surface              = surface,
        .device               = device,
        .caps                 = caps,
        .graphics             = graphics,
        .swapchain            = swapchain,
        .swapchain_info       = swapchain_info,
        .frames               = frames,
        .targets              = pool::create_pool{TargetRecord, RenderTargetId}(allocator, RENDER_TARGET_CAPACITY),
        .pipelines            = create_pipeline_cache(allocator, shader::BUILTIN_REGISTRY),
        .linear_clamp_sampler = linear_clamp_sampler,
        .log                  = log,
        .timestamps           = timestamps,
        .timestamps_enabled   = timestamps_enabled,
        .output_width         = desc.output_width,
        .output_height        = desc.output_height,
    };
    renderer.pending_copies.init(allocator, RETIRE_INITIAL_CAPACITY);
    return renderer;
}

<*
 Release the renderer after draining every submission and presentation.
 @param [&inout] renderer : "Left zeroed; destroy the window backing its surface afterwards."
*>
fn void destroy_renderer(Renderer* renderer) {
    if (renderer.frame_open) (void)gpu::discard_commands(&renderer.commands);
    (void)wait_frames(renderer);
    free_geometries(renderer);
    free_material_heap(renderer);
    release_view_targets(&renderer.device, &renderer.hdr_color, &renderer.depth);

    foreach (&record : renderer.targets.items) {
        if (record.target.texture.is_valid()) release_target(&renderer.device, &record.target);
    }
    pool::destroy_pool{TargetRecord, RenderTargetId}(&renderer.targets);
    destroy_pipeline_cache(&renderer.device, &renderer.pipelines);

    if (renderer.swapchain.is_valid()) {
        uint attempts = 0;
        while (catch excuse = gpu::wait_swapchain_presentations(
            device:     &renderer.device,
            swapchain:  renderer.swapchain,
            timeout_ns: RETIRE_TIMEOUT_NS,
        )) {
            attempts++;
            if (excuse != gpu::WAIT_TIMEOUT || attempts >= TEARDOWN_RETIRE_ATTEMPTS) break;
        }
        (void)gpu::destroy_swapchain(&renderer.device, renderer.swapchain);
    }

    foreach (&slot : renderer.frames) {
        drain_retired(&renderer.device, &slot.retire);
        slot.retire.free();
        free_upload_ring(&renderer.device, &slot.upload);
        (void)gpu::destroy_command_allocator(&slot.allocator);
    }
    if (renderer.timestamps.is_valid()) {
        (void)gpu::destroy_timestamp_pool(&renderer.device, renderer.timestamps);
    }
    (void)gpu::destroy_device(&renderer.device);
    if (renderer.surface.is_valid()) (void)gpu::destroy_surface(&renderer.surface);
    (void)gpu::destroy_runtime(&renderer.runtime);
    // Freed last: the backend reports leaked children through the callback while the runtime dies.
    alloc::free(renderer.allocator, renderer.log);
    *renderer = {};
}

fn gpu::Adapter? select_adapter(gpu::Runtime* runtime, gpu::DeviceDesc* desc) @private {
    gpu::AdapterList adapters = gpu::enumerate_adapters(runtime)!;
    gpu::Adapter? selected = c3d::UNSUPPORTED~;
    for (uint index = 0; index < adapters.count; index++) {
        gpu::Adapter adapter = adapters.get(index)!;
        if (!gpu::supports_device_desc(&adapter, desc)!.supported) continue;
        if (gpu::get_adapter_info(&adapter)!.device_class == gpu::AdapterClass.DISCRETE) return adapter;
        if (catch selected) selected = adapter;
    }
    return selected;
}

fn void? recover_window_output(Renderer* renderer) @private {
    wait_frames(renderer)!;

    if (catch excuse = gpu::wait_swapchain_presentations(
        device:     &renderer.device,
        swapchain:  renderer.swapchain,
        timeout_ns: RETIRE_TIMEOUT_NS,
    )) {
        if (excuse != gpu::WAIT_TIMEOUT) return excuse~;
        return;
    }
    if (!renderer.output_width || !renderer.output_height) return;

    gpu::resize_swapchain(
        device:    &renderer.device,
        swapchain: renderer.swapchain,
        width:     renderer.output_width,
        height:    renderer.output_height,
    )!;
    renderer.swapchain_info = gpu::get_swapchain_info(&renderer.device, renderer.swapchain)!;
    release_view_targets(&renderer.device, &renderer.hdr_color, &renderer.depth);
    allocate_view_targets(
        device:    &renderer.device,
        width:     renderer.output_width,
        height:    renderer.output_height,
        hdr_color: &renderer.hdr_color,
        depth:     &renderer.depth,
    )!;
    renderer.output_dirty = false;
}

fn void? read_pass_timings(Renderer* renderer, Frame* slot, ulong frame_index) @private {
    if (!renderer.timestamps_enabled) return;
    foreach (pass_ordinal, timed : slot.timed) {
        if (!timed) continue;
        ulong[TIMESTAMPS_PER_PASS] raw;
        gpu::read_timestamps(
            device: &renderer.device,
            pool:   renderer.timestamps,
            first:  pass_timestamp_slot(frame_index, (usz)pass_ordinal),
            count:  TIMESTAMPS_PER_PASS,
            out:    raw[..],
        )!;
        double nanoseconds = gpu::timestamp_delta_ns(
            caps:  &renderer.caps.timestamps,
            queue: gpu::QueueKind.GRAPHICS,
            begin: raw[0],
            end:   raw[1],
        )!;
        renderer.stats.gpu_pass_ms[pass_ordinal] = (float)(nanoseconds / NANOSECONDS_PER_MILLISECOND);
    }
}

fn void? write_pass_timestamp(Renderer* renderer, ulong frame_index, Pass pass, uint half) @private {
    if (!renderer.timestamps_enabled) return;
    gpu::cmd_write_timestamp(
        commands: &renderer.commands,
        pool:     renderer.timestamps,
        index:    pass_timestamp_slot(frame_index, (usz)pass.ordinal) + half,
        stage:    { .all },
    )!;
}

fn void? reset_upload_ring(Renderer* renderer, Frame* slot) @private {
    foreach (allocation : slot.upload.overflow) {
        slot.retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = allocation });
    }
    slot.upload.overflow.clear();

    usz capacity = slot.upload.mapped.bytes.len;
    usz target = grown_capacity(capacity, slot.upload.demand);
    slot.upload.demand = 0;
    slot.upload.head = 0;
    if (target == capacity) return;

    slot.retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = slot.upload.allocation });
    slot.upload.allocation = gpu::GPU_ALLOCATION_INVALID;
    return allocate_upload_ring(
        device:     &renderer.device,
        ring:       &slot.upload,
        bytes:      target,
        debug_name: UPLOAD_RING_NAMES[renderer.frame_index % FRAMES_IN_FLIGHT],
    );
}

// Copies queued into a discarded frame point into a ring the next begin_frame resets.
fn void abort_frame(Renderer* renderer) @private {
    renderer.frame_open = false;
    (void)gpu::discard_commands(&renderer.commands);
    renderer.pending_copies.clear();
    renderer.pending_overwrite = false;
}

fn float elapsed_ms(time::Clock started) @private {
    return (float)((double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND);
}
