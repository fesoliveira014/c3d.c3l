module c3d_physics_joint_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::physics;
import c3d::scene;
import b3;

alias Quat @private = Quaternionf;

const float TOLERANCE @private = 0.0001f;
const uint  SETTLE_UPDATES @private = 120;
const uint  DRIVE_UPDATES @private = 60;
const float LIMIT_SLACK @private = 0.02f;

struct Fixture @private {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
}

fn void setup(Fixture* fixture, PhysicsDesc desc = physics::default_physics_desc()) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    physics::register_physics(&fixture.scene)!!;
    create_world(fixture, desc);
}

fn void create_world(Fixture* fixture, PhysicsDesc desc) @private {
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      desc,
    )!!;
}

fn void teardown(Fixture* fixture) @private {
    if (fixture.physics.scene) physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn PhysicsDesc weightless_desc() @private {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    return desc;
}

fn Node* add_component_box(Fixture* fixture, Vec3 position, BodyKind kind = DYNAMIC) @private {
    Node* node = fixture.scene.add_node(name: "box")!!;
    node.local.position = position;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = { 0.5f, 0.5f, 0.5f };
    fixture.scene.add_physics_body(node, physics::default_body_desc(kind), (&collider)[:1])!!;
    return node;
}

// Pivot at the attached body's origin, so the hinge spins it in place about the anchor z.
fn JointDesc hinge_desc(Node* anchor, Node* attached, JointKind kind = REVOLUTE) @private {
    JointDesc desc = physics::default_joint_desc(kind, anchor.id);
    desc.anchor_frame.position = attached.local.position - anchor.local.position;
    return desc;
}

fn Node* hinge(Fixture* fixture, Node* anchor, Node* attached, JointKind kind = REVOLUTE) @private {
    fixture.scene.add_physics_joint(attached, hinge_desc(anchor, attached, kind))!!;
    return attached;
}

fn void step(Fixture* fixture, uint updates) @private {
    for (uint index = 0; index < updates; index++) {
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.scene.update_world();
    }
}

fn bool same_body(b3::BodyId first, b3::BodyId second) @private {
    return first.index1 == second.index1 && first.world0 == second.world0 && first.generation == second.generation;
}

fn float angle_about_z(Quat rotation) @private => 2 * math::atan2(rotation.k, rotation.l);

fn void test_joint_binds_on_the_update_after_both_bodies_are_live() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* attached = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 0, 0 }));
    assert(fixture.scene.get(attached, PhysicsJoint).status == PENDING);
    assert(@catch(fixture.physics.joint(attached)) == physics::NO_JOINT);

    fixture.physics.update(0);
    assert(fixture.scene.get(attached, PhysicsJoint).status == LIVE);
    assert(fixture.physics.joint(attached)!!.is_valid());
}

fn void test_joint_waits_for_a_body_authored_later() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = fixture.scene.add_node(name: "anchor")!!;
    Node* attached = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 0, 0 }));
    fixture.physics.update(0);
    assert(fixture.scene.get(attached, PhysicsJoint).status == PENDING);
    assert(fixture.physics.build_failures().len == 0);

    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = { 0.5f, 0.5f, 0.5f };
    fixture.scene.add_physics_body(anchor, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    fixture.physics.update(0);
    assert(fixture.scene.get(attached, PhysicsJoint).status == LIVE);
}

fn void test_mark_changed_on_either_body_rebinds_its_joint() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* attached = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 0, 0 }));
    fixture.physics.update(0);

    foreach (body_node : (Node*[]){ anchor, attached }) {
        b3::JointId first = fixture.physics.joint(attached)!!;
        fixture.scene.get(body_node, PhysicsBody).mark_changed();
        fixture.physics.update(0);
        assert(!first.is_valid());
        assert(fixture.physics.joint(attached)!!.is_valid());
        assert(fixture.scene.get(attached, PhysicsJoint).status == LIVE);
    }
}

fn void test_removing_physics_joint_destroys_the_bound_joint() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* attached = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 0, 0 }));
    fixture.physics.update(0);
    b3::JointId bound = fixture.physics.joint(attached)!!;

    fixture.scene.remove_component(attached, PhysicsJoint);
    fixture.physics.update(0);
    assert(!fixture.scene.has(attached, Joint));
    assert(!bound.is_valid());
}

fn void test_dead_other_fails_with_no_body_and_lists_once() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* attached = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 0, 0 }));
    fixture.physics.update(0);

    fixture.scene.remove(anchor);
    fixture.physics.update(0);
    PhysicsJoint* physics_joint = fixture.scene.get(attached, PhysicsJoint);
    assert(physics_joint.status == FAILED);
    assert(physics_joint.failure == physics::NO_BODY);
    assert(fixture.physics.build_failures().len == 1);
    assert(fixture.physics.build_failures()[0].node == attached);

    fixture.physics.update(0);
    assert(fixture.physics.build_failures().len == 0);
}

fn void test_add_joint_without_a_live_body_faults_and_leaves_no_components() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* attached = add_component_box(&fixture, { 2, 0, 0 });
    fixture.physics.update(0);
    Node* pending = add_component_box(&fixture, { 0, 3, 0 }, STATIC);

    assert(@catch(fixture.physics.add_joint(attached, hinge_desc(pending, attached))) == physics::NO_BODY);
    assert(!fixture.scene.has(attached, PhysicsJoint));
    assert(!fixture.scene.has(attached, Joint));

    fixture.physics.add_joint(attached, hinge_desc(anchor, attached))!!;
    assert(fixture.scene.get(attached, PhysicsJoint).status == LIVE);
}

