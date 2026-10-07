module c3d_physics_breakable_test;

import std::math;
import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::asset;
import c3d::geometry;
import c3d::physics;
import c3d::scene;
import b3;

fn GeometryId offset_cube(Fixture* fixture, Vec3 offset) @private {
    @pool() {
        Geometry cube = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        foreach (&point : cube.positions) *point += offset;
        cube.finalize();
        return fixture.assets.add_geometry(&cube)!!;
    };
}

fn void assert_frame_equal(maths::Transform first, maths::Transform second) @private {
    assert(first.position == second.position && first.rotation.v == second.rotation.v && first.scale == second.scale);
}

fn void assert_weld_equal(BreakableWeldView first, BreakableWeldView second) @private {
    assert(first.piece_a == second.piece_a && first.piece_b == second.piece_b && first.anchor == second.anchor);
    assert_frame_equal(first.frame_b, second.frame_b);
}

fn void test_explicit_one_hull_matches_legacy_and_reauthors_in_a_fresh_scene() @test {
    for (uint form = 0; form < 2; form++) {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 3);
        root.local.position = { 3, 4, 5 };
        fixture.scene.update_world();
        BreakableDesc desc = physics::default_breakable_desc();
        desc.sleep_until_hit = form == 0;
        fixture.physics.add_breakable(root, desc)!!;
        BreakableState* legacy = fixture.scene.get(root, Breakable).state;
        BreakablePieceDesc[3] pieces;
        GeometryId[3] hulls;
        maths::Transform[3] frames;
        BreakableWeldView[2] welds;
        foreach (index, &piece : pieces) {
            BreakablePieceView view = legacy.piece_view((uint)index);
            assert(view.hulls.len == 1 && c3d::same_id(view.hulls[0], fixture.unit_cube));
            hulls[index] = view.hulls[0];
            frames[index] = view.rest_frame;
            *piece = { .node = view.node, .hulls = (&hulls[index])[:1] };
        }
        foreach (index, &weld : welds) *weld = legacy.weld_view((uint)index);
        int body_count = fixture.physics.world.counters().body_count;
        fixture.physics.remove_breakable(root);
        fixture.physics.add_breakable_pieces(root, &pieces, desc)!!;
        BreakableState* explicit = fixture.scene.get(root, Breakable).state;
        assert(explicit.pieces.len == 3 && explicit.welds.len == 2);
        assert(fixture.physics.world.counters().body_count == body_count);
        foreach (index, piece : pieces) {
            assert(c3d::same_id(explicit.pieces[index], piece.node));
            assert_frame_equal(explicit.piece_view((uint)index).rest_frame, frames[index]);
            if (!desc.sleep_until_hit) {
                assert(fixture.scene.get(fixture.scene.node(piece.node), RigidBody).colliders.len == 1);
            }
        }
        if (desc.sleep_until_hit) assert(fixture.scene.get(root, RigidBody).colliders.len == 3);
        foreach (index, weld : welds) assert_weld_equal(explicit.weld_view((uint)index), weld);

        Fixture restored;
        setup(&restored, weightless_desc());
        defer teardown(&restored);
        Node* restored_root = restored.scene.add_node(null, "restored")!!;
        foreach (index, &piece : pieces) {
            Node* node = restored.scene.add_node(restored_root)!!;
            node.local = frames[index];
            *piece = { .node = node.id, .hulls = (&restored.unit_cube)[:1] };
        }
        restored.scene.update_world();
        restored.physics.add_breakable_pieces(restored_root, &pieces, desc)!!;
        BreakableState* rebuilt = restored.scene.get(restored_root, Breakable).state;
        assert(rebuilt.welds.len == 2);
        foreach (index, weld : welds) assert_weld_equal(rebuilt.weld_view((uint)index), weld);
    }
}

