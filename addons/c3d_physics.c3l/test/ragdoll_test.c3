module c3d_physics_ragdoll_test;

import std::math;
import std::io;
import c3d::physics::getup_fixture;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::ecs;
import c3d::debug;
import c3d::geometry;
import c3d::material;
import c3d::physics::cloth;
import c3d::maths;
import c3d::physics;
import c3d::scene;
import b3;

alias Quat @private = Quaternionf;

const float TOLERANCE @private = 0.001f;
const float BONE_RADIUS @private = 0.1f;
const uint  DRIVE_UPDATES @private = 10;
const float DRIVE_SPEED @private = 1; // meters per second along X
const float VELOCITY_TOLERANCE @private = 0.1f;
const float ATTACHMENT_TOLERANCE @private = 0.02f; // meters; box3d's soft joint lets the anchor drift slightly
const float SPRING_HERTZ @private = 5;
const uint  SPRING_SETTLE_UPDATES @private = 120;
const float SPRING_TOLERANCE @private = 0.05f; // radians

struct Fixture @private {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
}

struct Rig @private {
    Node*   character;
    Node*   skin;
    Node*[] joints;
}

fn void setup(Fixture* fixture, PhysicsDesc desc = physics::default_physics_desc()) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    physics::register_physics(&fixture.scene)!!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      desc,
    )!!;
}

fn void teardown(Fixture* fixture) @private {
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn PhysicsDesc weightless_desc() @private {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    return desc;
}

// Joint nodes chain under the character; the skin node is their sibling, as instantiate lays them out.
fn Rig add_rig(Fixture* fixture, Vec3[] positions, int[] parents) @private {
    sz count = (sz)positions.len;
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(mem, String, count),
        .parents      = alloc::new_array(mem, int, count),
        .rest_pose    = alloc::new_array(mem, maths::Transform, count),
        .inverse_bind = alloc::new_array(mem, Mat4, count),
    };
    skeleton.parents[..] = parents[..];
    foreach (index, position : positions) {
        maths::Transform unbind = maths::TRANSFORM_IDENTITY;
        unbind.position = -position;
        skeleton.inverse_bind[index] = unbind.to_mat4();
        skeleton.rest_pose[index] = maths::TRANSFORM_IDENTITY;
    }
    SkeletonId skeleton_id = fixture.assets.add_skeleton_owned(&skeleton)!!;

    Rig rig = { .joints = alloc::new_array(fixture.scene.allocator, Node*, count) };
    rig.character = fixture.scene.add_node(name: "character")!!;
    rig.skin = fixture.scene.add_node(rig.character, "skin")!!;
    foreach (index, position : positions) {
        int parent = parents[index];
        Node* parent_node = parent < 0 ? rig.character : rig.joints[parent];
        Node* joint = fixture.scene.add_node(parent_node, "joint")!!;
        joint.local.position = parent < 0 ? position : position - positions[parent];
        rig.joints[index] = joint;
    }
    fixture.scene.add(rig.skin, (SkinBinding){ .skeleton = skeleton_id, .joints = rig.joints });
    fixture.scene.update_world();
    return rig;
}

fn Rig add_chain(Fixture* fixture) @private {
    Vec3[3] positions = { { 0, 0, 0 }, { 0, 1, 0 }, { 0, 2, 0 } };
    int[3] parents = { -1, 0, 1 };
    return add_rig(fixture, positions[..], parents[..]);
}

// A branch off the spine: hips, spine, arm and a hand joint without a bone.
fn Rig add_arm_rig(Fixture* fixture) @private {
    Vec3[4] positions = { { 0, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 }, { 2, 1, 0 } };
    int[4] parents = { -1, 0, 1, 2 };
    return add_rig(fixture, positions[..], parents[..]);
}

fn RagdollBone bone(uint joint, JointKind kind = SPHERICAL, float length = 0) @private {
    RagdollBone result = physics::default_ragdoll_bone(joint);
    result.radius = BONE_RADIUS;
    result.kind = kind;
    result.length = length;
    return result;
}

fn Ragdoll* build(Fixture* fixture, Rig* rig, RagdollBone[] bones) @private {
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones;
    fixture.scene.build_ragdoll(&fixture.assets, rig.skin, desc)!!;
    fixture.scene.update_world();
    return fixture.scene.get(rig.skin, Ragdoll);
}

fn Ragdoll* build_two_bones(Fixture* fixture, Rig* rig) @private {
    RagdollBone[2] bones = { bone(0), bone(1, length: 1) };
    return build(fixture, rig, bones[..]);
}

fn Ragdoll* build_arm(Fixture* fixture, Rig* rig) @private {
    RagdollBone[3] bones = { bone(0), bone(1), bone(2) };
    return build(fixture, rig, bones[..]);
}

fn Ragdoll* build_driven(Fixture* fixture, Rig* rig, JointKind kind) @private {
    RagdollBone[2] bones = { bone(0), bone(1, kind, length: 1) };
    bones[1].hinge_axis = { 1, 0, 0 };
    bones[1].drive = { .enabled = true, .hertz = SPRING_HERTZ, .damping_ratio = 1 };
    return build(fixture, rig, bones[..]);
}

fn fault build_fault(Fixture* fixture, Rig* rig, RagdollBone[] bones) @private {
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones;
    return @catch(fixture.scene.build_ragdoll(&fixture.assets, rig.skin, desc));
}

fn Vec3 world_position(Node* node) @private => maths::translation(node.world);

fn bool close_vec(Vec3 first, Vec3 second) @private => (first - second).length() <= TOLERANCE;

fn float angle_between(Quat first, Quat second) @private {
    Quat difference = first.mul(second.conjugate()).normalize();
    if (difference.l < 0) difference = -difference;
    Vec3 vector = { difference.i, difference.j, difference.k };
    return 2 * math::atan2(vector.length(), difference.l);
}

fn bool same_body(b3::BodyId first, b3::BodyId second) @private {
    return first.index1 == second.index1 && first.world0 == second.world0 && first.generation == second.generation;
}

