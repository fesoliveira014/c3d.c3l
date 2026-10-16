module c3d_physics_breakable_test;

import c3d;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::core::mem::allocators;
import std::math;
import std::math::quaternion;
import b3;

fn BreakableRecipeDesc row_recipe(Fixture* fixture, Node* root, Node* target = null) @private {
    BreakableRecipeDesc recipe = physics::default_breakable_recipe_desc();
    recipe.settings.sleep_until_hit = false;
    recipe.settings.density = 1;
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
        .piece_a = 0,
        .piece_b = 1,
        .frame_a = { .position = { 0.5f, 0, 0 }, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
        .frame_b = { .position = { -0.5f, 0, 0 }, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
        .moment_axis = { 1, 0, 0 },
    };
    if (target) {
        recipe.anchors = alloc::new_array(tmem, BreakableAnchorDesc, 1);
        recipe.anchors[0] = {
            .piece = 0,
            .target = target.id,
            .frame_a = { .position = { -0.5f, 0, 0 }, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
            .frame_b = { .position = { 0.5f, 0, 0 }, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
            .moment_axis = { 1, 0, 0 },
        };
    }
    return recipe;
}

fn void test_breakable_recipe_pending_capture_is_independent_and_retryable() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        physics::destroy_physics_world(&fixture.physics);
        Node* root = add_row(&fixture, 2);
        Node* target = fixture.scene.add_node(name: "support")!!;
        target.local.position = { -1, 0, 0 };
        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = { 0.5f, 0.5f, 0.5f };
        fixture.scene.add_physics_body(target, physics::default_body_desc(STATIC), (&collider)[:1])!!;
        fixture.scene.update_world();

        BreakableRecipeDesc recipe = row_recipe(&fixture, root, target);
        recipe.pieces[0].has_strength = true;
        recipe.pieces[0].strength = physics::default_breakable_strength(90);
        recipe.pieces[1].has_strength = true;
        recipe.pieces[1].strength = physics::default_breakable_strength(120);
        fixture.scene.attach_breakable_recipe(assets: &fixture.assets, root: root, recipe: recipe)!!;
        BreakableState* pending = fixture.scene.get(root, Breakable).state;
        assert(!fixture.scene.get(root, Breakable).is_prepared());
        assert(fixture.scene.count(RigidBody) == 0 && fixture.scene.count(PhysicsBody) == 1);
        assert(pending.anchor_count() == 1 && pending.weld_view(0).strength.force == 90);
        assert(pending.anchor_view(0).strength.force == 90);

        recipe.pieces[0].hulls[0] = {};
        recipe.pieces[0].rest_frame.position.x = 20;
        recipe.welds[0].moment_axis = {};
        recipe.anchors[0].target = {};
        assert(c3d::same_id(pending.piece_view(0).hulls[0], fixture.unit_cube));
        assert(pending.piece_view(0).rest_frame.position == (Vec3){});
        assert(pending.weld_view(0).moment_axis == (Vec3){ 1, 0, 0 });
        assert(c3d::same_id(pending.anchor_view(0).authored.target, target.id));

        create_world(&fixture, weightless_desc());
        assert(@catch(fixture.physics.prepare_breakable(root)) == physics::NO_BODY);
        assert(fixture.scene.get(root, Breakable).state == pending);
        assert(fixture.physics.world.counters().body_count == 0 && fixture.physics.world.counters().joint_count == 0);
        fixture.physics.update(0);
        fixture.physics.prepare_breakable_subtree(root)!!;
        BreakableState* prepared = fixture.scene.get(root, Breakable).state;
        assert(prepared.recipe_kind == AUTHORED_REST && prepared.welds.len == 1 && prepared.anchor_count() == 1);
        assert(fixture.physics.world.counters().body_count == 3 && fixture.physics.world.counters().joint_count == 2);
    };
}

fn void test_breakable_recipe_empty_edges_and_eager_failure_do_not_generate_welds() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        BreakableRecipeDesc recipe = row_recipe(&fixture, root);
        recipe.welds = {};
        fixture.physics.add_breakable_recipe(root, recipe)!!;
        assert(fixture.scene.get(root, Breakable).state.welds.len == 0);
        assert(fixture.physics.world.counters().body_count == 2 && fixture.physics.world.counters().joint_count == 0);
        fixture.physics.remove_breakable(root);

        Node* target = fixture.scene.add_node(name: "unprepared_support")!!;
        target.local.position = { -1, 0, 0 };
        fixture.scene.update_world();
        recipe = row_recipe(&fixture, root, target);
        assert(@catch(fixture.physics.add_breakable_recipe(root, recipe)) == physics::NO_BODY);
        assert(!fixture.scene.has(root, Breakable) && fixture.scene.count(PhysicsBody) == 0);
        assert(fixture.physics.world.counters().body_count == 0 && fixture.physics.world.counters().joint_count == 0);
    };
}

