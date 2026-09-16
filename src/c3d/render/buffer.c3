module c3d::render;

import c3d;
import c3d::pool;
import gpu;

<*
 Pooled buffer records a renderer can hold at once.
*>
const uint BUFFER_CAPACITY = 64; // one device allocation each; a scene has a handful of application buffers

<*
 Who writes a buffer: shaders only, or the CPU through the upload ring.
*>
enum BufferUsage {
    GPU_PRIVATE,
    UPLOAD,
}

<*
 Size, writer and name of an application-owned buffer.
*>
struct BufferDesc {
    usz         size;
    BufferUsage usage;
    ZString     debug_name;
}

<*
 Renderer-owned allocation behind a BufferId.
*>
struct BufferRecord {
    gpu::GpuAllocation allocation;
    gpu::GpuAddress    address;
    usz                size;
    BufferUsage        usage;
}

<*
 Buffer records addressed by BufferId.
*>
alias BufferPool = Pool{BufferRecord, BufferId};

<*
 Create a device buffer that shaders address through buffer_address.
 @require desc.size > 0
 @return? c3d::CAPACITY_EXCEEDED, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::UNSUPPORTED_FEATURE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn BufferId? Renderer.create_buffer(&self, BufferDesc desc) {
    gpu::AllocationDesc allocation_desc = {
        .size         = desc.size,
        .alignment    = STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = desc.debug_name,
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&self.device, &allocation_desc)!;
    defer catch (void)gpu::free_allocation(&self.device, &allocation);
    gpu::GpuAddress address = gpu::get_span_address(
        &self.device,
        gpu::get_allocation_span(&self.device, allocation)!,
    )!;
    return self.buffers.add({
        .allocation = allocation,
        .address    = address,
        .size       = desc.size,
        .usage      = desc.usage,
    });
}

<*
 Retire the buffer after its last submitted use. The id is dead afterwards.
 @return? c3d::INVALID_ID
*>
fn void? Renderer.destroy_buffer(&self, BufferId buffer) {
    BufferRecord* record = self.buffers.try_get(buffer)!;
    RetireList* retire = self.frame_open
        ? &self.frames[self.frame_index % FRAMES_IN_FLIGHT].retire
        : &self.pending_upload_retire;
    retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = record.allocation });
    *record = {};
    self.buffers.remove(buffer);
}

<*
 Device address of the buffer, for roots and material payloads.
 @require self.buffers.is_live(buffer)
*>
fn gpu::GpuAddress Renderer.buffer_address(&self, BufferId buffer) {
    return self.buffers.get(buffer).address;
}

<*
 Stage bytes for the buffer; copied before the frame's first dispatch.
 @param bytes : "At most the buffer size; written from offset zero."
 @require self.frame_open
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::OUT_OF_DEVICE_MEMORY, gpu::UNSUPPORTED_FEATURE, gpu::DEVICE_LOST
 @return? gpu::BACKEND_ERROR
*>
fn void? Renderer.write_buffer(&self, BufferId buffer, char[] bytes) {
    BufferRecord* record = self.buffers.try_get(buffer)!;
    if (record.usage != BufferUsage.UPLOAD || bytes.len > record.size) return c3d::INVALID_ARGUMENT~;
    if (self.frame_recorded || self.stats.dispatches) return c3d::INVALID_ARGUMENT~;
    if (!bytes.len) return;

    Frame* slot = &self.frames[self.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = slot.upload.take(&self.device, bytes.len, STREAM_ALIGNMENT)!;
    staging.bytes[:bytes.len] = bytes[..];
    gpu::GpuSpan destination = gpu::get_allocation_span(&self.device, record.allocation)!;
    self.pending_copies.push({ .src = staging.span, .dst = destination.checked_subspan(0, bytes.len)! });
    self.pending_overwrite = true;
    self.stats.upload_bytes += (uint)bytes.len;
}

fn void free_buffers(Renderer* renderer) @private {
    foreach (&record : renderer.buffers.items) {
        if (record.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &record.allocation);
    }
    pool::destroy_pool{BufferRecord, BufferId}(&renderer.buffers);
}