fn void test_explicit_hull_distance_uses_minimum_and_caller_order_for_ties() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = fixture.scene.add_node()!!;
    Node* first = fixture.scene.add_node(root)!!;
    Node* second = fixture.scene.add_node(root)!!;
    GeometryId[2] hulls = { offset_cube(&fixture, { -2, 0, 0 }), offset_cube(&fixture, { 2, 0, 0 }) };
    BreakablePieceDesc[2] pieces = {
        { .node = first.id, .hulls = &hulls },
        { .node = second.id, .hulls = (&fixture.unit_cube)[:1] },
    };
    BreakableDesc desc = physics::default_breakable_desc();
    desc.contact_distance = 5;
    second.local.position.x = 0.25f;
    fixture.scene.update_world();
    fixture.physics.add_breakable_pieces(root, &pieces, desc)!!;
    BreakableState* state = fixture.scene.get(root, Breakable).state;
    assert(state.welds.len == 1 && state.welds[0].anchor.x > 0);
    fixture.physics.remove_breakable(root);
    second.local.position.x = 0;
    fixture.scene.update_world();
    fixture.physics.add_breakable_pieces(root, &pieces, desc)!!;
    assert(fixture.scene.get(root, Breakable).state.welds[0].anchor.x < 0);
    fixture.physics.remove_breakable(root);
    GeometryId reversed = hulls[0];
    hulls[0] = hulls[1];
    hulls[1] = reversed;
    fixture.physics.add_breakable_pieces(root, &pieces, desc)!!;
    assert(fixture.scene.get(root, Breakable).state.welds[0].anchor.x > 0);
}

fn void test_explicit_multihull_mass_and_render_child_removal_keep_one_body() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = fixture.scene.add_node()!!;
    Node* first = fixture.scene.add_node(root)!!;
    Node* second = fixture.scene.add_node(root)!!;
    second.local.position.x = 5;
    Node* render_child = add_piece(&fixture, first, {});
    GeometryId[2] hulls = { fixture.unit_cube, offset_cube(&fixture, { 2, 0, 0 }) };
    BreakablePieceDesc[2] pieces = {
        { .node = first.id, .hulls = &hulls },
        { .node = second.id, .hulls = (&fixture.unit_cube)[:1] },
    };
    fixture.scene.update_world();
    BreakableDesc desc = physics::default_breakable_desc();
    desc.sleep_until_hit = false;
    desc.density = 3;
    fixture.physics.add_breakable_pieces(root, &pieces, desc)!!;
    hulls = {};
    BreakablePieceView captured = fixture.scene.get(root, Breakable).state.piece_view(0);
    assert(captured.hulls.len == 2 && c3d::same_id(captured.hulls[0], fixture.unit_cube));
    b3::BodyId body = fixture.physics.body(first)!!;
    assert(math::abs(body.mass() - 6) < 1e-5f);
    assert(((Vec3)body.local_center() - (Vec3){ 1, 0, 0 }).length() < 1e-5f);
    assert(body.shape_count() == 2 && fixture.physics.world.counters().body_count == 2);
    fixture.scene.remove(render_child);
    fixture.physics.update(0);
    b3::BodyId retained = fixture.physics.body(first)!!;
    assert(body.index1 == retained.index1 && body.generation == retained.generation);
    assert(retained.shape_count() == 2);
    assert(fixture.scene.get(root, Breakable).state.alive_pieces == 2);
    assert_snapshot_holders_match(&fixture);
}

