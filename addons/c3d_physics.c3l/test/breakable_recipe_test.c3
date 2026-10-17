module c3d_physics_breakable_test;

import c3d;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math;
import std::math::quaternion;
import b3;

fn BreakableRecipeDesc row_recipe(Fixture* fixture, Node* root, Node* target = null) @local {
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

fn void test_breakable_recipe_authoring_and_strength_overrides() @test {
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
        recipe.evaluation = SAMPLED_REACTION;
        recipe.pieces[0].has_strength = true;
        recipe.pieces[0].strength = { .force = 4, .twist = 5, .bending = 6 };
        recipe.pieces[1].has_strength = true;
        recipe.pieces[1].strength = { .force = 6, .twist = 3, .bending = 9 };
        recipe.anchors[0].has_target_strength = true;
        recipe.anchors[0].target_strength = { .force = 2, .twist = 4, .bending = 7 };
        fixture.scene.attach_breakable_recipe(assets: &fixture.assets, root: root, recipe: recipe)!!;

        BreakableState* pending = fixture.scene.get(root, Breakable).state;
        assert(!fixture.scene.get(root, Breakable).is_prepared());
        BreakableStrength combined = pending.weld_view(0).strength;
        assert(combined.force == 4 && combined.twist == 3 && combined.bending == 6);
        assert(pending.anchor_view(0).strength.force == 2 && pending.anchor_view(0).strength.bending == 6);

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
        fixture.physics.update(0);
        fixture.physics.prepare_breakable_subtree(root)!!;
        BreakableState* prepared = fixture.scene.get(root, Breakable).state;
        assert(prepared.recipe_kind == AUTHORED_REST && prepared.welds.len == 1 && prepared.anchor_count() == 1);
        assert(fixture.physics.world.counters().body_count == 3 && fixture.physics.world.counters().joint_count == 2);
        fixture.physics.remove_breakable(root);

        recipe = row_recipe(&fixture, root, target);
        recipe.evaluation = SAMPLED_REACTION;
        recipe.welds[0].has_strength_override = true;
        recipe.welds[0].strength_override = { .force = 10, .twist = 0, .bending = float::max };
        fixture.scene.attach_breakable_recipe(assets: &fixture.assets, root: root, recipe: recipe)!!;
        combined = fixture.scene.get(root, Breakable).state.weld_view(0).strength;
        assert(combined.force == 10 && combined.twist == 0 && combined.bending == float::max);
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
        };
    }
}

fn void test_breakable_sampled_reports_and_anchors() @test {
    @pool() {
        Fixture fixture;
        PhysicsDesc desc = weightless_desc();
        desc.event_capacity = 1;
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
        fixture.physics.update(2 * physics::DEFAULT_FIXED_DT);
        assert(state.welds[0].broken && state.runtime.anchors[0].broken);
        assert(state.alive_welds == 0 && state.alive_anchors == 0);
        assert(fixture.physics.breaks().len == 1 && fixture.physics.dropped_events == 1);

        BreakEvent event = fixture.physics.breaks()[0];
        assert(event.edge_kind == INTERNAL_WELD && event.criterion == FORCE && event.phase == POST_FIXED_STEP);
        assert(event.loads_available && c3d::same_id(event.root_id, root.id));
    };

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

        fixture.physics.remove_body(target);
        fixture.physics.update(0);
        assert(!state.runtime.anchors[1].joint.is_valid() && fixture.physics.build_failures().len == 1);

        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = { 0.5f, 0.5f, 0.5f };
        fixture.physics.add_body(target, physics::default_body_desc(STATIC), (&collider)[:1])!!;
        fixture.physics.update(0);
        assert(state.runtime.anchors[1].joint.is_valid() && !state.runtime.anchors[0].joint.is_valid());
    };
}

fn void test_breakable_recipe_rejects_invalid_strength_frames_and_foreign_descendant_roles() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        BreakableRecipeDesc recipe = row_recipe(&fixture, root);
        recipe.strength = { .force = -1, .twist = float::max, .bending = float::max };
        assert(@catch(fixture.scene.attach_breakable_recipe(
            assets: &fixture.assets,
            root: root,
            recipe: recipe,
        )) == c3d::INVALID_ARGUMENT);

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

        Node* independent = fixture.scene.add_node(root, "independent")!!;
        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = { 1, 1, 1 };
        fixture.scene.add_physics_body(independent, physics::default_body_desc(STATIC), (&collider)[:1])!!;
        fixture.scene.update_world();
        assert(@catch(fixture.physics.add_breakable_recipe(root, recipe)) == physics::BODY_EXISTS);
        assert(!fixture.scene.has(root, Breakable));
    };
}

fn void test_breakable_reset_repairs_forms_poses_and_world_rebuilds() @test {
    @pool() {
        Fixture fixture;
        setup(&fixture, weightless_desc());
        defer teardown(&fixture);
        Node* root = add_row(&fixture, 2);
        Node* target = add_static_box(&fixture, { -1, 0, 0 }, { 0.5f, 0.5f, 0.5f });
        BreakableRecipeDesc recipe = row_recipe(&fixture, root, target);
        recipe.strength.force = 0;
        fixture.physics.add_breakable_recipe(root, recipe)!!;
        BreakableState* state = fixture.scene.get(root, Breakable).state;

        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        assert(state.welds[0].broken && state.runtime.anchors[0].broken);

        fixture.physics.reset_breakable(root, ASSEMBLY)!!;
        assert(state.form == ASSEMBLY && !state.runtime.anchors[0].joint.is_valid());

        fixture.physics.reset_breakable(root, PIECES)!!;
        assert(state.form == PIECES && !state.welds[0].broken && state.welds[0].joint.is_valid());
        assert(state.runtime.anchors[0].joint.is_valid());

        fixture.physics.remove_breakable(root);
        recipe = row_recipe(&fixture, root);
        fixture.physics.add_breakable_recipe(root, recipe)!!;
        state = fixture.scene.get(root, Breakable).state;

        maths::Transform pose = {
            .position = { 2, 3, 4 },
            .rotation = quaternion::from_axis_angle((Vec3){ 0, 1, 0 }, 0.6f),
            .scale = { 1, 1, 1 },
        };
        fixture.physics.reset_breakable(root: root, form: PIECES, root_pose: &pose)!!;
        assert((root.world_position() - pose.position).length() < 1e-5f);

        physics::destroy_physics_world(&fixture.physics);
        create_world(&fixture, weightless_desc());
        fixture.physics.update(0);
        assert(!state.welds[0].broken && state.welds[0].joint.is_valid());
        assert_snapshot_holders_match(&fixture);
    };
}
