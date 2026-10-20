module c3d::render;

import c3d::maths;
import c3d::shader;
import std::time;
import std::time::clock;

// Measurement only; nothing here merges. State is module-level and unsynchronised: the recording thread writes it.
// MEASURE_GATHER times the passes and functions of the trace gather. MEASURE_GATHER_ROWS adds the per-row timers.
// A coarse build (no rows) separates the cost of the row timers from the passes they sit in.

enum GatherStage : int {
    PREPARE,                // prepare_scene_trace past the same-frame early return
    GATHER,                 // record_scene_trace
    COLLECT,                // collect_trace_instances
    COLLECT_ALLOCATE,       // group_live
    COLLECT_ALLOCATE_ROWS,  // the record and pose arrays
    COLLECT_CAPACITY,       // the capacity passes, lod_group_is_live included
    COLLECT_MESH_PASS,      // the Mesh pass
    COLLECT_BATCH_PASS,     // the InstancedMesh pass
    COLLECT_BATCH,          // one batch: liveness, traceability, pose source and its rows
    COLLECT_BATCH_ROW,      // one row of a batch (rows)
    COLLECT_LOD_PASS,       // the LodGroup pass
    COLLECT_LOD_ROW,        // one row of a LOD group part (rows)
    COLLECT_SWAY_LAST,      // sway_rows_last
    RESOLVE,                // resolve_trace_instances
    RESOLVE_SETUP,          // material scope, pose groups, counters
    RESOLVE_CLASSIFY,       // per row: pose key, trace and BLAS sources (rows)
    RESOLVE_RESOURCES,      // per row: resolve_geometry, resolve_material, published_stage_matches (rows)
    RESOLVE_CLAIM_HIT,      // per row: the claim found its key (rows)
    RESOLVE_CLAIM_MISS,     // per row: the claim took a vacant or stale slot (rows)
    RESOLVE_CLAIM_OVERFLOW, // per row: the claim scanned every slot and faulted (rows)
    RESOLVE_FALLBACK,       // per overflow row: the rest-form fallback after the fault (rows)
    RESOLVE_FINISH,         // per row: builds, slot fields, sway join or posed resolve (rows)
    RESOLVE_JOIN,           // per sway row: acquire_posed_slot, point_at_posed_slot, push (rows)
    RESOLVE_CLOSE,          // PosedSwayBatch.close at a batch change, inside RESOLVE_FINISH
    RESOLVE_CLOSE_LAST,     // PosedSwayBatch.close after the last row
    RESOLVE_COMPACT,        // per row: the copy into the kept records (rows)
    COMPARE_ROWS,           // rows_unchanged: the full-record compare
    COMPARE_PREFIX,         // top_level_reusable: the prefix compare
    WRITE_TOP_LEVEL,        // write_top_level
    WRITE_TOP_BVH,          // box gather and build_box_bvh
    WRITE_TOP_ROWS,         // the TraceInstanceGpu row writes
    WRITE_TOP_BASELINE,     // the baseline copy
    IDENTITY_CHECK,         // measurement only: the previous-write comparison
    TLAS_RECORD,            // record_top_level_build
    TLAS_PACK,              // upload take and instance packing
    CALIBRATION,            // empty interval
}

enum GatherCounter : int {
    ROWS_KEPT,
    CLAIM_HITS,
    CLAIM_MISSES,
    CLAIM_OVERFLOWS,
    SLOT_VISITS_MISS,       // slots visited by claims that found a slot
    SLOT_VISITS_OVERFLOW,   // slots visited by claims that faulted
    WRITE_TOP_LEVEL_CALLS,
    TLAS_BUILDS,
    RECORD_CAPACITY,        // length of the record and pose arrays collection allocates
    SWAY_ONLY_WRITES,       // writes whose records differ from the baseline in pose_serial alone
    SWAY_ONLY_SERIAL_ROWS,  // rows whose pose_serial moved in those writes
    SWAY_ONLY_BOXES_SAME,   // sway-only writes with the box BVH input equal to the previous write's
    SWAY_ONLY_ROWS_SAME,    // sway-only writes with the TraceInstanceGpu rows equal to the previous write's
    SWAY_ONLY_BOXES_DIFFER, // boxes that differ from the previous write, summed over sway-only writes
    SWAY_ONLY_ROWS_DIFFER,  // rows that differ from the previous write, summed over sway-only writes
    BOUNDS_WRITES,          // writes whose records differ from the baseline in pose_serial and bounds alone
    BOUNDS_BOXES_DIFFER,    // boxes that differ from the previous write, summed over those writes
    BOUNDS_ROWS_DIFFER,     // rows that differ from the previous write, summed over those writes
    OTHER_WRITES,           // writes over the same set whose records differ in anything else
    NEW_SET_WRITES,         // writes over a new set: another scene, row count or origin
}

