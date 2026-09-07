module c3d::render;

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
 State an image is presented from.
*>
const gpu::TextureState PRESENT_STATE = { .layout = gpu::TextureLayout.PRESENT };

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
