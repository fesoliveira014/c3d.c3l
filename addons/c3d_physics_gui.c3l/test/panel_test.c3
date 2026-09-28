module c3d_physics_gui_panel_test @feat(C3D_PHYSICS_GUI);

import std::math;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::gui @public;
import c3d::maths;
import c3d::physics;
import c3d::scene;

const float FRAME_DT @private = 0.016f;
const uint  RING_CAPACITY @private = 4;
const float HIT_THRESHOLD @private = 0.5f;
const uint  FALL_UPDATES @private = 120;

struct Fixture @private {
    AssetStore    assets;
    Scene         scene;
    PhysicsWorld  physics;
    GuiPanelState selection;
    PhysicsPanel  panel;
}

fn void setup(Fixture* fixture, uint event_capacity = gui::PHYSICS_EVENT_CAPACITY) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    physics::register_physics(&fixture.scene)!!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      physics::default_physics_desc(),
    )!!;
    fixture.panel = gui::create_physics_panel(
        allocator:      mem,
        physics:        &fixture.physics,
        scene:          &fixture.scene,
        selection:      &fixture.selection,
        event_capacity: event_capacity,
    );
}

fn void teardown(Fixture* fixture) @private {
    gui::destroy_physics_panel(&fixture.panel);
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node* add_box(
    Fixture* fixture,
    Vec3 position,
    BodyKind kind = DYNAMIC,
    Vec3 half_extents = { 0.5f, 0.5f, 0.5f },
) @private {
    Node* node = fixture.scene.add_node(name: "box")!!;
    node.local.position = position;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = half_extents;
    collider.hit_events = true;
    fixture.physics.add_body(node, physics::default_body_desc(kind), (&collider)[:1])!!;
    return node;
}

fn Node* add_skin_with_ragdoll(Fixture* fixture) @private {
    Vec3[2] positions = { { 0, 0, 0 }, { 0, 1, 0 } };
    int[2] parents = { -1, 0 };
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(mem, String, 2),
        .parents      = alloc::new_array(mem, int, 2),
        .rest_pose    = alloc::new_array(mem, maths::Transform, 2),
        .inverse_bind = alloc::new_array(mem, Mat4, 2),
    };
    skeleton.parents[..] = parents[..];
    foreach (index, position : positions) {
        maths::Transform unbind = maths::TRANSFORM_IDENTITY;
        unbind.position = -position;
        skeleton.inverse_bind[index] = unbind.to_mat4();
        skeleton.rest_pose[index] = maths::TRANSFORM_IDENTITY;
    }
    SkeletonId skeleton_id = fixture.assets.add_skeleton_owned(&skeleton)!!;

    Node* character = fixture.scene.add_node(name: "character")!!;
    Node* skin = fixture.scene.add_node(character, "skin")!!;
    Node*[] joints = alloc::new_array(fixture.scene.allocator, Node*, 2);
    joints[0] = fixture.scene.add_node(character, "hips")!!;
    joints[1] = fixture.scene.add_node(joints[0], "spine")!!;
    joints[1].local.position = positions[1];
    fixture.scene.add(skin, (SkinBinding){ .skeleton = skeleton_id, .joints = joints });
    fixture.scene.update_world();

    RagdollBone[1] bones = { physics::default_ragdoll_bone(0) };
    bones[0].radius = 0.1f;
    bones[0].length = 1;
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones[..];
    fixture.scene.build_ragdoll(&fixture.assets, skin, desc)!!;
    fixture.scene.update_world();
    return skin;
}

fn void test_panel_defaults() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    PhysicsDebugOptions draw = fixture.panel.draw;
    assert(draw.colliders && !draw.contacts && !draw.bounds && !draw.joints && !draw.joint_extras);
    assert(!draw.mass && !draw.anchor_a && !draw.contact_forces && !draw.graph_colors && !draw.islands);
    assert(!fixture.panel.paused && fixture.panel.event_count == 0);
    assert(!fixture.panel.has_replay && fixture.panel.recording.len == 0);
}

fn void test_step_dt_pauses_and_single_steps() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    PhysicsPanel* panel = &fixture.panel;

    assert(panel.step_dt(FRAME_DT) == FRAME_DT);
    panel.paused = true;
    assert(panel.step_dt(FRAME_DT) == 0);
    panel.single_step = true;
    assert(panel.step_dt(FRAME_DT) == fixture.physics.desc.tuning.fixed_dt);
    assert(!panel.single_step && panel.step_dt(FRAME_DT) == 0);
}

