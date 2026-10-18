module c3d_physics_cloth_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::physics;
import c3d::physics::cloth @public;
import c3d::scene;

const float SLEEP_SPEED @private = 0.1f;
const uint SLEEP_STEPS @private = 5;
const uint ZERO_STEP_UPDATES @private = 3;
const uint HELD_UPDATES @private = 6;
const float COLLIDER_RADIUS @private = 0.1f;
const Vec3 DISTANT_BODY @private = { 10, 0, 0 };
const uint PUSH_CELLS @private = 4;
const float PUSH_SIZE @private = 4;
const uint PUSHED_VERTEX @private = 12; // centre of the 5x5 vertex grid
const float PUSH_RADIUS @private = 0.3f;
const uint HOLD_CAPACITY @private = 2;

struct CrowdRig @private {
    Node*     node;
    CrowdPose seed;
}

fn ClothDesc resting_desc(uint[] pins) @private {
    ClothDesc desc = pinned_desc(pins);
    desc.sleep_speed = SLEEP_SPEED;
    desc.sleep_steps = SLEEP_STEPS;
    return desc;
}

fn Node* add_resting_cloth(Fixture* fixture, Entity[] colliders = {}) @private {
    Node* node = add_cloth_node(fixture, add_grid(fixture, GRID_CELLS));
    ClothDesc desc = resting_desc(top_row(GRID_CELLS));
    desc.colliders = colliders;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    return node;
}

fn uint settle(Fixture* fixture, Node* node) @private {
    Cloth* cloth = fixture.scene.get(node, Cloth);
    uint updates;
    while (cloth.activity() != RESTING) {
        assert(updates < SETTLE_STEPS);
        step(fixture, physics::DEFAULT_FIXED_DT);
        updates++;
    }
    return updates;
}

fn uint revision_of(Fixture* fixture, Node* node) @private => geometry_of(fixture, node).header.revision;

fn void test_cloth_rests_after_settling_and_wakes_on_wind_change() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* node = add_cloth_node(&fixture, add_grid(&fixture, GRID_CELLS));
    fixture.scene.add(node, (Wind){ .velocity = { 0, 0, 4 } });
    fixture.scene.add_cloth(&fixture.assets, node, resting_desc(top_row(GRID_CELLS)))!!;
    Cloth* cloth = fixture.scene.get(node, Cloth);

    for (uint update = 0; update < SLEEP_STEPS - 1; update++) step(&fixture, physics::DEFAULT_FIXED_DT);
    for (uint update = 0; update < ZERO_STEP_UPDATES; update++) step(&fixture, 0);
    assert(cloth.activity() == AWAKE);

    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(cloth.activity() == RESTING);
    foreach (velocity : cloth.state.velocities) assert(velocity == (Vec3){});

    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(fixture.physics.cloth_stats.resting == 1);

    fixture.scene.get(node, Wind).velocity = { 0, 0, 5 };
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(cloth.activity() == AWAKE);

    settle(&fixture, node);
    fixture.scene.remove_component(node, Wind);
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(cloth.activity() == AWAKE);
}

fn void test_resting_cloth_wakes_on_reference_and_collider_motion() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ColliderDesc ball = sphere(COLLIDER_RADIUS);
    Node* body = add_body_node(&fixture, (&ball)[:1], DISTANT_BODY);
    Entity[1] colliders = { body.id };
    Node* node = add_resting_cloth(&fixture, colliders[..]);
    Cloth* cloth = fixture.scene.get(node, Cloth);
    settle(&fixture, node);

    node.local.position = { 0.5f, 0, 0 };
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(cloth.activity() == AWAKE);

    settle(&fixture, node);
    body.local.position = DISTANT_BODY * 2;
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(cloth.activity() == RESTING);

    body.local.position = node.world_position() + (Vec3){ 0.5f, -0.5f, 0 };
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(cloth.activity() == AWAKE);
}

