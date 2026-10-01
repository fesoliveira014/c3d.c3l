module c3d_physics_breakable_test;

import std::math;
import std::core::mem;
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::physics;
import c3d::scene;
import b3;

const float LOOSE_TOLERANCE @private = 0.05f;  // solver slack, not agreement to the bit
const uint  SETTLE_UPDATES @private = 120;

struct Fixture @private {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    GeometryId   unit_cube;
}

fn void create_world(Fixture* fixture, PhysicsDesc desc) @private {
    fixture.physics = physics::create_physics_world(
        allocator: fixture.scene.allocator,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      desc,
    )!!;
}

fn void setup(
    Fixture* fixture,
    PhysicsDesc desc = physics::default_physics_desc(),
    Allocator allocator = mem,
) @private {
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(allocator, { .max_nodes = 64 });
    desc.tuning.interpolate = false;
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

fn PhysicsDesc weightless_desc() @private {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    desc.tuning.interpolate = false;
    return desc;
}

fn Node* add_piece(Fixture* fixture, Node* root, Vec3 position) @private {
    Node* node = fixture.scene.add_mesh(
        geometry: fixture.unit_cube,
        material: {},
        parent:   root,
        name:     "piece",
    )!!;
    node.local.position = position;
    return node;
}

fn Node* add_row(Fixture* fixture, uint count) @private {
    Node* root = fixture.scene.add_node(null, "wall")!!;
    // Children prepend on insertion, so pieces are added right to left; the subtree walk then reads ascending in x.
    for (uint index = 0; index < count; index++) {
        add_piece(fixture, root, { (float)(count - 1 - index), 0, 0 });
    }
    fixture.scene.update_world();
    assert(root.first_child.local.position.x == 0);
    return root;
}

fn Node* add_static_box(Fixture* fixture, Vec3 position, Vec3 half_extents) @private {
    Node* node = fixture.scene.add_node(null, "ground")!!;
    node.local.position = position;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = half_extents;
    fixture.physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    return node;
}

fn Node* add_visitor(Fixture* fixture, Vec3 position, float density) @private {
    Node* node = fixture.scene.add_node(null, "visitor")!!;
    node.local.position = position;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = { 0.5f, 0.5f, 0.5f };
    collider.density = density;
    collider.hit_events = true;
    collider.material.friction = 0;
    fixture.physics.add_body(node, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;
    return node;
}

fn void step(Fixture* fixture, uint updates) @private {
    for (uint index = 0; index < updates; index++) {
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.scene.update_world();
    }
}

fn void assert_snapshot_holders_match(Fixture* fixture) @private {
    foreach (index, &slot : fixture.physics.snapshots.slots) {
        uint holders;
        fixture.scene.@each(RigidBody; entity, body) {
            foreach (&collider : body.colliders) {
                if (collider.snapshot.generation && collider.snapshot.index == index) holders++;
            }
        };
        assert(holders == slot.holders);
    }
}

fn void test_contact_graph_welds_touching_pieces_and_skips_distant_ones() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* root = fixture.scene.add_node(null, "wall")!!;
    // Children prepend: added right to left, so the walk order below is x = 0, 1, 2, 5.
    add_piece(&fixture, root, { 5, 0, 0 });
    add_piece(&fixture, root, { 2, 0, 0 });
    add_piece(&fixture, root, { 1, 0, 0 });
    add_piece(&fixture, root, {});
    fixture.scene.update_world();

    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    fixture.physics.add_breakable(root, desc)!!;

    BreakableState* breakable = fixture.scene.get(root, Breakable).state;
    assert(breakable.pieces.len == 4);
    assert(fixture.scene.node(breakable.pieces[0]).local.position.x == 0);
    assert(fixture.scene.node(breakable.pieces[3]).local.position.x == 5);
    assert(breakable.welds.len == 2);
    assert(breakable.alive_welds == 2);
    assert(breakable.form == PIECES);
    assert(breakable.welds[0].piece_a == 0 && breakable.welds[0].piece_b == 1);
    assert(breakable.welds[1].piece_a == 1 && breakable.welds[1].piece_b == 2);
    assert(fixture.physics.world.counters().joint_count == 2);
}

fn void test_add_breakable_rejects_one_piece_and_a_second_breakable() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* root = fixture.scene.add_node(null, "wall")!!;
    add_piece(&fixture, root, {});
    fixture.scene.update_world();
    assert(@catch(fixture.physics.add_breakable(root, physics::default_breakable_desc())) == c3d::INVALID_ARGUMENT);
    assert(!fixture.scene.has(root, Breakable));

    add_piece(&fixture, root, { 1, 0, 0 });
    fixture.scene.update_world();
    fixture.physics.add_breakable(root, physics::default_breakable_desc())!!;
    assert(fixture.scene.get(root, Breakable).state.welds.len == 1);
    assert(@catch(fixture.physics.add_breakable(root, physics::default_breakable_desc())) == physics::BREAKABLE_EXISTS);
    assert(fixture.scene.get(root, Breakable).state.welds.len == 1);
}

