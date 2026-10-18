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
import b3;

const float BONE_RADIUS @private = 0.1f;
const uint  SETTLE_UPDATES @private = 120;

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

fn PhysicsDesc weightless_desc() @private {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    return desc;
}

fn void create_world(Fixture* fixture, PhysicsDesc desc = physics::default_physics_desc()) @private {
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      desc,
    )!!;
}

fn void setup(Fixture* fixture, PhysicsDesc desc = physics::default_physics_desc()) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, { .max_nodes = 64 });
    physics::register_physics(&fixture.scene)!!;
    create_world(fixture, desc);
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

// Pieces are added right to left because children prepend, so the subtree walk reads them in the order given.
fn Node* add_wall(Fixture* fixture, Vec3 position, float[] offsets) @private {
    Node* root = fixture.scene.add_node(null, "wall")!!;
    for (usz index = offsets.len; index-- > 0;) {
        Node* piece = fixture.scene.add_mesh(
            geometry: fixture.unit_cube,
            material: {},
            parent:   root,
            name:     "piece",
        )!!;
        piece.local.position = { offsets[index], 0, 0 };
    }
    root.local.position = position;
    fixture.scene.update_world();
    return root;
}

fn void step(Fixture* fixture) @private {
    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    fixture.scene.update_world();
}

fn BreakableRecipeDesc anchored_recipe(Fixture* fixture, Node* root, Node* target) @private {
    maths::Transform toward_next = {
        .position = { 0.5f, 0, 0 },
        .rotation = maths::TRANSFORM_IDENTITY.rotation,
        .scale    = { 1, 1, 1 },
    };
    maths::Transform toward_previous = toward_next;
    toward_previous.position.x = -0.5f;

    BreakableRecipeDesc recipe = physics::default_breakable_recipe_desc();
    recipe.settings.sleep_until_hit = false;
    recipe.settings.density = 1;
    recipe.strength = physics::default_breakable_strength(float::max);
    recipe.pieces = alloc::new_array(tmem, BreakablePieceView, 2);
    Node* node = root.first_child;
    foreach (&piece : recipe.pieces) {
        GeometryId[] hulls = alloc::new_array(tmem, GeometryId, 1);
        hulls[0] = fixture.unit_cube;
        *piece = { .node = node.id, .hulls = hulls, .rest_frame = node.local };
        node = node.next_sibling;
    }
    recipe.welds = alloc::new_array(tmem, BreakableWeldDesc, 1);
    recipe.welds[0] = {
        .piece_a     = 0,
        .piece_b     = 1,
        .frame_a     = toward_next,
        .frame_b     = toward_previous,
        .moment_axis = { 1, 0, 0 },
    };
    recipe.anchors = alloc::new_array(tmem, BreakableAnchorDesc, 2);
    foreach (&anchor : recipe.anchors) {
        *anchor = {
            .piece       = 0,
            .target      = target.id,
            .frame_a     = toward_previous,
            .frame_b     = toward_next,
            .moment_axis = { 1, 0, 0 },
        };
    }
    recipe.anchors[1].has_strength_override = true;
    recipe.anchors[1].strength_override = physics::default_breakable_strength(0);
    return recipe;
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

    float[2] offsets = { 0, 1 };
    Node* wall = add_wall(&fixture, { 20, 10, 0 }, offsets[..]);
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

fn void test_orphaned_body_is_removed_on_the_next_update() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* kept = add_body(&fixture, DYNAMIC, { 0, 0, 0 });
    Node* orphan = add_body(&fixture, STATIC, { 0, -5, 0 });
    fixture.scene.remove_component(orphan, PhysicsBody);
    assert(fixture.scene.has(orphan, RigidBody));
    assert(fixture.physics.roles.orphans_dirty);

    fixture.physics.update(0);
    assert(!fixture.scene.has(orphan, RigidBody));
    assert(fixture.scene.has(kept, RigidBody));
    assert(fixture.physics.world.counters().body_count == 1);
    assert(!fixture.physics.roles.orphans_dirty);

    physics::destroy_physics_world(&fixture.physics);
    create_world(&fixture);
    fixture.physics.update(0);
    assert(fixture.scene.has(kept, RigidBody));

    Node* moving_orphan = add_body(&fixture, DYNAMIC, { 4, 0, 0 });
    fixture.scene.remove_component(moving_orphan, PhysicsBody);
    assert(fixture.physics.roles.orphans_dirty);

    fixture.physics.update(0);
    assert(!fixture.scene.has(moving_orphan, RigidBody));
    assert(fixture.scene.has(kept, RigidBody));
    assert(fixture.physics.world.counters().body_count == 1);
    assert_moving_list_is_exact(&fixture);
}