fn void test_explicit_assembly_prunes_every_hull_and_rebuilds_its_mapping() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = fixture.scene.add_node()!!;
    BreakablePieceDesc[3] pieces;
    GeometryId[2] hulls = { fixture.unit_cube, offset_cube(&fixture, { 0, 1, 0 }) };
    foreach (index, &piece : pieces) {
        Node* node = fixture.scene.add_node(root)!!;
        node.local.position.x = (float)index;
        *piece = { .node = node.id, .hulls = &hulls };
    }
    fixture.scene.update_world();
    fixture.physics.add_breakable_pieces(root, &pieces, physics::default_breakable_desc())!!;
    BreakableState* state = fixture.scene.get(root, Breakable).state;
    assert(state.welds.len == 2 && fixture.scene.get(root, RigidBody).colliders.len == 6);
    fixture.scene.remove(fixture.scene.node(pieces[1].node));
    fixture.physics.update(0);
    assert(state.alive_pieces == 2 && state.alive_welds == 0);
    assert(state.welds[0].broken && state.welds[1].broken);
    assert(fixture.scene.get(root, RigidBody).colliders.len == 4);
    assert(fixture.scene.get(root, PhysicsBody).colliders.len == 4);
    physics::destroy_physics_world(&fixture.physics);
    create_world(&fixture, weightless_desc());
    fixture.physics.update(0);
    assert((fixture.physics.body(root)!!).shape_count() == 4);
    fixture.scene.remove(fixture.scene.node(pieces[2].node));
    fixture.physics.update(0);
    assert((fixture.physics.body(root)!!).shape_count() == 2);
    fixture.physics.wake_breakable(root)!!;
    assert(state.form == PIECES && state.alive_pieces == 1);
    assert((fixture.physics.body(fixture.scene.node(pieces[0].node))!!).shape_count() == 2);
    assert_snapshot_holders_match(&fixture);
}

fn void test_explicit_multihull_failed_wake_rolls_back_every_staged_body() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = fixture.scene.add_node()!!;
    Node* first = fixture.scene.add_node(root)!!;
    Node* second = fixture.scene.add_node(root)!!;
    second.local.position.x = 1;
    GeometryId[2] hulls = { fixture.unit_cube, offset_cube(&fixture, { 0, 1, 0 }) };
    BreakablePieceDesc[2] pieces = {
        { .node = first.id, .hulls = (&fixture.unit_cube)[:1] },
        { .node = second.id, .hulls = &hulls },
    };
    fixture.scene.update_world();
    fixture.physics.add_breakable_pieces(root, &pieces, physics::default_breakable_desc())!!;
    b3::BodyId assembly = fixture.physics.body(root)!!;
    fixture.assets.mark_geometry_dirty(hulls[1]);
    fixture.assets.release_geometry_cpu(hulls[1]);
    if (catch excuse = fixture.physics.wake_breakable(root)) {
        assert(excuse == physics::SOURCE_UNAVAILABLE);
    } else { assert(false); }
    BreakableState* state = fixture.scene.get(root, Breakable).state;
    assert(state.form == ASSEMBLY && state.status == LIVE && state.alive_welds == 1);
    b3::BodyId retained = fixture.physics.body(root)!!;
    assert(assembly.index1 == retained.index1 && assembly.generation == retained.generation);
    assert(retained.shape_count() == 3 && fixture.physics.world.counters().body_count == 1);
    assert(fixture.physics.world.counters().joint_count == 0);
    assert(!fixture.scene.has(first, PhysicsBody) && !fixture.scene.has(second, PhysicsBody));
    assert(first.transform_space == PARENT && second.transform_space == PARENT);
    assert(first.local.position == (Vec3){} && second.local.position == (Vec3){ 1, 0, 0 });
    assert_snapshot_holders_match(&fixture);
    fixture.assets.geometry(hulls[1]).data = geometry::box(
        allocator: fixture.assets.allocator,
        width: 1,
        height: 1,
        depth: 1,
    );
    foreach (&point : fixture.assets.geometry(hulls[1]).data.positions) point.y += 1;
    fixture.assets.geometry(hulls[1]).data.finalize();
    fixture.assets.mark_geometry_dirty(hulls[1]);
    fixture.physics.wake_breakable(root)!!;
    assert(state.form == PIECES && (fixture.physics.body(second)!!).shape_count() == 2);
    assert_snapshot_holders_match(&fixture);
}

