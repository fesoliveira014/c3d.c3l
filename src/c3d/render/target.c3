module c3d::render;

import c3d;
import c3d::material;
import c3d::pool;
import gpu;

<*
 State a color attachment is written in.
*>
const gpu::TextureState COLOR_ATTACHMENT_STATE = {
    .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
    .stages = { .color_output },
    .access = { .read, .write },
};

<*
 State a target is read from by fragment shaders.
*>
const gpu::TextureState FRAGMENT_READ_STATE = {
    .layout = gpu::TextureLayout.SAMPLED,
    .stages = { .fragment_shader },
    .access = { .read },
};

<*
 State a depth target is written in.
*>
const gpu::TextureState DEPTH_ATTACHMENT_STATE = {
    .layout = gpu::TextureLayout.DEPTH_ATTACHMENT,
    .stages = { .depth_output },
    .access = { .read, .write },
};

<*
 State an image is presented from.
*>
const gpu::TextureState PRESENT_STATE = { .layout = gpu::TextureLayout.PRESENT };

const gpu::TextureState TRANSFER_SOURCE_STATE @private = {
    .layout = gpu::TextureLayout.TRANSFER_SOURCE,
    .stages = { .transfer },
    .access = { .read },
};

<*
 Size and pixel format of an application-owned render target.
*>
struct RenderTargetDesc {
    uint        width;
    uint        height;
    PixelFormat format;
}

<*
 Renderer-owned image and the state its last recorded barrier left it in.
*>
struct Target {
    gpu::TextureHandle        texture;
    gpu::AttachmentViewHandle attachment;
    gpu::TextureView          view;
    gpu::TextureState         state;
    gpu::Format               format;
    uint                      width;
    uint                      height;
    uint                      depth; // zero for a 2D image
}

<*
 A pooled render target, its backing revision and frame state.
*>
struct TargetRecord {
    Target            target;
    PixelFormat       format;
    uint              revision;
    gpu::TextureState frame_state;    // at frame start, or at creation inside the frame; an abort restores it
    bool              sample_pending; // a resolved binding samples it; the next view's preparation readies it
}

<*
 Render-target records addressed by RenderTargetId.
*>
alias TargetPool = Pool{TargetRecord, RenderTargetId};

<*
 Record the barrier from the tracked state and store the new one.
 @param [&inout] self : "State advances to next."
 @param [&inout] commands : "Open command list receiving the barrier."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::DEVICE_LOST
 @return? gpu::BACKEND_ERROR
*>
fn void? Target.transition(&self, gpu::CommandList* commands, gpu::TextureState next) {
    gpu::TextureBarrier barrier = gpu::texture_transition(self.texture, self.state, next)!;
    gpu::cmd_texture_barrier(commands, &barrier)!;
    self.state = next;
}

<*
 Describe a render target; the default format keeps scene-linear color.
*>
fn RenderTargetDesc render_target_desc(uint width, uint height, PixelFormat format = PixelFormat.RGBA16_FLOAT) {
    return { .width = width, .height = height, .format = format };
}

<*
 Whether the format can back a render target.
*>
fn bool render_target_format_valid(PixelFormat format) {
    return @ok(render_target_format(format));
}

<*
 Bytes one texel of a render-target format occupies.
 @require render_target_format_valid(format)
*>
fn usz render_target_texel_bytes(PixelFormat format) {
    switch (format) {
        case RGBA8_UNORM:
        case RGBA8_SRGB: return 4;
        case RGBA16_FLOAT: return 8;
        case RGBA32_FLOAT: return 16;
        case R16_UINT:
        case BC1_RGBA_UNORM:
        case BC1_RGBA_SRGB:
        case BC3_UNORM:
        case BC3_SRGB:
        case BC4_UNORM:
        case BC5_UNORM:
        case BC6H_UFLOAT:
        case BC7_UNORM:
        case BC7_SRGB: return 0;
    }
}

<*
 Copy the target's pixels into caller memory once every submitted frame completes.
 @param [out] pixels : "Tight rows, top row first, bytes as stored."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !self.frame_open
