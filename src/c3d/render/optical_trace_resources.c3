module c3d::render;

import gpu;

fn void discard_optical_scene_trace(Renderer* renderer) @private {
    SceneTrace* trace = &renderer.optical_scene_trace;
    trace.prepared_frame = 0;
    trace.baseline_count = 0;
    trace.scene = 0;

    RtContext* rt = &renderer.optical_rt;
    rt.build_pending = false;
    rt.current_holds_set = false;
    renderer.optical_trace_overflow = false;
}

fn void retire_optical_scene_trace(Renderer* renderer) @private {
    SceneTrace* trace = &renderer.optical_scene_trace;
    RtContext* rt = &renderer.optical_rt;
    RetireList* retire = &renderer.pending_upload_retire;
    foreach (top_level : rt.top_levels) {
        if (top_level.view.is_valid()) {
            retire.push({
                .kind = RetiredKind.ACCELERATION_STRUCTURE_VIEW,
                .acceleration_structure_view = top_level.view,
            });
        }
        if (top_level.tlas.is_valid()) {
            retire.push({
                .kind = RetiredKind.ACCELERATION_STRUCTURE,
                .acceleration_structure = top_level.tlas,
            });
        }
    }
    foreach (scratch : rt.scratch) {
        if (scratch.allocation.is_valid()) retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = scratch.allocation });
    }
    if (trace.allocation.is_valid()) retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = trace.allocation });

    if (trace.baseline.len) alloc::free(renderer.allocator, trace.baseline.ptr);
    if (trace.row_records.len) alloc::free(renderer.allocator, trace.row_records.ptr);
    trace.pending_builds.free();
    rt.pending_blas.free();
    *trace = {};
    *rt = { .current = FRAMES_IN_FLIGHT };
    renderer.optical_trace_overflow = false;
}
