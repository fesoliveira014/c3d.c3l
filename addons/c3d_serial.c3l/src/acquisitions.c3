module c3d::serial;

import c3d;

struct Acquisition @private {
    Acquisition* previous;
}

struct Acquisitions @private {
    Allocator allocator;
    Acquisition* last;
}

fn void*? Acquisitions.acquire(
    &self,
    usz count,
    usz element_size,
    usz alignment,
) {
    if (!count) return null;
    usz padding = alignment - 1 + Acquisition::size;
    if (element_size && count > ((usz)sz::max - padding) / element_size) return c3d::CAPACITY_EXCEEDED~;
    usz size = count * element_size + padding;
    Acquisition* allocation = self.allocator.acquire((sz)size, ZERO) ?? c3d::CAPACITY_EXCEEDED~!;
    allocation.previous = self.last;
    self.last = allocation;
    uptr address = ((uptr)(allocation + 1) + alignment - 1) & ~(alignment - 1);
    return (void*)address;
}

fn void Acquisitions.release(&self) {
    while (self.last) {
        Acquisition* allocation = self.last;
        self.last = allocation.previous;
        self.allocator.release(allocation, false);
    }
}
