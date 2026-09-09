module c3d::render;

import gpu;

<*
 Upload a fresh RGBA8 texture and wait for completion.
 @param [&inout] self : "Owns recording, staging and the completion point."
 @param texture : "Fresh single-mip RGBA8_UNORM texture; sampled and transfer destination."
 @param pixels : "Complete mip in tightly packed RGBA8 rows."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::UNSUPPORTED_FEATURE, gpu::WAIT_TIMEOUT, gpu::RESOURCE_IN_USE
 @require !self.frame_open, pixels.len > 0
*>
fn void? Renderer.upload_rgba8_texture(&self, gpu::TextureHandle texture, char[] pixels) {
    open_closed_frame_slot(self)!;
    Frame* slot = &self.frames[self.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = slot.upload.take(&self.device, pixels.len, UPLOAD_RING_ALIGNMENT)!;
    mem::copy(staging.bytes.ptr, pixels.ptr, pixels.len);
    gpu::CommandList commands = gpu::begin_commands(&slot.allocator)!;
    defer catch (void)gpu::discard_commands(&commands);
    record_pending_copies(self, &commands)!;
    gpu::TextureBarrier to_upload = gpu::texture_transition(
        texture: texture,
        before: { .layout = gpu::TextureLayout.UNDEFINED },
        after: {
            .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
            .stages = { .transfer },
            .access = { .write },
        },
    )!;
    gpu::cmd_texture_barrier(&commands, &to_upload)!;
    gpu::BufferTextureCopyDesc copy = { .src = staging.span, .texture = texture };
    gpu::cmd_copy_buffer_to_texture(&commands, &copy)!;
    gpu::TextureBarrier to_sampled = gpu::texture_transition(
        texture: texture,
        before: to_upload.after,
        after: gpu::sampled_at({ .fragment_shader }),
    )!;
    gpu::cmd_texture_barrier(&commands, &to_sampled)!;
    slot.upload.flush(&self.device)!;
    gpu::ExecutableCommandList[1] executable = { gpu::end_commands(&commands)! };
    defer catch (void)gpu::discard_executable_commands(&executable[0]);
    gpu::SubmitDesc submit = { .command_lists = executable[..] };
    slot.done = gpu::submit(self.graphics, &submit)!;
    return gpu::wait_completion(slot.done);
}
