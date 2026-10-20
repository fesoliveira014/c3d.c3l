module c3d::physics::cloth;

import std::time;
import std::time::clock;

// Throwaway per-stage timing for the cloth solve. Measurement branch only; never merged.
// Counters are module-level and unsynchronised: run with zero job workers.

enum MeasureStage : int {
    SOLVE,
    WIND,
    PREDICT,
    FILTER_PRE,
    CERTIFY_PRE,
    PLACE_SHAPES,
    SOFT,
    EDGES,
    BENDS,
    BEND_CERTIFY,
    CONTACT_ITERATION,
    RESOLVE,
    CERTIFY_COMMIT,
    VELOCITY,
    CUTS,
    FINISH,
    FILTER_ALL,
    PUBLISH_PREPARE,
    PUBLISH_PLACE,
    PUBLISH_RESOLVE,
    PUBLISH_CERTIFY,
    PUBLISH_LOCAL,
    PUBLISH_ROUNDTRIP,
    PUBLISH_MATERIAL,
    PUBLISH_COMMIT,
}

const String[MeasureStage::len] MEASURE_STAGE_NAMES = {
    "solve_cloth (total)",
    "wind",
    "prediction and pins",
    "filter_displacement (pre-sweep)",
    "certify_hinge_step (pre-sweep)",
    "place_shapes",
    "soft attachments",
    "edges",
    "dihedral bends",
    "  of which certify_hinge_path",
    "contact_pass (iterations)",
    "resolve_contacts",
    "certify_hinge_step (commit)",
    "velocity update",
    "substep cuts",
    "end-of-solve copies",
    "filter_displacement (all calls)",
    "publish: prepare_publication",
    "publish: place_shapes",
    "publish: resolve_contacts",
    "publish: certify_hinge_step",
    "publish: stage_local_positions",
    "publish: roundtrip contact_pass",
    "publish: material frames",
    "publish: commit_cloth",
};

const uint MEASURE_SCOPE_ITERATION = 0;
const uint MEASURE_SCOPE_RESOLVE = 1;
const uint MEASURE_SCOPE_OTHER = 2;
const String[3] MEASURE_SCOPE_NAMES = { "iteration passes", "resolve_contacts passes", "publication and other passes" };

const uint MEASURE_PHASE_BENDS = 0;
const uint MEASURE_PHASE_PRE = 1;
const uint MEASURE_PHASE_COMMIT = 2;
const uint MEASURE_PHASE_OTHER = 3;
const String[4] MEASURE_PHASE_NAMES = { "bend projection", "pre-sweep", "commit", "publication and other" };

struct ContactScopeMeasure {
    long gather_ns;
    long evaluate_ns;
    long apply_ns;
    long passes;
    long applied_passes;
    long candidates;
    long contacts;
    long shape_tests;
    long finite_ns;
    long ground_ns;
    long setup_ns;
    long loop_ns;
    long ground_tests;
}

struct ClothMeasure {
    long[MeasureStage::len]  ns;
    long[MeasureStage::len]  calls;
    ContactScopeMeasure[3]   contact;
    uint                     contact_scope;
    uint                     path_phase;
    long[4]                  path_calls;
    long[4]                  path_unmoved;
    long[4]                  path_intervals;
    long[4]                  path_bisections;
    long                     solves;
    long                     substeps;
    long                     iterations;
    long                     bend_passes;
    long                     timer_pairs;
}

ClothMeasure measure;

fn void measure_add(MeasureStage stage, time::Clock started) {
    measure.ns[stage.ordinal] += (long)started.to_now();
    measure.calls[stage.ordinal]++;
    measure.timer_pairs++;
}

fn long measure_clock_pair_cost() {
    const long ROUNDS = 4_000_000;
    long sink;
    time::Clock begin = clock::now();
    for (long round = 0; round < ROUNDS; round++) {
        time::Clock started = clock::now();
        sink += (long)started.to_now();
    }
    long total = (long)begin.to_now();
    return total / ROUNDS + (sink & 0);
}
