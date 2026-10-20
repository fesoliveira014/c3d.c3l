module particle_gpu_acceptance;

import c3d;
import c3d::particle;
import c3d::particle::gpu;
import c3d::render;
import c3d::scene;
import std::math;

const float SUB_LIFETIME_LONG @private = 10;
const uint SMALL_CAPACITY @private = 64;
const uint QUEUE_EVENTS @private = 64; // above the deaths one step raises in any case here
const uint CHILD_COUNT @private = 2;
const uint SUB_FRAMES @private = 12;
const uint DEATH_BURST @private = 32;
const float DEATH_LIFETIME @private = 0.1f;
const uint DEATH_COUNT @private = 3;
const uint SMALL_QUEUE @private = 8;
const float LONGEST_STEP @private = 0.1f; // the longest step, so a newborn shorter-lived than it dies in its first
const float SHORT_LIFETIME @private = 0.05f;
const uint SKIPPED_BURST @private = 8;
const uint VELOCITY_BURST @private = 16;
const float VELOCITY_SPEED @private = 2;
const float FAR_CHILD_X @private = 40;
const uint REBASE_FIRST @private = 4; // the deaths fall around step 6, so a shift meets delivered children
const uint REBASE_COUNT @private = 5;
const Vec3 REBASE_OFFSET @private = { 0.7f, 0, -0.3f };
const uint BIRTH_BURST @private = 16;
const float DROP_HEIGHT @private = 0.5f;
const float IMPACT_SIZE @private = 0.02f;
const uint IMPACT_FRAMES @private = 30; // the fall takes about 19 steps
const uint IMPACT_BURST @private = 8;

alias FrameCheck = fn void(Fixture* fixture, void* context);

struct Rebase @private {
    uint first;
    uint count;
    Vec3 offset;
}

struct InheritedChildren @private {
    ParticleSystem* cpu;
    ParticleSystem* device;
}

fn ParticleSystemDesc sub_desc(Fixture* fixture, uint capacity, float lifetime) @private {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = capacity;
    desc.seed = 3;
    desc.material = fixture.material;
    desc.lifetime = { .min = lifetime, .max = lifetime };
    desc.size = { .min = 0.1f, .max = 0.1f };
    desc.execution = ParticleExecution.GPU;
    return desc;
}

fn void listen(
    ParticleSystemDesc* desc,
    SubEmitter sub_emitter,
    uint max_events,
    uint index = 0,
) @private {
    desc.max_events = max_events;
    desc.sub_emitters[index] = sub_emitter;
    desc.sub_emitter_count = index + 1;
}

fn Node* add_system(Fixture* fixture, ParticleSystemDesc desc) @private {
    return fixture.scene.add_particle_system(desc)!!;
}

fn ParticleSystem* system_of(Fixture* fixture, Node* node) @private {
    return fixture.scene.get(node, ParticleSystem);
}

fn void? record_sub_frame(
    Fixture* fixture,
    float dt,
    ParticleSystem* copied,
    FrameCheck check,
    void* context,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::update(
        particles: &fixture.particles,
        renderer: renderer,
        scene: &fixture.scene,
        dt: dt,
    )!;
    if (copied) copy_records(fixture, copied)!;
    if (check) check(fixture, context);
    renderer.end_frame()!;
}

fn void run_sub_frames(
    Fixture* fixture,
    uint steps,
    float dt,
    ParticleSystem* copied = null,
    FrameCheck check = null,
    void* context = null,
    Rebase rebase = {},
) @private {
    uint frames = steps + render::FRAMES_IN_FLIGHT;
    for (uint frame = 0; frame < frames; frame++) {
        float seconds = frame < steps ? dt : 0;
        if (frame >= rebase.first && frame < rebase.first + rebase.count) {
            fixture.scene.shift_origin(rebase.offset);
            fixture.scene.shift_particles(rebase.offset);
            fixture.scene.update_world();
        }
        particle::update(&fixture.scene, seconds);
        record_sub_frame(
            fixture: fixture,
            dt: seconds,
            copied: copied,
            check: frame + 1 == frames ? check : null,
            context: context,
        )!!;
    }
}

fn void test_gpu_death_sub_emitter_spawns_count_children_per_death() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* child_node = add_system(&fixture, sub_desc(&fixture, CAPACITY, SUB_LIFETIME_LONG));
    ParticleSystemDesc parent_desc = sub_desc(&fixture, SMALL_CAPACITY, DEATH_LIFETIME);
    listen(
        desc: &parent_desc,
        sub_emitter: { .trigger = DEATH, .target = child_node.id, .count = DEATH_COUNT },
        max_events: QUEUE_EVENTS,
    );
    ParticleSystem* parent = system_of(&fixture, add_system(&fixture, parent_desc));
    ParticleSystem* child = system_of(&fixture, child_node);
    parent.emit_burst(DEATH_BURST);
    fixture.scene.update_world();
    run_sub_frames(&fixture, SUB_FRAMES, STEP_SECONDS);

    assert(child.alive == DEATH_BURST * DEATH_COUNT);
    assert(parent.alive == 0 && parent.dropped_events == 0);
}

