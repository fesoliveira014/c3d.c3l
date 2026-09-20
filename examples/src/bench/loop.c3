module bench_loop;

import c3d::render;
import std::io;
import std::time;
import std::time::clock;

<*
 Timing and counters for one measured frame.
 GPU values arrive when the frame's slot is reused; store them into the row of the submitting frame.
*>
struct FrameSample {
    double wall_ms;
    double update_ms;
    double begin_ms;
    double render_ms;
    double finish_ms;
    double end_ms;
    double gui_ms;
    float cpu_record_ms;
    float[render::PASS_COUNT] gpu_ms;
    uint draws;
    uint lights;
    uint dropped;
    uint overflows;
}

<*
 Milliseconds elapsed since the clock value.
*>
fn double milliseconds(time::Clock started) {
    return (double)(clock::now() - started) / 1_000_000.0;
}

<*
 Print the CSV header and one row per sample to stdout.
 @param timestamps_enabled : "False prints -1 in every GPU column."
*>
fn void write_samples(FrameSample[] samples, bool timestamps_enabled) {
    io::printn("frame,wall_ms,update_ms,begin_ms,render_ms,finish_ms,end_ms,gui_ms,cpu_record_ms,draws,lights,dropped,overflows,gpu_cull_ms,gpu_opaque_ms,gpu_post_ms,gpu_composite_ms");
    foreach (index, sample : samples) {
        float unavailable = -1;
        io::printfn("%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%d,%d,%d,%.6f,%.6f,%.6f,%.6f",
            index, sample.wall_ms, sample.update_ms, sample.begin_ms, sample.render_ms,
            sample.finish_ms, sample.end_ms, sample.gui_ms, sample.cpu_record_ms, sample.draws, sample.lights,
            sample.dropped, sample.overflows,
            timestamps_enabled ? sample.gpu_ms[Pass.LIGHT_CULL.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.FORWARD_OPAQUE.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.POST_CHAIN.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.COMPOSITE.ordinal] : unavailable);
    }
}
