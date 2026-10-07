module c3d_physics_breakable_test;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::physics;
import c3d::scene;
import std::core::mem::allocators;
import std::math;
import std::math::quaternion;
import b3;

fn void attach_pending_row(Fixture* fixture, Node* root, BreakableDesc desc) @private {
    BreakablePieceView[2] pieces;
    Node* node = root.first_child;
    foreach (&piece : pieces) {
        *piece = { .node = node.id, .hulls = (&fixture.unit_cube)[:1], .rest_frame = node.local };
        node = node.next_sibling;
    }
    fixture.scene.attach_breakable_pieces(
        assets: &fixture.assets,
        root: root,
        pieces: &pieces,
        desc: desc,
    )!!;
}

fn void test_pending_breakable_copies_authoring_and_waits_for_explicit_preparation() @test {
    foreach (assembly : (bool[2]){ true, false }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            Fixture fixture;
            setup(&fixture, weightless_desc(), &tracker);
            defer teardown(&fixture);
            Node* root = add_row(&fixture, 2);
            GeometryId[2] hulls = { fixture.unit_cube, fixture.unit_cube };
            BreakablePieceView[2] pieces = {
                { .node = root.first_child.id, .hulls = &hulls, .rest_frame = root.first_child.local },
                { .node = root.first_child.next_sibling.id, .hulls = (&fixture.unit_cube)[:1], .rest_frame = root.first_child.next_sibling.local },
            };
            BreakableDesc desc = physics::default_breakable_desc();
            desc.sleep_until_hit = assembly;
            fixture.scene.attach_breakable_pieces(
                assets: &fixture.assets,
                root: root,
                pieces: &pieces,
                desc: desc,
            )!!;
            Breakable* component = fixture.scene.get(root, Breakable);
            BreakableState* pending = component.state;
            assert(!component.is_prepared() && pending.status == PENDING && pending.welds.len == 0);
            assert(pending.piece_view(0).hulls.len == 2 && pending.piece_view(1).hulls.len == 1);
            hulls[0] = {};
            pieces[0].rest_frame.position.x = 100;
            assert(c3d::same_id(pending.piece_view(0).hulls[0], fixture.unit_cube));
            assert(pending.piece_view(0).rest_frame.position.x == 0);
            fixture.physics.update(0);
            assert(component.state == pending && !component.is_prepared());
            assert(fixture.scene.count(PhysicsBody) == 0 && fixture.scene.count(RigidBody) == 0);
            assert(fixture.physics.world.counters().body_count == 0 && fixture.physics.world.counters().joint_count == 0);
            foreach (slot : fixture.physics.snapshots.slots) assert(slot.holders == 0);
            physics::destroy_physics_world(&fixture.physics);
            create_world(&fixture, weightless_desc());
            fixture.physics.update(0);
            assert(component.state == pending && pending.status == PENDING);
            root.local.position = { 7, 2, -3 };
            fixture.scene.update_world();
            fixture.physics.prepare_breakable(root)!!;
            assert(component.is_prepared() && component.state != pending && component.state.status == LIVE);
            assert(component.state.welds.len == 1 && component.state.alive_welds == 1);
            assert(component.state.piece_view(0).hulls.len == 2);
            assert(fixture.physics.world.counters().body_count == (assembly ? 1 : 2));
            BreakableState* prepared = component.state;
            sz allocations = tracker.total_allocation_count();
            fixture.physics.prepare_breakable(root)!!;
            assert(component.state == prepared && tracker.total_allocation_count() == allocations);
            assert_snapshot_holders_match(&fixture);
            fixture.physics.remove_breakable(root);
            assert(fixture.scene.count(PhysicsBody) == 0 && fixture.scene.count(RigidBody) == 0);
            assert(fixture.scene.count(scene::Mesh) == 2 && root.first_child);
        }
        assert(!tracker.has_leaks());
    }
}