fn void test_gpu_full_event_buffer_counts_dropped_events() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* child_node = add_system(&fixture, sub_desc(&fixture, CAPACITY, SUB_LIFETIME_LONG));
    ParticleSystemDesc parent_desc = sub_desc(&fixture, SMALL_CAPACITY, SHORT_LIFETIME);
    listen(
        desc: &parent_desc,
        sub_emitter: { .trigger = DEATH, .target = child_node.id, .count = CHILD_COUNT },
        max_events: SMALL_QUEUE,
    );
    ParticleSystem* parent = system_of(&fixture, add_system(&fixture, parent_desc));
    ParticleSystem* child = system_of(&fixture, child_node);
    parent.emit_burst(DEATH_BURST);
    fixture.scene.update_world();
    run_sub_frames(&fixture, 3, LONGEST_STEP);

    assert(parent.dropped_events == DEATH_BURST - SMALL_QUEUE);
    assert(child.alive == CHILD_COUNT * SMALL_QUEUE);
}

fn void test_gpu_delivery_across_executions_is_skipped_and_counted() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    ParticleSystemDesc cpu_child_desc = sub_desc(&fixture, SMALL_CAPACITY, SUB_LIFETIME_LONG);
    cpu_child_desc.execution = ParticleExecution.CPU;
    Node* cpu_child_node = add_system(&fixture, cpu_child_desc);
    Node* device_child_node = add_system(&fixture, sub_desc(&fixture, SMALL_CAPACITY, SUB_LIFETIME_LONG));
    SubEmitter[2] sub_emitters = {
        { .trigger = DEATH, .target = cpu_child_node.id, .count = 1 },
        { .trigger = DEATH, .target = device_child_node.id, .count = 1 },
    };
    ParticleExecution[2] executions = { ParticleExecution.GPU, ParticleExecution.CPU };
    ParticleSystem*[2] parents;
    foreach (index, execution : executions) {
        ParticleSystemDesc desc = sub_desc(&fixture, SMALL_CAPACITY, DEATH_LIFETIME);
        desc.execution = execution;
        listen(
            desc: &desc,
            sub_emitter: sub_emitters[index],
            max_events: QUEUE_EVENTS,
        );
        parents[index] = system_of(&fixture, add_system(&fixture, desc));
        parents[index].emit_burst(SKIPPED_BURST);
    }
    fixture.scene.update_world();
    run_sub_frames(&fixture, SUB_FRAMES, STEP_SECONDS);

    assert(parents[0].skipped_events == SKIPPED_BURST);
    assert(parents[1].skipped_events == SKIPPED_BURST);
    assert(system_of(&fixture, cpu_child_node).alive == 0);
    assert(system_of(&fixture, device_child_node).alive == 0);
}

fn bool bound_holds(Aabb bound, Vec3 point) @private {
    return point.x >= bound.min.x && point.y >= bound.min.y && point.z >= bound.min.z
        && point.x <= bound.max.x && point.y <= bound.max.y && point.z <= bound.max.z;
}

fn void sort_by_x(Vec3[] points) @private {
    for (usz filled = 1; filled < points.len; filled++) {
        Vec3 moving = points[filled];
        usz position = filled;
        while (position > 0 && points[position - 1].x > moving.x) {
            points[position] = points[position - 1];
            position--;
        }
        points[position] = moving;
    }
}

fn void check_inherited_children(Fixture* fixture, void* context) @private {
    InheritedChildren* children = context;
    char[] copied = fixture.renderer.read_buffer(fixture.copied)!!;
    BillboardRecord* records = (BillboardRecord*)copied.ptr;
    uint count = *(uint*)(copied.ptr + CAPACITY * BillboardRecord::size);
    assert(count == VELOCITY_BURST && children.cpu.alive == VELOCITY_BURST);

    Vec3[VELOCITY_BURST] expected;
    Vec3[VELOCITY_BURST] found;
    BillboardBatch* batch = fixture.scene.get(fixture.scene.node(children.device.draw_node), BillboardBatch);
    for (uint index = 0; index < VELOCITY_BURST; index++) {
        expected[index] = children.cpu.position[index] - fixture.renderer.frame_origin;
        Vec4 placed = records[index].position_width;
        found[index] = { placed.x, placed.y, placed.z };
        assert(bound_holds(batch.local_bounds, found[index] + fixture.renderer.frame_origin));
    }
    sort_by_x(expected[..]);
    sort_by_x(found[..]);
    for (uint index = 0; index < VELOCITY_BURST; index++) {
        assert((found[index] - expected[index]).length() <= POSITION_TOLERANCE);
    }
}