fn void test_build_ragdoll_places_bones_on_bind_midpoints() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    Node* hips = ragdoll.bone_nodes[0];
    Node* spine = ragdoll.bone_nodes[1];
    assert(close_vec(world_position(hips), { 0, 0.5f, 0 }));
    assert(close_vec(world_position(spine), { 0, 1.5f, 0 }));
    assert(fixture.scene.get(hips, PhysicsBody).body.kind == KINEMATIC);
    assert(fixture.scene.get(spine, PhysicsBody).body.kind == KINEMATIC);
    assert(fixture.scene.get(spine, PhysicsJoint).desc.other.index == hips.id.index);
    assert(!fixture.scene.has(hips, PhysicsJoint));

    fixture.physics.update(0);
    assert(same_body(fixture.physics.joint(spine)!!.body_a(), fixture.physics.body(hips)!!));
}

fn void test_revolute_bone_frames_hinge_about_the_bind_axis() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    RagdollBone[2] bones = { bone(0), bone(1, REVOLUTE, 1) };
    bones[1].hinge_axis = { 1, 0, 0 };
    Ragdoll* ragdoll = build(&fixture, &rig, bones[..]);

    JointDesc* desc = &fixture.scene.get(ragdoll.bone_nodes[1], PhysicsJoint).desc;
    assert(desc.kind == REVOLUTE);
    Quat anchor_rotation = maths::transform_from_mat4(ragdoll.bone_nodes[0].world).rotation;
    Vec3 hinge = anchor_rotation.mul(desc.anchor_frame.rotation).rotate_vec3({ 0, 0, 1 });
    assert(close_vec(hinge, { 1, 0, 0 }));
}

fn void test_build_ragdoll_rejects_bad_descs() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    RagdollBone[1] leaf = { bone(2) };
    RagdollBone[2] reversed = { bone(1, length: 1), bone(0) };
    RagdollBone[1] out_of_range = { bone(3, length: 1) };
    RagdollBone[1] welded = { bone(0, WELD) };
    RagdollBone[2] no_hinge = { bone(0), bone(1, REVOLUTE, 1) };
    assert(build_fault(&fixture, &rig, leaf[..]) == c3d::INVALID_ARGUMENT);
    assert(build_fault(&fixture, &rig, reversed[..]) == c3d::INVALID_ARGUMENT);
    assert(build_fault(&fixture, &rig, out_of_range[..]) == c3d::INVALID_ARGUMENT);
    assert(build_fault(&fixture, &rig, welded[..]) == c3d::INVALID_ARGUMENT);
    assert(build_fault(&fixture, &rig, no_hinge[..]) == c3d::INVALID_ARGUMENT);
    assert(rig.skin.first_child == null);
    assert(fixture.scene.count(PhysicsBody) == 0);

    rig.character.local.scale = { 2, 2, 2 };
    fixture.scene.update_world();
    RagdollBone[2] valid = { bone(0), bone(1, length: 1) };
    assert(build_fault(&fixture, &rig, valid[..]) == c3d::UNSUPPORTED);
    assert(rig.skin.first_child == null);
}

fn void test_branching_joint_points_at_the_listed_child_bone() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Vec3[4] positions = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 2, 0 } };
    int[4] parents = { -1, 0, 0, 2 };
    Rig rig = add_rig(&fixture, positions[..], parents[..]);
    RagdollBone[2] bones = { bone(0), bone(2, length: 1) };
    Ragdoll* ragdoll = build(&fixture, &rig, bones[..]);

    Quat hips = maths::transform_from_mat4(ragdoll.bone_nodes[0].world).rotation;
    assert(close_vec(hips.rotate_vec3({ 0, 1, 0 }), { 0, 1, 0 }));
}

fn void test_build_ragdoll_without_skin_faults_no_skin() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* plain = fixture.scene.add_node(name: "plain")!!;
    RagdollBone[1] bones = { bone(0, length: 1) };
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones[..];
    assert(@catch(fixture.scene.build_ragdoll(&fixture.assets, plain, desc)) == physics::NO_SKIN);
}

fn void test_build_ragdoll_twice_faults() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    build_two_bones(&fixture, &rig);
    RagdollBone[2] bones = { bone(0), bone(1, length: 1) };
    assert(build_fault(&fixture, &rig, bones[..]) == physics::RAGDOLL_EXISTS);
}

fn void test_animated_ragdoll_drives_bone_bodies_from_joint_nodes() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    fixture.physics.update(0);

    rig.joints[0].local.position += { 1, 0, 0 };
    fixture.scene.update_world();
    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    assert(close_vec(fixture.scene.get(ragdoll.bone_nodes[1], RigidBody).current.position, { 1, 1.5f, 0 }));
}

fn void test_weight_zero_leaves_the_animator_pose() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    fixture.physics.update(0);
    fixture.physics.set_ragdoll_mode(rig.skin, SIMULATED);
    ragdoll.weight = 0;
    fixture.physics.update(physics::DEFAULT_FIXED_DT);

    maths::Transform before = rig.joints[1].local;
    fixture.physics.update_ragdolls();
    assert(close_vec(rig.joints[1].local.position, before.position));
    assert(rig.joints[1].local.rotation.v == before.rotation.v);
}

fn void test_weight_one_writes_body_poses_into_joints() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    fixture.physics.update(0);
    fixture.physics.set_ragdoll_mode(rig.skin, SIMULATED);
    ragdoll.weight = 1;

    Node* spine = ragdoll.bone_nodes[1];
    RigidBody* body = fixture.scene.get(spine, RigidBody);
    fixture.physics.teleport(spine, body.current.position + { 0, 0, 1 }, body.current.rotation);
    fixture.physics.update(0);
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    assert(close_vec(world_position(rig.joints[1]), { 0, 1, 1 }));
    assert(close_vec(world_position(rig.joints[0]), { 0, 0, 0 }));
}

fn void test_set_ragdoll_mode_keeps_bone_velocity() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    fixture.physics.update(0);
    for (uint index = 0; index < DRIVE_UPDATES; index++) {
        rig.joints[0].local.position.x += DRIVE_SPEED * physics::DEFAULT_FIXED_DT;
        fixture.scene.update_world();
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
    }

    fixture.physics.set_ragdoll_mode(rig.skin, SIMULATED);
    assert(fixture.scene.get(ragdoll.bone_nodes[0], RigidBody).kind == DYNAMIC);
    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    float speed = fixture.physics.body(ragdoll.bone_nodes[0])!!.linear_velocity().x;
    assert(math::abs(speed - DRIVE_SPEED) <= VELOCITY_TOLERANCE);
}

