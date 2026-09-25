module c3d_physics_ragdoll_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::ecs;
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

fn fault build_fault(Fixture* fixture, Rig* rig, RagdollBone[] bones) @private {
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones;
    return @catch(fixture.scene.build_ragdoll(&fixture.assets, rig.skin, desc));
}

fn Vec3 world_position(Node* node) @private => maths::translation(node.world);

fn bool close_vec(Vec3 first, Vec3 second) @private => (first - second).length() <= TOLERANCE;

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
    fixture.physics.recover_ragdoll(rig.skin, rig.character);
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
    assert(ragdoll.mode == ANIMATED);
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    foreach (index, joint : rig.joints) assert(close_vec(world_position(joint), recorded[index]));
}

fn void test_blend_from_frozen_is_halfway_at_half_weight() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Rig rig = add_chain(&fixture);
    Ragdoll* ragdoll = build_two_bones(&fixture, &rig);
    Vec3[3] recorded;
    fall_and_recover(&fixture, &rig, ragdoll, recorded[..]);

    Vec3 animated = { 0, 1, 0 };
    rig.joints[0].local.position = {};
    rig.joints[1].local.position = animated;
    ragdoll.weight = 0.5f;
    fixture.physics.update_ragdolls();
    assert(close_vec(rig.joints[1].local.position, (animated + ragdoll.frozen[1].position) * 0.5f));
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