fn void test_gpu_children_follow_the_cpu_reference() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    ParticleSystem*[2] child_systems;
    ParticleExecution[2] executions = { ParticleExecution.CPU, ParticleExecution.GPU };
    foreach (index, execution : executions) {
        ParticleSystemDesc child_desc = sub_desc(&fixture, SMALL_CAPACITY, SUB_LIFETIME_LONG);
        child_desc.execution = execution;
        child_desc.speed = { .min = 0, .max = 0 };
        Node* child_node = add_system(&fixture, child_desc);
        child_node.local.position = { FAR_CHILD_X, 0, 0 };
        ParticleSystemDesc parent_desc = sub_desc(&fixture, SMALL_CAPACITY, DEATH_LIFETIME);
        parent_desc.execution = execution;
        parent_desc.speed = { .min = VELOCITY_SPEED, .max = VELOCITY_SPEED };
        listen(
            desc: &parent_desc,
            sub_emitter: { .trigger = DEATH, .target = child_node.id, .count = 1, .inherit_velocity = 1 },
            max_events: QUEUE_EVENTS,
        );
        system_of(&fixture, add_system(&fixture, parent_desc)).emit_burst(VELOCITY_BURST);
        child_systems[index] = system_of(&fixture, child_node);
    }
    InheritedChildren children = { .cpu = child_systems[0], .device = child_systems[1] };
    fixture.scene.update_world();
    run_sub_frames(
        fixture: &fixture,
        steps: SUB_FRAMES,
        dt: STEP_SECONDS,
        copied: children.device,
        check: &check_inherited_children,
        context: &children,
        rebase: { .first = REBASE_FIRST, .count = REBASE_COUNT, .offset = REBASE_OFFSET },
    );
}

fn void test_gpu_births_fire_for_emitted_and_delivered_particles() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* last_node = add_system(&fixture, sub_desc(&fixture, SMALL_CAPACITY, SUB_LIFETIME_LONG));
    ParticleSystemDesc middle_desc = sub_desc(&fixture, SMALL_CAPACITY, SUB_LIFETIME_LONG);
    listen(
        desc: &middle_desc,
        sub_emitter: { .trigger = BIRTH, .target = last_node.id, .count = 1 },
        max_events: QUEUE_EVENTS,
    );
    Node* middle_node = add_system(&fixture, middle_desc);
    ParticleSystemDesc first_desc = sub_desc(&fixture, SMALL_CAPACITY, SUB_LIFETIME_LONG);
    listen(
        desc: &first_desc,
        sub_emitter: { .trigger = BIRTH, .target = middle_node.id, .count = CHILD_COUNT },
        max_events: QUEUE_EVENTS,
    );
    ParticleSystem* first = system_of(&fixture, add_system(&fixture, first_desc));
    first.emit_burst(BIRTH_BURST);
    fixture.scene.update_world();
    run_sub_frames(&fixture, SUB_FRAMES, STEP_SECONDS);

    assert(system_of(&fixture, middle_node).alive == BIRTH_BURST * CHILD_COUNT);
    assert(system_of(&fixture, last_node).alive == BIRTH_BURST * CHILD_COUNT);
}

fn void test_gpu_ground_hits_raise_impact_and_death_events() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* impact_child = add_system(&fixture, sub_desc(&fixture, SMALL_CAPACITY, SUB_LIFETIME_LONG));
    Node* death_child = add_system(&fixture, sub_desc(&fixture, SMALL_CAPACITY, SUB_LIFETIME_LONG));
    ParticleSystemDesc parent_desc = sub_desc(&fixture, SMALL_CAPACITY, SUB_LIFETIME_LONG);
    parent_desc.size = { .min = IMPACT_SIZE, .max = IMPACT_SIZE };
    parent_desc.gravity_scale = 1;
    parent_desc.collision.response = CollisionResponse.DIE;
    parent_desc.collision.ground_plane = true;
    listen(
        desc: &parent_desc,
        sub_emitter: { .trigger = IMPACT, .target = impact_child.id, .count = 1 },
        max_events: QUEUE_EVENTS,
    );
    listen(
        desc: &parent_desc,
        sub_emitter: { .trigger = DEATH, .target = death_child.id, .count = 1 },
        max_events: QUEUE_EVENTS,
        index: 1,
    );
    Node* parent_node = add_system(&fixture, parent_desc);
    parent_node.local.position = { 0, DROP_HEIGHT, 0 };
    ParticleSystem* parent = system_of(&fixture, parent_node);
    parent.emit_burst(IMPACT_BURST);
    fixture.scene.update_world();
    run_sub_frames(&fixture, IMPACT_FRAMES, STEP_SECONDS);

    assert(parent.alive == 0);
    assert(system_of(&fixture, impact_child).alive == IMPACT_BURST);
    assert(system_of(&fixture, death_child).alive == IMPACT_BURST);
}