fn void test_load_below_break_force_keeps_every_weld() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* root = add_row(&fixture, 2);
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    desc.density = 1;
    desc.break_force = 1e6f;
    fixture.physics.add_breakable(root, desc)!!;

    BreakableState* breakable = fixture.scene.get(root, Breakable).state;
    Node* first = fixture.scene.node(breakable.pieces[0]);
    Node* second = fixture.scene.node(breakable.pieces[1]);
    fixture.physics.apply_impulse(first, { 10, 0, 0 }, first.world_position());
    for (uint update = 0; update < 10; update++) {
        step(&fixture, 1);
        assert(fixture.physics.breaks().len == 0);
    }
    assert(breakable.alive_welds == 1);
    Vec3 offset = second.world_position() - first.world_position();
    assert((offset - (Vec3){ 1, 0, 0 }).length() < LOOSE_TOLERANCE);
}

fn void test_threshold_breaks_once_reports_anchor_and_releases_pieces() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* root = add_row(&fixture, 2);
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    desc.density = 1;
    desc.break_force = 0.01f;
    fixture.physics.add_breakable(root, desc)!!;
    BreakableState* state = fixture.scene.get(root, Breakable).state;
    Weld* weld = &state.welds[0];
    Node* first = fixture.scene.node(state.pieces[weld.piece_a]);
    Node* second = fixture.scene.node(state.pieces[weld.piece_b]);
    fixture.physics.apply_impulse(first, { -12, 0, 0 }, first.world_position());

    uint waited;
    while (!fixture.physics.breaks().len && waited++ < SETTLE_UPDATES) step(&fixture, 1);
    BreakEvent[] events = fixture.physics.breaks();
    assert(events.len == 1);
    assert(events[0].root == root && events[0].piece_a == first && events[0].piece_b == second);
    b3::BodyId body = fixture.physics.body(first)!!;
    Vec3 expected = body.world_point(weld.anchor);
    assert((events[0].point - expected).length() < 1e-4f);
    assert(weld.broken && !weld.joint.is_valid());
    assert(state.alive_welds == 0);

    step(&fixture, 2);
    assert(fixture.physics.breaks().len == 0);

    Vec3 before = second.world_position() - first.world_position();
    fixture.physics.apply_impulse(first, { -20, 0, 0 }, first.world_position());
    step(&fixture, 10);
    Vec3 after = second.world_position() - first.world_position();
    assert((after - before).length() > 0.2f);
    assert(fixture.physics.world.counters().joint_count == 0);
}


fn void test_sleep_until_hit_keeps_one_kinematic_body_until_a_qualifying_hit() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* root = add_row(&fixture, 2);
    BreakableDesc desc = physics::default_breakable_desc();
    desc.density = 1;
    desc.break_force = 100;
    desc.material.friction = 0;
    fixture.physics.add_breakable(root, desc)!!;

    BreakableState* breakable = fixture.scene.get(root, Breakable).state;
    assert(breakable.form == ASSEMBLY);
    RigidBody* assembly = fixture.scene.get(root, RigidBody);
    assert(assembly.kind == KINEMATIC);
    assert(assembly.colliders.len == 2);
    foreach (entity : breakable.pieces) {
        assert(!fixture.scene.has(fixture.scene.node(entity), PhysicsBody));
    }
    assert(fixture.physics.world.counters().body_count == 1);
    assert(breakable.alive_welds == 1);

    Node* visitor = add_visitor(&fixture, { -1.05f, 0, 0 }, 1);
    fixture.physics.set_velocity(visitor, { 20, 3, 0 }, {});
    uint waited;
    while (breakable.form == ASSEMBLY && waited < SETTLE_UPDATES) {
        step(&fixture, 1);
        waited++;
    }
    assert(breakable.form == PIECES);
    assert(waited < SETTLE_UPDATES);
    assert(!fixture.scene.has(root, RigidBody));
    foreach (entity : breakable.pieces) {
        assert(fixture.scene.get(fixture.scene.node(entity), RigidBody).kind == DYNAMIC);
    }
    assert(breakable.alive_welds == 1);
    assert(fixture.physics.breaks().len == 0);
    b3::BodyId visitor_body = fixture.physics.body(visitor)!!;
    assert(math::abs(visitor_body.linear_velocity().y - 3) < 0.02f);

    waited = 0;
    while (fixture.physics.breaks().len == 0 && waited < SETTLE_UPDATES) {
        step(&fixture, 1);
        waited++;
    }
    assert(fixture.physics.breaks().len == 1);
    assert(waited < SETTLE_UPDATES);
}

