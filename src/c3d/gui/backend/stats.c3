module c3d::gui::backend;

import c3d::render;
import gpu;
import imgui;

<*
 Display live GPU allocation counts and per-heap memory usage.
 @param [&inout] renderer : "Borrowed device; current ImGui window is open."
 @return? gpu::INVALID_HANDLE, gpu::DEVICE_BUSY, gpu::DEVICE_LOST
*>
fn void? memory_panel(Renderer* renderer) {
    gpu::MemoryStats stats = gpu::get_memory_stats(&renderer.device)!;

    imgui::text("Textures: %llu", stats.texture_count);
    imgui::text("Allocations: %llu", stats.live_allocation_count);

    foreach (index, heap : stats.heaps[:stats.heap_count]) {
        imgui::text("Heap %u", (uint)index);
        imgui::text("Usage / budget: %llu / %llu bytes", heap.usage, heap.budget);
        imgui::text("Allocation / block: %llu / %llu bytes", heap.allocation_bytes, heap.block_bytes);
    }
}
