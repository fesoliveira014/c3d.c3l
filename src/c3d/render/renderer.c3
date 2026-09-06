module c3d::render;

import c3d;
import gpu;
import std::math;

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

<*
 How a renderer is created. A null surface factory selects headless.
*>
struct RendererDesc {
    bool             validation;
    SurfaceFn        surface_fn;
    void*            surface_user;
    uint             output_width;
    uint             output_height;
    gpu::PresentMode present_mode;
    ZString          application_name;
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

    uint                    output_width;
    uint                    output_height;
    bool                    output_dormant;
    bool                    output_dirty;

    gpu::CommandList        commands;
    gpu::AcquiredImage      acquired;
    Target                  window_target;
    FrameInfo               info;
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
 Open a frame slot and acquire the window image when one is available.
 @param [&inout] self : "Reuses the slot whose completion point has been waited."
 @require !self.frame_open
 @return? gpu::DEVICE_BUSY, gpu::INVALID_HANDLE, gpu::INVALID_ARGUMENT
 @return? gpu::INVALID_RESOURCE_STATE, gpu::COMMAND_RECORDING_ERROR, gpu::RESOURCE_IN_USE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::SURFACE_LOST
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? Renderer.begin_frame(&self, FrameInfo info = {}) {
    Frame* slot = &self.frames[self.frame_index % FRAMES_IN_FLIGHT];
    if (slot.done.is_valid()) gpu::wait_completion(slot.done)!;

    self.has_output = false;
    if (self.swapchain.is_valid()) {
        if (self.output_dirty) recover_window_output(self)!;
        acquire_window_output(self)!;
    }

    self.commands = gpu::begin_commands(&slot.allocator)!;
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
    Frame* slot = &self.frames[self.frame_index % FRAMES_IN_FLIGHT];
    self.frame_open = false;
    self.frame_index++;

    if (!self.has_output) {
        (void)gpu::discard_commands(&self.commands);
        return;
    }
    self.has_output = false;

    defer catch (void)gpu::discard_commands(&self.commands);
    self.window_target.transition(&self.commands, PRESENT_STATE)!;

    gpu::ExecutableCommandList[1] executable = { gpu::end_commands(&self.commands)! };
    defer catch (void)gpu::discard_executable_commands(&executable[0]);

    gpu::SubmitDesc submit = {
        .command_lists    = executable[..],
        .readiness        = self.acquired.readiness,
        .readiness_before = { .color_output },
    };
    slot.done = gpu::submit(self.graphics, &submit)!;

    return present_window_output(self, slot.done);
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
 @require desc.surface_fn == null || (desc.output_width > 0 && desc.output_height > 0)
 @return? c3d::UNSUPPORTED, gpu::UNSUPPORTED_BACKEND, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::SLOT_TABLE_FULL
 @return? gpu::DESCRIPTOR_HEAP_FULL, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED
 @return? gpu::DEVICE_LOST, gpu::DEVICE_BUSY, gpu::SURFACE_LOST, gpu::BACKEND_ERROR
*>
fn Renderer? create_renderer(Allocator allocator, RendererDesc desc = {}) {
    gpu::RuntimeDesc runtime_desc = desc.validation
        ? gpu::full_validation_runtime_desc()
        : (gpu::RuntimeDesc){};
    runtime_desc.application_name = desc.application_name;

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

    Frame[FRAMES_IN_FLIGHT] frames;
    usz allocators_created = 0;
    defer catch {
        for (usz slot = 0; slot < allocators_created; slot++) {
            (void)gpu::destroy_command_allocator(&frames[slot].allocator);
        }
    }
    for (usz slot = 0; slot < FRAMES_IN_FLIGHT; slot++) {
        gpu::CommandAllocatorDesc allocator_desc = {
            .command_buffer_capacity = COMMAND_BUFFERS_PER_FRAME,
            .debug_name              = FRAME_ALLOCATOR_NAMES[slot],
        };
        frames[slot].allocator = gpu::create_command_allocator(&device, graphics, &allocator_desc)!;
        allocators_created++;
    }

    return {
        .allocator      = allocator,
        .runtime        = runtime,
        .surface        = surface,
        .device         = device,
        .caps           = caps,
        .graphics       = graphics,
        .swapchain      = swapchain,
        .swapchain_info = swapchain_info,
        .frames         = frames,
        .output_width   = desc.output_width,
        .output_height  = desc.output_height,
    };
}

<*
 Release the renderer after draining every submission and presentation.
 @param [&inout] renderer : "Left zeroed; destroy the window backing its surface afterwards."
*>
fn void destroy_renderer(Renderer* renderer) {
    if (renderer.frame_open) (void)gpu::discard_commands(&renderer.commands);
    foreach (&slot : renderer.frames) {
        if (slot.done.is_valid()) (void)gpu::wait_completion(slot.done);
    }

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

    foreach (&slot : renderer.frames) (void)gpu::destroy_command_allocator(&slot.allocator);
    (void)gpu::destroy_device(&renderer.device);
    if (renderer.surface.is_valid()) (void)gpu::destroy_surface(&renderer.surface);
    (void)gpu::destroy_runtime(&renderer.runtime);
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
    foreach (&slot : renderer.frames) {
        if (slot.done.is_valid()) gpu::wait_completion(slot.done)!;
    }

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
    renderer.output_dirty = false;
}