fn void test_slow_hit_leaves_the_assembly_asleep() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* root = add_row(&fixture, 2);
    BreakableDesc desc = physics::default_breakable_desc();
    desc.density = 1;
    desc.break_force = 1000;
    fixture.physics.add_breakable(root, desc)!!;

    BreakableState* breakable = fixture.scene.get(root, Breakable).state;
    Node* visitor = add_visitor(&fixture, { -1.05f, 0, 0 }, 1);
    fixture.physics.set_velocity(visitor, { 1.5f, 0, 0 }, {});
    bool saw_hit;
    for (uint frame = 0; frame < 30; frame++) {
        step(&fixture, 1);
        saw_hit |= fixture.physics.hits().len > 0;
    }
    assert(saw_hit);

    assert(breakable.form == ASSEMBLY);
    assert(breakable.alive_welds == 1);
    assert(fixture.physics.world.counters().body_count == 2);
}

fn void test_manual_wake_keeps_poses_motion_and_is_idempotent() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* root = add_row(&fixture, 2);
    fixture.physics.add_breakable(root, physics::default_breakable_desc())!!;

    BreakableState* breakable = fixture.scene.get(root, Breakable).state;
    assert(breakable.form == ASSEMBLY);

    fixture.physics.set_velocity(root, { 2, 0, 1 }, { 0, 2, 0 });
    root.local.position = { 3, 0, 0 };
    fixture.scene.update_world();
    fixture.physics.wake_breakable(root)!!;
    assert(breakable.form == PIECES);
    assert(fixture.scene.node(breakable.pieces[0]).transform_space == TransformSpace.WORLD);
    assert((fixture.scene.node(breakable.pieces[0]).local.position - (Vec3){ 3, 0, 0 }).length() < LOOSE_TOLERANCE);
    assert(!fixture.scene.has(root, PhysicsBody));
    assert(fixture.physics.world.counters().body_count == 2);
    assert(fixture.physics.world.counters().joint_count == 1);
    foreach (entity : breakable.pieces) {
        assert(fixture.scene.get(fixture.scene.node(entity), RigidBody).kind == DYNAMIC);
    }

    Vec3[2] expected = { { 2, 0, 1 }, { 2, 0, -1 } };
    foreach (index, entity : breakable.pieces) {
        b3::BodyId body = fixture.physics.body(fixture.scene.node(entity))!!;
        assert((body.linear_velocity() - expected[index]).length() < 1e-4f);
        assert((body.angular_velocity() - (Vec3){ 0, 2, 0 }).length() < 1e-4f);
    }

    fixture.physics.wake_breakable(root)!!;
    assert(fixture.physics.world.counters().body_count == 2);
    assert(fixture.physics.world.counters().joint_count == 1);
}

