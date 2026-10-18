module breakable_example;

import c3d;
import b3;
import c3d::physics;
import c3d::scene;
import std::io;
import std::math;
import std::core::mem::allocators;
import std::sort;
import std::time;
import std::time::clock;

const uint BENCHMARK_WARMUP @local = 300; // five simulated seconds to settle the walls
const uint BENCHMARK_FRAMES @local = 600; // ten simulated seconds of the steady workload
const uint BENCHMARK_REPEATS @local = 3;
const uint LATENCY_FRAMES @local = 300;
const usz RECORDING_BYTES @local = 4 * 1024 * 1024; // starting capacity for the recorded impact
const uint RESET_SAMPLES @local = 32;
const uint LARGE_WALL_SIDE @local = 32; // 1,024 pieces and 523,776 pairs; the graph reserves about 12 MiB for them
const ulong CHECKSUM_BASIS @local = 0xcbf2_9ce4_8422_2325; // FNV-1a offset basis
const ulong CHECKSUM_PRIME @local = 0x0000_0100_0000_01b3; // FNV-1a prime

fn bool belongs_to_wall(Node* node, Node* root) @local {
    for (Node* current = node; current; current = current.parent) {
        if (current == root) return true;
    }
    return false;
}

fn void? measure_idle(bool sleeping, uint run) @local {
    Demo demo;
    create_demo(mem, &demo, "")!;
    defer destroy_demo(&demo);
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = sleeping;
    desc.break_force = float::max;
    rebuild_demo(&demo, 1, desc)!;
    double author_ms = demo.author_ms;
    uint edges = (uint)demo.scene.get(demo.walls[0], Breakable).state.welds.len;
    rebuild_demo(&demo, MAX_WALLS, desc)!;

    double elapsed;
    for (uint frame = 0; frame < BENCHMARK_WARMUP + BENCHMARK_FRAMES; frame++) {
        demo.scene.update_world();
        time::Clock started = clock::now();
        demo.physics.update(physics::DEFAULT_FIXED_DT);
        double duration = (double)(clock::now() - started);
        if (frame >= BENCHMARK_WARMUP) elapsed += duration;
    }
    foreach (root : demo.walls[:demo.wall_count]) {
        BreakableState* state = demo.scene.get(root, Breakable).state;
        if (state.alive_welds != state.welds.len) return c3d::INVALID_ARGUMENT~;
    }
    b3::Counters counters = demo.physics.world.counters();
    io::printfn("idle,%s,run,%d,author_ms,%.6f,edges,%d,update_ms,%.6f,bodies,%d,joints,%d,awake,%d",
        sleeping ? "ASSEMBLY" : "PIECES", run, author_ms, edges,
        elapsed / BENCHMARK_FRAMES / 1_000_000, counters.body_count, counters.joint_count,
        demo.physics.world.awake_body_count());
}

