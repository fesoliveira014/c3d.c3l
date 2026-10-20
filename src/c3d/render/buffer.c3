module c3d::render;

import c3d;
import c3d::pool;
import gpu;

<*
 Pooled buffer records a renderer can hold at once.
*>
const uint BUFFER_CAPACITY = 64; // one device allocation each; a scene has a handful of application buffers

const uint READBACK_SLOTS @private = FRAMES_IN_FLIGHT + 1; // keeps the slot a read borrows clear of the next copy

<*
 Who writes a buffer: shaders only, the CPU through the upload ring, or shaders with a delayed CPU read.
*>
enum BufferUsage {
    GPU_PRIVATE,
    UPLOAD,
    READBACK,
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
    gpu::GpuAllocation    allocation;
    gpu::GpuAddress       address;
    usz                   size;
    BufferUsage           usage;
    gpu::MappedGpuSpan    readback;         // READBACK_SLOTS copies, one per recent frame
    usz                   readback_stride;
    ulong[READBACK_SLOTS] readback_frames;  // closing frame_index + 1 of each slot's copy; 0 when none
    bool                  readback_pending; // a copy is recorded in the open frame
}

<*
 Buffer records addressed by BufferId.
*>
alias BufferPool = Pool{BufferRecord, BufferId};

<*
 Create a device buffer that shaders address through buffer_address.
 A READBACK buffer also keeps the copies read_buffer returns.
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

    gpu::MappedGpuSpan readback;
    usz stride = (desc.size + STREAM_ALIGNMENT - 1) / STREAM_ALIGNMENT * STREAM_ALIGNMENT;
    if (desc.usage == BufferUsage.READBACK) {
        gpu::AllocationDesc readback_desc = {
            .size         = stride * READBACK_SLOTS,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.CPU_READ,
            .access       = { .graphics },
            .debug_name   = desc.debug_name,
        };
        readback = gpu::allocate_mapped_memory(&self.device, &readback_desc)!;
    }
    defer catch {
        gpu::GpuAllocation staging = readback.span.allocation();
        if (staging.is_valid()) (void)gpu::free_allocation(&self.device, &staging);
    }
    return self.buffers.add({
        .allocation      = allocation,
        .address         = address,
        .size            = desc.size,
        .usage           = desc.usage,
        .readback        = readback,
        .readback_stride = stride,
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
    if (record.usage == BufferUsage.READBACK) {
        retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = record.readback.span.allocation() });
    }
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

<*
 Contents of a READBACK buffer as the frame FRAMES_IN_FLIGHT frames earlier left them.
 Borrows mapped memory without copying; the view is valid until the next begin_frame.
 @param [&inout] self : "Makes the completed copy visible to the CPU."
 @require self.frame_open
 @return? NOT_READY, c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn char[]? Renderer.read_buffer(&self, BufferId buffer) {
    BufferRecord* record = self.buffers.try_get(buffer)!;
    if (record.usage != BufferUsage.READBACK) return c3d::INVALID_ARGUMENT~;
    if (self.frame_index < FRAMES_IN_FLIGHT) return NOT_READY~;

    ulong wanted = self.frame_index - FRAMES_IN_FLIGHT;
    usz slot = (usz)(wanted % READBACK_SLOTS);
    if (record.readback_frames[slot] != wanted + 1) return NOT_READY~;

    gpu::MappedGpuSpan copy = record.readback.checked_subspan(slot * record.readback_stride, record.size)!;
    gpu::invalidate_mapped_span(&self.device, copy.span)!;
    return copy.bytes;
}

// Copies every READBACK buffer into the slot of the frame being closed.
fn void? record_buffer_readbacks(Renderer* renderer, ulong closing_frame) @private {
    usz slot = (usz)(closing_frame % READBACK_SLOTS);
    bool barriered;
    foreach (&record : renderer.buffers.items) {
        if (record.usage != BufferUsage.READBACK || !record.allocation.is_valid()) continue;

        if (!barriered) {
            gpu::Barrier before_copy = { .before = renderer.consumer_stages, .after = { .transfer } };
            gpu::cmd_barrier(&renderer.commands, &before_copy)!;
            barriered = true;
        }
        gpu::GpuSpan source = gpu::get_allocation_span(&renderer.device, record.allocation)!;
        gpu::BufferCopyDesc copy = {
            .src = source.checked_subspan(0, record.size)!,
            .dst = record.readback.span.unchecked_subspan(slot * record.readback_stride, record.size),
        };
        gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
        record.readback_pending = true;
    }
    if (barriered) {
        gpu::Barrier to_host = { .before = { .transfer }, .after = { .host } };
        gpu::cmd_barrier(&renderer.commands, &to_host)!;
    }
}

fn void commit_buffer_readbacks(Renderer* renderer, ulong closing_frame) @private {
    usz slot = (usz)(closing_frame % READBACK_SLOTS);
    foreach (&record : renderer.buffers.items) {
        if (!record.readback_pending) continue;

        record.readback_frames[slot] = closing_frame + 1;
        record.readback_pending = false;
    }
}

fn void discard_buffer_readbacks(Renderer* renderer) @private {
    foreach (&record : renderer.buffers.items) record.readback_pending = false;
}

fn void free_buffers(Renderer* renderer) @private {
    foreach (&record : renderer.buffers.items) {
        if (record.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &record.allocation);
        gpu::GpuAllocation staging = record.readback.span.allocation();
        if (staging.is_valid()) (void)gpu::free_allocation(&renderer.device, &staging);
    }
    pool::destroy_pool{BufferRecord, BufferId}(&renderer.buffers);
}