fn void test_breakable_reset_late_source_failure_preserves_live_native_state() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Geometry cube = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId second_geometry = fixture.assets.add_geometry(&cube, "second_reset_cube")!!;
        Node* root = add_row(&fixture, 2);
        Node* target = add_static_box(&fixture, { -1, 0, 0 }, { 0.5f, 0.5f, 0.5f });
        BreakableRecipeDesc recipe = row_recipe(&fixture, root, target);
        recipe.pieces[1].hulls[0] = second_geometry;
        recipe.strength.force = float::max;
        fixture.physics.add_breakable_recipe(root, recipe)!!;
        BreakableState* state = fixture.scene.get(root, Breakable).state;
        Node* first = fixture.scene.node(state.pieces[0]);
        Node* second = fixture.scene.node(state.pieces[1]);
        b3::BodyId old_first = fixture.physics.body(first)!!;
        b3::BodyId old_second = fixture.physics.body(second)!!;
        b3::JointId old_joint = state.welds[0].joint;
        b3::JointId old_anchor = state.runtime.anchors[0].joint;
        fixture.physics.teleport(node: first, position: { 6, 0, 0 }, rotation: maths::TRANSFORM_IDENTITY.rotation);
        fixture.physics.set_velocity(first, { 2, 3, 4 }, { 1, 0, 0 });
        fixture.scene.update_world();
        maths::Transform old_previous = fixture.scene.get(first, RigidBody).previous;
        maths::Transform old_current = fixture.scene.get(first, RigidBody).current;
        fixture.assets.mark_geometry_dirty(second_geometry);
        fixture.assets.release_geometry_cpu(second_geometry);

        assert(@catch(fixture.physics.reset_breakable(root, PIECES)) == physics::SOURCE_UNAVAILABLE);
        assert(fixture.scene.get(root, Breakable).state == state && state.form == PIECES && state.status == LIVE);
        assert(physics::same_breakable_body(fixture.physics.body(first)!!, old_first));
        assert(physics::same_breakable_body(fixture.physics.body(second)!!, old_second));
        assert(physics::same_breakable_joint(state.welds[0].joint, old_joint) && old_joint.is_valid());
        assert(physics::same_breakable_joint(state.runtime.anchors[0].joint, old_anchor) && old_anchor.is_valid());
        assert(first.world_position() == (Vec3){ 6, 0, 0 } && old_first.linear_velocity() == (Vec3){ 2, 3, 4 });
        assert(old_first.angular_velocity() == (Vec3){ 1, 0, 0 });
        assert(fixture.scene.get(first, RigidBody).previous.position == old_previous.position);
        assert(fixture.scene.get(first, RigidBody).current.position == old_current.position);
        assert(fixture.physics.world.counters().body_count == 3 && fixture.physics.world.counters().joint_count == 2);
        assert_snapshot_holders_match(&fixture);

        fixture.assets.geometry(second_geometry).data = geometry::box(
            allocator: fixture.assets.allocator,
            width: 1,
            height: 1,
            depth: 1,
        );
        fixture.assets.mark_geometry_dirty(second_geometry);
        fixture.physics.reset_breakable(root, PIECES)!!;
        assert(fixture.scene.get(root, Breakable).state == state && !old_first.is_valid() && !old_second.is_valid());
        assert(!old_joint.is_valid() && !old_anchor.is_valid() && state.welds[0].joint.is_valid() && !state.welds[0].broken);
        assert(first.world_position() == (Vec3){} && second.world_position() == (Vec3){ 1, 0, 0 });
        RigidBody* body = fixture.scene.get(first, RigidBody);
        assert(body.body.linear_velocity() == (Vec3){} && body.body.angular_velocity() == (Vec3){});
        assert(body.previous.position == body.current.position && body.current.position == (Vec3){});
        assert_snapshot_holders_match(&fixture);

        fixture.physics.reset_breakable(root, ASSEMBLY)!!;
        b3::BodyId assembly = fixture.physics.body(root)!!;
        fixture.assets.mark_geometry_dirty(second_geometry);
        fixture.assets.release_geometry_cpu(second_geometry);
        assert(@catch(fixture.physics.wake_breakable(root)) == physics::SOURCE_UNAVAILABLE);
        assert(assembly.is_valid() && state.form == ASSEMBLY && !state.runtime.anchors[0].joint.is_valid());
        assert(fixture.physics.world.counters().body_count == 2 && fixture.physics.world.counters().joint_count == 0);
        assert_snapshot_holders_match(&fixture);

        fixture.assets.geometry(second_geometry).data = geometry::box(
            allocator: fixture.assets.allocator,
            width: 1,
            height: 1,
            depth: 1,
        );
        Geometry* changed = &fixture.assets.geometry(second_geometry).data;
        changed.positions[..] = {};
        changed.finalize();
        fixture.assets.mark_geometry_dirty(second_geometry);
        assert(@catch(fixture.physics.reset_breakable(root, PIECES)) == b3::DEGENERATE_GEOMETRY);
        assert(assembly.is_valid() && state.form == ASSEMBLY && fixture.physics.world.counters().body_count == 2);
        assert_snapshot_holders_match(&fixture);
        changed.positions[..] = fixture.assets.geometry(fixture.unit_cube).data.positions[..];
        changed.finalize();
        fixture.assets.mark_geometry_dirty(second_geometry);
        fixture.physics.reset_breakable(root, PIECES)!!;
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        assert(state.alive_welds == 1 && state.alive_anchors == 1);
        assert_snapshot_holders_match(&fixture);
    };
}