fn void test_removed_piece_drops_its_welds_from_the_count() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* root = add_row(&fixture, 3);
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    fixture.physics.add_breakable(root, desc)!!;

    BreakableState* breakable = fixture.scene.get(root, Breakable).state;
    Node* third = fixture.scene.node(breakable.pieces[2]);
    fixture.scene.remove_later(third);
    fixture.scene.flush_removals();
    fixture.physics.update(0);

    assert(breakable.alive_welds == 1);
    assert(!breakable.welds[0].broken);
    assert(breakable.welds[1].broken);
    assert(fixture.physics.breaks().len == 0);
    assert(fixture.physics.world.counters().joint_count == 1);

    Node* assembly_root = add_row(&fixture, 2);
    fixture.physics.add_breakable(assembly_root, physics::default_breakable_desc())!!;
    BreakableState* assembly = fixture.scene.get(assembly_root, Breakable).state;
    Node* dropped = fixture.scene.node(assembly.pieces[1]);
    fixture.scene.remove_later(dropped);
    fixture.scene.flush_removals();
    fixture.physics.update(0);

    assert(assembly.form == ASSEMBLY);
    assert(assembly.welds[0].broken);
    assert(assembly.alive_welds == 0 && assembly.alive_pieces == 1);
    b3::BodyId assembly_body = fixture.physics.body(assembly_root)!!;
    assert(assembly_body.shape_count() == 1);
    assert(fixture.scene.get(assembly_root, PhysicsBody).colliders.len == 1);
    assert(fixture.scene.get(assembly_root, RigidBody).colliders.len == 1);
    assert_snapshot_holders_match(&fixture);

    physics::destroy_physics_world(&fixture.physics);
    create_world(&fixture, weightless_desc());
    fixture.physics.update(0);
    assembly_body = fixture.physics.body(assembly_root)!!;
    assert(assembly_body.shape_count() == 1);
    fixture.physics.wake_breakable(assembly_root)!!;
    assert(assembly.form == PIECES && assembly.alive_pieces == 1);
    assert_snapshot_holders_match(&fixture);
}

fn void test_new_world_rebinds_unbroken_welds_only() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* root = fixture.scene.add_node(null, "wall")!!;
    add_piece(&fixture, root, { 6, 0, 0 });
    add_piece(&fixture, root, { 5, 0, 0 });
    add_piece(&fixture, root, { 1, 0, 0 });
    Node* first = add_piece(&fixture, root, {});
    fixture.scene.update_world();
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    desc.density = 1;
    desc.break_force = 0.01f;
    fixture.physics.add_breakable(root, desc)!!;
    BreakableState* state = fixture.scene.get(root, Breakable).state;
    assert(state.welds.len == 2);
    fixture.physics.apply_impulse(first, { -12, 0, 0 }, first.world_position());
    uint waited;
    while (state.alive_welds == 2 && waited++ < SETTLE_UPDATES) step(&fixture, 1);
    assert(state.alive_welds == 1);

    physics::destroy_physics_world(&fixture.physics);
    assert(state.status == PENDING);
    foreach (weld : state.welds) assert(!weld.joint.is_valid());
    create_world(&fixture, weightless_desc());
    fixture.physics.update(0);

    assert(state.status == LIVE && state.alive_welds == 1);
    uint broken;
    foreach (weld : state.welds) {
        if (weld.broken) broken++;
        assert(weld.broken ? !weld.joint.is_valid() : weld.joint.is_valid());
    }
    assert(broken == 1);
    assert(fixture.physics.world.counters().body_count == 4);
    assert(fixture.physics.world.counters().joint_count == 1);
    foreach (entity : state.pieces) {
        b3::BodyId body = fixture.physics.body(fixture.scene.node(entity))!!;
        assert(body.is_enabled());
    }
}

fn void test_removing_the_root_removes_pieces_and_welds() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* root = add_row(&fixture, 4);
    add_static_box(&fixture, { 1.5f, -1, 0 }, { 3, 0.5f, 1 });
    fixture.scene.update_world();
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    fixture.physics.add_breakable(root, desc)!!;
    step(&fixture, 5);
    assert_snapshot_holders_match(&fixture);

    fixture.scene.remove(root);

    assert(fixture.scene.count(Breakable) == 0);
    assert(fixture.scene.count(PhysicsBody) == 1);
    assert(fixture.scene.count(RigidBody) == 1);
    assert(fixture.physics.world.counters().body_count == 1);
    assert(fixture.physics.world.counters().joint_count == 0);
    assert_snapshot_holders_match(&fixture);
}

fn void test_remove_breakable_leaves_meshes_and_nodes() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* root = add_row(&fixture, 2);
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    fixture.physics.add_breakable(root, desc)!!;

    BreakableState* breakable = fixture.scene.get(root, Breakable).state;
    Node* first = fixture.scene.node(breakable.pieces[0]);
    Node* second = fixture.scene.node(breakable.pieces[1]);
    fixture.physics.remove_breakable(root);

    assert(fixture.physics.world.counters().joint_count == 0);
    assert(fixture.scene.count(Breakable) == 0);
    assert(fixture.scene.count(PhysicsBody) == 0);
    assert(fixture.scene.count(RigidBody) == 0);
    assert(fixture.scene.world.is_alive(first.id));
    assert(fixture.scene.has(first, scene::Mesh));
    assert(fixture.scene.world.is_alive(second.id));
    assert(fixture.scene.has(second, scene::Mesh));
}

