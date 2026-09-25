module bench_loop;

import c3d;
import c3d::gui;
import c3d::platform;
import c3d::render;
import c3d::render::post;
import c3d::scene;
import gpu;
import std::io;
import std::time;
import std::time::clock;

const uint FRAMES_MAX = 100000; // bounds sample storage requested from the command line
const uint EXTENT_MAX = 8192; // bounds the offscreen target requested from the command line

<*
 Options every benchmark example parses the same way.
*>
struct BenchmarkFlags {
    bool enabled;
    bool gpu_timings;
    bool validation;
    bool capture;
    bool window;
    bool panel;
    bool print_features;
    uint frames;
    uint warmup;
    uint width;
    uint height;
    AntiAliasing anti_aliasing;
    AmbientOcclusionDesc ambient_occlusion;
    bool depth_prepass;
    bool reflections;
}

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
    uint material_resolutions;
    uint pipeline_lookups;
}

<*
 Borrowed objects one benchmark loop drives; optional members stay null.
*>
struct BenchmarkRun {
    Renderer* renderer;
    Scene* scene;
    Node* camera_node;
    ViewId view;
    platform::Window* window;
    BenchmarkRecorder* recorder @if($feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU));
    GuiRenderer* gui_renderer @if($feat(C3D_PROFILE_GUI));
    gui::ProfilerPanel* panel @if($feat(C3D_PROFILE_GUI));
}

<*
 Default flags: 300 frames after 60 warmup, 1440 by 900, FXAA, depth prepass, no AO.
*>
fn BenchmarkFlags default_flags() {
    return {
        .frames        = 300,
        .warmup        = 60,
        .width         = 1440,
        .height        = 900,
        .anti_aliasing = AntiAliasing.FXAA,
        .depth_prepass = true,
    };
}

<*
 Consume one common option at args[*index], advancing past its value.
 @param [&inout] index : "Left on the last consumed argument."
 @param [&inout] flags : "Receives the option."
 @param target : "Example target named in build recipes."
 @return "True when the argument was a common option."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
*>
fn bool? parse_flag(String[] args, usz* index, BenchmarkFlags* flags, String target) {
    switch (args[*index]) {
        case "--benchmark": flags.enabled = true;
        case "--validation": flags.validation = true;
        case "--window": flags.window = true;
        case "--print-features": flags.print_features = true;
        case "--gpu-timings":
            $if $feat(C3D_PROFILE_GPU):
                flags.gpu_timings = true;
            $else
                io::eprintfn("--gpu-timings needs GPU profiling: c3c build %s --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL", target);
                return c3d::UNSUPPORTED~;
            $endif
        case "--capture":
            $if $feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU):
                flags.capture = true;
            $else
                io::eprintfn("--capture needs CPU or GPU profiling: c3c build %s --path examples --lib c3d_profile -D C3D_PROFILE_CPU -D C3D_PROFILE_INTERNAL", target);
                return c3d::UNSUPPORTED~;
            $endif
        case "--panel":
            $if $feat(C3D_PROFILE_GUI):
                flags.panel = true;
            $else
                io::eprintfn("--panel needs the profiler GUI: c3c build %s --path examples --lib c3d_profile_gui --lib c3d_profile -D C3D_PROFILE_GUI -D C3D_PROFILE_CPU -D C3D_PROFILE_INTERNAL", target);
                return c3d::UNSUPPORTED~;
            $endif
        case "--frames": flags.frames = option_value(args, index)!.to_uint()!;
        case "--warmup": flags.warmup = option_value(args, index)!.to_uint()!;
        case "--width": flags.width = option_value(args, index)!.to_uint()!;
        case "--height": flags.height = option_value(args, index)!.to_uint()!;
        case "--anti-aliasing":
            switch (option_value(args, index)!) {
                case "none": flags.anti_aliasing = AntiAliasing.NONE;
                case "fxaa": flags.anti_aliasing = AntiAliasing.FXAA;
                case "taa": flags.anti_aliasing = AntiAliasing.TAA;
                default: return c3d::INVALID_ARGUMENT~;
            }
        case "--depth-prepass":
            switch (option_value(args, index)!) {
                case "on": flags.depth_prepass = true;
                case "off": flags.depth_prepass = false;
                default: return c3d::INVALID_ARGUMENT~;
            }
        case "--ambient-occlusion":
            switch (option_value(args, index)!) {
                case "none": flags.ambient_occlusion = {};
                case "half": flags.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
                case "full":
                    flags.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
                    flags.ambient_occlusion.full_resolution = true;
                case "ray-traced":
                    flags.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
                    flags.ambient_occlusion.kind = AoKind.RAY_TRACED;
                default: return c3d::INVALID_ARGUMENT~;
            }
        case "--reflections":
            switch (option_value(args, index)!) {
                case "on": flags.reflections = true;
                case "off": flags.reflections = false;
                default: return c3d::INVALID_ARGUMENT~;
            }
        default: return false;
    }
    return true;
}

<*
 Value following an option, advancing the index onto it.
 @return? c3d::INVALID_ARGUMENT