fn void test_explicit_validation_faults_attach_nothing() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = fixture.scene.add_node()!!;
    Node* first = fixture.scene.add_node(root)!!;
    Node* second = fixture.scene.add_node(root)!!;
    Node* outside = fixture.scene.add_node()!!;
    Node* child = fixture.scene.add_node(first)!!;
    Entity dead = fixture.scene.add_node(root)!!.id;
    fixture.scene.remove(fixture.scene.node(dead));
    BreakablePieceDesc[2] valid = {
        { .node = first.id, .hulls = (&fixture.unit_cube)[:1] },
        { .node = second.id, .hulls = (&fixture.unit_cube)[:1] },
    };
    BreakableDesc desc = physics::default_breakable_desc();
    for (uint test_case = 0; test_case < 10; test_case++) {
        BreakablePieceDesc[2] pieces = valid;
        fault expected = c3d::INVALID_ARGUMENT;
        switch (test_case) {
            case 0: pieces[0].node = dead; expected = c3d::INVALID_ID;
            case 1: pieces[1].node = first.id;
            case 2: pieces[1].node = outside.id;
            case 3: pieces[1].node = child.id;
            case 4: pieces[0].hulls = {};
            case 5: pieces[0].node = root.id;
            case 6: first.local.scale.x = 2; expected = c3d::UNSUPPORTED;
            case 7: first.transform_space = WORLD; expected = c3d::UNSUPPORTED;
            case 8: pieces[0].hulls = (&&(GeometryId){})[:1]; expected = c3d::INVALID_ID;
            case 9: expected = c3d::UNSUPPORTED;
        }
        fixture.scene.update_world();
        if (test_case == 9) first.world.m01 = 0.25f;
        if (catch excuse = fixture.physics.add_breakable_pieces(root, &pieces, desc)) {
            assert(excuse == expected);
        } else { assert(false); }
        assert(!fixture.scene.has(root, Breakable));
        assert(fixture.scene.count(PhysicsBody) == 0 && fixture.scene.count(RigidBody) == 0);
        assert(fixture.physics.world.counters().body_count == 0 && fixture.physics.world.counters().joint_count == 0);
        first.local.scale = { 1, 1, 1 };
        first.transform_space = PARENT;
    }
    fixture.scene.update_world();
    if (catch excuse = fixture.physics.add_breakable_pieces(root, valid[:1], desc)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else { assert(false); }
    ColliderDesc collider = physics::default_collider_desc(BOX);
    fixture.physics.add_body(first, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;
    if (catch excuse = fixture.physics.add_breakable_pieces(root, &valid, desc)) {
        assert(excuse == physics::BODY_EXISTS);
    } else { assert(false); }
    assert(!fixture.scene.has(root, Breakable) && fixture.physics.world.counters().body_count == 1);
    fixture.physics.remove_body(first);
    fixture.physics.add_breakable_pieces(root, &valid, desc)!!;
    BreakableState* original = fixture.scene.get(root, Breakable).state;
    if (catch excuse = fixture.physics.add_breakable_pieces(root, &valid, desc)) {
        assert(excuse == physics::BREAKABLE_EXISTS);
    } else { assert(false); }
    assert(fixture.scene.get(root, Breakable).state == original);
    assert(fixture.physics.world.counters().body_count == 1);
}

fn void test_explicit_native_cooking_fault_releases_the_acquired_hulls() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = fixture.scene.add_node()!!;
    Node* first = fixture.scene.add_node(root)!!;
    Node* second = fixture.scene.add_node(root)!!;
    GeometryId flat;
    @pool() {
        Geometry cube = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        foreach (&point : cube.positions) point.y = 0;
        cube.finalize();
        flat = fixture.assets.add_geometry(&cube)!!;
    };
    GeometryId[2] hulls = { fixture.unit_cube, flat };
    BreakablePieceDesc[2] pieces = {
        { .node = first.id, .hulls = (&fixture.unit_cube)[:1] },
        { .node = second.id, .hulls = &hulls },
    };
    fixture.scene.update_world();
    if (catch excuse = fixture.physics.add_breakable_pieces(root, &pieces, physics::default_breakable_desc())) {
        assert(excuse == b3::DEGENERATE_GEOMETRY);
    } else { assert(false); }
    assert(!fixture.scene.has(root, Breakable));
    assert(fixture.scene.count(PhysicsBody) == 0 && fixture.scene.count(RigidBody) == 0);
    assert(fixture.physics.world.counters().body_count == 0 && fixture.physics.world.counters().joint_count == 0);
    foreach (slot : fixture.physics.snapshots.slots) assert(slot.holders == 0);
}
