module c3d::render;

import c3d;
import c3d::material;
import c3d::pool;
import gpu;

<*
 Pooled render-target records a renderer can hold at once.
*>
const uint RENDER_TARGET_CAPACITY = 8; // one texture and two views each; sampled-target bookkeeping is a uint mask
$assert(RENDER_TARGET_CAPACITY <= 32);

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
}

<*
 A pooled render target and the revision of its backing image.
*>
struct TargetRecord {
    Target      target;
    PixelFormat format;
    uint        revision;
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
    return renderer.targets.add({ .target = target, .format = desc.format, .revision = 1 });
}

<*
 Recreate the target's backing at a new size after every submitted use completes.
 Keeps the id; bumps the revision; views on the target resize and forget their history.
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
    gpu::Format format = record.target.format;
    release_target(&renderer.device, &record.target);
    record.target = allocate_render_target(renderer, width, height, format)!;
    record.revision++;

    foreach (&view : renderer.views.items) {
        if (view.live && view_selects_target(view, target)) resize_view(renderer, view)!;
    }
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

fn bool view_selects_target(ViewRecord* view, RenderTargetId target) @private {
    return view.desc.output == ViewOutput.TEXTURE
        && view.desc.target.index == target.index
        && view.desc.target.generation == target.generation;
}

fn Target? allocate_render_target(
    Renderer* renderer,
    uint width,
    uint height,
    gpu::Format format,
) @private {
    // Storage writes decode nothing, so an sRGB target stays sampled and attached only.
    gpu::TextureUsage usage = format == gpu::Format.RGBA8_SRGB
        ? (gpu::TextureUsage){ .color_attach, .sampled }
        : (gpu::TextureUsage){ .color_attach, .sampled, .storage };
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

<*
 Wait for every renderer-owned frame submission.
 @param [&inout] renderer : "Completion points remain owned by the renderer."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::DEVICE_BUSY
 @return? gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !renderer.frame_open
*>
fn void? wait_frames(Renderer* renderer) {
    foreach (&slot : renderer.frames) {
        if (slot.done.is_valid()) gpu::wait_completion(slot.done)!;
    }
}
