module c3d::render;

import gpu;
import std::time;
import std::time::clock;

// Throwaway per-stage CPU timing for swayed posed trace rows. Measurement branch only; never merged.
// Counters are module-level and unsynchronised: the recording thread is the only writer.
// Each stage lists its parent, so the overhead of nested timers can be subtracted from the enclosing stage.

enum SwayStage : int {
    TRACE_PREPARE,      // prepare_scene_trace body past the same-frame early return
    GATHER,             // record_scene_trace: extract, rows, claims, resolves, top-level box BVH
    COLLECT,            // collect_trace_instances: scene walk
    ROWS,               // resolve_trace_instances: every row, posed or not
    RESOLVE,            // resolve_posed_instance (per slot)
    POSE_INPUTS,        // pose_inputs(): tmem alloc, sway_pose_root, copy
    ROOT_BUILD_INPUTS,  // the sway_pose_root call inside pose_inputs
    POSE_COMPARE,       // update_pose: 320 B mem::equals and copy
    POSE_WRITE,         // write_pose_root
    ROOT_BUILD_WRITE,   // the sway_pose_root call inside write_pose_root
    POSE_UPLOAD,        // upload_bytes inside write_pose_root: ring take and 320 B write
    REFIT_ROOT,         // write_refit_root (software kind)
    ROW_COMPARE,        // top_level_reusable and records_equal over the rows
    TOP_BVH,            // write_top_level: box BVH over the rows and the trace row upload
    POSES_TOTAL,        // record_trace_poses past its early return
    POSE_RECORD,        // pose bind and dispatch loop
    REFIT_RECORD,       // refit bind and dispatch loop
    BUILDS_TOTAL,       // record_acceleration_builds past its early return
    BUILD_SIZING,       // scratch sizing loops
    BUILD_LOOP,         // record_posed_builds past its early return
    BUILD_CMD,          // cmd_update / cmd_build call of one posed build
    GPU_PREPARE,        // prepare_acceleration_structure_build_mode inside the call (local gpu.c3l patch)
    GPU_EMIT,           // emit_acceleration_structure_build inside the call (local gpu.c3l patch)
    TLAS,               // record_top_level_build
    TLAS_PACK,          // upload-ring take and row packing
    TLAS_CMD,           // cmd_build_acceleration_structure of the top level
}

const SwayStage[SwayStage::len] SWAY_STAGE_PARENT = {
    SwayStage.TRACE_PREPARE,    // TRACE_PREPARE is the root
    SwayStage.TRACE_PREPARE,    // GATHER
    SwayStage.GATHER,           // COLLECT
    SwayStage.GATHER,           // ROWS
    SwayStage.ROWS,             // RESOLVE
    SwayStage.RESOLVE,          // POSE_INPUTS
    SwayStage.POSE_INPUTS,      // ROOT_BUILD_INPUTS
    SwayStage.RESOLVE,          // POSE_COMPARE
    SwayStage.RESOLVE,          // POSE_WRITE
    SwayStage.POSE_WRITE,       // ROOT_BUILD_WRITE
    SwayStage.POSE_WRITE,       // POSE_UPLOAD
    SwayStage.RESOLVE,          // REFIT_ROOT
    SwayStage.GATHER,           // ROW_COMPARE
    SwayStage.GATHER,           // TOP_BVH
    SwayStage.TRACE_PREPARE,    // POSES_TOTAL
    SwayStage.POSES_TOTAL,      // POSE_RECORD
    SwayStage.POSES_TOTAL,      // REFIT_RECORD
    SwayStage.TRACE_PREPARE,    // BUILDS_TOTAL
    SwayStage.BUILDS_TOTAL,     // BUILD_SIZING
    SwayStage.BUILDS_TOTAL,     // BUILD_LOOP
    SwayStage.BUILD_LOOP,       // BUILD_CMD
    SwayStage.BUILD_CMD,        // GPU_PREPARE
    SwayStage.BUILD_CMD,        // GPU_EMIT
    SwayStage.BUILDS_TOTAL,     // TLAS
    SwayStage.TLAS,             // TLAS_PACK
    SwayStage.TLAS,             // TLAS_CMD
};

const String[SwayStage::len] SWAY_STAGE_NAMES = {
    "trace_prepare",
    "gather",
    "collect",
    "rows",
    "resolve",
    "pose_inputs",
    "root_build_inputs",
    "pose_compare",
    "pose_write",
    "root_build_write",
    "pose_upload",
    "refit_root",
    "row_compare",
    "top_bvh",
    "poses_total",
    "pose_record",
    "refit_record",
    "builds_total",
    "build_sizing",
    "build_loop",
    "build_cmd",
    "gpu_prepare",
    "gpu_emit",
    "tlas",
    "tlas_pack",
    "tlas_cmd",
};

struct SwayMeasure {
    long[SwayStage::len] ns;
    long[SwayStage::len] calls;
    long                 tlas_rows;
}

SwayMeasure sway_measure;
long sway_pair_ns;  // cost one nested timer adds to every enclosing interval
long sway_empty_ns; // value an empty interval records: the timer's own cost in a leaf

fn void sway_measure_stop(SwayStage stage, time::Clock started) {
    sway_measure.ns[stage.ordinal] += (long)started.to_now();
    sway_measure.calls[stage.ordinal]++;
}

fn void sway_measure_reset() {
    sway_measure = {};
}

<*
 Fold the counters a local gpu.c3l patch keeps into the stage table; no-op without the patch.
*>
fn void sway_measure_collect_gpu() {
    $if $feat(MEASURE_GPU_PREPARE):
        sway_measure.ns[SwayStage.GPU_PREPARE.ordinal] += gpu::measure_prepare_ns;
        sway_measure.calls[SwayStage.GPU_PREPARE.ordinal] += gpu::measure_calls;
        sway_measure.ns[SwayStage.GPU_EMIT.ordinal] += gpu::measure_emit_ns;
        sway_measure.calls[SwayStage.GPU_EMIT.ordinal] += gpu::measure_calls;
        gpu::measure_prepare_ns = 0;
        gpu::measure_emit_ns = 0;
        gpu::measure_calls = 0;
    $endif
}

fn void sway_measure_calibrate() {
    const long ROUNDS = 2_000_000;
    long sink;
    long recorded;
    time::Clock begin = clock::now();
    for (long round = 0; round < ROUNDS; round++) {
        time::Clock started = clock::now();
        long interval = (long)started.to_now();
        recorded += interval;
        sink += interval;
    }
    long total = (long)begin.to_now();
    sway_pair_ns = total / ROUNDS + (sink & 0);
    sway_empty_ns = recorded / ROUNDS;
}

<*
 Stage time minus the cost of its own timer and of every timer nested below it.
*>
fn long sway_net_ns(SwayMeasure* measure, SwayStage stage) {
    long nested_calls;
    foreach (descendant : SwayStage::values) {
        SwayStage ancestor = SWAY_STAGE_PARENT[descendant.ordinal];
        if (descendant == stage) continue;
        // Walk up from the descendant's parent; the root points at itself.
        for (usz depth = 0; depth < SwayStage::len; depth++) {
            if (ancestor == stage) {
                nested_calls += measure.calls[descendant.ordinal];
                break;
            }
            if (SWAY_STAGE_PARENT[ancestor.ordinal] == ancestor) break;
            ancestor = SWAY_STAGE_PARENT[ancestor.ordinal];
        }
    }
    return measure.ns[stage.ordinal] - measure.calls[stage.ordinal] * sway_empty_ns - nested_calls * sway_pair_ns;
}