// Only the arm simulates and blends; its body is moved one meter along z.
fn void go_limp(Fixture* fixture, Rig* rig, Ragdoll* ragdoll) @private {
    fixture.physics.update(0);
    fixture.physics.set_bone_mode(rig.skin, 2, SIMULATED);
    ragdoll.weight = 1;
    ragdoll.bone_weights[0] = 0;
    ragdoll.bone_weights[1] = 0;
    Node* arm = ragdoll.bone_nodes[2];
    RigidBody* body = fixture.scene.get(arm, RigidBody);
    fixture.physics.teleport(arm, body.current.position + { 0, 0, 1 }, body.current.rotation);
    fixture.physics.update(0);
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
}

fn void test_limp_arm_blends_while_the_spine_keeps_its_pose() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_arm_rig(&fixture);
    Ragdoll* ragdoll = build_arm(&fixture, &rig);
    go_limp(&fixture, &rig, ragdoll);

    assert(close_vec(world_position(rig.joints[0]), { 0, 0, 0 }));
    assert(close_vec(world_position(rig.joints[1]), { 0, 1, 0 }));
    assert(close_vec(world_position(rig.joints[2]), { 1, 1, 1 }));
    assert(close_vec(world_position(rig.joints[3]), { 2, 1, 1 }));
}

fn void test_dynamic_bone_stays_attached_to_its_kinematic_parent() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    fixture.physics.update(0);
    fixture.physics.set_bone_mode(rig.skin, 1, SIMULATED);
    for (uint index = 0; index < 60; index++) fixture.physics.update(physics::DEFAULT_FIXED_DT);

    assert(fixture.scene.get(ragdoll.bone_nodes[0], RigidBody).kind == KINEMATIC);
    RigidBody* child = fixture.scene.get(ragdoll.bone_nodes[1], RigidBody);
    Vec3 anchor = maths::translation(child.current.to_mat4().mul(ragdoll.joint_in_bone[1].to_mat4()));
    assert((anchor - world_position(rig.joints[1])).length() <= ATTACHMENT_TOLERANCE);
}

fn void test_set_bone_mode_keeps_velocity() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    fixture.physics.update(0);
    for (uint index = 0; index < DRIVE_UPDATES; index++) {
        rig.joints[0].local.position.x += DRIVE_SPEED * physics::DEFAULT_FIXED_DT;
        fixture.scene.update_world();
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
    }

    fixture.physics.set_bone_mode(rig.skin, 1, SIMULATED);
    fixture.physics.set_bone_mode(rig.skin, 1, SIMULATED);
    assert(fixture.scene.get(ragdoll.bone_nodes[0], RigidBody).kind == KINEMATIC);
    assert(fixture.scene.get(ragdoll.bone_nodes[1], RigidBody).kind == DYNAMIC);
    float speed = fixture.physics.body(ragdoll.bone_nodes[1])!!.linear_velocity().x;
    assert(math::abs(speed - DRIVE_SPEED) <= VELOCITY_TOLERANCE);
}

fn void test_recover_bones_keeps_the_limp_arm_dynamic_and_leaves_the_character() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_arm_rig(&fixture);
    Ragdoll* ragdoll = build_arm(&fixture, &rig);
    go_limp(&fixture, &rig, ragdoll);
    Vec3[4] recorded;
    foreach (index, joint : rig.joints) recorded[index] = world_position(joint);
    Vec3 character = world_position(rig.character);

    fixture.physics.recover_bones(rig.skin)!!;
    assert(ragdoll.bone_modes[0] == ANIMATED && ragdoll.bone_modes[1] == ANIMATED
        && ragdoll.bone_modes[2] == SIMULATED);
    assert(close_vec(world_position(rig.character), character));
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    foreach (index, joint : rig.joints) assert(close_vec(world_position(joint), recorded[index]));
}

// Bodies and joints are built by the first update; the drive pushes from the second.
fn void power_bone(Fixture* fixture, Rig* rig, Ragdoll* ragdoll, float strength) @private {
    fixture.physics.update(0);
    fixture.physics.set_bone_mode(rig.skin, 1, SIMULATED);
    ragdoll.drive_strength = strength;
}

fn void test_drive_target_is_identity_at_the_bind_pose() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_driven(&fixture, &rig, SPHERICAL);
    power_bone(&fixture, &rig, ragdoll, 1);
    fixture.physics.update(0);

    b3::SphericalJointId joint = fixture.physics.joint(ragdoll.bone_nodes[1])!!.as_spherical()!!;
    assert(angle_between(joint.target_rotation(), quaternion::IDENTITY) <= TOLERANCE);
    assert(math::abs(joint.spring_hertz() - SPRING_HERTZ) <= TOLERANCE);
}

fn void test_revolute_drive_targets_the_animated_hinge_angle() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_driven(&fixture, &rig, REVOLUTE);
    power_bone(&fixture, &rig, ragdoll, 1);
    rig.joints[1].local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.4f);
    fixture.scene.update_world();
    fixture.physics.update(0);

    b3::RevoluteJointId joint = fixture.physics.joint(ragdoll.bone_nodes[1])!!.as_revolute()!!;
    assert(math::abs(joint.target_angle() - 0.4f) <= TOLERANCE);
}

// Angles of the settled bone body from the animated bone rotation and from its bind rotation.
fn float[2] settle_driven_bone(float strength) @private {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_driven(&fixture, &rig, SPHERICAL);
    power_bone(&fixture, &rig, ragdoll, strength);
    Quat bind = fixture.scene.get(ragdoll.bone_nodes[1], RigidBody).current.rotation;
    rig.joints[1].local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.5f);
    fixture.scene.update_world();
    for (uint index = 0; index < SPRING_SETTLE_UPDATES; index++) fixture.physics.update(physics::DEFAULT_FIXED_DT);

    Quat body = fixture.scene.get(ragdoll.bone_nodes[1], RigidBody).current.rotation;
    Quat joint_rotation = maths::transform_from_mat4(rig.joints[1].world).rotation;
    Quat animated = joint_rotation * ragdoll.joint_in_bone[1].rotation.conjugate();
    return { angle_between(body, animated), angle_between(body, bind) };
}

fn void test_sprung_bone_converges_to_the_animated_pose() @test {
    assert(settle_driven_bone(1)[0] <= SPRING_TOLERANCE);
    assert(settle_driven_bone(0)[1] <= SPRING_TOLERANCE);
}