fn void test_nested_pieces_keep_exact_world_poses_under_motion() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* root = fixture.scene.add_node(null, "wall")!!;
    Node* outer = add_piece(&fixture, root, {});
    Node* inner = add_piece(&fixture, outer, { 0, 1, 0 });
    outer.local.scale.x = 1.000001f;
    fixture.scene.update_world();

    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    desc.density = 1;
    desc.break_force = float::max;
    fixture.physics.add_breakable(root, desc)!!;

    BreakableState* breakable = fixture.scene.get(root, Breakable).state;
    assert(breakable.pieces.len == 2);
    assert(breakable.welds.len == 1);
    assert(outer.transform_space == TransformSpace.WORLD);
    assert(inner.transform_space == TransformSpace.WORLD);
    assert(outer.local.scale.x == 1);
    assert(inner.local.scale.x == 1);

    fixture.physics.apply_impulse(outer, { 5, 0, 0 }, outer.world_position());
    for (uint update = 0; update < 20; update++) {
        step(&fixture, 1);
        b3::BodyId outer_body = fixture.physics.body(outer)!!;
        b3::BodyId inner_body = fixture.physics.body(inner)!!;
        assert((outer.world_position() - (Vec3)outer_body.position()).length() < 1e-4f);
        assert((inner.world_position() - (Vec3)inner_body.position()).length() < 1e-4f);
        Vec3 offset = outer_body.local_point(inner_body.position());
        assert((offset - (Vec3){ 0, 1, 0 }).length() < LOOSE_TOLERANCE);
    }
}

fn void test_late_failed_wake_preserves_the_assembly_and_releases_staged_holds() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    GeometryId second_geometry;
    @pool() {
        Geometry cube = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        second_geometry = fixture.assets.add_geometry(&cube, "second_cube")!!;
    };
    Node* root = add_row(&fixture, 3);
    Node* second_node = root.first_child.next_sibling;
    fixture.scene.get(second_node, scene::Mesh).geometry = second_geometry;
    fixture.physics.add_breakable(root, physics::default_breakable_desc())!!;
    BreakableState* state = fixture.scene.get(root, Breakable).state;
    Node* first = fixture.scene.node(state.pieces[0]);
    Node* second = fixture.scene.node(state.pieces[1]);
    Vec3 first_local = first.local.position;
    Vec3 second_local = second.local.position;
    b3::BodyId assembly = fixture.physics.body(root)!!;

    Node* removed = fixture.scene.node(state.pieces[2]);
    fixture.scene.remove(removed);
    fixture.assets.mark_geometry_dirty(second_geometry);
    fixture.assets.release_geometry_cpu(second_geometry);
    assert(@catch(fixture.physics.wake_breakable(root)) == physics::SOURCE_UNAVAILABLE);

    assert(state.form == ASSEMBLY && state.status == LIVE && state.alive_welds == 1);
    assert(state.alive_pieces == 2);
    assert(fixture.scene.get(root, PhysicsBody).colliders.len == 2);
    b3::BodyId retained = fixture.physics.body(root)!!;
    assert(retained.index1 == assembly.index1 && retained.generation == assembly.generation);
    assert(first.transform_space == TransformSpace.PARENT && second.transform_space == TransformSpace.PARENT);
    assert(first.local.position == first_local && second.local.position == second_local);
    assert(!fixture.scene.has(first, PhysicsBody) && !fixture.scene.has(second, PhysicsBody));
    assert(fixture.physics.world.counters().body_count == 1);
    assert(fixture.physics.world.counters().joint_count == 0);
    assert_snapshot_holders_match(&fixture);

    fixture.assets.geometry(second_geometry).data = geometry::box(
        allocator: fixture.assets.allocator,
        width: 1,
        height: 1,
        depth: 1,
    );
    fixture.assets.mark_geometry_dirty(second_geometry);
    fixture.physics.wake_breakable(root)!!;
    assert(state.form == PIECES);
    assert(first.transform_space == TransformSpace.WORLD && second.transform_space == TransformSpace.WORLD);
    assert_snapshot_holders_match(&fixture);
}

