module c3d::render;

import c3d;
import c3d::pool;
import gpu;

<*
 Pooled render-target records a renderer can hold at once.
*>
const uint RENDER_TARGET_CAPACITY = 8; // one texture and two views each; views multiply this later

<*
 Pixel format of every render target until pixel formats become a c3d type.
*>
const gpu::Format RENDER_TARGET_FORMAT = gpu::Format.RGBA16_FLOAT;

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
    .layout = gpu::TextureLayout.STORAGE,
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
 Size of an application-owned render target, in pixels.
*>
struct RenderTargetDesc {
    uint width;
    uint height;
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
    Target target;
    uint   revision;
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
 Create an HDR render target the application owns.
 @require desc.width > 0 && desc.height > 0
 @return? c3d::CAPACITY_EXCEEDED, gpu::INVALID_ARGUMENT, gpu::UNSUPPORTED_FEATURE
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn RenderTargetId? create_render_target(Renderer* renderer, RenderTargetDesc desc) {
    Target target = allocate_target(
        device:     &renderer.device,
        width:      desc.width,
        height:     desc.height,
        format:     RENDER_TARGET_FORMAT,
        usage:      { .color_attach, .sampled, .storage },
        debug_name: "render_target",
    )!;
    defer catch release_target(&renderer.device, &target);
    return renderer.targets.add({ .target = target, .revision = 1 });
}

<*
 Recreate the target's backing at a new size after every submitted use completes.
 Keeps the id; bumps the revision.
 @require !renderer.frame_open
 @require width > 0 && height > 0
 @return? c3d::INVALID_ID, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::UNSUPPORTED_FEATURE
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? resize_render_target(Renderer* renderer, RenderTargetId target, uint width, uint height) {
    TargetRecord* record = renderer.targets.try_get(target)!;
    wait_frames(renderer)!;
    release_target(&renderer.device, &record.target);
    record.target = allocate_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     RENDER_TARGET_FORMAT,
        usage:      { .color_attach, .sampled, .storage },
        debug_name: "render_target",
    )!;
    record.revision++;
}

<*
 Release the target after every submitted use completes. The id is dead afterwards.
 @require !renderer.frame_open
 @return? c3d::INVALID_ID, gpu::INVALID_HANDLE, gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? destroy_render_target(Renderer* renderer, RenderTargetId target) {
    TargetRecord* record = renderer.targets.try_get(target)!;
    wait_frames(renderer)!;
    release_target(&renderer.device, &record.target);
    *record = {};
    renderer.targets.remove(target);
}

fn Target? allocate_target(gpu::Device* device, uint width, uint height, gpu::Format format,
  gpu::TextureUsage usage, ZString debug_name) @private {
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

fn void? wait_frames(Renderer* renderer) @private {
    foreach (&slot : renderer.frames) {
        if (slot.done.is_valid()) gpu::wait_completion(slot.done)!;
    }
}