fn void test_breakable_strength_limits_have_independent_units_and_priority() @test {
    Vec3 force = { 3, 4, 0 };
    Vec3 torque = { 2, 3, 4 };
    BreakableStrength limits = { .force = 5, .twist = 2, .bending = 5 };
    physics::BreakableReaction reaction = physics::evaluate_breakable_reaction(
        force: force,
        torque: torque,
        axis: { 1, 0, 0 },
        strength: limits,
    );
    assert(reaction.matched && reaction.criterion == FORCE);
    assert(reaction.loads.force == 5 && reaction.loads.twist == 2 && reaction.loads.bending == 5);
    limits.force = float::max;
    reaction = physics::evaluate_breakable_reaction(
        force: force,
        torque: torque,
        axis: { -1, 0, 0 },
        strength: limits,
    );
    assert(reaction.matched && reaction.criterion == TWIST && reaction.loads.twist == 2 && reaction.loads.bending == 5);
    limits.twist = float::max;
    reaction = physics::evaluate_breakable_reaction(
        force: force,
        torque: torque,
        axis: { 1, 0, 0 },
        strength: limits,
    );
    assert(reaction.matched && reaction.criterion == BENDING);
    limits.bending = float::max;
    reaction = physics::evaluate_breakable_reaction(
        force: force,
        torque: torque,
        axis: { 1, 0, 0 },
        strength: limits,
    );
    assert(!reaction.matched);
    limits.force = 5.01f;
    reaction = physics::evaluate_breakable_reaction(
        force: force,
        torque: torque,
        axis: { 1, 0, 0 },
        strength: limits,
    );
    assert(!reaction.matched);
    limits.force = 0;
    reaction = physics::evaluate_breakable_reaction(
        force: {},
        torque: {},
        axis: { 0, 1, 0 },
        strength: limits,
    );
    assert(reaction.matched && reaction.criterion == FORCE && reaction.loads.force == 0);
}

fn void test_breakable_sampled_force_twist_and_bending_select_the_loaded_limit() @test {
    foreach (criterion : (BreakCriterion[3]){ FORCE, TWIST, BENDING }) {
        @pool() {
            Fixture fixture;
            setup(&fixture, weightless_desc());
            defer teardown(&fixture);
            Node* root = add_row(&fixture, 2);
            BreakableRecipeDesc recipe = row_recipe(&fixture, root);
            recipe.evaluation = SAMPLED_REACTION;
            recipe.strength = physics::default_breakable_strength(float::max);
            switch (criterion) {
                case FORCE: recipe.strength.force = 1;
                case TWIST: recipe.strength.twist = 1;
                case BENDING: recipe.strength.bending = 1;
            }
            fixture.physics.add_breakable_recipe(root, recipe)!!;
            BreakableState* state = fixture.scene.get(root, Breakable).state;
            b3::BodyId body = fixture.physics.body(fixture.scene.node(state.pieces[1]))!!;
            for (uint attempt = 0; attempt < 8 && !state.welds[0].broken; attempt++) {
                switch (criterion) {
                    case FORCE: b3::body_apply_force_to_center(body, { 0, 40, 0 }, true);
                    case TWIST: b3::body_apply_torque(body, { 40, 0, 0 }, true);
                    case BENDING: b3::body_apply_torque(body, { 0, 40, 0 }, true);
                }
                fixture.physics.update(physics::DEFAULT_FIXED_DT);
            }
            assert(state.welds[0].broken && fixture.physics.breaks().len == 1);
            BreakEvent event = fixture.physics.breaks()[0];
            assert(event.criterion == criterion && event.phase == POST_FIXED_STEP && event.loads_available);
            switch (criterion) {
                case FORCE: assert(event.loads.force >= 1);
                case TWIST: assert(event.loads.twist >= 1);
                case BENDING: assert(event.loads.bending >= 1);
            }
        };
    }
}