fn void test_held_cloth_ignores_triggers_and_carries_on_wake() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* node = add_cloth_node(&fixture, add_grid(&fixture, GRID_CELLS));
    fixture.scene.add(node, (Wind){ .velocity = { 0, 0, 4 } });
    fixture.scene.add_cloth(&fixture.assets, node, resting_desc(top_row(GRID_CELLS)))!!;
    Cloth* cloth = fixture.scene.get(node, Cloth);
    ClothState* state = cloth.state;
    settle(&fixture, node);

    cloth.sleep();
    assert(cloth.activity() == HELD);
    Vec3[(GRID_CELLS + 1) * (GRID_CELLS + 1)] held_positions;
    held_positions[..] = state.positions[..];
    uint revision = revision_of(&fixture, node);

    Vec3 displacement = { 1, 0.5f, -0.25f };
    node.local.position = displacement;
    fixture.scene.get(node, Wind).velocity = { 0, 0, 9 };
    for (uint update = 0; update < HELD_UPDATES; update++) step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(cloth.activity() == HELD);
    assert(fixture.physics.cloth_stats.held == 1);
    assert(revision_of(&fixture, node) == revision);
    foreach (index, position : state.positions) assert(position == held_positions[index]);

    cloth.wake();
    step(&fixture, 0);
    foreach (index, position : state.positions) assert(near(position, held_positions[index] + displacement));

    step(&fixture, physics::DEFAULT_FIXED_DT);
    foreach (velocity : state.velocities) assert(velocity.length() < SLEEP_SPEED);
}

fn void test_cloth_marks_changed_ranges_and_nothing_at_rest() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ColliderDesc ball = sphere(PUSH_RADIUS);
    Node* body = add_body_node(&fixture, (&ball)[:1], { 1.8f, -2, 0 });
    Entity[1] colliders = { body.id };
    Node* pushed = add_cloth_node(&fixture, add_grid(&fixture, PUSH_CELLS, PUSH_SIZE));
    uint[2] pins = { 0, PUSH_CELLS };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.stretch_stiffness = 0;
    desc.bend_stiffness = 0;
    desc.colliders = colliders[..];
    fixture.scene.add_cloth(&fixture.assets, pushed, desc)!!;
    Node* resting = add_resting_cloth(&fixture);
    settle(&fixture, resting);

    GeometryId pushed_geometry = fixture.scene.get(pushed, scene::Mesh).geometry;
    fixture.assets.clear_geometry_dirty(pushed_geometry);
    uint resting_revision = revision_of(&fixture, resting);
    step(&fixture, physics::DEFAULT_FIXED_DT);

    VertexRange[GeometryStream::len] ranges = fixture.assets.geometry(pushed_geometry).dirty.ranges;
    VertexRange positions = ranges[GeometryStream.POSITIONS.ordinal];
    assert(positions.first == PUSHED_VERTEX && positions.end == PUSHED_VERTEX + 1);
    foreach (stream : GeometryStream::values) {
        if (stream != GeometryStream.POSITIONS) assert(ranges[stream.ordinal].is_empty());
    }
    assert(revision_of(&fixture, resting) == resting_revision);
}

fn void test_failed_update_keeps_activity() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* node = add_resting_cloth(&fixture);
    Cloth* cloth = fixture.scene.get(node, Cloth);
    ClothState* state = cloth.state;
    settle(&fixture, node);
    Vec3[(GRID_CELLS + 1) * (GRID_CELLS + 1)] resting_positions;
    resting_positions[..] = state.positions[..];

    cloth.wake();
    node.local.scale = {};
    step(&fixture, 0);
    assert(fixture.physics.cloth_stats.failed == 1);
    assert(state.contact_result.failure == cloth::CONTACT_PRECISION_EXCEEDED);
    assert(cloth.activity() == RESTING);
    foreach (index, position : state.positions) assert(position == resting_positions[index]);

    node.local.scale = { 1, 1, 1 };
    step(&fixture, 0);
    assert(fixture.physics.cloth_stats.failed == 0);
    assert(cloth.activity() == AWAKE);
}

fn void test_cloth_rejects_invalid_sleep_speed() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* node = add_cloth_node(&fixture, add_grid(&fixture, 1));
    ClothDesc desc = cloth::default_cloth_desc();
    desc.sleep_speed = -1;
    assert(rejected_atomically(&fixture, node, desc) == c3d::INVALID_ARGUMENT);
}

