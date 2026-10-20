module particle_gpu_acceptance;

import c3d;
import c3d::particle;
import c3d::render;
import c3d::scene;

const float EVICTION_LIFETIME @private = 10; // nothing expires, so the pool leaves only by eviction
const uint EVICTION_STEPS @private = 20;
const Burst[2] EVICTION_BURSTS @private = { { 0, 200 }, { 10, 100 } };
const uint EVICTION_EVICTED @private = 44; // the second burst's 100 against the 56 slots the first left free
const Burst[2] OVERSIZED_BURSTS @private = { { 0, 100 }, { 5, 400 } };
const uint OVERSIZED_EVICTED @private = 100; // every survivor
const uint OVERSIZED_REFUSED @private = 144; // the 400 against the 256 slots
const uint EVICT_POOL @private = 4;
const uint EVICT_FILL_FRAMES @private = 2;
const uint EVICT_BURST @private = 3;
const uint EVICT_SETTLE_FRAMES @private = render::FRAMES_IN_FLIGHT + 2; // the delivery lands a step late

fn Pair? add_eviction_pair(Fixture* fixture, bool trailed) @private {
    ParticleSystemDesc desc = reference_desc(fixture.material);
    if (trailed) add_trail(&desc, fixture.material);
    desc.saturation = ParticleSaturation.DROP_OLDEST;
    desc.lifetime = { .min = EVICTION_LIFETIME, .max = EVICTION_LIFETIME };
    fixture.trailed = trailed;
    return add_pair_of(fixture, desc);
}

fn void run_eviction_steps(
    Fixture* fixture,
    Pair* pair,
    Burst[] bursts,
    uint alive,
    ulong dropped,
    ulong evicted,
) @private {
    uint steps = EVICTION_STEPS + render::FRAMES_IN_FLIGHT;
    for (uint step = 0; step < steps; step++) {
        float dt = step < EVICTION_STEPS ? STEP_SECONDS : 0;
        queue_bursts(pair, step, bursts);
        particle::update(&fixture.scene, dt, WIND);
        record_frame(
            fixture: fixture,
            pair: pair,
            dt: dt,
            kind: step + 1 == steps ? FrameKind.FINAL : FrameKind.NORMAL,
            expected_alive: alive,
            expected_dropped: dropped,
            expected_evicted: evicted,
        )!!;
    }
}

fn void test_gpu_drop_oldest_follows_the_cpu_reference() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Pair pair = add_eviction_pair(&fixture, false)!!;
    run_eviction_steps(
        fixture: &fixture,
        pair: &pair,
        bursts: EVICTION_BURSTS[..],
        alive: CAPACITY,
        dropped: 0,
        evicted: EVICTION_EVICTED,
    );
}

fn void test_gpu_oversized_request_evicts_every_survivor_and_refuses_the_excess() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Pair pair = add_eviction_pair(&fixture, false)!!;
    run_eviction_steps(
        fixture: &fixture,
        pair: &pair,
        bursts: OVERSIZED_BURSTS[..],
        alive: CAPACITY,
        dropped: OVERSIZED_REFUSED,
        evicted: OVERSIZED_EVICTED,
    );
}

fn void test_gpu_eviction_moves_trails_with_their_particles() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Pair pair = add_eviction_pair(&fixture, true)!!;
    run_eviction_steps(
        fixture: &fixture,
        pair: &pair,
        bursts: EVICTION_BURSTS[..],
        alive: CAPACITY,
        dropped: 0,
        evicted: EVICTION_EVICTED,
    );
}

fn void test_gpu_evicted_particles_fire_death_only_with_on_evict() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    bool[2] on_evict = { true, false };
    ParticleSystem*[2] parents;
    ParticleSystem*[2] children;
    foreach (index, evicts : on_evict) {
        Node* child_node = add_system(&fixture, sub_desc(&fixture, SMALL_CAPACITY, SUB_LIFETIME_LONG));
        ParticleSystemDesc parent_desc = sub_desc(&fixture, EVICT_POOL, SUB_LIFETIME_LONG);
        parent_desc.saturation = ParticleSaturation.DROP_OLDEST;
        listen(
            desc: &parent_desc,
            sub_emitter: { .trigger = DEATH, .target = child_node.id, .count = 1, .on_evict = evicts },
            max_events: QUEUE_EVENTS,
        );
        parents[index] = system_of(&fixture, add_system(&fixture, parent_desc));
        children[index] = system_of(&fixture, child_node);
        parents[index].emit_burst(EVICT_POOL);
    }
    fixture.scene.update_world();
    for (uint frame = 0; frame < EVICT_FILL_FRAMES + 1 + EVICT_SETTLE_FRAMES; frame++) {
        if (frame == EVICT_FILL_FRAMES) {
            foreach (parent : parents) parent.emit_burst(EVICT_BURST);
        }
        particle::update(&fixture.scene, STEP_SECONDS);
        record_sub_frame(
            fixture: &fixture,
            dt: STEP_SECONDS,
            copied: null,
            check: null,
            context: null,
        )!!;
    }

    assert(parents[0].evicted == EVICT_BURST && parents[1].evicted == EVICT_BURST);
    assert(children[0].alive == EVICT_BURST && children[1].alive == 0);
    assert(parents[0].dropped_events == 0 && parents[1].dropped_events == 0);
}