enum GatherWrite : int {
    NEW_SET,
    SERIAL_ONLY,
    SERIAL_AND_BOUNDS,
    OTHER,
}

const String[TracePose::len] GATHER_POSE_NAMES = {
    "rest",
    "mesh",
    "crowd",
    "animated_lod",
    "vertex_motion",
    "custom",
    "sway",
};

struct GatherMeasure {
    long[GatherStage::len]   ns;
    long[GatherStage::len]   calls;
    long[GatherCounter::len] counts;
    long[TracePose::len]     rows_by_pose;
}

GatherMeasure gather_measure;
long gather_pair_ns;  // cost one timer adds to every interval around it
long gather_empty_ns; // value an empty interval records: the timer's own cost inside its interval

// Boxes and rows the last top-level write held.
Aabb[]             gather_boxes_before;
TraceInstanceGpu[] gather_rows_before;

fn GatherStage gather_parent(GatherStage stage) {
    switch (stage) {
        case PREPARE:
        case CALIBRATION:
        case GATHER:
        case TLAS_RECORD:
            return GatherStage.PREPARE;
        case COLLECT:
        case RESOLVE:
        case COMPARE_ROWS:
        case COMPARE_PREFIX:
        case WRITE_TOP_LEVEL:
            return GatherStage.GATHER;
        case COLLECT_ALLOCATE:
        case COLLECT_ALLOCATE_ROWS:
        case COLLECT_CAPACITY:
        case COLLECT_MESH_PASS:
        case COLLECT_BATCH_PASS:
        case COLLECT_LOD_PASS:
        case COLLECT_SWAY_LAST:
            return GatherStage.COLLECT;
        case COLLECT_BATCH:
            return GatherStage.COLLECT_BATCH_PASS;
        case COLLECT_BATCH_ROW:
            return GatherStage.COLLECT_BATCH;
        case COLLECT_LOD_ROW:
            return GatherStage.COLLECT_LOD_PASS;
        case RESOLVE_SETUP:
        case RESOLVE_CLASSIFY:
        case RESOLVE_RESOURCES:
        case RESOLVE_CLAIM_HIT:
        case RESOLVE_CLAIM_MISS:
        case RESOLVE_CLAIM_OVERFLOW:
        case RESOLVE_FALLBACK:
        case RESOLVE_FINISH:
        case RESOLVE_CLOSE_LAST:
        case RESOLVE_COMPACT:
            return GatherStage.RESOLVE;
        case RESOLVE_JOIN:
        case RESOLVE_CLOSE:
            return GatherStage.RESOLVE_FINISH;
        case WRITE_TOP_BVH:
        case WRITE_TOP_ROWS:
        case WRITE_TOP_BASELINE:
        case IDENTITY_CHECK:
            return GatherStage.WRITE_TOP_LEVEL;
        case TLAS_PACK:
            return GatherStage.TLAS_RECORD;
    }
}

fn time::Clock gather_start() @inline {
    $if $feat(MEASURE_GATHER):
        return clock::now();
    $else
        return (time::Clock)0;
    $endif
}

fn void gather_stop(GatherStage stage, time::Clock started) @inline {
    $if $feat(MEASURE_GATHER):
        gather_measure.ns[stage.ordinal] += (long)started.to_now();
        gather_measure.calls[stage.ordinal]++;
    $endif
}

fn time::Clock gather_row_start() @inline {
    $if $feat(MEASURE_GATHER) && $feat(MEASURE_GATHER_ROWS):
        return clock::now();
    $else
        return (time::Clock)0;
    $endif
}

fn void gather_row_stop(GatherStage stage, time::Clock started) @inline {
    $if $feat(MEASURE_GATHER) && $feat(MEASURE_GATHER_ROWS):
        gather_measure.ns[stage.ordinal] += (long)started.to_now();
        gather_measure.calls[stage.ordinal]++;
    $endif
}

fn void gather_count(GatherCounter counter, long amount = 1) @inline {
    $if $feat(MEASURE_GATHER):
        gather_measure.counts[counter.ordinal] += amount;
    $endif
}

fn void gather_count_pose(TracePose kind) @inline {
    $if $feat(MEASURE_GATHER):
        gather_measure.rows_by_pose[kind.ordinal]++;
    $endif
}

fn void gather_reset() {
    gather_measure = {};
}

<*
 Time an empty interval through the real timer path, to price one timer.