fn void test_gap_policy_includes_corner_contacts_and_rejects_a_larger_gap() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);

    Node* diagonal = fixture.scene.add_node(null, "diagonal")!!;
    add_piece(&fixture, diagonal, {});
    add_piece(&fixture, diagonal, { 1, 1, 0 });
    fixture.scene.update_world();
    fixture.physics.add_breakable(diagonal, physics::default_breakable_desc())!!;
    assert(fixture.scene.get(diagonal, Breakable).state.alive_welds == 1);

    Node* gap = fixture.scene.add_node(null, "gap")!!;
    add_piece(&fixture, gap, { 5, 0, 0 });
    add_piece(&fixture, gap, { 6.02f, 0, 0 });
    fixture.scene.update_world();
    fixture.physics.add_breakable(gap, physics::default_breakable_desc())!!;
    assert(fixture.scene.get(gap, Breakable).state.alive_welds == 0);
}

fn void test_invalid_descriptors_do_not_publish_components_or_native_objects() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = add_row(&fixture, 2);

    BreakableDesc[5] invalid;
    foreach (&desc : invalid) *desc = physics::default_breakable_desc();
    invalid[0].break_force = -1;
    invalid[1].contact_distance = bitcast(0x7fc00000u, float);
    invalid[2].density = 0;
    invalid[3].material.friction = -1;
    invalid[4].material.tangent_velocity.y = bitcast(0x7f800000u, float);
    foreach (desc : invalid) {
        assert(@catch(fixture.physics.add_breakable(root, desc)) == c3d::INVALID_ARGUMENT);
        assert(!fixture.scene.has(root, Breakable));
        assert(fixture.physics.world.counters().body_count == 0);
        assert(fixture.physics.world.counters().joint_count == 0);
    }
}

fn void test_root_scale_and_world_piece_paths_are_rejected_for_assemblies() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = add_row(&fixture, 2);

    root.local.scale = { 2, 2, 2 };
    for (Node* piece = root.first_child; piece; piece = piece.next_sibling) piece.local.scale = { 0.5f, 0.5f, 0.5f };
    fixture.scene.update_world();
    assert(@catch(fixture.physics.add_breakable(root, physics::default_breakable_desc())) == c3d::UNSUPPORTED);

    root.local.scale = { 1, 1, 1 };
    for (Node* piece = root.first_child; piece; piece = piece.next_sibling) piece.local.scale = { 1, 1, 1 };
    root.first_child.transform_space = TransformSpace.WORLD;
    fixture.scene.update_world();
    assert(@catch(fixture.physics.add_breakable(root, physics::default_breakable_desc())) == c3d::UNSUPPORTED);
    assert(!fixture.scene.has(root, Breakable));
    assert(fixture.physics.world.counters().body_count == 0);
}

fn void test_overlapping_composite_ownership_is_rejected_without_changes() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* outer = fixture.scene.add_node(null, "outer")!!;
    Node* inner = fixture.scene.add_node(outer, "inner")!!;
    add_piece(&fixture, inner, {});
    add_piece(&fixture, inner, { 1, 0, 0 });
    fixture.scene.update_world();
    fixture.physics.add_breakable(inner, physics::default_breakable_desc())!!;

    assert(@catch(fixture.physics.add_breakable(outer, physics::default_breakable_desc())) == physics::BREAKABLE_EXISTS);
    assert(fixture.physics.world.counters().body_count == 1);
    assert(fixture.scene.count(Breakable) == 1);
}


fn void test_zero_event_capacity_does_not_prevent_wake_or_break() @test {
    Fixture fixture;
    PhysicsDesc world_desc = weightless_desc();
    world_desc.event_capacity = 0;
    setup(&fixture, world_desc);
    defer teardown(&fixture);
    Node* root = add_row(&fixture, 2);
    BreakableDesc desc = physics::default_breakable_desc();
    desc.break_force = 0.01f;
    desc.density = 1;
    fixture.physics.add_breakable(root, desc)!!;
    Node* visitor = add_visitor(&fixture, { -1.05f, 0, 0 }, 1);
    fixture.physics.set_velocity(visitor, { 20, 0, 0 }, {});

    BreakableState* state = fixture.scene.get(root, Breakable).state;
    uint dropped;
    uint waited;
    while ((state.form != PIECES || state.alive_welds) && waited++ < SETTLE_UPDATES) {
        step(&fixture, 1);
        dropped += fixture.physics.dropped_events;
        assert(fixture.physics.breaks().len == 0);
    }
    assert(state.form == PIECES && state.alive_welds == 0);
    assert(dropped > 0);
    fixture.physics.update(0);
    assert(fixture.physics.breaks().len == 0 && fixture.physics.dropped_events == 0);
}