fn void test_breakable_sample_uses_native_pose_and_post_step_getters() @test {
    foreach (substeps : (int[2]){ 1, 4 }) {
        @pool() {
            Fixture fixture;
            setup(&fixture, weightless_desc());
            defer teardown(&fixture);
            Node* root = add_row(&fixture, 2);
            BreakableRecipeDesc recipe = row_recipe(&fixture, root);
            recipe.evaluation = SAMPLED_REACTION;
            recipe.strength = physics::default_breakable_strength(0);
            recipe.welds[0].moment_axis = { 0, 1, 0 };
            fixture.physics.add_breakable_recipe(root, recipe)!!;
            BreakableState* state = fixture.scene.get(root, Breakable).state;
            Node* first = fixture.scene.node(state.pieces[0]);
            b3::BodyId body = fixture.physics.body(first)!!;
            Quat rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, 0.4f);
            body.set_transform((b3::Pos){}, rotation);
            b3::body_apply_torque(body, { 20, 30, 40 }, true);
            b3::world_step(fixture.physics.world, physics::DEFAULT_FIXED_DT, substeps);
            b3::JointId joint = state.welds[0].joint;
            Vec3 axis = body.world_vector(recipe.welds[0].moment_axis);
            Vec3 torque = joint.constraint_torque();
            Vec3 point = body.world_point(recipe.welds[0].frame_a.position);
            float twist = torque.dot(axis);
            Vec3 stale_point = maths::transform_point(first.world, recipe.welds[0].frame_a.position);
            assert((point - stale_point).length() > 0.01f);
            physics::sample_breakables(&fixture.physics);
            BreakEvent event = fixture.physics.breaks()[0];
            assert((event.point - point).length() < 1e-5f);
            assert(math::abs(event.loads.force - joint.constraint_force().length()) < 1e-5f);
            assert(math::abs(event.loads.twist - math::abs(twist)) < 1e-5f);
            assert(math::abs(event.loads.bending - (torque - axis * twist).length()) < 1e-5f);
            physics::finish_breakable_step(&fixture.physics);
            assert(!joint.is_valid());
        };
    }
}

fn void test_breakable_sampled_reports_are_ordered_and_capacity_independent() @test {
    foreach (capacity : (uint[3]){ 0, 1, 2 }) {
        @pool() {
            Fixture fixture;
            PhysicsDesc desc = weightless_desc();
            desc.event_capacity = capacity;
            setup(&fixture, desc);
            defer teardown(&fixture);
            Node* root = add_row(&fixture, 2);
            Node* target = add_static_box(&fixture, { -2, 0, 0 }, { 0.5f, 0.5f, 0.5f });
            BreakableRecipeDesc recipe = row_recipe(&fixture, root, target);
            recipe.anchors[0].frame_b.position.x = 1.5f;
            recipe.evaluation = SAMPLED_REACTION;
            recipe.strength = { .force = 0, .twist = 0, .bending = 0 };
            fixture.physics.add_breakable_recipe(root, recipe)!!;
            BreakableState* state = fixture.scene.get(root, Breakable).state;
            fixture.physics.update(0);
            assert(!state.welds[0].broken && state.alive_anchors == 1 && fixture.physics.breaks().len == 0);
            fixture.physics.update(2 * physics::DEFAULT_FIXED_DT);
            assert(state.welds[0].broken && state.runtime.anchors[0].broken);
            assert(state.alive_welds == 0 && state.alive_anchors == 0 && fixture.physics.world.counters().joint_count == 0);
            assert(fixture.physics.breaks().len == capacity && fixture.physics.dropped_events == 2 - capacity);
            foreach (uint index, event : fixture.physics.breaks()) {
                assert(event.edge_kind == (index == 0 ? INTERNAL_WELD : ANCHOR));
                assert(event.edge_index == 0 && event.criterion == FORCE && event.phase == POST_FIXED_STEP);
                assert(event.loads_available && c3d::same_id(event.root_id, root.id));
                assert(c3d::same_id(event.endpoint_a, state.pieces[0]));
                assert(c3d::same_id(event.endpoint_b, index == 0 ? state.pieces[1] : target.id));
            }
            fixture.physics.reset_breakable(root, PIECES)!!;
            assert(fixture.physics.breaks().len == capacity && fixture.physics.dropped_events == 2 - capacity);
        };
    }
}

fn void test_breakable_identical_impacts_leave_only_the_supported_component_attached() @test {
    Vec3[2] first_positions;
    foreach (anchored : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            setup(&fixture, weightless_desc());
            defer teardown(&fixture);
            Node* root = add_row(&fixture, 2);
            Node* target = add_static_box(&fixture, { -2, 0, 0 }, { 0.5f, 0.5f, 0.5f });
            BreakableRecipeDesc recipe = row_recipe(&fixture, root, anchored ? target : null);
            recipe.evaluation = SAMPLED_REACTION;
            recipe.strength = physics::default_breakable_strength(1);
            if (anchored) {
                recipe.anchors[0].frame_b.position.x = 1.5f;
                recipe.anchors[0].has_strength_override = true;
                recipe.anchors[0].strength_override = physics::default_breakable_strength(float::max);
            }
            fixture.physics.add_breakable_recipe(root, recipe)!!;
            BreakableState* state = fixture.scene.get(root, Breakable).state;
            Node* first = fixture.scene.node(state.pieces[0]);
            Node* second = fixture.scene.node(state.pieces[1]);
            fixture.physics.apply_impulse(node: second, impulse: { 0, 20, 0 }, world_point: second.world_position());
            step(&fixture, 1);
            assert(fixture.physics.breaks().len == 1 && fixture.physics.breaks()[0].edge_kind == INTERNAL_WELD);
            assert(fixture.physics.breaks()[0].loads.force >= 1);
            step(&fixture, 29);
            assert(state.welds[0].broken && state.alive_welds == 0);
            assert((second.world_position() - (Vec3){ 1, 0, 0 }).length() > 0.5f);
            assert(target.world_position() == (Vec3){ -2, 0, 0 });
            assert(fixture.physics.world.counters().joint_count == (anchored ? 1 : 0));
            if (anchored) assert(!state.runtime.anchors[0].broken && state.runtime.anchors[0].joint.is_valid());
            first_positions[anchored ? 1 : 0] = first.world_position();
        };
    }
    assert(first_positions[0].y > 0.2f && first_positions[1].length() < LOOSE_TOLERANCE);
}