*>
fn String? option_value(String[] args, usz* index) {
    if (++*index == args.len) return c3d::INVALID_ARGUMENT~;
    return args[*index];
}

<*
 Reject frame counts, extents and flag combinations the loop cannot run.
 @return? c3d::INVALID_ARGUMENT
*>
fn void? validate_flags(BenchmarkFlags flags) {
    if (!flags.frames || flags.frames > FRAMES_MAX || flags.warmup > FRAMES_MAX
        || !flags.width || flags.width > EXTENT_MAX || !flags.height || flags.height > EXTENT_MAX
        || (flags.panel && (!flags.window || !flags.capture))) {
        return c3d::INVALID_ARGUMENT~;
    }
}

<*
 Whether the flags select an effect that traces rays.
*>
fn bool needs_ray_queries(BenchmarkFlags flags) {
    return flags.reflections || flags.ambient_occlusion.kind == AoKind.RAY_TRACED;
}

<*
 Shading path a --shading value names: forward, deferred or path-traced.
 @return? c3d::INVALID_ARGUMENT
*>
fn ShadingPath? parse_shading(String value) {
    switch (value) {
        case "forward": return ShadingPath.FORWARD;
        case "deferred": return ShadingPath.DEFERRED;
        case "path-traced": return ShadingPath.PATH_TRACED;
        default: return c3d::INVALID_ARGUMENT~;
    }
}

<*
 Banner name of a shading path, as --shading spells it.
*>
fn String shading_name(ShadingPath shading) {
    switch (shading) {
        case FORWARD: return "forward";
        case DEFERRED: return "deferred";
        case PATH_TRACED: return "path-traced";
    }
}

<*
 Banner name of the ambient occlusion flag: none, half, full or ray-traced.
*>
fn String ambient_occlusion_name(AmbientOcclusionDesc ambient_occlusion) {
    switch (ambient_occlusion.kind) {
        case NONE: return "none";
        case SSAO: return ambient_occlusion.full_resolution ? "full" : "half";
        case RAY_TRACED: return "ray-traced";
    }
}

<*
 Print the compiled profiling features as cpu= gpu= internal= gui= on one line.
*>
fn void print_features() {
    io::printfn("cpu=%d gpu=%d internal=%d gui=%d",
        $feat(C3D_PROFILE_CPU) ? 1 : 0, $feat(C3D_PROFILE_GPU) ? 1 : 0,
        $feat(C3D_PROFILE_INTERNAL) ? 1 : 0, $feat(C3D_PROFILE_GUI) ? 1 : 0);
}

<*
 Milliseconds elapsed since the clock value.
*>
fn double milliseconds(time::Clock started) {
    return (double)(clock::now() - started) / 1_000_000.0;
}

<*
 Prepare the scene, run warmup and measured frames, then drain the frame slots.
 A closed window ends the run early with the rows collected so far.
 @param [&inout] run : "Renderer, scene and optional window, recorder and panel."
 @param [out] samples : "One row per measured frame; length is the frame count."
 @return "Number of rows written."
*>
fn usz? run_frames(BenchmarkRun* run, BenchmarkFlags flags, FrameSample[] samples) {
    Renderer* renderer = run.renderer;
    renderer.prepare_scene(run.scene)!;
    usz collected;
    for (uint frame = 0; frame < flags.warmup + flags.frames + render::FRAMES_IN_FLIGHT; frame++) {
        if (run.window && !run.window.poll()) break;
        FrameSample sample;
        $if $feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU):
            if (run.recorder) {
                record_captured_frame(run, frame, &sample)!;
            } else {
                record_frame(run, frame, &sample)!;
            }
        $else
            record_frame(run, frame, &sample)!;
        $endif
        if (frame >= flags.warmup + render::FRAMES_IN_FLIGHT) {
            uint completed = frame - flags.warmup - render::FRAMES_IN_FLIGHT;
            samples[completed].gpu_ms = renderer.stats.gpu_pass_ms;
            samples[completed].overflows = renderer.stats.cluster_overflows;
        }
        if (frame >= flags.warmup && frame < flags.warmup + flags.frames) {
            samples[frame - flags.warmup] = sample;
            collected = (usz)(frame - flags.warmup + 1);
        }
    }
    foreach (&slot : renderer.frames) {
        if (slot.done.is_valid()) gpu::wait_completion(slot.done)!;
    }
    return collected;
}

<*
 Print the CSV header and one row per sample to stdout.
 @param timestamps_enabled : "False prints -1 in every GPU column."