fn void fall_and_recover(Fixture* fixture, Rig* rig, Ragdoll* ragdoll, Vec3[] recorded) @private {
    fixture.physics.update(0);
    fixture.physics.set_ragdoll_mode(rig.skin, SIMULATED);
    ragdoll.weight = 1;
    foreach (node : ragdoll.bone_nodes) {
        RigidBody* body = fixture.scene.get(node, RigidBody);
        fixture.physics.teleport(node, body.current.position + { 3, 0, 2 }, body.current.rotation);
    }
    fixture.physics.update(0);
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    foreach (index, joint : rig.joints) recorded[index] = world_position(joint);
    fixture.physics.recover_ragdoll(rig.skin, rig.character)!!;
}

fn void test_recover_moves_the_character_and_keeps_joint_worlds() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    Vec3[3] recorded;
    fall_and_recover(&fixture, &rig, ragdoll, recorded[..]);

    Vec3 hips = fixture.scene.get(ragdoll.bone_nodes[0], RigidBody).current.position;
    Vec3 character = world_position(rig.character);
    assert(math::abs(character.x - hips.x) <= TOLERANCE && math::abs(character.z - hips.z) <= TOLERANCE);
    foreach (mode : ragdoll.bone_modes) assert(mode == SIMULATED);
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    foreach (index, joint : rig.joints) assert(close_vec(world_position(joint), recorded[index]));
}

fn void test_recovery_half_weight_keeps_native_publication() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    Vec3[3] recorded;
    fall_and_recover(&fixture, &rig, ragdoll, recorded[..]);
    rig.joints[0].local.position = {};
    rig.joints[1].local.position = { 0, 1, 0 };
    ragdoll.weight = 0.5f;
    fixture.scene.update_world();
    fixture.physics.update(0);
    assert_recovery_publication(&fixture, &rig, ragdoll);
    foreach (index, joint : rig.joints) assert(close_vec(world_position(joint), recorded[index]));
}

fn void test_remove_ragdoll_removes_bone_nodes_and_components() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    fixture.physics.update(0);
    Entity[2] bones = { ragdoll.bone_nodes[0].id, ragdoll.bone_nodes[1].id };

    fixture.scene.remove_ragdoll(rig.skin);
    assert(!fixture.scene.has(rig.skin, Ragdoll));
    foreach (entity : bones) assert(!fixture.scene.world.is_alive(entity));
    assert(fixture.scene.count(PhysicsBody) == 0);
    assert(fixture.scene.count(RigidBody) == 0);
    assert(fixture.scene.count(Joint) == 0);
}

// Rotates every bone body about the world origin, as if the rig fell pivoting on its root joint.
fn RagdollFacing fall_rotated(Fixture* fixture, Rig* rig, Ragdoll* ragdoll, Quat fall) @private {
    fixture.physics.update(0);
    fixture.physics.set_ragdoll_mode(rig.skin, SIMULATED);
    ragdoll.weight = 1;
    foreach (node : ragdoll.bone_nodes) {
        RigidBody* body = fixture.scene.get(node, RigidBody);
        fixture.physics.teleport(node, fall.rotate_vec3(body.current.position), fall.mul(body.current.rotation));
    }
    fixture.physics.update(0);
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    return fixture.physics.recover_ragdoll(rig.skin, rig.character)!!;
}

fn Vec3 character_forward(Rig* rig) @private {
    return maths::transform_from_mat4(rig.character.world).rotation.rotate_vec3({ 0, 0, 1 });
}

fn Quat about(Vec3 axis, float degrees) @private {
    return quaternion::from_axis_angle{float}(axis, degrees * (float)math::PI / 180);
}

fn void test_recover_on_the_back_reports_face_up_and_keeps_heading() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    assert(fall_rotated(&fixture, &rig, ragdoll, about({ 1, 0, 0 }, -90)) == FACE_UP);
    assert(close_vec(character_forward(&rig), { 0, 0, 1 }));
}

fn void test_recover_face_down_turns_toward_the_head() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    Quat fall = about({ 0, 1, 0 }, 90).mul(about({ 1, 0, 0 }, 90));
    assert(fall_rotated(&fixture, &rig, ragdoll, fall) == FACE_DOWN);
    assert(close_vec(character_forward(&rig), { 1, 0, 0 }));
    assert(ragdoll.last_facing == FACE_DOWN && ragdoll.recoveries == 1);
    RagdollFacing second = fall_rotated(&fixture, &rig, ragdoll, about({ 1, 0, 0 }, -90));
    assert(ragdoll.last_facing == second && ragdoll.recoveries == 2);
}

fn void test_fresh_ragdoll_has_no_recovery() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    assert(ragdoll.recoveries == 0);
}

fn void test_recover_bones_keeps_the_recovery_reading() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    Quat fall = about({ 0, 1, 0 }, 90).mul(about({ 1, 0, 0 }, 90));
    assert(fall_rotated(&fixture, &rig, ragdoll, fall) == FACE_DOWN);
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    fixture.physics.recover_bones(rig.skin)!!;
    assert(ragdoll.last_facing == FACE_DOWN && ragdoll.recoveries == 1);
}

fn void test_recover_counts_a_turn_made_before_the_fall_once() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Quat turned = about({ 0, 1, 0 }, 90);
    rig.character.local.rotation = turned;
    fixture.scene.update_world();
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    Quat fall = turned.mul(about({ 1, 0, 0 }, 90)).mul(turned.conjugate());
    assert(fall_rotated(&fixture, &rig, ragdoll, fall) == FACE_DOWN);
    assert(close_vec(character_forward(&rig), { 1, 0, 0 }));
}

fn void test_ragdoll_animation_uses_a_world_joint_basis() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Rig rig = add_chain(&fixture);
    rig.joints[0].transform_space = TransformSpace.WORLD;
    rig.character.local.position = { 5, 2, -3 };
    rig.character.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.7f);
    fixture.scene.update_world();
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    fixture.physics.update(0);
    rig.joints[0].local.position += { 1, 0, 0 };
    fixture.scene.update_world();
    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    assert(close_vec(fixture.scene.get(ragdoll.bone_nodes[1], RigidBody).current.position, { 1, 1.5f, 0 }));
}