fn void test_breakable_anchor_rebinds_same_entity_but_never_deleted_or_broken_entries() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        Node* target = add_static_box(&fixture, { -1, 0, 0 }, { 0.5f, 0.5f, 0.5f });
        BreakableRecipeDesc recipe = row_recipe(&fixture, root, target);
        recipe.strength = physics::default_breakable_strength(float::max);
        BreakableAnchorDesc[2] anchors = { recipe.anchors[0], recipe.anchors[0] };
        anchors[0].has_strength_override = true;
        anchors[0].strength_override = physics::default_breakable_strength(0);
        recipe.anchors = &anchors;
        fixture.physics.add_breakable_recipe(root, recipe)!!;
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        BreakableState* state = fixture.scene.get(root, Breakable).state;
        assert(state.runtime.anchors[0].broken && !state.runtime.anchors[1].broken && state.alive_anchors == 1);
        assert(fixture.physics.breaks().len == 1 && !fixture.physics.breaks()[0].loads_available);
        assert(fixture.physics.breaks()[0].phase == NATIVE_THRESHOLD);
        b3::BodyId original_target = fixture.physics.body(target)!!;
        fixture.physics.remove_body(target);
        fixture.physics.update(0);
        assert(!state.runtime.anchors[1].joint.is_valid() && fixture.physics.build_failures().len == 1);
        assert(fixture.physics.breaks().len == 0 && state.alive_anchors == 1);

        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = { 0.5f, 0.5f, 0.5f };
        fixture.physics.add_body(target, physics::default_body_desc(STATIC), (&collider)[:1])!!;
        fixture.physics.update(0);
        assert(!original_target.is_valid() && state.runtime.anchors[1].joint.is_valid());
        assert(!state.runtime.anchors[0].joint.is_valid() && state.runtime.anchors[0].broken);
        fixture.scene.get(target, PhysicsBody).body.kind = DYNAMIC;
        fixture.scene.get(target, PhysicsBody).mark_changed();
        fixture.physics.update(0);
        assert(!state.runtime.anchors[1].joint.is_valid() && fixture.physics.build_failures()[0].reason == c3d::INVALID_ARGUMENT);
        fixture.scene.get(target, PhysicsBody).body.kind = STATIC;
        fixture.scene.get(target, PhysicsBody).mark_changed();
        fixture.physics.update(0);
        assert(state.runtime.anchors[1].joint.is_valid());

        for (uint repeat = 0; repeat < 3; repeat++) {
            if (repeat == 1) {
                Entity removed = target.id;
                fixture.scene.remove(target);
                target = add_static_box(&fixture, { -1, 0, 0 }, { 0.5f, 0.5f, 0.5f });
                assert(target.id.index == removed.index && !c3d::same_id(target.id, removed));
            }
            physics::destroy_physics_world(&fixture.physics);
            create_world(&fixture, weightless_desc());
            fixture.physics.update(0);
            assert(state.anchor_count() == 2 && state.runtime.anchors[0].broken);
            assert(state.alive_anchors == (repeat == 0 ? 1 : 0));
            assert(fixture.physics.world.counters().body_count == 3);
            assert(fixture.physics.world.counters().joint_count == (repeat == 0 ? 2 : 1));
            if (repeat) assert(state.runtime.anchors[0].pruned && state.runtime.anchors[1].pruned);
        }
    };
}