fn void test_weld_events_map_directly_and_reject_stale_joints() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);

        float[4] row = { 0, 1, 5, 6 };
        Node* loose = add_wall(&fixture, {}, row[..]);
        BreakableDesc desc = physics::default_breakable_desc();
        desc.sleep_until_hit = false;
        desc.density = 1;
        desc.break_force = 0.01f;
        fixture.physics.add_breakable(loose, desc)!!;
        BreakableState* welded = fixture.scene.get(loose, Breakable).state;
        assert(welded.welds.len == 2);

        float[2] pair = { 0, 1 };
        Node* supported_wall = add_wall(&fixture, { 0, 10, 0 }, pair[..]);
        Node* support = add_body(&fixture, STATIC, { -1, 10, 0 });
        fixture.physics.add_breakable_recipe(supported_wall, anchored_recipe(&fixture, supported_wall, support))!!;
        BreakableState* supported = fixture.scene.get(supported_wall, Breakable).state;
        assert(supported.anchor_count() == 2);

        b3::JointId old_weld = welded.welds[1].joint;
        b3::JointId old_anchor = supported.runtime.anchors[1].joint;
        step(&fixture);
        assert(supported.runtime.anchors[1].broken && !supported.runtime.anchors[0].broken);
        BreakEvent[] events = fixture.physics.breaks();
        assert(events.len == 1);
        assert(events[0].edge_kind == ANCHOR && events[0].edge_index == 1);
        assert(c3d::same_id(events[0].root_id, supported_wall.id));

        Node* last = fixture.scene.node(welded.pieces[3]);
        fixture.physics.apply_impulse(last, { 12, 0, 0 }, last.world_position());
        uint waited;
        while (!welded.welds[1].broken && waited++ < SETTLE_UPDATES) step(&fixture);
        assert(welded.welds[1].broken && !welded.welds[0].broken);
        events = fixture.physics.breaks();
        assert(events.len == 1);
        assert(events[0].edge_kind == INTERNAL_WELD && events[0].edge_index == 1);
        assert(c3d::same_id(events[0].endpoint_a, welded.pieces[2]));
        assert(c3d::same_id(events[0].endpoint_b, welded.pieces[3]));

        fixture.physics.reset_breakable(loose, PIECES)!!;
        fixture.physics.reset_breakable(supported_wall, PIECES)!!;
        foreach (weld : welded.welds) assert(!physics::same_breakable_joint(old_weld, weld.joint));
        foreach (anchor : supported.runtime.anchors) assert(!physics::same_breakable_joint(old_anchor, anchor.joint));

        uint reported = fixture.physics.breaks().len;
        assert(!physics::breakable_joint_event(&fixture.physics, loose, old_weld));
        assert(!physics::breakable_joint_event(&fixture.physics, supported_wall, old_anchor));
        assert(fixture.physics.breaks().len == reported);
        assert(welded.alive_welds == 2 && supported.alive_anchors == 2);

        physics::destroy_physics_world(&fixture.physics);
        create_world(&fixture, weightless_desc());
        fixture.physics.update(0);
        assert(welded.welds[1].joint.is_valid() && supported.runtime.anchors[1].joint.is_valid());

        assert(physics::breakable_joint_event(&fixture.physics, loose, welded.welds[1].joint));
        assert(physics::breakable_joint_event(&fixture.physics, supported_wall, supported.runtime.anchors[1].joint));
        events = fixture.physics.breaks();
        assert(events.len == 2);
        assert(events[0].edge_kind == INTERNAL_WELD && events[0].edge_index == 1);
        assert(events[1].edge_kind == ANCHOR && events[1].edge_index == 1);
        assert(welded.welds[1].broken && !welded.welds[0].broken);
        assert(supported.runtime.anchors[1].broken && !supported.runtime.anchors[0].broken);
    };
}