fn CrowdRig add_cloth_crowd(Fixture* fixture) @private {
    AnimationClip clip = {
        .name     = "idle".copy(mem),
        .duration = 1,
        .tracks   = alloc::new_array(mem, Track, 1),
        .targets  = alloc::new_array(mem, uint, 1),
    };
    clip.targets[0] = 0;
    clip.tracks[0] = {
        .target        = 0,
        .path          = TargetPath.TRANSLATION,
        .interpolation = Interpolation.STEP,
        .times         = alloc::new_array(mem, float, 1),
        .values        = alloc::new_array(mem, float, 3),
    };
    ClipId clip_id = fixture.assets.add_clip_owned(&clip, "idle")!!;

    NodeTemplate[] nodes = alloc::new_array(mem, NodeTemplate, 1);
    nodes[0] = { .parent = -1, .name = "cape".copy(mem), .local = maths::TRANSFORM_IDENTITY, .visible = true };
    ModelMesh[] meshes = alloc::new_array(mem, ModelMesh, 1);
    meshes[0] = { .node = 0, .geometry = add_grid(fixture, 1), .material = fixture.material };
    ClipId[] clips = alloc::new_array(mem, ClipId, 1);
    clips[0] = clip_id;
    ModelTemplate model_template = { .nodes = nodes, .meshes = meshes, .clips = clips };
    ModelId model = fixture.assets.add_model_owned(&model_template, "held_cape")!!;

    CrowdPose seed = { .clip = clip_id, .speed = 1, .loop = true };
    CrowdInstance[HOLD_CAPACITY] instances = {
        { .placement = maths::TRANSFORM_IDENTITY, .pose = seed, .color = { 1, 0, 0, 1 } },
        { .placement = maths::TRANSFORM_IDENTITY, .pose = seed, .color = { 0, 1, 0, 1 } },
    };
    instances[1].placement.position = { 4, 0, 0 };
    Node* crowd_node = model::add_crowd(
        assets:      &fixture.assets,
        scene:       &fixture.scene,
        model:       model,
        capacity:    HOLD_CAPACITY,
        pose_bounds: { .min = { -2, -2, -2 }, .max = { 6, 2, 2 } },
        instances:   instances[..],
        name:        "crowd",
    )!!;
    fixture.scene.add(crowd_node, (Wind){ .velocity = { 0, 0, 5 }, .drag = 1 });
    fixture.scene.update_world();

    uint[2] pins = { 0, 1 };
    fixture.scene.attach_crowd_cloth(
        assets: &fixture.assets,
        owner:  crowd_node,
        part:   0,
        desc:   pinned_desc(pins[..]),
    )!!;
    fixture.physics.update(0);
    cloth::prepare_crowd_cloth(
        world:  &fixture.physics,
        assets: &fixture.assets,
        owner:  crowd_node,
    )!!;
    return { .node = crowd_node, .seed = seed };
}

fn uint slot_revision(Fixture* fixture, CrowdCloth* crowd_cloth, uint slot) @private {
    Node* output = fixture.scene.node(crowd_cloth.find_part(0)!!.outputs[slot]);
    return fixture.assets.geometry(fixture.scene.get(output, scene::Mesh).geometry).header.revision;
}

fn void test_crowd_slot_hold_leaves_other_slots_simulating() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    CrowdRig rig = add_cloth_crowd(&fixture);
    CrowdCloth* crowd_cloth = fixture.scene.get(rig.node, CrowdCloth);
    step(&fixture, physics::DEFAULT_FIXED_DT);

    crowd_cloth.sleep_slot(0);
    uint held_revision = slot_revision(&fixture, crowd_cloth, 0);
    uint running_revision = slot_revision(&fixture, crowd_cloth, 1);
    for (uint update = 0; update < HELD_UPDATES; update++) step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(crowd_cloth.slot_activity(0) == HELD && crowd_cloth.slot_activity(1) == AWAKE);
    assert(fixture.physics.cloth_stats.held == 1);
    assert(slot_revision(&fixture, crowd_cloth, 0) == held_revision);
    assert(slot_revision(&fixture, crowd_cloth, 1) > running_revision);

    crowd_cloth.wake_slot(0);
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(crowd_cloth.slot_activity(0) == AWAKE);
    assert(slot_revision(&fixture, crowd_cloth, 0) > held_revision);
}

fn void test_reused_crowd_slot_starts_awake() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    CrowdRig rig = add_cloth_crowd(&fixture);
    CrowdCloth* crowd_cloth = fixture.scene.get(rig.node, CrowdCloth);
    step(&fixture, physics::DEFAULT_FIXED_DT);
    crowd_cloth.sleep_slot(0);
    assert(crowd_cloth.slot_activity(0) == HELD);

    CrowdInstance[1] replacement = {
        { .placement = maths::TRANSFORM_IDENTITY, .pose = rig.seed, .color = { 0, 0, 1, 1 } },
    };
    model::set_crowd(
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        node:      rig.node,
        instances: replacement[..],
    )!!;
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(crowd_cloth.slot_activity(0) == AWAKE);
}