fn void test_pending_breakable_failure_preserves_recipe_and_other_owners() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* failed_root = add_row(&fixture, 2);
    Node* ready_root = add_row(&fixture, 2);
    Node* outside = add_row(&fixture, 2);
    GeometryId repairable;
    @pool() {
        Geometry invalid = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        invalid.positions[..] = {};
        invalid.finalize();
        repairable = fixture.assets.add_geometry(&invalid, "repairable")!!;
    };
    BreakablePieceView[2] failed_pieces = {
        { .node = failed_root.first_child.id, .hulls = (&fixture.unit_cube)[:1], .rest_frame = failed_root.first_child.local },
        { .node = failed_root.first_child.next_sibling.id, .hulls = (&repairable)[:1], .rest_frame = failed_root.first_child.next_sibling.local },
    };
    fixture.scene.attach_breakable_pieces(
        assets: &fixture.assets,
        root: failed_root,
        pieces: &failed_pieces,
        desc: physics::default_breakable_desc(),
    )!!;
    attach_pending_row(&fixture, ready_root, physics::default_breakable_desc());
    attach_pending_row(&fixture, outside, physics::default_breakable_desc());
    Node* selection = fixture.scene.add_node(name: "selected")!!;
    fixture.scene.reparent(failed_root, selection);
    fixture.scene.reparent(ready_root, selection);
    fixture.scene.update_world();
    BreakableState* pending = fixture.scene.get(failed_root, Breakable).state;
    fault failure = @catch(fixture.physics.prepare_breakable_subtree(selection));
    assert(failure == b3::DEGENERATE_GEOMETRY);
    assert(fixture.scene.get(failed_root, Breakable).state == pending && pending.welds.len == 0);
    assert(!fixture.scene.get(failed_root, Breakable).is_prepared());
    assert(fixture.scene.get(ready_root, Breakable).is_prepared());
    assert(!fixture.scene.get(outside, Breakable).is_prepared());
    assert(fixture.physics.world.counters().body_count == 1);
    assert(!fixture.scene.has(failed_root, PhysicsBody) && !fixture.scene.has(failed_root, RigidBody));
    assert_snapshot_holders_match(&fixture);
    Geometry* repaired = &fixture.assets.geometry(repairable).data;
    repaired.positions[..] = fixture.assets.geometry(fixture.unit_cube).data.positions[..];
    repaired.finalize();
    fixture.assets.mark_geometry_dirty(repairable);
    BreakableState* ready = fixture.scene.get(ready_root, Breakable).state;
    fixture.physics.prepare_breakable_subtree(selection)!!;
    assert(fixture.scene.get(failed_root, Breakable).is_prepared());
    assert(fixture.scene.get(ready_root, Breakable).state == ready);
    assert(!fixture.scene.get(outside, Breakable).is_prepared());
    assert(fixture.physics.world.counters().body_count == 2);
    fixture.physics.remove_breakable(outside);
    assert(outside.first_child && fixture.scene.count(scene::Mesh) == 6);
    assert_snapshot_holders_match(&fixture);
}

fn void test_pending_breakable_allocation_failure_is_retryable_and_dead_piece_stays_absent() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = add_row(&fixture, 2);
    BreakablePieceView[2] pieces = {
        { .node = root.first_child.id, .hulls = (&fixture.unit_cube)[:1], .rest_frame = root.first_child.local },
        { .node = root.first_child.next_sibling.id, .hulls = (&fixture.unit_cube)[:1], .rest_frame = root.first_child.next_sibling.local },
    };
    NullAllocator failure;
    Allocator original = fixture.scene.allocator;
    fixture.scene.allocator = &failure;
    assert(@catch(fixture.scene.attach_breakable_pieces(
        assets: &fixture.assets,
        root: root,
        pieces: &pieces,
        desc: physics::default_breakable_desc(),
    )) == c3d::CAPACITY_EXCEEDED);
    fixture.scene.allocator = original;
    assert(!fixture.scene.has(root, Breakable));
    fixture.scene.attach_breakable_pieces(
        assets: &fixture.assets,
        root: root,
        pieces: &pieces,
        desc: physics::default_breakable_desc(),
    )!!;
    BreakableState* pending = fixture.scene.get(root, Breakable).state;
    fixture.scene.allocator = &failure;
    assert(@catch(fixture.physics.prepare_breakable(root)) == c3d::CAPACITY_EXCEEDED);
    fixture.scene.allocator = original;
    assert(fixture.scene.get(root, Breakable).state == pending && !fixture.scene.get(root, Breakable).is_prepared());
    assert(fixture.scene.count(PhysicsBody) == 0 && fixture.physics.world.counters().body_count == 0);
    assert_snapshot_holders_match(&fixture);
    fixture.physics.prepare_breakable(root)!!;
    assert(fixture.scene.get(root, Breakable).is_prepared());
    fixture.physics.remove_breakable(root);
    attach_pending_row(&fixture, root, physics::default_breakable_desc());
    Entity removed = root.first_child.id;
    fixture.scene.remove(root.first_child);
    Node* replacement = fixture.scene.add_node(root, "replacement")!!;
    assert(replacement.id.index == removed.index && !c3d::same_id(replacement.id, removed));
    fixture.scene.update_world();
    assert(@catch(fixture.physics.prepare_breakable(root)) == c3d::INVALID_ID);
    assert(!fixture.scene.get(root, Breakable).is_prepared() && fixture.physics.world.counters().body_count == 0);
}

