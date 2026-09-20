module c3d::gui;

$assert !$feat(C3D_PROFILE_GUI) || $feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU)
  : "C3D_PROFILE_GUI requires C3D_PROFILE_CPU or C3D_PROFILE_GPU.";

module c3d::gui @feat(C3D_PROFILE_GUI & (C3D_PROFILE_CPU | C3D_PROFILE_GPU));

import c3d::profile;

struct ScopeAggregate @private {
    uint sample_index;
    uint call_count;
    double inclusive_ns;
    double self_ns;
    bool self_complete;
}

struct PanelStorageLayout @private {
    usz size;
    usz frame_ids;
    usz history;
    usz cpu;
    usz gpu @if($feat(C3D_PROFILE_GPU));
    usz labels;
    usz depths;
    usz aggregates;
    usz scope_capacity;
}

<* Owned profiler inspection state for one borrowed recorder. *>
struct ProfilerPanel {
    Allocator allocator;
    profile::Recorder* recorder;
    char[] storage;
    ulong[] frame_ids;
    profile::FrameCaptureView[] history;
    usz frame_count;
    profile::CpuSample[] cpu;
    profile::GpuSample[] gpu @if($feat(C3D_PROFILE_GPU));
    char[] labels;
    uint[] depths;
    ScopeAggregate[] aggregates;
    profile::FrameCaptureView snapshot;
    bool has_snapshot;
    bool following;
    bool has_selected_scope;
    bool selected_gpu;
    uint selected_scope;
    bool source_evicted;
}

<* @return? PROFILE_STORAGE_OVERFLOW *>
fn usz? panel_multiply_size(usz left, usz right) @private {
    if (left && right > (usz)sz::max / left) return PROFILE_STORAGE_OVERFLOW~;
    return left * right;
}

<* @return? PROFILE_STORAGE_OVERFLOW *>
fn usz? panel_add_size(usz left, usz right) @private {
    if (left > (usz)sz::max || right > (usz)sz::max - left) return PROFILE_STORAGE_OVERFLOW~;
    return left + right;
}

<*
 @return? PROFILE_STORAGE_OVERFLOW
 @require alignment > 0 && (alignment & (alignment - 1)) == 0
*>
fn usz? panel_align_size(usz size, usz alignment) @private {
    usz padding = (alignment - size % alignment) % alignment;
    return panel_add_size(size, padding);
}

<*
 @param [&inout] size : "Current layout byte count."
 @return? PROFILE_STORAGE_OVERFLOW
*>
fn usz? panel_reserve_span(
    usz* size,
    usz count,
    usz stride,
    usz alignment,
) @private {
    usz offset = panel_align_size(*size, alignment)!;
    *size = panel_add_size(offset, panel_multiply_size(count, stride)!)!;
    return offset;
}

<* @return? PROFILE_STORAGE_OVERFLOW *>
fn PanelStorageLayout? panel_storage_layout(profile::RecorderDesc desc) @private {
    PanelStorageLayout layout;
    layout.frame_ids = panel_reserve_span(
        size: &layout.size,
        count: desc.frame_capacity,
        stride: ulong::size,
        alignment: ulong::alignment,
    )!;
    layout.history = panel_reserve_span(
        size: &layout.size,
        count: desc.frame_capacity,
        stride: profile::FrameCaptureView::size,
        alignment: profile::FrameCaptureView::alignment,
    )!;
    $if $feat(C3D_PROFILE_CPU):
        layout.scope_capacity = desc.cpu_scopes_per_frame;
        layout.cpu = panel_reserve_span(
            size: &layout.size,
            count: desc.cpu_scopes_per_frame,
            stride: profile::CpuSample::size,
            alignment: profile::CpuSample::alignment,
        )!;
    $endif
    $if $feat(C3D_PROFILE_GPU):
        if (desc.gpu_scopes_per_frame > layout.scope_capacity) layout.scope_capacity = desc.gpu_scopes_per_frame;
        layout.gpu = panel_reserve_span(
            size: &layout.size,
            count: desc.gpu_scopes_per_frame,
            stride: profile::GpuSample::size,
            alignment: profile::GpuSample::alignment,
        )!;
    $endif
    layout.labels = panel_reserve_span(
        size: &layout.size,
        count: desc.label_bytes_per_frame,
        stride: char::size,
        alignment: char::alignment,
    )!;
    layout.depths = panel_reserve_span(
        size: &layout.size,
        count: layout.scope_capacity,
        stride: uint::size,
        alignment: uint::alignment,
    )!;
    layout.aggregates = panel_reserve_span(
        size: &layout.size,
        count: layout.scope_capacity,
        stride: ScopeAggregate::size,
        alignment: ScopeAggregate::alignment,
    )!;
    return layout;
}

<* @return? PROFILE_STORAGE_OVERFLOW *>
fn usz? panel_storage_size(profile::RecorderDesc desc) @private {
    return panel_storage_layout(desc)!.size;
}

<*
 Allocate inspection storage for one recorder.
 @param [&in] recorder : "Stable recorder outliving the panel."
 @return? PROFILE_STORAGE_OVERFLOW
*>
fn ProfilerPanel? create_profiler_panel(Allocator allocator, profile::Recorder* recorder) {
    $assert ulong::alignment <= mem::DEFAULT_MEM_ALIGNMENT;
    $assert profile::FrameCaptureView::alignment <= mem::DEFAULT_MEM_ALIGNMENT;
    $assert profile::CpuSample::alignment <= mem::DEFAULT_MEM_ALIGNMENT;
    $assert uint::alignment <= mem::DEFAULT_MEM_ALIGNMENT;
    $assert ScopeAggregate::alignment <= mem::DEFAULT_MEM_ALIGNMENT;
    $if $feat(C3D_PROFILE_GPU):
        $assert profile::GpuSample::alignment <= mem::DEFAULT_MEM_ALIGNMENT;
    $endif
    PanelStorageLayout layout = panel_storage_layout(recorder.desc)!;
    char[] storage = alloc::new_array(allocator, char, (sz)layout.size);
    ProfilerPanel panel = {
        .allocator = allocator,
        .recorder = recorder,
        .storage = storage,
        .frame_ids = ((ulong*)(storage.ptr + layout.frame_ids))[:recorder.desc.frame_capacity],
        .history = ((profile::FrameCaptureView*)(storage.ptr + layout.history))[:recorder.desc.frame_capacity],
        .labels = storage[layout.labels : recorder.desc.label_bytes_per_frame],
        .depths = ((uint*)(storage.ptr + layout.depths))[:layout.scope_capacity],
        .aggregates = ((ScopeAggregate*)(storage.ptr + layout.aggregates))[:layout.scope_capacity],
        .following = true,
    };
    $if $feat(C3D_PROFILE_CPU):
        panel.cpu = ((profile::CpuSample*)(storage.ptr + layout.cpu))[:recorder.desc.cpu_scopes_per_frame];
    $endif
    $if $feat(C3D_PROFILE_GPU):
        panel.gpu = ((profile::GpuSample*)(storage.ptr + layout.gpu))[:recorder.desc.gpu_scopes_per_frame];
    $endif
    return panel;
}

<*
 Release profiler inspection storage.
 @param [&inout] panel : "Owned panel with no active draw."
*>
fn void destroy_profiler_panel(ProfilerPanel* panel) {
    alloc::free(panel.allocator, panel.storage.ptr);
    *panel = {};
}