fn void? measure_latency(bool sleeping) @local {
    Demo demo;
    create_demo(mem, &demo, "")!;
    defer destroy_demo(&demo);
    demo.physics.start_recording(RECORDING_BYTES)!;
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = sleeping;
    desc.break_force = EXAMPLE_BREAK_FORCE;
    rebuild_demo(&demo, 1, desc)!;
    for (uint frame = 0; frame < BENCHMARK_WARMUP; frame++) {
        demo.scene.update_world();
        demo.physics.update(physics::DEFAULT_FIXED_DT);
        if (demo.physics.breaks().len) return c3d::INVALID_ARGUMENT~;
    }
    throw_box(
        demo: &demo,
        position: aim_point(&demo) + (Vec3){ 0, 0, 3 },
        direction: { 0, 0, -1 },
        speed: 15,
    )!;
    uint hit_step = uint::max;
    uint wake_step = uint::max;
    uint break_step = uint::max;
    for (uint step = 0; step < LATENCY_FRAMES; step++) {
        demo.scene.update_world();
        demo.physics.update(physics::DEFAULT_FIXED_DT);
        foreach (hit : demo.physics.hits()) {
            if (hit_step == uint::max && (belongs_to_wall(hit.a, demo.walls[0]) || belongs_to_wall(hit.b, demo.walls[0]))) {
                hit_step = step;
            }
        }
        BreakableState* state = demo.scene.get(demo.walls[0], Breakable).state;
        if (sleeping && state.form == PIECES && wake_step == uint::max) wake_step = step;
        if (demo.physics.breaks().len && break_step == uint::max) break_step = step;
    }
    if (hit_step == uint::max || break_step == uint::max) return c3d::INVALID_ARGUMENT~;
    if (sleeping) {
        io::printfn("latency,ASSEMBLY,hit_step,%d,wake_step,%d,break_step,%d,after_hit,%d",
            hit_step, wake_step, break_step, break_step - hit_step);
    } else {
        io::printfn("latency,PIECES,hit_step,%d,break_step,%d,after_hit,%d",
            hit_step, break_step, break_step - hit_step);
    }

    char[] bytes = demo.physics.stop_recording(mem)!;
    defer free(bytes);
    PhysicsReplay replay = physics::create_physics_replay(
        allocator: mem,
        data: bytes,
        friction_mix: demo.physics.desc.tuning.friction_mix,
        restitution_mix: demo.physics.desc.tuning.restitution_mix,
    )!;
    defer physics::destroy_physics_replay(&replay);
    while (replay.step()) {}
    if (try frame = replay.diverge_frame()) {
        io::eprintfn("Replay diverged at %d", frame);
        return c3d::INVALID_ARGUMENT~;
    }
    io::printfn("replay,%s,frames,%d,matched", sleeping ? "ASSEMBLY" : "PIECES", replay.frame_count());
}

fn ulong mix_checksum(ulong checksum, uint value) @local {
    return (checksum ^ value) * CHECKSUM_PRIME;
}

fn ulong mix_vector(ulong checksum, Vec3 value) @local {
    for (usz axis = 0; axis < 3; axis++) checksum = mix_checksum(checksum, bitcast(value[axis], uint));
    return checksum;
}

fn ulong mix_frame(ulong checksum, maths::Transform frame) @local {
    checksum = mix_vector(checksum, frame.position);
    for (usz lane = 0; lane < 4; lane++) checksum = mix_checksum(checksum, bitcast(frame.rotation.v[lane], uint));
    return mix_vector(checksum, frame.scale);
}

fn ulong graph_checksum(BreakableState* state) @local {
    ulong checksum = CHECKSUM_BASIS;
    for (uint index = 0; index < state.welds.len; index++) {
        BreakableWeldView weld = state.weld_view(index);
        checksum = mix_checksum(checksum, weld.piece_a);
        checksum = mix_checksum(checksum, weld.piece_b);
        checksum = mix_vector(checksum, weld.anchor);
        checksum = mix_frame(checksum, weld.frame_a);
        checksum = mix_frame(checksum, weld.frame_b);
    }
    return checksum;
}

fn void? measure_authoring(uint workers, uint wall_side, uint run) @local {
    Demo demo;
    create_demo(
        allocator: mem,
        demo: &demo,
        model_path: "",
        wall_side: wall_side,
    )!;
    defer destroy_demo(&demo);
    if (workers) start_workers(&demo, workers)!;

    BreakableDesc desc = physics::default_breakable_desc();
    desc.break_force = float::max;
    rebuild_demo(&demo, 1, desc)!;
    BreakableState* state = demo.scene.get(demo.walls[0], Breakable).state;
    io::printfn("authoring,workers,%d,side,%d,run,%d,pieces,%d,edges,%d,author_ms,%.6f,graph_checksum,%016x",
        workers, wall_side, run, state.pieces.len, state.welds.len, demo.author_ms, graph_checksum(state));
}

fn void? run_benchmark(uint workers) @private {
    for (uint run = 0; run < BENCHMARK_REPEATS; run++) {
        measure_authoring(workers, WALL_SIDE, run)!;
        measure_authoring(workers, LARGE_WALL_SIDE, run)!;
    }
    for (uint run = 0; run < BENCHMARK_REPEATS; run++) {
        measure_idle(true, run)!;
        measure_idle(false, run)!;
    }
    measure_latency(true)!;
    measure_latency(false)!;
    for (uint run = 0; run < BENCHMARK_REPEATS; run++) {
        measure_strength_evaluation(NATIVE_FORCE, run)!;
        measure_strength_evaluation(SAMPLED_REACTION, run)!;
    }
    measure_reset()!;
    io::printfn("component_bytes,%d,event_bytes,%d", Breakable::size, BreakEvent::size);
}

