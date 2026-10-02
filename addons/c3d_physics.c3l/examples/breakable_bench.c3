module breakable_example;

import c3d;
import b3;
import c3d::physics;
import c3d::scene;
import std::io;
import std::math;
import std::time;
import std::time::clock;

const uint BENCHMARK_WARMUP @local = 300; // five simulated seconds to settle the walls
const uint BENCHMARK_FRAMES @local = 600; // ten simulated seconds of the steady workload
const uint BENCHMARK_REPEATS @local = 3;
const uint LATENCY_FRAMES @local = 300;
const usz RECORDING_BYTES @local = 4 * 1024 * 1024; // starting capacity for the recorded impact

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

fn void? run_benchmark() @private {
    for (uint run = 0; run < BENCHMARK_REPEATS; run++) {
        measure_idle(true, run)!;
        measure_idle(false, run)!;
    }
    measure_latency(true)!;
    measure_latency(false)!;
    io::printfn("component_bytes,%d,event_bytes,%d", Breakable::size, BreakEvent::size);
}
