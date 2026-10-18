module c3d_physics_roles_test;

import std::math;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;

const float BONE_RADIUS @private = 0.1f;

struct Fixture @private {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    GeometryId   unit_cube;
}

struct Rig @private {
    Node*   skin;
    Node*[] joints;
}

fn void create_world(Fixture* fixture) @private {
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      physics::default_physics_desc(),
    )!!;
}

fn void setup(Fixture* fixture) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, { .max_nodes = 64 });
    physics::register_physics(&fixture.scene)!!;
    create_world(fixture);
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width:     1,
            height:    1,
            depth:     1,
        );
        fixture.unit_cube = fixture.assets.add_geometry(&box, "unit_cube")!!;
    };
}

fn void teardown(Fixture* fixture) @private {
    if (fixture.physics.scene) physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node* add_body(Fixture* fixture, BodyKind kind, Vec3 position) @private {
    Node* node = fixture.scene.add_node(null, "body")!!;
    node.local.position = position;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = { 0.5f, 0.5f, 0.5f };
    fixture.physics.add_body(node, physics::default_body_desc(kind), (&collider)[:1])!!;
    return node;
}

fn Rig add_two_bone_ragdoll(Fixture* fixture, Vec3 origin) @private {
    Vec3[3] positions = { { 0, 0, 0 }, { 0, 1, 0 }, { 0, 2, 0 } };
    int[3] parents = { -1, 0, 1 };
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(mem, String, positions.len),
        .parents      = alloc::new_array(mem, int, positions.len),
        .rest_pose    = alloc::new_array(mem, maths::Transform, positions.len),
        .inverse_bind = alloc::new_array(mem, Mat4, positions.len),
    };
    skeleton.parents[..] = parents[..];
    foreach (index, position : positions) {
        maths::Transform unbind = maths::TRANSFORM_IDENTITY;
        unbind.position = -position;
        skeleton.inverse_bind[index] = unbind.to_mat4();
        skeleton.rest_pose[index] = maths::TRANSFORM_IDENTITY;
    }
    SkeletonId skeleton_id = fixture.assets.add_skeleton_owned(&skeleton)!!;

    Rig rig = { .joints = alloc::new_array(fixture.scene.allocator, Node*, positions.len) };
    Node* character = fixture.scene.add_node(name: "character")!!;
    character.local.position = origin;
    rig.skin = fixture.scene.add_node(character, "skin")!!;
    foreach (index, position : positions) {
        Node* parent = parents[index] < 0 ? character : rig.joints[parents[index]];
        Node* joint = fixture.scene.add_node(parent, "joint")!!;
        joint.local.position = parents[index] < 0 ? position : position - positions[parents[index]];
        rig.joints[index] = joint;
    }
    fixture.scene.add(rig.skin, (SkinBinding){ .skeleton = skeleton_id, .joints = rig.joints });
    fixture.scene.update_world();

    RagdollBone[2] bones = { physics::default_ragdoll_bone(0), physics::default_ragdoll_bone(1) };
    foreach (&bone : bones) bone.radius = BONE_RADIUS;
    bones[1].length = 1;
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones[..];
    fixture.scene.build_ragdoll(&fixture.assets, rig.skin, desc)!!;
    fixture.scene.update_world();
    return rig;
}

fn Node* add_wall(Fixture* fixture, Vec3 position) @private {
    Node* root = fixture.scene.add_node(null, "wall")!!;
    for (uint index = 0; index < 2; index++) {
        Node* piece = fixture.scene.add_mesh(
            geometry: fixture.unit_cube,
            material: {},
            parent:   root,
            name:     "piece",
        )!!;
        piece.local.position = { (float)index, 0, 0 };
    }
    root.local.position = position;
    fixture.scene.update_world();
    return root;
}

fn void assert_moving_list_is_exact(Fixture* fixture) @private {
    uint expected;
    fixture.scene.@each(RigidBody; Entity entity, RigidBody* body) {
        if (body.kind != STATIC) expected++;
    };
    Entity[] moving = fixture.physics.roles.moving_bodies();
    assert(moving.len == expected);

    foreach (index, entity : moving) {
        assert(fixture.scene.world.is_alive(entity));
        RigidBody* body = fixture.scene.world.get(entity, RigidBody);
        assert(body != null && body.kind != STATIC);
        assert(body.moving_index == index);
    }
}

fn void test_moving_list_tracks_kinds_and_lifecycles() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    add_body(&fixture, STATIC, { 0, -5, 0 });
    Node* dynamic = add_body(&fixture, DYNAMIC, { 0, 0, 0 });
    Node* kinematic = add_body(&fixture, KINEMATIC, { 4, 0, 0 });
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 2);

    Rig rig = add_two_bone_ragdoll(&fixture, { 10, 0, 0 });
    fixture.physics.update(0);
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 4);

    fixture.physics.set_ragdoll_mode(rig.skin, SIMULATED);
    assert_moving_list_is_exact(&fixture);
    fixture.physics.set_bone_mode(rig.skin, 1, ANIMATED);
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 4);

    fixture.scene.get(dynamic, PhysicsBody).mark_changed();
    fixture.physics.update(0);
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 4);

    fixture.scene.get(dynamic, PhysicsBody).body.kind = STATIC;
    fixture.scene.get(dynamic, PhysicsBody).mark_changed();
    fixture.physics.update(0);
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 3);

    fixture.scene.get(dynamic, PhysicsBody).body.kind = KINEMATIC;
    fixture.scene.get(dynamic, PhysicsBody).mark_changed();
    fixture.physics.update(0);
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 4);

    Entity removed = kinematic.id;
    fixture.scene.remove(kinematic);
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 3);

    Node* reused = add_body(&fixture, DYNAMIC, { 4, 0, 0 });
    assert(reused.id.index == removed.index && reused.id.generation != removed.generation);
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 4);

    Node* wall = add_wall(&fixture, { 20, 10, 0 });
    fixture.physics.add_breakable(wall, physics::default_breakable_desc())!!;
    assert_moving_list_is_exact(&fixture);
    assert(fixture.scene.get(wall, RigidBody).kind == KINEMATIC);

    fixture.physics.wake_breakable(wall)!!;
    assert_moving_list_is_exact(&fixture);
    assert(!fixture.scene.has(wall, RigidBody));

    fixture.physics.reset_breakable(wall, ASSEMBLY)!!;
    assert_moving_list_is_exact(&fixture);
    assert(fixture.scene.get(wall, RigidBody).kind == KINEMATIC);

    fixture.physics.reset_breakable(wall, PIECES)!!;
    assert_moving_list_is_exact(&fixture);
    assert(!fixture.scene.has(wall, RigidBody));

    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    assert_moving_list_is_exact(&fixture);
}

fn void test_world_rebuild_restores_the_moving_list() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    add_body(&fixture, STATIC, { 0, -5, 0 });
    add_body(&fixture, DYNAMIC, { 0, 0, 0 });
    Node* kinematic = add_body(&fixture, KINEMATIC, { 4, 0, 0 });
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 2);

    physics::destroy_physics_world(&fixture.physics);
    assert(fixture.scene.world.count(RigidBody) == 0);

    create_world(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 0);
    fixture.physics.update(0);
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 2);

    fixture.scene.remove(kinematic);
    assert_moving_list_is_exact(&fixture);
    assert(fixture.physics.roles.moving_bodies().len == 1);
}