fn void assert_recovery_publication(Fixture* fixture, Rig* rig, Ragdoll* ragdoll) @private {
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    foreach (index, node : ragdoll.bone_nodes) {
        if (ragdoll.bone_modes[index] != SIMULATED
            && ragdoll.recovery_status().phase != RagdollRecoveryPhase.COMPLETING) continue;
        b3::WorldTransform native = fixture.physics.body(node)!!.transform();
        maths::Transform actual = maths::transform_from_mat4(node.world);

        assert((actual.position - (Vec3)native.p).length() <= 0.00002f);
        assert(angle_between(actual.rotation, native.q) <= 0.0001f);

        maths::Transform native_pose = { .position = native.p, .rotation = native.q, .scale = { 1, 1, 1 } };
        maths::Transform mapped =
          maths::transform_from_mat4(native_pose.to_mat4().mul(ragdoll.joint_in_bone[index].to_mat4()));
        maths::Transform visible = maths::transform_from_mat4(rig.joints[ragdoll.bone_joints[index]].world);

        assert((mapped.position - visible.position).length() <= 0.00002f);
        assert(angle_between(mapped.rotation, visible.rotation) <= 0.0001f);
    }
}

fn void enter_recovery(Fixture* fixture, Rig* rig, Ragdoll* ragdoll) @private {
    fixture.physics.update(0);
    fixture.physics.set_ragdoll_mode(rig.skin, SIMULATED);
    ragdoll.weight = 1;
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    fixture.physics.recover_bones(rig.skin)!!;
}

fn void test_recovery_missing_body_and_invalid_settings_are_atomic() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    fixture.physics.set_ragdoll_mode(rig.skin, SIMULATED);
    Vec3 character = world_position(rig.character);

    assert(@catch(fixture.physics.recover_ragdoll(rig.skin, rig.character)) == physics::NO_BODY);
    assert(close_vec(character, world_position(rig.character)) && ragdoll.recoveries == 0);

    fixture.physics.update(0);
    ragdoll.weight = 1;
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    fixture.physics.recover_bones(rig.skin)!!;
    RagdollRecoverySettings settings = physics::default_ragdoll_recovery_settings();
    settings.position_hertz = 1e30f;

    assert(@catch(fixture.physics.recover_bones(rig.skin, settings)) == c3d::INVALID_ARGUMENT);

    settings = physics::default_ragdoll_recovery_settings();
    settings.max_force = -1;

    assert(@catch(fixture.physics.recover_bones(rig.skin, settings)) == c3d::INVALID_ARGUMENT);
    assert(ragdoll.recovery_status().participating == 2);
    assert(ragdoll.bone_modes[0] == SIMULATED && ragdoll.recoveries == 0);

    rig.joints[0].local.position.x += 1;
    fixture.scene.update_world();

    assert(@catch(fixture.physics.recover_ragdoll(rig.skin, rig.character)) == physics::RECOVERY_POSE_MISMATCH);
    assert(close_vec(character, world_position(rig.character)) && ragdoll.recoveries == 0);
    assert(ragdoll.recovery_status().participating == 2);
}

fn void test_recovery_zero_and_multiple_steps_publish_current_idempotently() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_arm_rig(&fixture);
    Ragdoll* ragdoll = build_arm(&fixture, &rig);
    enter_recovery(&fixture, &rig, ragdoll);
    ragdoll.weight = 0;
    rig.joints[0].local.position.x += 0.2f;
    rig.joints[3].local.rotation = about({ 0, 1, 0 }, 20);
    maths::Transform unmapped = rig.joints[3].local;
    fixture.scene.update_world();
    b3::BodyId identity = fixture.physics.body(ragdoll.bone_nodes[0])!!;
    Vec3 previous = identity.position();
    fixture.physics.update(0);

    assert(fixture.physics.steps_last_update == 0 && close_vec(identity.position(), previous));

    assert_recovery_publication(&fixture, &rig, ragdoll);

    assert(angle_between(rig.joints[3].local.rotation, unmapped.rotation) <= TOLERANCE);

    Vec3 published = world_position(rig.joints[0]);
    assert_recovery_publication(&fixture, &rig, ragdoll);

    assert(close_vec(world_position(rig.joints[0]), published));

    rig.joints[0].local.position.x += 0.2f;
    fixture.scene.update_world();
    fixture.physics.update(2 * physics::DEFAULT_FIXED_DT);

    assert(fixture.physics.steps_last_update == 2);

    assert_recovery_publication(&fixture, &rig, ragdoll);

    assert(same_body(identity, fixture.physics.body(ragdoll.bone_nodes[0])!!));

    RagdollRecoveryStatus status = ragdoll.recovery_status();

    assert(status.force > 0 && status.force <= 200.0001f && status.torque <= 20.0001f);

    assert_recovery_publication(&fixture, &rig, ragdoll);
}

fn void test_recovery_completion_checks_captured_weights_and_retains_publication() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    enter_recovery(&fixture, &rig, ragdoll);

    assert(@catch(fixture.physics.finish_ragdoll_recovery(rig.skin)) == physics::RECOVERY_NOT_READY);

    fixture.physics.update(0);
    ragdoll.weight = 0;

    assert(@catch(fixture.physics.finish_ragdoll_recovery(rig.skin)) == physics::RECOVERY_NOT_READY);

    fixture.physics.update(0);
    b3::BodyId identity = fixture.physics.body(ragdoll.bone_nodes[0])!!;
    fixture.physics.finish_ragdoll_recovery(rig.skin)!!;

    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.COMPLETING);

    foreach (mode : ragdoll.bone_modes) assert(mode == ANIMATED);
    rig.joints[0].local.position.x += 1;
    assert_recovery_publication(&fixture, &rig, ragdoll);
    assert_recovery_publication(&fixture, &rig, ragdoll);

    assert(same_body(identity, fixture.physics.body(ragdoll.bone_nodes[0])!!));

    fixture.physics.update(0);

    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.INACTIVE);
}

fn void test_recovery_unsettled_zero_weight_does_not_finish() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    enter_recovery(&fixture, &rig, ragdoll);
    ragdoll.weight = 0;
    rig.joints[0].local.position.x += 2;
    fixture.scene.update_world();
    fixture.physics.update(0);

    assert(@catch(fixture.physics.finish_ragdoll_recovery(rig.skin)) == physics::RECOVERY_NOT_READY);
    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.BLOCKED);
    assert(ragdoll.bone_modes[0] == SIMULATED);

    assert_recovery_publication(&fixture, &rig, ragdoll);
}