fn void test_single_step_runs_one_fixed_step() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_box(&fixture, { 0, 5, 0 });
    PhysicsPanel* panel = &fixture.panel;

    panel.paused = true;
    panel.single_step = true;
    fixture.physics.update(panel.step_dt(FRAME_DT));
    assert(fixture.physics.steps_last_update == 1);
    fixture.physics.update(panel.step_dt(FRAME_DT));
    assert(fixture.physics.steps_last_update == 0);
}

fn void test_pause_holds_body_poses() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* box = add_box(&fixture, { 0, 5, 0 });
    PhysicsPanel* panel = &fixture.panel;
    fixture.physics.update(panel.step_dt(FRAME_DT));
    fixture.physics.update(panel.step_dt(FRAME_DT));
    Mat4 held = box.world;

    panel.paused = true;
    fixture.physics.update(panel.step_dt(FRAME_DT));
    fixture.physics.update(panel.step_dt(FRAME_DT));
    assert(box.world == held);
}

fn void test_event_log_keeps_the_newest_rows() @test {
    Fixture fixture;
    setup(&fixture, RING_CAPACITY);
    defer teardown(&fixture);
    PhysicsPanel* panel = &fixture.panel;

    for (uint value = 1; value <= 6; value++) gui::append_physics_event(panel, { .kind = HIT, .value = (float)value });
    assert(panel.event_count == RING_CAPACITY);
    float[RING_CAPACITY] newest_first = { 6, 5, 4, 3 };
    foreach (uint index, value : newest_first) assert(gui::physics_event_at(panel, index).value == value);
}

fn void test_record_events_logs_a_real_hit() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    PhysicsTuning tuning = fixture.physics.desc.tuning;
    tuning.hit_speed_threshold = HIT_THRESHOLD;
    fixture.physics.set_tuning(tuning);
    Node* ground = add_box(&fixture, { 0, -0.5f, 0 }, STATIC, { 10, 0.5f, 10 });
    Node* box = add_box(&fixture, { 0, 2, 0 });

    for (uint update = 0; update < FALL_UPDATES && fixture.physics.hits().len == 0; update++) {
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
        fixture.panel.record_events(0);
    }
    HitEvent[] hits = fixture.physics.hits();
    assert(hits.len > 0);
    PhysicsEventRow* row = gui::physics_event_at(&fixture.panel, 0);
    assert(row.kind == HIT && row.value == hits[hits.len - 1].approach_speed);
    bool box_and_ground = c3d::same_id(row.a, box.id) && c3d::same_id(row.b, ground.id);
    bool ground_and_box = c3d::same_id(row.a, ground.id) && c3d::same_id(row.b, box.id);
    assert(box_and_ground || ground_and_box);
}

fn void test_event_rows_store_entities() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* first = add_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* second = add_box(&fixture, { 3, 0, 0 }, STATIC);
    gui::append_physics_event(&fixture.panel, { .kind = CONTACT_BEGIN, .a = first.id, .b = second.id });

    fixture.scene.remove(first);
    PhysicsEventRow* row = gui::physics_event_at(&fixture.panel, 0);
    assert(!fixture.scene.world.is_alive(row.a));
    assert(fixture.scene.world.is_alive(row.b));
}

fn void test_selection_blocks_follow_the_components() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* body = add_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* hinged = add_box(&fixture, { 0, 3, 0 });
    fixture.physics.add_joint(hinged, physics::default_joint_desc(REVOLUTE, body.id))!!;
    Node* skin = add_skin_with_ragdoll(&fixture);
    Node* plain = fixture.scene.add_node(name: "plain")!!;
    Scene* scene = &fixture.scene;

    PhysicsSelectionBlocks expected_body = { .body = true };
    PhysicsSelectionBlocks expected_joint = { .body = true, .joint = true };
    PhysicsSelectionBlocks expected_ragdoll = { .ragdoll = true };
    assert(gui::physics_selection_blocks(scene, body.id) == expected_body);
    assert(gui::physics_selection_blocks(scene, hinged.id) == expected_joint);
    assert(gui::physics_selection_blocks(scene, skin.id) == expected_ragdoll);
    assert(!gui::physics_selection_blocks(scene, plain.id));
    Entity dead = plain.id;
    scene.remove(plain);
    assert(!gui::physics_selection_blocks(scene, dead));
}