fn void test_breakable_reset_repairs_forms_and_preserves_borrowed_targets() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        Node* target = add_static_box(&fixture, { -1, 0, 0 }, { 0.5f, 0.5f, 0.5f });
        Node* visitor = add_visitor(&fixture, { 10, 0, 0 }, 1);
        BreakableRecipeDesc recipe = row_recipe(&fixture, root, target);
        recipe.settings.sleep_until_hit = true;
        recipe.strength = physics::default_breakable_strength(float::max);
        fixture.physics.add_breakable_recipe(root, recipe)!!;
        BreakableState* state = fixture.scene.get(root, Breakable).state;
        b3::BodyId support = fixture.physics.body(target)!!;
        b3::FilterJointDef external = b3::default_filter_joint_def();
        external.base.body_id_a = support;
        external.base.body_id_b = fixture.physics.body(visitor)!!;
        b3::JointId support_joint = b3::create_filter_joint(fixture.physics.world, &external)!!;
        assert(state.form == ASSEMBLY && !state.runtime.anchors[0].joint.is_valid());
        fixture.physics.wake_breakable(root)!!;
        Node* first = fixture.scene.node(state.pieces[0]);
        Node* second = fixture.scene.node(state.pieces[1]);
        b3::BodyId original = fixture.physics.body(first)!!;
        maths::Transform incompatible = maths::TRANSFORM_IDENTITY;
        incompatible.position = { 0, 3, 0 };
        assert(@catch(fixture.physics.reset_breakable(
            root: root,
            form: PIECES,
            root_pose: &incompatible,
        )) == c3d::INVALID_ARGUMENT);
        assert(original.is_valid() && support_joint.is_valid() && support.is_valid());

        external.base.body_id_a = original;
        b3::JointId foreign = b3::create_filter_joint(fixture.physics.world, &external)!!;
        assert(@catch(fixture.physics.reset_breakable(root, ASSEMBLY)) == c3d::INVALID_ARGUMENT);
        assert(foreign.is_valid() && original.is_valid());
        b3::destroy_joint(foreign, true);
        fixture.physics.reset_breakable(root, ASSEMBLY)!!;
        assert(state.form == ASSEMBLY && !original.is_valid() && support_joint.is_valid() && support.is_valid());
        assert(first.transform_space == TransformSpace.PARENT && second.transform_space == TransformSpace.PARENT);
        fixture.physics.reset_breakable(root, PIECES)!!;
        assert(state.form == PIECES && state.welds[0].joint.is_valid() && state.runtime.anchors[0].joint.is_valid());
        assert(first.transform_space == TransformSpace.WORLD && support_joint.is_valid());

        fixture.scene.remove(second);
        fixture.physics.reset_breakable(root, PIECES)!!;
        assert(state.alive_pieces == 1 && state.alive_welds == 0 && state.alive_anchors == 1);
        assert(fixture.physics.world.counters().body_count == 3 && fixture.physics.world.counters().joint_count == 2);
        fixture.scene.remove(first);
        fixture.physics.reset_breakable(root, ASSEMBLY)!!;
        assert(state.alive_pieces == 0 && state.alive_anchors == 0 && state.form == ASSEMBLY);
        assert(fixture.physics.world.counters().body_count == 2 && fixture.physics.world.counters().joint_count == 1);
        assert(support_joint.is_valid() && support.is_valid());
    };
}

fn void test_breakable_reset_capacity_failure_and_pending_completion_release_owned_storage() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        @pool() {
            Fixture fixture;
            setup(&fixture, weightless_desc(), &tracker);
            defer teardown(&fixture);
            Node* root = add_row(&fixture, 2);
            BreakableRecipeDesc recipe = row_recipe(&fixture, root);
            fixture.scene.attach_breakable_recipe(assets: &fixture.assets, root: root, recipe: recipe)!!;
            BreakableState* pending = fixture.scene.get(root, Breakable).state;
            NullAllocator failure;
            Allocator original = fixture.scene.allocator;
            fixture.scene.allocator = &failure;
            assert(@catch(fixture.physics.reset_breakable(root, PIECES)) == c3d::CAPACITY_EXCEEDED);
            fixture.scene.allocator = original;
            assert(fixture.scene.get(root, Breakable).state == pending && !fixture.scene.get(root, Breakable).is_prepared());
            assert(fixture.physics.world.counters().body_count == 0 && fixture.physics.world.counters().joint_count == 0);
            fixture.physics.reset_breakable(root, PIECES)!!;
            BreakableState* prepared = fixture.scene.get(root, Breakable).state;
            assert(prepared != pending && fixture.scene.get(root, Breakable).is_prepared());
            b3::BodyId first = fixture.physics.body(fixture.scene.node(prepared.pieces[0]))!!;
            sz allocations = tracker.allocation_count();
            fixture.scene.allocator = &failure;
            assert(@catch(fixture.physics.reset_breakable(root, ASSEMBLY)) == c3d::CAPACITY_EXCEEDED);
            fixture.scene.allocator = original;
            assert(first.is_valid() && fixture.scene.get(root, Breakable).state == prepared);
            assert(tracker.allocation_count() == allocations);
            prepared.status = FAILED;
            prepared.failure = physics::SOURCE_UNAVAILABLE;
            fixture.physics.reset_breakable(root, ASSEMBLY)!!;
            assert(prepared.status == LIVE && prepared.failure == (fault){} && prepared.form == ASSEMBLY);
            fixture.physics.remove_breakable(root);
            assert(fixture.physics.world.counters().body_count == 0 && fixture.physics.world.counters().joint_count == 0);
            assert_snapshot_holders_match(&fixture);
        };
    }
    assert(!tracker.has_leaks());
}