fn void test_recovery_masks_springs_and_restores_latest_authoring_on_same_mode() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_driven(&fixture, &rig, SPHERICAL);
    enter_recovery(&fixture, &rig, ragdoll);
    b3::SphericalJointId joint = fixture.physics.joint(ragdoll.bone_nodes[1])!!.as_spherical()!!;
    fixture.physics.update(0);

    assert(!joint.is_spring_enabled());

    ragdoll.bone_drives[1] = { .enabled = true, .hertz = 3, .damping_ratio = 0.7f };
    ragdoll.drive_strength = 2;
    fixture.physics.set_bone_mode(rig.skin, 1, SIMULATED);

    assert(joint.is_spring_enabled());
    assert(math::abs(joint.spring_hertz() - 6) <= TOLERANCE);
    assert(math::abs(joint.spring_damping_ratio() - 0.7f) <= TOLERANCE);
    assert(ragdoll.recovery_status().participating == 1);

    fixture.physics.set_ragdoll_mode(rig.skin, SIMULATED);

    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.INACTIVE);
}

fn void test_recovery_teleport_cancels_before_moving_without_completion() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    enter_recovery(&fixture, &rig, ragdoll);
    Node* node = ragdoll.bone_nodes[0];
    b3::BodyId body = fixture.physics.body(node)!!;
    body.set_linear_velocity({ 1, 0, 0 });
    fixture.physics.teleport(node, { 3, 2, 1 }, quaternion::IDENTITY);

    assert(ragdoll.recovery_status().participating == 1);
    assert(ragdoll.bone_modes[0] == SIMULATED && body.linear_velocity().x == 1);
    assert(close_vec(body.position(), { 3, 2, 1 }));

    fixture.physics.teleport(ragdoll.bone_nodes[1], { 3, 3, 1 }, quaternion::IDENTITY);

    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.INACTIVE);
    assert(ragdoll.recoveries == 0);
}

fn void test_recovery_removal_and_world_replacement_cancel_transient_state() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    enter_recovery(&fixture, &rig, ragdoll);
    fixture.physics.remove_joint(ragdoll.bone_nodes[1]);
    fixture.physics.update(0);

    assert(ragdoll.recovery_status().participating == 1);

    physics::destroy_physics_world(&fixture.physics);

    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.INACTIVE);

    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets: &fixture.assets,
        scene: &fixture.scene,
        desc: weightless_desc(),
    )!!;
    fixture.physics.update(0);

    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.INACTIVE);
}

fn void test_recovery_reentry_preserves_physical_source_and_uses_fresh_target() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    enter_recovery(&fixture, &rig, ragdoll);
    ragdoll.weight = 0;
    for (uint frame = 0; frame < 30; frame++) {
        rig.joints[0].local.position = { 0.3f, 0, 0 };
        rig.joints[1].local.position = { 0, 1, 0 };
        rig.joints[2].local.position = { 0, 1, 0 };
        fixture.scene.update_world();
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.physics.update_ragdolls();
        fixture.scene.update_world();
    }
    Vec3 visible = world_position(rig.joints[0]);
    fixture.physics.recover_bones(rig.skin)!!;
    ragdoll.weight = 1;
    rig.joints[0].local.position = { 5, 0, 0 };
    fixture.scene.update_world();
    fixture.physics.update(0);

    assert(ragdoll.recovery_status().position_error < TOLERANCE);

    assert_recovery_publication(&fixture, &rig, ragdoll);

    assert(close_vec(world_position(rig.joints[0]), visible));

    ragdoll.weight = 0;
    rig.joints[0].local.position = { 5, 0, 0 };
    fixture.scene.update_world();
    fixture.physics.update(0);

    assert(ragdoll.recovery_status().position_error > 4);

    fixture.physics.set_bone_mode(rig.skin, 1, ANIMATED);
    assert_recovery_publication(&fixture, &rig, ragdoll);
    fixture.physics.recover_bones(rig.skin)!!;

    assert(ragdoll.recovery_status().participating == 1 && ragdoll.bone_modes[1] == ANIMATED);
}

fn void test_recovery_velocity_and_completing_cancellation_are_checked() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    enter_recovery(&fixture, &rig, ragdoll);
    ragdoll.weight = 0;
    b3::BodyId body = fixture.physics.body(ragdoll.bone_nodes[0])!!;
    body.set_linear_velocity({ 0.1f, 0, 0 });
    fixture.physics.update(0);

    assert(@catch(fixture.physics.finish_ragdoll_recovery(rig.skin)) == physics::RECOVERY_NOT_READY);

    body.set_linear_velocity({});
    fixture.physics.finish_ragdoll_recovery(rig.skin)!!;
    fixture.physics.set_bone_mode(rig.skin, 0, ANIMATED);

    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.COMPLETING);

    fixture.physics.teleport(ragdoll.bone_nodes[1], { 2, 2, 2 }, quaternion::IDENTITY);

    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.INACTIVE);
    assert(ragdoll.bone_modes[0] == ANIMATED && ragdoll.bone_modes[1] == ANIMATED);
}

fn void test_recovery_origin_shift_keeps_local_targets_and_residuals() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    enter_recovery(&fixture, &rig, ragdoll);
    ragdoll.weight = 0;
    rig.joints[0].local.position.x = 0.1f;
    fixture.scene.update_world();
    fixture.physics.update(0);
    RagdollRecoveryStatus before = ragdoll.recovery_status();
    maths::Transform source = ragdoll.frozen[0];
    Vec3 offset = { 8, 0, -4 };
    fixture.scene.shift_origin(offset);
    fixture.scene.update_world();
    fixture.physics.shift_origin(&fixture.scene, offset);
    assert_recovery_publication(&fixture, &rig, ragdoll);
    assert_recovery_publication(&fixture, &rig, ragdoll);

    assert(ragdoll.frozen[0].position == source.position);
    assert(@catch(fixture.physics.finish_ragdoll_recovery(rig.skin)) == physics::RECOVERY_NOT_READY);
    assert(math::abs(ragdoll.recovery_status().position_error - before.position_error) <= TOLERANCE);
}

fn void test_recovery_body_replacement_and_bone_removal_cancel_matching_state() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_driven(&fixture, &rig, SPHERICAL);
    enter_recovery(&fixture, &rig, ragdoll);
    Node* node = ragdoll.bone_nodes[1];
    b3::BodyId old = fixture.physics.body(node)!!;
    fixture.scene.remove_component(node, RigidBody);
    fixture.scene.get(node, PhysicsBody).status = PENDING;
    fixture.physics.update(0);

    assert(!old.is_valid() && ragdoll.recovery_status().participating == 1);

    b3::SphericalJointId joint = fixture.physics.joint(node)!!.as_spherical()!!;

    assert(joint.is_spring_enabled());

    fixture.scene.remove(ragdoll.bone_nodes[0]);
    fixture.physics.update(0);

    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.INACTIVE);
}