fn void test_pending_breakable_pose_check_accepts_rigid_motion_and_retries_mismatch() @test {
    foreach (assembly : (bool[2]){ true, false }) {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        BreakableDesc desc = physics::default_breakable_desc();
        desc.sleep_until_hit = assembly;
        attach_pending_row(&fixture, root, desc);
        Node* first = root.first_child;
        Node* second = first.next_sibling;
        Breakable* component = fixture.scene.get(root, Breakable);
        assert(!component.preparation_mismatch());
        second.local.position.x += 0.25f;
        fixture.scene.update_world();
        BreakableState* pending = component.state;
        assert(@catch(fixture.physics.prepare_breakable(root)) == c3d::INVALID_ARGUMENT);
        assert(component.state == pending && !component.is_prepared());
        BreakableMismatch* mismatch = component.preparation_mismatch();
        assert(mismatch && mismatch.piece_a == 0 && mismatch.piece_b == 1);
        assert(fixture.scene.count(PhysicsBody) == 0 && fixture.physics.world.counters().body_count == 0);
        assert_snapshot_holders_match(&fixture);
        second.local.position.x -= 0.25f;
        Quaternionf rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.7f);
        Vec3 translation = { 4, 5, -2 };
        for (Node* piece = first; piece; piece = piece.next_sibling) {
            piece.local.position = translation + rotation.rotate_vec3(piece.local.position);
            piece.local.rotation = rotation;
        }
        fixture.scene.update_world();
        Vec3 first_position = first.world_position();
        Vec3 second_position = second.world_position();
        fixture.physics.prepare_breakable(root)!!;
        assert(component.is_prepared() && !component.preparation_mismatch());
        if (assembly) fixture.physics.wake_breakable(root)!!;
        assert((first.world_position() - first_position).length() < 1e-4f);
        assert((second.world_position() - second_position).length() < 1e-4f);
        RigidBody* first_body = fixture.scene.get(first, RigidBody);
        RigidBody* second_body = fixture.scene.get(second, RigidBody);
        assert((first_body.current.position - first_position).length() < 1e-4f);
        assert((second_body.current.position - second_position).length() < 1e-4f);
        assert(component.state.alive_welds == 1);
    }
}

fn void test_pending_breakable_attachment_faults_publish_nothing() @test {
    fault[10] expected = {
        c3d::INVALID_ID, c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::INVALID_ARGUMENT,
        c3d::INVALID_ARGUMENT, c3d::INVALID_ARGUMENT, physics::BREAKABLE_EXISTS,
        physics::BODY_EXISTS, c3d::UNSUPPORTED, c3d::UNSUPPORTED,
    };
    foreach (scenario, wanted : expected) {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        GeometryId first_hull = fixture.unit_cube;
        BreakablePieceView[2] storage = {
            { .node = root.first_child.id, .hulls = (&first_hull)[:1], .rest_frame = root.first_child.local },
            { .node = root.first_child.next_sibling.id, .hulls = (&fixture.unit_cube)[:1], .rest_frame = root.first_child.next_sibling.local },
        };
        BreakablePieceView[] pieces = &storage;
        BreakableState* existing;
        switch (scenario) {
            case 0: fixture.scene.remove(fixture.scene.node(pieces[0].node));
            case 1: fixture.assets.remove_geometry(first_hull);
            case 2: pieces[0].hulls = {};
            case 3: pieces[1].node = pieces[0].node;
            case 4: fixture.scene.reparent(fixture.scene.node(pieces[0].node), fixture.scene.root);
            case 5: pieces = pieces[:1];
            case 6:
                attach_pending_row(&fixture, root, physics::default_breakable_desc());
                existing = fixture.scene.get(root, Breakable).state;
            case 7:
                ColliderDesc collider = physics::default_collider_desc(SPHERE);
                collider.radius = 1;
                fixture.scene.add_physics_body(root, physics::default_body_desc(STATIC), (&collider)[:1])!!;
            case 8: pieces[0].rest_frame.position.x = bitcast(0x7fc00000u, float);
            case 9: pieces[0].rest_frame.scale.x = 2;
        }
        uint nodes = fixture.scene.world.entities.free_count;
        uint bodies = fixture.scene.count(PhysicsBody);
        uint owners = fixture.scene.count(Breakable);
        assert(@catch(fixture.scene.attach_breakable_pieces(
            assets: &fixture.assets,
            root: root,
            pieces: pieces,
            desc: physics::default_breakable_desc(),
        )) == wanted);
        assert(fixture.scene.world.entities.free_count == nodes);
        assert(fixture.scene.count(PhysicsBody) == bodies && fixture.scene.count(Breakable) == owners);
        assert(fixture.physics.world.counters().body_count == 0 && fixture.physics.world.counters().joint_count == 0);
        if (existing) assert(fixture.scene.get(root, Breakable).state == existing);
        foreach (slot : fixture.physics.snapshots.slots) assert(slot.holders == 0);
    }
}

fn void test_pending_breakable_pose_tolerance_handles_distant_roots() @test {
    foreach (displaced : (bool[2]){ false, true }) {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        root.local.position = { 10000, 12000, -10000 };
        root.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.37f);
        fixture.scene.update_world();
        attach_pending_row(&fixture, root, physics::default_breakable_desc());
        if (displaced) root.first_child.local.position.x += 0.25f;
        fixture.scene.update_world();
        Breakable* owner = fixture.scene.get(root, Breakable);
        if (displaced) {
            assert(@catch(fixture.physics.prepare_breakable(root)) == c3d::INVALID_ARGUMENT);
            BreakableMismatch* mismatch = owner.preparation_mismatch();
            assert(mismatch && mismatch.piece_a == 0 && mismatch.piece_b == 1);
            assert(!owner.is_prepared() && fixture.physics.world.counters().body_count == 0);
        } else {
            fixture.physics.prepare_breakable(root)!!;
            assert(owner.is_prepared() && !owner.preparation_mismatch());
            assert(fixture.physics.world.counters().body_count == 1);
        }
    }
}