fn void? measure_strength_evaluation(BreakableEvaluation evaluation, uint run) @local {
    Demo demo;
    create_demo(mem, &demo, "")!;
    defer destroy_demo(&demo);
    demo.anchored = true;
    demo.evaluation = evaluation;
    demo.strength = physics::default_breakable_strength(float::max);
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    desc.break_force = float::max;
    rebuild_demo(&demo, MAX_WALLS, desc)!;

    double elapsed;
    for (uint frame = 0; frame < BENCHMARK_WARMUP + BENCHMARK_FRAMES; frame++) {
        demo.scene.update_world();
        time::Clock started = clock::now();
        demo.physics.update(physics::DEFAULT_FIXED_DT);
        double duration = (double)(clock::now() - started);
        if (frame >= BENCHMARK_WARMUP) elapsed += duration;
    }
    uint pieces;
    uint welds;
    uint anchors;
    foreach (root : demo.walls[:demo.wall_count]) {
        BreakableState* state = demo.scene.get(root, Breakable).state;
        if (state.alive_welds != state.welds.len || state.alive_anchors != state.anchor_count()) return c3d::INVALID_ARGUMENT~;
        pieces += state.alive_pieces;
        welds += state.alive_welds;
        anchors += state.alive_anchors;
    }
    b3::Counters counters = demo.physics.world.counters();
    io::printfn("strength_mode,%s,run,%d,walls,%d,pieces,%d,welds,%d,anchors,%d,update_ms,%.6f,bodies,%d,joints,%d,awake,%d,workers,%d",
        evaluation == NATIVE_FORCE ? "NATIVE_FORCE" : "SAMPLED_REACTION", run, demo.wall_count, pieces, welds, anchors,
        elapsed / BENCHMARK_FRAMES / 1_000_000, counters.body_count, counters.joint_count,
        demo.physics.world.awake_body_count(), demo.physics.worker_count());
}

fn void? measure_reset() @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Demo demo;
        create_demo(&tracker, &demo, "")!;
        defer destroy_demo(&demo);
        demo.anchored = true;
        demo.evaluation = SAMPLED_REACTION;
        demo.strength = physics::default_breakable_strength(float::max);
        BreakableDesc desc = physics::default_breakable_desc();
        desc.sleep_until_hit = false;
        desc.break_force = float::max;
        rebuild_demo(&demo, 1, desc)!;
        BreakableState* state = demo.scene.get(demo.walls[0], Breakable).state;
        b3::BodyId target = demo.physics.body(demo.anchor_target)!;
        double[RESET_SAMPLES] durations;
        foreach (&duration : durations) {
            time::Clock started = clock::now();
            demo.physics.reset_breakable(demo.walls[0], PIECES)!;
            *duration = (double)(clock::now() - started) / 1_000_000;
            b3::Counters counters = demo.physics.world.counters();
            if (!target.is_valid() || counters.body_count != state.pieces.len + 1
                || counters.joint_count != state.welds.len + state.anchor_count()) return c3d::INVALID_ARGUMENT~;
        }
        foreach (index, duration : durations) io::printfn("reset_cpu_ms,%d,%.6f", index, duration);
        sort::quicksort(durations[..]);
        double median = (durations[RESET_SAMPLES / 2 - 1] + durations[RESET_SAMPLES / 2]) * 0.5;
        io::printfn("reset,form,PIECES,samples,%d,pieces,%d,welds,%d,anchors,%d,median_ms,%.6f,max_ms,%.6f,c3_peak_bytes,%d",
            RESET_SAMPLES, state.pieces.len, state.welds.len, state.anchor_count(), median, durations[^1], tracker.max_allocated());
    }
    if (tracker.has_leaks()) return c3d::INVALID_ARGUMENT~;
}