fn void test_recovery_accepts_existing_weight_range_and_blocks_invalid_animation() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    enter_recovery(&fixture, &rig, ragdoll);
    ragdoll.weight = 1.75f;
    ragdoll.bone_weights[0] = 1.5f;
    fixture.physics.recover_bones(rig.skin)!!;
    rig.joints[0].local.position.x = 0.2f;
    fixture.scene.update_world();
    fixture.physics.update(0);

    assert(math::abs(ragdoll.recovery_status().position_error - 0.1f) <= TOLERANCE);

    rig.joints[0].local.rotation = {};
    fixture.physics.update(physics::DEFAULT_FIXED_DT);

    assert(ragdoll.recovery_status().failure == c3d::INVALID_ARGUMENT);
    assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.BLOCKED);
    assert(b3::is_valid_world_transform(fixture.physics.body(ragdoll.bone_nodes[0])!!.transform()));

    assert_recovery_publication(&fixture, &rig, ragdoll);
}

fn void test_recovery_publication_feeds_cloth_pins_and_collider_debug() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    enter_recovery(&fixture, &rig, ragdoll);
    GeometryId geometry_id;
    @pool() {
        Geometry geometry = {
            .positions = alloc::new_array(tmem, Vec3, 3),
            .indices = alloc::new_array(tmem, uint, 3),
        };
        geometry.positions[..] = ((Vec3[3]){ { 0, 0, 0 }, { 0.4f, 0, 0 }, { 0.4f, -0.3f, 0 } })[..];
        geometry.indices[..] = { 0, 1, 2 }[..];
        geometry.finalize();
        geometry_id = fixture.assets.add_geometry(&geometry)!!;
    };
    MaterialId material_id = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }))!!;
    Node* cloth_node = fixture.scene.add_mesh(geometry_id, material_id, rig.joints[1])!!;
    fixture.scene.update_world();
    uint[1] pins = { 0 };
    Entity[1] colliders = { ragdoll.bone_nodes[1].id };
    cloth::ClothDesc desc = cloth::default_cloth_desc();
    desc.pins = pins[..];
    desc.colliders = colliders[..];
    fixture.scene.add_cloth(&fixture.assets, cloth_node, desc)!!;
    debug::DebugDraw draw = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&draw);
    foreach (dt : (float[2]){ 1.5f * physics::DEFAULT_FIXED_DT, 0 }) {
        rig.joints[0].local.position = { 0.1f, 0, 0 };
        rig.joints[1].local.position = { 0, 1, 0 };
        ragdoll.weight = 0;
        fixture.scene.update_world();
        fixture.physics.update(dt);
        assert_recovery_publication(&fixture, &rig, ragdoll);
        fixture.physics.update_cloths();
        GeometryAsset* geometry = fixture.assets.geometry(fixture.scene.get(cloth_node, scene::Mesh).geometry);
        Vec3 pin = maths::transform_point(cloth_node.world, geometry.data.positions[0]);
        b3::BodyId body = fixture.physics.body(ragdoll.bone_nodes[1])!!;
        Vec3 native_joint = body.world_point(ragdoll.joint_in_bone[1].position);

        assert((pin - native_joint).length() <= 0.00002f);

        draw.clear();
        fixture.physics.debug_draw(&draw, { .colliders = true });

        assert(draw.vertices.len() > 0 && draw.dropped == 0);
    }
}

fn void check_recovery_contact_motion(bool wall, bool neighbour) @private {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_rig(&fixture, getup_fixture::CONTACT_JOINT_POSITIONS[..], getup_fixture::CONTACT_PARENTS[..]);
    RagdollBone[1] bones = { bone(0, length: getup_fixture::CONTACT_BONE_LENGTH) };
    bones[0].radius = getup_fixture::CONTACT_BONE_RADIUS;
    bones[0].density = getup_fixture::CONTACT_BONE_DENSITY;
    Ragdoll* ragdoll = build(&fixture, &rig, bones[..]);
    PhysicsBody* authoring = fixture.scene.get(ragdoll.bone_nodes[0], PhysicsBody);
    authoring.colliders[0].local.position = getup_fixture::CONTACT_COM_OFFSET;
    rig.joints[0].local.position = getup_fixture::CONTACT_JOINT_START;
    Node* ground = fixture.scene.add_node(name: "ground")!!;
    ground.local.position = getup_fixture::CONTACT_GROUND_POSITION;
    ColliderDesc floor = physics::default_collider_desc(BOX);
    floor.half_extents = getup_fixture::CONTACT_GROUND_HALF_EXTENTS;
    fixture.scene.add_physics_body(ground, physics::default_body_desc(STATIC), (&floor)[:1])!!;
    Node* obstacle;
    if (wall || neighbour) {
        obstacle = fixture.scene.add_node(name: "obstacle")!!;
        obstacle.local.position = getup_fixture::CONTACT_BOX_POSITION;
        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = wall ? (Vec3){ 0.15f, 0.8f, 2 } : getup_fixture::CONTACT_BOX_HALF_EXTENTS;
        collider.density = getup_fixture::CONTACT_BOX_DENSITY;
        fixture.scene.add_physics_body(
            node: obstacle,
            body: physics::default_body_desc(wall ? STATIC : DYNAMIC),
            colliders: (&collider)[:1],
        )!!;
    }
    fixture.scene.update_world();
    enter_recovery(&fixture, &rig, ragdoll);
    b3::BodyId body = fixture.physics.body(ragdoll.bone_nodes[0])!!;

    assert((body.local_center() - getup_fixture::CONTACT_COM_OFFSET).length() <= TOLERANCE);

    ragdoll.weight = 0;
    float peak_penetration;
    float peak_force;
    float peak_torque;
    float peak_free_error;
    uint contacts;
    float time;
    uint frame;
    bool blocked;
    while (time < getup_fixture::CONTACT_DURATION) {
        float dt =
          getup_fixture::FRAME_MULTIPLIERS[frame++ % getup_fixture::FRAME_MULTIPLIERS.len] * physics::DEFAULT_FIXED_DT;
        time += dt;
        rig.joints[0].local = getup_fixture::sample_contact_target(time, !wall && !neighbour);
        if (frame % 2 == 1) rig.joints[0].local.rotation = -rig.joints[0].local.rotation;
        rig.joints[1].local.position = { 0, 1, 0 };
        rig.joints[2].local.position = { 0, 1, 0 };
        fixture.scene.update_world();
        fixture.physics.update(dt);
        assert_recovery_publication(&fixture, &rig, ragdoll);
        RagdollRecoveryStatus status = ragdoll.recovery_status();

        assert(!status.failure && b3::is_valid_world_transform(body.transform()));
        assert(body.type() == b3::BodyType.DYNAMIC);

        peak_force = math::max(peak_force, status.force);
        peak_torque = math::max(peak_torque, status.torque);
        if (!wall && !neighbour) peak_free_error = math::max(peak_free_error, status.position_error);
        b3::ContactData[16] storage;
        foreach (contact : body.contact_data(storage[..])) {
            foreach (&manifold : contact.contact_manifolds()) {
                foreach (point : manifold.contact_points()) {
                    contacts++;
                    peak_penetration = math::max(peak_penetration, -point.separation);
                }
            }
        }
        if (wall && time > 3 && time < 4) {
            assert(status.phase == RagdollRecoveryPhase.BLOCKED);
            assert(@catch(fixture.physics.finish_ragdoll_recovery(rig.skin)) == physics::RECOVERY_NOT_READY);

            blocked = true;
        }
    }
    assert(peak_force > 0 && peak_force <= 200.0001f && peak_torque <= 20.0001f);
    assert(peak_penetration <= 0.025f);

    if (wall) assert(blocked && contacts > 0);
    if (neighbour) {
        b3::BodyId other = fixture.physics.body(obstacle)!!;
        io::printfn(
            "focused_neighbour,mass_kg,%.6f,displacement,%.9f,contact_samples,%d,force,%.6f,torque,%.6f,penetration,%.9f",
            other.mass(),
            (other.position() - getup_fixture::CONTACT_BOX_POSITION).length(),
            contacts,
            peak_force,
            peak_torque,
            peak_penetration,
        );

        assert(contacts > 0
            && (other.position() - getup_fixture::CONTACT_BOX_POSITION).length() > getup_fixture::CONTACT_RESPONSE_LIMIT);
    }
    if (!wall && !neighbour) assert(peak_free_error <= 0.15f);
    fixture.physics.finish_ragdoll_recovery(rig.skin)!!;
    assert_recovery_publication(&fixture, &rig, ragdoll);
}