*>
fn void write_samples(FrameSample[] samples, bool timestamps_enabled) {
    io::printn("frame,wall_ms,update_ms,begin_ms,render_ms,finish_ms,end_ms,gui_ms,cpu_record_ms,draws,lights,dropped,overflows,material_resolutions,pipeline_lookups,gpu_shadow_ms,gpu_cull_ms,gpu_prepass_ms,gpu_gbuffer_ms,gpu_ambient_occlusion_ms,gpu_rt_reflections_ms,gpu_path_trace_ms,gpu_lighting_ms,gpu_opaque_ms,gpu_post_ms,gpu_composite_ms,gpu_velocity_ms,gpu_taa_ms");
    foreach (index, sample : samples) {
        float unavailable = -1;
        io::printfn("%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%d,%d,%d,%d,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
            index, sample.wall_ms, sample.update_ms, sample.begin_ms, sample.render_ms,
            sample.finish_ms, sample.end_ms, sample.gui_ms, sample.cpu_record_ms, sample.draws, sample.lights,
            sample.dropped, sample.overflows, sample.material_resolutions, sample.pipeline_lookups,
            timestamps_enabled ? sample.gpu_ms[Pass.SHADOW_ATLAS.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.LIGHT_CULL.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.DEPTH_PREPASS.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.GBUFFER.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.AMBIENT_OCCLUSION.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.RT_REFLECTIONS.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.PATH_TRACE.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.LIGHTING.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.FORWARD_OPAQUE.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.POST_CHAIN.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.COMPOSITE.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.VELOCITY.ordinal] : unavailable,
            timestamps_enabled ? sample.gpu_ms[Pass.TEMPORAL_AA.ordinal] : unavailable);
    }
}

fn void? record_frame(BenchmarkRun* run, uint frame, FrameSample* sample) @private {
    Renderer* renderer = run.renderer;
    time::Clock started = clock::now();
    time::Clock phase = started;
    run.scene.update_world();
    sample.update_ms = milliseconds(phase);
    phase = clock::now();
    renderer.begin_frame({ .time = (double)frame / 60, .delta = 1.0f / 60 })!;
    defer catch render::abort_frame(renderer);
    sample.begin_ms = milliseconds(phase);
    phase = clock::now();
    renderer.render_view(run.scene, run.camera_node, run.view)!;
    sample.render_ms = milliseconds(phase);
    phase = clock::now();
    renderer.finish_view(run.view)!;
    sample.finish_ms = milliseconds(phase);
    $if $feat(C3D_PROFILE_GUI):
        if (run.panel && renderer.has_output) {
            phase = clock::now();
            run.gui_renderer.new_frame();
            gui::profiler_panel(run.panel);
            run.gui_renderer.finish_frame();
            OverlayContext overlay = renderer.begin_overlay()!;
            run.gui_renderer.record(&overlay)!;
            renderer.end_overlay(&overlay)!;
            sample.gui_ms = milliseconds(phase);
        }
    $endif
    phase = clock::now();
    renderer.end_frame()!;
    sample.end_ms = milliseconds(phase);
    sample.wall_ms = milliseconds(started);
    sample.cpu_record_ms = renderer.stats.cpu_record_ms;
    sample.draws = renderer.stats.draws;
    sample.lights = renderer.stats.lights;
    sample.dropped = renderer.stats.lights_dropped;
    sample.material_resolutions = renderer.stats.material_resolutions;
    sample.pipeline_lookups = renderer.stats.pipeline_lookups;
}

module bench_loop @feat(C3D_PROFILE_CPU | C3D_PROFILE_GPU);

import c3d;
import c3d::profile;
import c3d::render;

<*
 Recorder type a benchmark run borrows.
*>
alias BenchmarkRecorder = profile::Recorder;

const uint CAPTURE_FRAME_CAPACITY @local = render::FRAMES_IN_FLIGHT + 2; // history slots beyond the frames in flight so no capture is dropped
const uint CAPTURE_CPU_SCOPES @local = 64; // one application scope plus the renderer's library scopes for one view
const uint CAPTURE_MAX_DEPTH @local = 8;
const uint CAPTURE_GPU_SCOPES @local = 256; // frame, view, passes, clusters and shadow layers of one view
const uint CAPTURE_LABEL_BYTES @local = 8192; // 8 KiB of copied labels per retained frame

<*
 Recorder sized for one view per frame in every compiled domain.
 @return? profile::INVALID_ARGUMENT
*>
fn BenchmarkRecorder? create_recorder() {
    profile::RecorderDesc desc = {
        .frame_capacity = CAPTURE_FRAME_CAPACITY,
        .label_bytes_per_frame = CAPTURE_LABEL_BYTES,
    };
    $if $feat(C3D_PROFILE_CPU):
        desc.cpu_scopes_per_frame = CAPTURE_CPU_SCOPES;
        desc.max_depth = CAPTURE_MAX_DEPTH;
    $endif
    $if $feat(C3D_PROFILE_GPU):
        desc.gpu_scopes_per_frame = CAPTURE_GPU_SCOPES;
    $endif
    return profile::create_recorder(mem, desc);
}

<*
 Release a recorder after its renderer has been destroyed.
 @param [&inout] recorder : "No attached producer."
*>
fn void destroy_recorder(BenchmarkRecorder* recorder) {
    profile::destroy_recorder(recorder);
}

fn void? record_captured_frame(BenchmarkRun* run, uint frame, FrameSample* sample) @private {
    profile::@capture(run.recorder, frame) {
        profile::@scope("application.frame") {
            record_frame(run, frame, sample)!;
        };
    };
}