fn void test_add_joint_twice_faults_joint_exists() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* attached = add_component_box(&fixture, { 2, 0, 0 });
    fixture.physics.update(0);
    fixture.physics.add_joint(attached, hinge_desc(anchor, attached))!!;
    b3::JointId bound = fixture.physics.joint(attached)!!;

    assert(@catch(fixture.physics.add_joint(attached, hinge_desc(anchor, attached))) == physics::JOINT_EXISTS);
    assert(bound.is_valid());
    assert(fixture.physics.joint(attached)!!.index1 == bound.index1);
}

fn void test_destroy_world_keeps_physics_joint_and_a_new_world_rebinds() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* attached = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 0, 0 }));
    fixture.physics.update(0);

    physics::destroy_physics_world(&fixture.physics);
    assert(fixture.scene.get(attached, PhysicsJoint).status == PENDING);
    assert(!fixture.scene.has(attached, Joint));

    create_world(&fixture, physics::default_physics_desc());
    fixture.physics.update(0);
    assert(fixture.scene.get(attached, PhysicsJoint).status == LIVE);
    assert(fixture.physics.joint(attached)!!.is_valid());
}

fn void test_anchor_is_body_a() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* chassis = add_component_box(&fixture, { 0, 2, 0 });
    Node* wheel = hinge(&fixture, chassis, add_component_box(&fixture, { 2, 2, 0 }), WHEEL);
    Node* anchor = add_component_box(&fixture, { 0, 5, 0 }, STATIC);
    Node* door = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 5, 0 }));
    fixture.physics.update(0);

    b3::JointId wheel_joint = fixture.physics.joint(wheel)!!;
    assert(wheel_joint.type() == b3::JointType.WHEEL);
    assert(same_body(wheel_joint.body_a(), fixture.physics.body(chassis)!!));
    assert(same_body(wheel_joint.body_b(), fixture.physics.body(wheel)!!));
    b3::JointId door_joint = fixture.physics.joint(door)!!;
    assert(same_body(door_joint.body_a(), fixture.physics.body(anchor)!!));
    assert(same_body(door_joint.body_b(), fixture.physics.body(door)!!));
}

fn void test_joint_event_fires_above_threshold_and_names_both_nodes() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 5, 0 }, STATIC);
    Node* hanging = add_component_box(&fixture, { 0, 3.5f, 0 });
    JointDesc desc = physics::default_joint_desc(DISTANCE, anchor.id);
    desc.distance.length = 1.5f;
    desc.force_threshold = 1;
    fixture.scene.add_physics_joint(hanging, desc)!!;

    bool reported;
    for (uint index = 0; index < SETTLE_UPDATES && !reported; index++) {
        step(&fixture, 1);
        foreach (event : fixture.physics.joint_events()) {
            assert(event.node == hanging);
            assert(event.other == anchor);
            reported = true;
        }
    }
    assert(reported);
}

fn void test_apply_joint_drives_a_revolute_motor() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* wheel = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 0, 0 }));
    fixture.physics.update(0);

    fixture.scene.get(wheel, PhysicsJoint).desc.revolute.motor = { .enabled = true, .speed = 5, .max_force = 1000 };
    fixture.physics.apply_joint(wheel);
    step(&fixture, DRIVE_UPDATES);
    assert(fixture.physics.body(wheel)!!.angular_velocity().z > 0);
}

fn void test_apply_joint_limit_holds_a_revolute_angle() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* wheel = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 0, 0 }));
    fixture.physics.update(0);

    fixture.scene.get(wheel, PhysicsJoint).desc.revolute.angle = { .enabled = true, .lower = -0.1f, .upper = 0.1f };
    fixture.physics.apply_joint(wheel);
    for (uint index = 0; index < DRIVE_UPDATES; index++) {
        b3::body_apply_torque(fixture.physics.body(wheel)!!, { 0, 0, 100 }, true);
        step(&fixture, 1);
    }
    float angle = angle_about_z(fixture.scene.get(wheel, RigidBody).current.rotation);
    assert(angle > 0.1f - LIMIT_SLACK && angle < 0.1f + LIMIT_SLACK);
}

fn void test_apply_joint_with_a_changed_kind_rebinds_on_next_update() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* attached = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 0, 0 }));
    fixture.physics.update(0);

    PhysicsJoint* physics_joint = fixture.scene.get(attached, PhysicsJoint);
    physics_joint.desc = hinge_desc(anchor, attached, WELD);
    fixture.physics.apply_joint(attached);
    assert(physics_joint.status == PENDING);
    assert(!fixture.scene.has(attached, Joint));

    fixture.physics.update(0);
    assert(physics_joint.status == LIVE);
    assert(fixture.physics.joint(attached)!!.type() == b3::JointType.WELD);
}

fn void test_rebind_keeps_applied_desc_values() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* anchor = add_component_box(&fixture, { 0, 0, 0 }, STATIC);
    Node* attached = hinge(&fixture, anchor, add_component_box(&fixture, { 2, 0, 0 }));
    fixture.physics.update(0);

    fixture.scene.get(attached, PhysicsJoint).desc.revolute.motor = { .enabled = true, .speed = 3, .max_force = 10 };
    fixture.physics.apply_joint(attached);
    fixture.scene.get(attached, PhysicsBody).mark_changed();
    fixture.physics.update(0);

    b3::RevoluteJointId revolute = (b3::RevoluteJointId)fixture.physics.joint(attached)!!;
    assert(math::abs(revolute.motor_speed() - 3) <= TOLERANCE);
}