*>
fn void? Renderer.read_render_target(&self, RenderTargetId target, char[] pixels) {
    TargetRecord* record = self.targets.try_get(target)!;
    Target* image = &record.target;
    if (pixels.len != (usz)image.width * image.height * render_target_texel_bytes(record.format)) {
        return c3d::INVALID_ARGUMENT~;
    }
    wait_frames(self)!;
    open_closed_frame_slot(self)!;

    gpu::AllocationDesc desc = {
        .size         = pixels.len,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "render_target_readback",
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&self.device, &desc)!;
    defer (void)gpu::free_allocation(&self.device, &allocation);
    gpu::GpuSpan destination = gpu::get_allocation_span(&self.device, allocation)!;

    TextureReadback readback = { .target = image, .destination = destination };
    submit_pending(self, &readback)!;
    gpu::invalidate_mapped_span(&self.device, destination)!;
    pixels[..] = gpu::mapped_gpu_span(&self.device, destination)!.bytes[:pixels.len];
}

<*
 Create a sampled color render target the application owns.
 @require desc.width > 0 && desc.height > 0
 @return? c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED, gpu::INVALID_ARGUMENT, gpu::UNSUPPORTED_FEATURE
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn RenderTargetId? create_render_target(Renderer* renderer, RenderTargetDesc desc) {
    gpu::Format format = render_target_format(desc.format)!;
    Target target = allocate_render_target(renderer, desc.width, desc.height, format)!;
    defer catch release_target(&renderer.device, &target);
    return renderer.targets.add({
        .target      = target,
        .format      = desc.format,
        .revision    = 1,
        .frame_state = target.state,
    });
}

<*
 Recreate the target's backing at a new size after every submitted use completes.
 Needs room for the old and new images of the target and its views; a fault changes nothing.
 @require !renderer.frame_open
 @require width > 0 && height > 0
 @return? c3d::INVALID_ID, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::UNSUPPORTED_FEATURE
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_BUSY, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? resize_render_target(
    Renderer* renderer,
    RenderTargetId target,
    uint width,
    uint height,
) {
    TargetRecord* record = renderer.targets.try_get(target)!;
    wait_frames(renderer)!;
    Target replacement = allocate_render_target(
        renderer: renderer,
        width:    width,
        height:   height,
        format:   record.target.format,
    )!;
    defer catch release_target(&renderer.device, &replacement);
    resize_views(
        renderer: renderer,
        output:   ViewOutput.TEXTURE,
        extent:   { width, height },
        target:   target,
    )!;

    release_target(&renderer.device, &record.target);
    record.target = replacement;
    record.revision++;
}

<*
 Release the target after every submitted use completes. The id is dead afterwards.
 @require !renderer.frame_open
 @return? c3d::INVALID_ID, c3d::RESOURCE_IN_USE, gpu::INVALID_HANDLE, gpu::DEVICE_BUSY
 @return? gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? destroy_render_target(Renderer* renderer, RenderTargetId target) {
    TargetRecord* record = renderer.targets.try_get(target)!;
    foreach (&view : renderer.views.items) {
        if (view.live && view_selects_target(view, target)) return c3d::RESOURCE_IN_USE~;
    }
    wait_frames(renderer)!;
    release_target(&renderer.device, &record.target);
    *record = {};
    renderer.targets.remove(target);
}

fn bool same_texture_state(gpu::TextureState first, gpu::TextureState second) @private {
    return first.layout == second.layout && first.stages == second.stages && first.access == second.access;
}

fn bool view_selects_target(ViewRecord* view, RenderTargetId target) @private {
    return view.desc.output == ViewOutput.TEXTURE && c3d::same_id(view.desc.target, target);
}

fn Target? allocate_render_target(
    Renderer* renderer,
    uint width,
    uint height,
    gpu::Format format,
) @private {
    // Storage writes decode nothing, so an sRGB target stays sampled and attached only.
    gpu::TextureUsage usage = format == gpu::Format.RGBA8_SRGB
        ? (gpu::TextureUsage){ .color_attach, .sampled, .transfer_src }
        : (gpu::TextureUsage){ .color_attach, .sampled, .storage, .transfer_src };
    return allocate_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     format,
        usage:      usage,
        debug_name: "render_target",
    );
}

