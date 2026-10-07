module c3d::physics::fracture;

import std::time;

fn Clock begin_exact_measurement(ExactScratch* scratch) @private {
    Clock started;
    if (!scratch.measurement_depth++) started = clock::now();
    return started;
}

fn void finish_exact_measurement(ExactScratch* scratch, Clock started) @private {
    if (!--scratch.measurement_depth) scratch.exact_nanoseconds += (ulong)started.to_now();
}