fn void test_breakable_recipe_rejects_invalid_strength_frames_and_foreign_descendant_roles() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        BreakableRecipeDesc recipe = row_recipe(&fixture, root);
        BreakableStrength[3] invalid = {
            { .force = -1, .twist = float::max, .bending = float::max },
            { .force = float::nan, .twist = float::max, .bending = float::max },
            { .force = 1, .twist = float::max, .bending = bitcast(0x7f800000u, float) },
        };
        foreach (strength : invalid) {
            recipe.strength = strength;
            assert(@catch(fixture.scene.attach_breakable_recipe(
                assets: &fixture.assets,
                root: root,
                recipe: recipe,
            )) == c3d::INVALID_ARGUMENT);
            assert(!fixture.scene.has(root, Breakable));
        }
        recipe.strength = physics::default_breakable_strength();
        recipe.strength.twist = 1;
        assert(@catch(fixture.physics.add_breakable_recipe(root, recipe)) == c3d::INVALID_ARGUMENT);
        recipe.strength = physics::default_breakable_strength();
        recipe.welds[0].moment_axis = {};
        assert(@catch(fixture.physics.add_breakable_recipe(root, recipe)) == c3d::INVALID_ARGUMENT);
        recipe.welds[0].moment_axis = { 1, 0, 0 };
        recipe.welds[0].frame_b.position.x = 5;
        assert(@catch(fixture.physics.add_breakable_recipe(root, recipe)) == c3d::INVALID_ARGUMENT);
        recipe.welds[0].frame_b.position.x = -0.5f;
        recipe.welds[0].piece_b = 2;
        assert(@catch(fixture.physics.add_breakable_recipe(root, recipe)) == c3d::INVALID_ARGUMENT);
        recipe.welds[0].piece_b = 1;
        BreakableWeldDesc[] welds = recipe.welds;
        usz excessive_count = (usz)uint::max + 1;
        recipe.welds = welds.ptr[:excessive_count];
        assert(@catch(fixture.physics.add_breakable_recipe(root, recipe)) == c3d::CAPACITY_EXCEEDED);
        recipe.welds = welds;

        recipe.welds = {};
        recipe.pieces[0].rest_frame.rotation = {};
        assert(@catch(fixture.scene.attach_breakable_recipe(
            assets: &fixture.assets,
            root: root,
            recipe: recipe,
        )) == c3d::INVALID_ARGUMENT);
        recipe.pieces[0].rest_frame.rotation = maths::TRANSFORM_IDENTITY.rotation;
        recipe.welds = welds;

        Node* independent = fixture.scene.add_node(root, "independent")!!;
        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = { 1, 1, 1 };
        fixture.scene.add_physics_body(independent, physics::default_body_desc(STATIC), (&collider)[:1])!!;
        fixture.scene.update_world();
        assert(@catch(fixture.physics.add_breakable_recipe(root, recipe)) == physics::BODY_EXISTS);
        assert(!fixture.scene.has(root, Breakable) && fixture.scene.count(PhysicsBody) == 1);
        assert(fixture.physics.world.counters().body_count == 0 && fixture.physics.world.counters().joint_count == 0);
    };
}

fn void test_breakable_strength_override_replaces_the_whole_weaker_material_value() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        Node* target = add_static_box(&fixture, { -1, 0, 0 }, { 0.5f, 0.5f, 0.5f });
        BreakableRecipeDesc recipe = row_recipe(&fixture, root, target);
        recipe.evaluation = SAMPLED_REACTION;
        recipe.pieces[0].has_strength = true;
        recipe.pieces[0].strength = { .force = 4, .twist = 5, .bending = 6 };
        recipe.pieces[1].has_strength = true;
        recipe.pieces[1].strength = { .force = 6, .twist = 3, .bending = 9 };
        recipe.anchors[0].has_target_strength = true;
        recipe.anchors[0].target_strength = { .force = 2, .twist = 4, .bending = 7 };
        fixture.scene.attach_breakable_recipe(assets: &fixture.assets, root: root, recipe: recipe)!!;
        BreakableState* state = fixture.scene.get(root, Breakable).state;
        BreakableStrength combined = state.weld_view(0).strength;
        assert(combined.force == 4 && combined.twist == 3 && combined.bending == 6);
        assert(state.anchor_view(0).strength.force == 2 && state.anchor_view(0).strength.bending == 6);
        fixture.physics.remove_breakable(root);

        recipe.welds[0].has_strength_override = true;
        recipe.welds[0].strength_override = { .force = 10, .twist = 0, .bending = float::max };
        recipe.anchors[0].has_strength_override = true;
        recipe.anchors[0].strength_override = physics::default_breakable_strength(float::max);
        fixture.scene.attach_breakable_recipe(assets: &fixture.assets, root: root, recipe: recipe)!!;
        state = fixture.scene.get(root, Breakable).state;
        combined = state.weld_view(0).strength;
        assert(combined.force == 10 && combined.twist == 0 && combined.bending == float::max);
        assert(state.anchor_view(0).strength.force == float::max);
    };
}