fn void test_empty_assembly_does_not_recreate_removed_collision() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = add_row(&fixture, 2);
    fixture.physics.add_breakable(root, physics::default_breakable_desc())!!;
    while (root.first_child) fixture.scene.remove(root.first_child);
    fixture.physics.update(0);

    BreakableState* state = fixture.scene.get(root, Breakable).state;
    assert(state.alive_pieces == 0 && state.alive_welds == 0);
    assert(!fixture.scene.has(root, PhysicsBody) && !fixture.scene.has(root, RigidBody));
    physics::destroy_physics_world(&fixture.physics);
    create_world(&fixture, weightless_desc());
    fixture.physics.update(0);
    fixture.physics.wake_breakable(root)!!;
    assert(fixture.physics.world.counters().body_count == 0);
    assert(fixture.physics.world.counters().joint_count == 0);
}

fn void test_cached_hulls_and_component_cleanup_preserve_ownership() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Fixture fixture;
        setup(&fixture, weightless_desc(), &tracker);
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        fixture.physics.add_breakable(root, physics::default_breakable_desc())!!;
        fixture.assets.release_geometry_cpu(fixture.unit_cube);
        fixture.physics.wake_breakable(root)!!;
        assert_snapshot_holders_match(&fixture);

        sz allocations = tracker.total_allocation_count();
        step(&fixture, 20);
        assert(tracker.total_allocation_count() == allocations);
        fixture.physics.remove_breakable(root);
        assert(fixture.scene.count(PhysicsBody) == 0 && fixture.scene.count(RigidBody) == 0);
        assert_snapshot_holders_match(&fixture);
    }
    assert(!tracker.has_leaks());
}

fn void test_snapshot_capacity_failure_releases_the_acquired_prefix() @test {
    Fixture fixture;
    PhysicsDesc world_desc = weightless_desc();
    world_desc.snapshot_capacity = 1;
    setup(&fixture, world_desc);
    defer teardown(&fixture);

    GeometryId other_geometry;
    @pool() {
        Geometry cube = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        other_geometry = fixture.assets.add_geometry(&cube, "other_cube")!!;
    };
    Node* root = add_row(&fixture, 2);
    fixture.scene.get(root.first_child.next_sibling, scene::Mesh).geometry = other_geometry;
    assert(@catch(fixture.physics.add_breakable(root, physics::default_breakable_desc())) == c3d::CAPACITY_EXCEEDED);
    assert(!fixture.scene.has(root, Breakable));
    assert(fixture.scene.count(PhysicsBody) == 0 && fixture.scene.count(RigidBody) == 0);
    assert(fixture.physics.world.counters().body_count == 0);
    assert_snapshot_holders_match(&fixture);
    foreach (slot : fixture.physics.snapshots.slots) assert(slot.holders == 0);
}

fn void test_existing_body_dead_geometry_and_missing_source_are_atomic_faults() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = add_row(&fixture, 2);
    ColliderDesc collider = physics::default_collider_desc(BOX);
    fixture.physics.add_body(root, physics::default_body_desc(KINEMATIC), (&collider)[:1])!!;

    assert(@catch(fixture.physics.add_breakable(root, physics::default_breakable_desc())) == physics::BODY_EXISTS);
    assert(fixture.physics.world.counters().body_count == 1);
    fixture.physics.remove_body(root);
    fixture.scene.get(root.first_child, scene::Mesh).geometry = {};
    assert(@catch(fixture.physics.add_breakable(root, physics::default_breakable_desc())) == c3d::INVALID_ID);
    fixture.scene.get(root.first_child, scene::Mesh).geometry = fixture.unit_cube;
    fixture.assets.release_geometry_cpu(fixture.unit_cube);
    assert(@catch(fixture.physics.add_breakable(root, physics::default_breakable_desc())) == physics::SOURCE_UNAVAILABLE);
    assert(!fixture.scene.has(root, Breakable));
    assert(fixture.physics.world.counters().body_count == 0);
}