fn gpu::Format? render_target_format(PixelFormat format) @private {
    switch (format) {
        case RGBA8_UNORM: return gpu::Format.RGBA8_UNORM;
        case RGBA8_SRGB: return gpu::Format.RGBA8_SRGB;
        case RGBA16_FLOAT: return gpu::Format.RGBA16_FLOAT;
        case RGBA32_FLOAT: return gpu::Format.RGBA32_FLOAT;
        case R16_UINT:
        case BC1_RGBA_UNORM:
        case BC1_RGBA_SRGB:
        case BC3_UNORM:
        case BC3_SRGB:
        case BC4_UNORM:
        case BC5_UNORM:
        case BC6H_UFLOAT:
        case BC7_UNORM:
        case BC7_SRGB: return c3d::UNSUPPORTED~;
    }
}

fn Target? allocate_target(
    gpu::Device* device,
    uint width,
    uint height,
    gpu::Format format,
    gpu::TextureUsage usage,
    ZString debug_name,
) @private {
    gpu::TextureDesc texture_desc = {
        .width      = width,
        .height     = height,
        .format     = format,
        .usage      = usage,
        .access     = { .graphics },
        .debug_name = debug_name,
    };
    gpu::TextureHandle texture = gpu::create_texture(device, &texture_desc)!;
    defer catch (void)gpu::destroy_texture(device, texture);

    gpu::AttachmentViewDesc attachment_desc = { .texture = texture };
    gpu::AttachmentViewHandle attachment = gpu::create_attachment_view(device, &attachment_desc)!;
    defer catch (void)gpu::destroy_attachment_view(device, attachment);

    gpu::TextureView view = gpu::create_texture_view(device, texture, null)!;
    return {
        .texture    = texture,
        .attachment = attachment,
        .view       = view,
        .format     = format,
        .width      = width,
        .height     = height,
    };
}

fn void release_target(gpu::Device* device, Target* target) @private {
    (void)gpu::destroy_texture_view(device, target.view);
    (void)gpu::destroy_attachment_view(device, target.attachment);
    (void)gpu::destroy_texture(device, target.texture);
    *target = {};
}

fn Target? allocate_storage_target(
    gpu::Device* device,
    uint width,
    uint height,
    gpu::Format format,
    ZString debug_name,
    uint depth = 0,
) @private {
    gpu::TextureDesc texture_desc = {
        .width      = width,
        .height     = height,
        .depth      = depth,
        .format     = format,
        .usage      = { .sampled, .storage },
        .access     = { .graphics },
        .debug_name = debug_name,
    };
    gpu::TextureHandle texture = gpu::create_texture(device, &texture_desc)!;
    defer catch (void)gpu::destroy_texture(device, texture);

    gpu::TextureView view = gpu::create_texture_view(device, texture, null)!;
    return {
        .texture = texture,
        .view    = view,
        .format  = format,
        .width   = width,
        .height  = height,
        .depth   = depth,
    };
}

fn void retire_storage_target(RetireList* retire, Target* target) @private {
    retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = target.view });
    retire.push({ .kind = RetiredKind.TEXTURE, .texture = target.texture });
    *target = {};
}

fn void release_storage_target(gpu::Device* device, Target* target) @private {
    (void)gpu::destroy_texture_view(device, target.view);
    (void)gpu::destroy_texture(device, target.texture);
    *target = {};
}

<*
 Wait for every renderer-owned frame submission.
 @param [&inout] renderer : "Completion points remain owned by the renderer."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::DEVICE_BUSY
 @return? gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !renderer.frame_open
*>
fn void? wait_frames(Renderer* renderer) {
    foreach (index, &slot : renderer.frames) {
        if (slot.done.is_valid()) gpu::wait_completion(slot.done)!;
        collect_gpu_profile(renderer, (uint)index)!;
    }
}