fn void test_recovery_offset_com_tracks_free_motion_with_shortest_rotation() @test {
    check_recovery_contact_motion(false, false);
}

fn void test_recovery_wall_blocks_then_allows_retreat_and_completion() @test {
    check_recovery_contact_motion(true, false);
}

fn void test_recovery_moves_a_dynamic_neighbour_with_bounded_actuation() @test {
    check_recovery_contact_motion(false, true);
}

fn void test_recovery_masks_revolute_drive_without_removing_its_limit() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_driven(&fixture, &rig, REVOLUTE);
    PhysicsJoint* authored = fixture.scene.get(ragdoll.bone_nodes[1], PhysicsJoint);
    authored.desc.revolute.angle = { .enabled = true, .lower = -0.3f, .upper = 0.3f };
    enter_recovery(&fixture, &rig, ragdoll);
    b3::RevoluteJointId joint = fixture.physics.joint(ragdoll.bone_nodes[1])!!.as_revolute()!!;
    ragdoll.drive_strength = 0;
    ragdoll.weight = 0;
    rig.joints[1].local.rotation = about({ 1, 0, 0 }, 70);
    fixture.scene.update_world();
    fixture.physics.update(physics::DEFAULT_FIXED_DT);

    assert(!joint.is_spring_enabled() && joint.is_limit_enabled());
    assert(ragdoll.recovery_status().torque > 0 && ragdoll.recovery_status().torque <= 20.0001f);

    ragdoll.bone_drives[1] = { .enabled = false, .hertz = 2, .damping_ratio = 0.6f };
    ragdoll.drive_strength = 3;
    fixture.physics.set_bone_mode(rig.skin, 1, ANIMATED);

    assert(!joint.is_spring_enabled() && joint.is_limit_enabled());
    assert(math::abs(joint.spring_hertz() - 6) <= TOLERANCE);
    assert(math::abs(joint.spring_damping_ratio() - 0.6f) <= TOLERANCE);
}

fn void test_nonparticipant_spring_controls_survive_recovery_updates() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_driven(&fixture, &rig, SPHERICAL);
    fixture.physics.update(0);
    fixture.physics.set_bone_mode(rig.skin, 0, SIMULATED);
    ragdoll.weight = 1;
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    fixture.physics.recover_bones(rig.skin)!!;
    fixture.physics.set_bone_mode(rig.skin, 1, SIMULATED);
    ragdoll.drive_strength = 1;
    Node* child = ragdoll.bone_nodes[1];
    PhysicsJoint* authored = fixture.scene.get(child, PhysicsJoint);
    authored.desc.spherical.spring.enabled = false;
    authored.desc.spherical.spring.damping_ratio = 0.25f;
    fixture.physics.apply_joint(child);
    fixture.physics.update(0);
    b3::SphericalJointId joint = fixture.physics.joint(child)!!.as_spherical()!!;

    assert(!joint.is_spring_enabled());
    assert(math::abs(joint.spring_damping_ratio() - 0.25f) <= TOLERANCE);
    assert(math::abs(joint.spring_hertz() - SPRING_HERTZ) <= TOLERANCE);
    assert(ragdoll.recovery_status().participating == 1);
}

fn void test_nonparticipant_weight_edits_keep_ordinary_publication() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    fixture.physics.update(0);
    fixture.physics.set_bone_mode(rig.skin, 0, SIMULATED);
    ragdoll.weight = 1;
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    fixture.physics.recover_bones(rig.skin)!!;
    fixture.physics.set_bone_mode(rig.skin, 1, SIMULATED);
    ragdoll.bone_weights[1] = 0;
    rig.joints[1].local.position.x = 0.2f;
    fixture.scene.update_world();
    fixture.physics.update(0);
    ragdoll.bone_weights[1] = 1;
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    b3::BodyId body = fixture.physics.body(ragdoll.bone_nodes[1])!!;
    Vec3 expected = body.world_point(ragdoll.joint_in_bone[1].position);

    assert(close_vec(world_position(rig.joints[1]), expected));

    fixture.physics.update_ragdolls();
    fixture.scene.update_world();

    assert(close_vec(world_position(rig.joints[1]), expected));
}