fn void test_breakable_reset_rejects_replacement_bodies_without_destroying_them() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        fixture.physics.add_breakable_recipe(root, row_recipe(&fixture, root))!!;
        BreakableState* state = fixture.scene.get(root, Breakable).state;
        Node* piece = fixture.scene.node(state.pieces[0]);
        fixture.physics.remove_body(piece);
        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = { 0.2f, 0.3f, 0.4f };
        fixture.physics.add_body(piece, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;
        b3::BodyId replacement = fixture.physics.body(piece)!!;
        assert(@catch(fixture.physics.reset_breakable(root, PIECES)) == c3d::INVALID_ARGUMENT);
        assert(replacement.is_valid() && physics::same_breakable_body(fixture.physics.body(piece)!!, replacement));
        assert(fixture.scene.get(piece, PhysicsBody).colliders[0].half_extents == (Vec3){ 0.2f, 0.3f, 0.4f });
        fixture.physics.remove_body(piece);
        fixture.physics.reset_breakable(root, PIECES)!!;
        assert(state.welds[0].joint.is_valid() && fixture.physics.world.counters().body_count == 2);
        maths::Transform pose = {
            .position = { 2, 3, 4 },
            .rotation = quaternion::from_axis_angle((Vec3){ 0, 1, 0 }, 0.6f),
            .scale = { 1, 1, 1 },
        };
        fixture.physics.reset_breakable(root: root, form: PIECES, root_pose: &pose)!!;
        assert((root.world_position() - pose.position).length() < 1e-5f);
        foreach (uint index, entity : state.pieces) {
            Vec3 expected = pose.position + pose.rotation.rotate_vec3(state.piece_view(index).rest_frame.position);
            RigidBody* body = fixture.scene.get(fixture.scene.node(entity), RigidBody);
            assert((body.current.position - expected).length() < 1e-5f && body.previous.position == body.current.position);
            assert((body.current.rotation.v - pose.rotation.v).length() < 1e-5f);
        }
    };
}

fn void test_breakable_reset_prepares_legacy_survivors_without_deleted_sources() @test {
    Fixture fixture;
    setup(&fixture, weightless_desc());
    defer teardown(&fixture);
    Node* root = add_row(&fixture, 2);
    attach_pending_row(&fixture, root, physics::default_breakable_desc());
    fixture.scene.remove(root.first_child);
    fixture.physics.reset_breakable(root, ASSEMBLY)!!;
    BreakableState* state = fixture.scene.get(root, Breakable).state;
    assert(state.recipe_kind == LEGACY_CURRENT_POSE && state.alive_pieces == 1 && state.welds.len == 0);
    assert(fixture.physics.world.counters().body_count == 1 && fixture.physics.world.counters().joint_count == 0);
    fixture.scene.remove(root.first_child);
    fixture.assets.mark_geometry_dirty(fixture.unit_cube);
    fixture.assets.release_geometry_cpu(fixture.unit_cube);
    fixture.physics.reset_breakable(root, PIECES)!!;
    assert(state.alive_pieces == 0 && state.form == PIECES);
    assert(fixture.physics.world.counters().body_count == 0 && fixture.physics.world.counters().joint_count == 0);
}

fn void test_breakable_reset_repairs_one_break_cycle_across_repeated_world_rebuilds() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        BreakableRecipeDesc recipe = row_recipe(&fixture, root);
        recipe.strength.force = 0;
        fixture.physics.add_breakable_recipe(root, recipe)!!;
        BreakableState* state = fixture.scene.get(root, Breakable).state;
        for (uint repeat = 0; repeat < 3; repeat++) {
            fixture.physics.update(physics::DEFAULT_FIXED_DT);
            assert(state.welds[0].broken && fixture.physics.breaks().len == 1);
            fixture.physics.reset_breakable(root, PIECES)!!;
            assert(!state.welds[0].broken && state.welds[0].joint.is_valid());
            assert(fixture.physics.breaks().len == 1);
            physics::destroy_physics_world(&fixture.physics);
            create_world(&fixture, weightless_desc());
            fixture.physics.update(0);
            assert(!state.welds[0].broken && state.welds[0].joint.is_valid());
            assert(fixture.physics.world.counters().body_count == 2 && fixture.physics.world.counters().joint_count == 1);
            assert_snapshot_holders_match(&fixture);
        }
    };
}

fn void test_breakable_reset_snapshot_capacity_keeps_the_live_revision_until_rebuild() @test {
    @pool() {
        Fixture fixture;
        PhysicsDesc desc = weightless_desc();
        desc.snapshot_capacity = 1;
        setup(&fixture, desc);
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        fixture.physics.add_breakable_recipe(root, row_recipe(&fixture, root))!!;
        BreakableState* state = fixture.scene.get(root, Breakable).state;
        b3::BodyId original = fixture.physics.body(fixture.scene.node(state.pieces[0]))!!;
        b3::JointId weld = state.welds[0].joint;
        fixture.assets.mark_geometry_dirty(fixture.unit_cube);
        assert(@catch(fixture.physics.reset_breakable(root, PIECES)) == c3d::CAPACITY_EXCEEDED);
        assert(original.is_valid() && weld.is_valid() && state.status == LIVE);
        assert(fixture.physics.world.counters().body_count == 2 && fixture.physics.world.counters().joint_count == 1);
        assert_snapshot_holders_match(&fixture);

        physics::destroy_physics_world(&fixture.physics);
        create_world(&fixture, desc);
        fixture.physics.update(0);
        fixture.physics.reset_breakable(root, PIECES)!!;
        assert(state.status == LIVE && state.welds[0].joint.is_valid());
        assert_snapshot_holders_match(&fixture);
    };
}