fn void test_report_overflow_preserves_all_breaks_across_fixed_steps() @test {
    Fixture fixture;
    PhysicsDesc world_desc = weightless_desc();
    world_desc.event_capacity = 1;
    setup(&fixture, world_desc);
    defer teardown(&fixture);
    Node* root = fixture.scene.add_node(null, "wall")!!;
    add_piece(&fixture, root, { 6, 0, 0 });
    Node* far_first = add_piece(&fixture, root, { 5, 0, 0 });
    add_piece(&fixture, root, { 1, 0, 0 });
    Node* first = add_piece(&fixture, root, {});
    fixture.scene.update_world();
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    desc.density = 1;
    desc.break_force = 0.01f;
    fixture.physics.add_breakable(root, desc)!!;
    fixture.physics.apply_impulse(first, { -12, 0, 0 }, first.world_position());
    fixture.physics.apply_impulse(far_first, { -12, 0, 0 }, far_first.world_position());

    fixture.physics.update(physics::DEFAULT_FIXED_DT * 3);
    fixture.scene.update_world();
    BreakableState* state = fixture.scene.get(root, Breakable).state;
    assert(state.alive_welds == 0);
    assert(fixture.physics.world.counters().joint_count == 0);
    assert(fixture.physics.breaks().len == 1);
    assert(fixture.physics.dropped_events >= 1);
}

fn void test_pending_rebuild_keeps_partial_pieces_disabled_until_ready() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    GeometryId other_geometry;
    @pool() {
        Geometry cube = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        other_geometry = fixture.assets.add_geometry(&cube, "other_cube")!!;
    };
    Node* root = add_row(&fixture, 2);
    Node* first = root.first_child;
    Node* second = first.next_sibling;
    fixture.scene.get(second, scene::Mesh).geometry = other_geometry;
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    fixture.physics.add_breakable(root, desc)!!;
    BreakableState* state = fixture.scene.get(root, Breakable).state;
    physics::destroy_physics_world(&fixture.physics);
    fixture.assets.release_geometry_cpu(other_geometry);
    create_world(&fixture, weightless_desc());
    fixture.physics.update(0);

    assert(state.status == PENDING);
    b3::BodyId first_body = fixture.physics.body(first)!!;
    assert(!first_body.is_enabled());
    assert(!fixture.scene.has(second, RigidBody));
    assert(fixture.physics.world.counters().joint_count == 0);
    assert(@catch(fixture.physics.wake_breakable(root)) == physics::NO_BODY);

    fixture.assets.geometry(other_geometry).data = geometry::box(
        allocator: fixture.assets.allocator,
        width: 1,
        height: 1,
        depth: 1,
    );
    fixture.assets.mark_geometry_dirty(other_geometry);
    fixture.physics.update(0);
    assert(state.status == LIVE && state.alive_welds == 1);
    first_body = fixture.physics.body(first)!!;
    b3::BodyId second_body = fixture.physics.body(second)!!;
    assert(first_body.is_enabled() && second_body.is_enabled());
    assert_snapshot_holders_match(&fixture);
}

fn void test_automatic_wake_publishes_native_poses_after_multiple_steps() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = add_row(&fixture, 2);
    BreakableDesc desc = physics::default_breakable_desc();
    desc.density = 1;
    desc.break_force = 0.01f;
    desc.material.friction = 0;
    fixture.physics.add_breakable(root, desc)!!;
    Node* visitor = add_visitor(&fixture, { -1.05f, 0, 0 }, 1);
    fixture.physics.set_velocity(visitor, { 20, 0, 0 }, {});
    root.local.position.x = 0.1f;
    fixture.scene.update_world();

    fixture.physics.update(physics::DEFAULT_FIXED_DT * 3);
    fixture.scene.update_world();
    BreakableState* state = fixture.scene.get(root, Breakable).state;
    assert(state.form == PIECES);
    foreach (entity : state.pieces) {
        Node* node = fixture.scene.node(entity);
        b3::BodyId body = fixture.physics.body(node)!!;
        assert(node.transform_space == TransformSpace.WORLD);
        assert((node.world_position() - (Vec3)body.position()).length() < 1e-4f);
    }
}
