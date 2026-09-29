module c3d::gui::backend;

import c3d::gui;
import c3d::render;
import gpu;
import imgui;

const usz DIAGNOSTICS_ROWS @local = 16; // one screen of recent messages; the ring keeps 64

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

<*
 Display the validation state and the renderer's recent debug messages.
 @param [&in] renderer : "Current ImGui window is open."
*>
fn void diagnostics_section(Renderer* renderer) {
    if (!imgui::collapsing_header("Diagnostics", {})) return;

    imgui::text("Validation: %s", renderer.validation ? "on" : "off");
    imgui::text("GPU timings: %s", renderer.timestamps_enabled ? "on" : "off");

    DebugEntry[DIAGNOSTICS_ROWS] entries;
    usz count = renderer.log.recent(entries[..]);
    if (!count) imgui::text_unformatted("No messages");
    @pool() {
        foreach (entry : entries[:count]) {
            imgui::text("%s %s %s#%u %s",
                gui::@enum_name(gpu::DebugMessageSeverity, entry.severity),
                category_name(entry.category),
                gui::@enum_name(gpu::DebugResourceKind, entry.resource_kind),
                entry.resource_index,
                (ZString)&entry.operation);
            if (entry.has_fault) imgui::text("  %s", entry.public_fault.description.zstr_tcopy());
        }
    };
}

fn ZString category_name(gpu::DebugMessageCategory category) @local {
    if (category.validation) return "validation";
    if (category.public_contract) return "contract";
    if (category.performance) return "performance";
    if (category.resource_lifetime) return "lifetime";
    if (category.backend) return "backend";
    return "general";
}