*>
fn void gather_calibrate() {
    const long ROUNDS = 2_000_000;
    time::Clock begin = clock::now();
    for (long round = 0; round < ROUNDS; round++) {
        time::Clock started = clock::now();
        gather_measure.ns[GatherStage.CALIBRATION.ordinal] += (long)started.to_now();
        gather_measure.calls[GatherStage.CALIBRATION.ordinal]++;
    }
    gather_pair_ns = (long)begin.to_now() / ROUNDS;
    gather_empty_ns = gather_measure.ns[GatherStage.CALIBRATION.ordinal] / ROUNDS;
    gather_reset();
}

<*
 Stage time minus the cost of its own timers and of every timer nested below it.
*>
fn long gather_net_ns(GatherMeasure* measure, GatherStage stage) {
    long nested_calls;
    foreach (descendant : GatherStage::values) {
        if (descendant == stage || descendant == GatherStage.CALIBRATION) continue;

        GatherStage ancestor = gather_parent(descendant);
        for (usz depth = 0; depth < GatherStage::len; depth++) {
            if (ancestor == stage) {
                nested_calls += measure.calls[descendant.ordinal];
                break;
            }
            if (gather_parent(ancestor) == ancestor) break;
            ancestor = gather_parent(ancestor);
        }
    }
    return measure.ns[stage.ordinal] - measure.calls[stage.ordinal] * gather_empty_ns - nested_calls * gather_pair_ns;
}

<*
 Which fields of the records differ from the baseline over the same set, and in how many rows pose_serial moved.
*>
fn GatherWrite gather_classify_write(TraceInstance[] baseline, TraceInstance[] records, long* serial_rows) {
    *serial_rows = 0;
    bool bounds_moved;
    foreach (index, &record : records) {
        TraceInstance* before = &baseline[index];
        TraceInstance masked = *record;
        masked.pose_serial = before.pose_serial;
        masked.bounds = before.bounds;
        if (!mem::equals(&masked, before, TraceInstance::size)) return GatherWrite.OTHER;

        if (record.pose_serial != before.pose_serial) (*serial_rows)++;
        if (record.bounds.min != before.bounds.min || record.bounds.max != before.bounds.max) bounds_moved = true;
    }
    return bounds_moved ? GatherWrite.SERIAL_AND_BOUNDS : GatherWrite.SERIAL_ONLY;
}

<*
 Compare the boxes and rows about to be written with the last write's, then keep them.
*>
fn void gather_compare_with_last_write(Aabb[] boxes, TraceInstanceGpu[] rows, GatherWrite write, long serial_rows) {
    switch (write) {
        case NEW_SET:
            gather_count(GatherCounter.NEW_SET_WRITES);
        case OTHER:
            gather_count(GatherCounter.OTHER_WRITES);
        case SERIAL_ONLY:
        case SERIAL_AND_BOUNDS:
            if (gather_boxes_before.len == boxes.len && gather_rows_before.len == rows.len) {
                long boxes_differing;
                foreach (index, &box : boxes) {
                    Aabb* before = &gather_boxes_before[index];
                    if (box.min != before.min || box.max != before.max) boxes_differing++;
                }
                long rows_differing;
                foreach (index, &row : rows) {
                    if (!mem::equals(row, &gather_rows_before[index], TraceInstanceGpu::size)) rows_differing++;
                }
                if (write == GatherWrite.SERIAL_ONLY) {
                    gather_count(GatherCounter.SWAY_ONLY_WRITES);
                    gather_count(GatherCounter.SWAY_ONLY_SERIAL_ROWS, serial_rows);
                    if (!boxes_differing) gather_count(GatherCounter.SWAY_ONLY_BOXES_SAME);
                    if (!rows_differing) gather_count(GatherCounter.SWAY_ONLY_ROWS_SAME);
                    gather_count(GatherCounter.SWAY_ONLY_BOXES_DIFFER, boxes_differing);
                    gather_count(GatherCounter.SWAY_ONLY_ROWS_DIFFER, rows_differing);
                } else {
                    gather_count(GatherCounter.BOUNDS_WRITES);
                    gather_count(GatherCounter.BOUNDS_BOXES_DIFFER, boxes_differing);
                    gather_count(GatherCounter.BOUNDS_ROWS_DIFFER, rows_differing);
                }
            }
    }

    if (gather_boxes_before.len != boxes.len) {
        if (gather_boxes_before.len) alloc::free(mem, gather_boxes_before.ptr);
        if (gather_rows_before.len) alloc::free(mem, gather_rows_before.ptr);
        gather_boxes_before = alloc::new_array(mem, Aabb, (sz)boxes.len);
        gather_rows_before = alloc::new_array(mem, TraceInstanceGpu, (sz)rows.len);
    }
    gather_boxes_before[..] = boxes[..];
    gather_rows_before[..] = rows[..];
}
