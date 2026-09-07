module c3d::render;

import gpu;
import std::collections::list;

<*
 Bytes a frame slot's upload ring starts with.
*>
const usz UPLOAD_RING_BYTES = 32 << 20; // one frame of roots, draw blocks and small staging

<*
 Alignment the ring base is allocated at.
*>
const usz UPLOAD_RING_ALIGNMENT = 256; // an aligned offset only implies an aligned address because the base covers every alignment a caller may ask for

<*
 Largest request that teaches the ring to grow.
*>
const usz OVERSIZED_UPLOAD_BYTES = 8 << 20; // one huge texture would otherwise cost its own size in every later frame

<*
 Persistently mapped per-frame upload storage. Suballocations stay valid until the frame completes.
*>
struct UploadRing {
    gpu::GpuAllocation       allocation;
    gpu::MappedGpuSpan       mapped;
    usz                      head;
    usz                      demand;
    List{gpu::GpuAllocation} overflow;
}

<*
 Suballocate mapped, addressable bytes for the frame being recorded.
 @param [&inout] self : "Head advances; suballocations already returned never move."
 @param [&inout] device : "Owns an overflow allocation when the request does not fit."
 @require size > 0
 @require alignment > 0 && alignment <= UPLOAD_RING_ALIGNMENT
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::OUT_OF_DEVICE_MEMORY, gpu::UNSUPPORTED_FEATURE, gpu::DEVICE_LOST
 @return? gpu::BACKEND_ERROR
*>
fn gpu::MappedGpuSpan? UploadRing.take(&self, gpu::Device* device, usz size, usz alignment = 16) {
    if (size <= OVERSIZED_UPLOAD_BYTES) self.demand += size;

    usz offset = align_up(self.head, alignment);
    if (offset + size <= self.mapped.bytes.len) {
        gpu::GpuSpan span = self.mapped.span.checked_subspan(offset, size)!;
        self.head = offset + size;
        return gpu::mapped_gpu_span(device, span);
    }

    gpu::AllocationDesc overflow_desc = {
        .size         = size,
        .alignment    = UPLOAD_RING_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "upload_overflow",
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(device, &overflow_desc)!;
    self.overflow.push(allocation);
    return gpu::mapped_gpu_span(device, gpu::get_allocation_span(device, allocation)!);
}

<*
 Flush every range written into the ring and its overflow this frame.
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? UploadRing.flush(&self, gpu::Device* device) {
    if (self.head) {
        gpu::flush_mapped_span(device, self.mapped.span.checked_subspan(0, self.head)!)!;
    }
    foreach (allocation : self.overflow) {
        gpu::flush_mapped_span(device, gpu::get_allocation_span(device, allocation)!)!;
    }
}

<*
 Capacity that covers the demand, doubling from the capacity in use.
 @require capacity > 0
 @pure
*>
fn usz grown_capacity(usz capacity, usz demand) {
    usz target = capacity;
    while (target < demand) target *= 2;
    return target;
}

fn usz align_up(usz value, usz alignment) @private {
    return (value + alignment - 1) / alignment * alignment;
}

fn void? allocate_upload_ring(gpu::Device* device, UploadRing* ring, usz bytes, ZString debug_name) @private {
    gpu::AllocationDesc desc = {
        .size         = bytes,
        .alignment    = UPLOAD_RING_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = debug_name,
    };
    ring.allocation = gpu::allocate_memory(device, &desc)!;
    ring.mapped = gpu::mapped_gpu_span(device, gpu::get_allocation_span(device, ring.allocation)!)!;
    ring.head = 0;
}

fn void free_upload_ring(gpu::Device* device, UploadRing* ring) @private {
    foreach (&allocation : ring.overflow) {
        (void)gpu::free_allocation(device, allocation);
    }
    ring.overflow.free();
    if (ring.allocation.is_valid()) (void)gpu::free_allocation(device, &ring.allocation);
}
