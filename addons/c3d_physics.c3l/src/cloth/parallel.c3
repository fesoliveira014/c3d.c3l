module c3d::physics::cloth;

import c3d;
import c3d::anim;
import c3d::physics @public;
import c3d::scene;
import std::time;
import std::time::clock;

const uint CLOTH_STAGE_BATCH @private = 1; // items per range; one item is a whole cloth update, dearer than a range's fork

enum ClothWorkSource @private {
    ORDINARY,
    CROWD_SLOT,
}

struct ClothWork @private {
    ClothWorkSource source;
    Node*           node;               // the cloth's node, or the crowd owner
    Node*           batch_node;
    AnimatedCrowd*  crowd;
    CrowdClothPart* part_record;
    Node*           output_node;
    scene::Mesh*    output_mesh;
    uint            slot;
    uint            live_generation;
    bool            reseeded;
    ClothUpdateKind kind;
    fault           failure;
    bool            changed;
    bool            colors_changed;
    bool            reset_history;
    bool            clear_generation;
    double          stage_seconds;
    double          publication_seconds;
}

struct ClothStageContext @local {
    PhysicsWorld* world;
    uint          steps;
}

fn void collect_cloth_work(PhysicsWorld* world) @private {
    world.cloth_work_count = 0;
    world.scene.@each(Cloth; Entity entity, Cloth* component) {
        if (!component.is_prepared()) {
            world.cloth_stats.pending++;
        } else {
            Node* node = world.scene.node(entity);
            if (component.authoring.held) {
                collect_held_cloth(world, component.state, node);
            } else {
                enqueue_cloth_work(world, component.state, { .source = ORDINARY, .node = node });
            }
        }
    };
    collect_crowd_cloths(world);
}

fn void enqueue_cloth_work(PhysicsWorld* world, ClothState* state, ClothWork work) @private {
    state.work = work;
    world.cloth_work[world.cloth_work_count++] = state;
}

fn void stage_cloth_work(PhysicsWorld* world, uint steps) @private {
    ClothStageContext context = { .world = world, .steps = steps };
    uint count = world.cloth_work_count;

    time::Clock started = clock::now();
    if (world.parallel.run) {
        world.parallel.run(world.parallel.context, &stage_cloth_range, &context, count, CLOTH_STAGE_BATCH);
    } else {
        stage_cloth_range(&context, 0, count);
    }
    world.cloth_stats.stage_seconds = (clock::now() - started).to_sec();
}

fn void stage_cloth_range(void* data, uint first, uint count) @local {
    ClothStageContext* context = data;
    foreach (state : context.world.cloth_work[first:count]) {
        stage_cloth_item(context.world, state, context.steps);
    }
}

fn void stage_cloth_item(PhysicsWorld* world, ClothState* state, uint steps) @local {
    ClothWork* work = &state.work;
    time::Clock started = clock::now();
    switch (work.source) {
        case ORDINARY:
            ClothUpdateKind? ordinary = stage_ordinary_cloth(world, state, steps);
            if (catch excuse = ordinary) {
                work.failure = excuse;
            } else {
                work.kind = ordinary;
            }
        case CROWD_SLOT:
            ClothUpdateKind? crowd_slot = stage_crowd_slot(world, state, steps);
            if (catch excuse = crowd_slot) {
                work.failure = excuse;
            } else {
                work.kind = crowd_slot;
            }
    }
    work.stage_seconds = (clock::now() - started).to_sec();
}

fn void commit_cloth_work(PhysicsWorld* world) @private {
    time::Clock started = clock::now();
    foreach (state : world.cloth_work[:world.cloth_work_count]) {
        commit_cloth_item(world, state);
    }
    world.cloth_stats.commit_seconds = (clock::now() - started).to_sec();
}

fn void commit_cloth_item(PhysicsWorld* world, ClothState* state) @local {
    ClothWork* work = &state.work;
    time::Clock started = clock::now();
    switch (work.source) {
        case ORDINARY:
            commit_ordinary_cloth(world, state);
        case CROWD_SLOT:
            commit_crowd_slot(world, state);
    }

    double commit_seconds = (clock::now() - started).to_sec();
    tally_cloth(
        stats:               &world.cloth_stats,
        state:               state,
        kind:                work.kind,
        total_seconds:       work.stage_seconds + commit_seconds,
        publication_seconds: work.publication_seconds + commit_seconds,
    );
}
