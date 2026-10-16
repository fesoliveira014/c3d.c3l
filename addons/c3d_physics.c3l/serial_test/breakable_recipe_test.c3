module c3d_physics_serial_test;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import c3d::serial @public;
import std::core::mem::allocators;
import std::math::quaternion;
import b3;

struct SerialBreakableNodes @private {
    Node* common;
    Node*[] pieces;
    Node* first_support;
    Node* last_support;
}

fn SerialBreakableNodes add_serial_breakable_nodes(Fixture* fixture) @private {
    SerialBreakableNodes nodes;
    nodes.common = fixture.source.add_node(name: "anchored_group")!!;
    fixture.source.reparent(fixture.root, nodes.common);
    fixture.root.local.position = { 3, 4, 5 };
    nodes.pieces = add_breakable_row(fixture, 4);
    nodes.first_support = add_sphere(
        scene: &fixture.source,
        parent: nodes.common,
        name: "support_a",
        kind: STATIC,
    );
    nodes.last_support = add_sphere(
        scene: &fixture.source,
        parent: nodes.common,
        name: "support_b",
        kind: STATIC,
    );
    nodes.first_support.local.position = { 2, 4, 5 };
    nodes.last_support.local.position = { 7, 4, 5 };
    fixture.source.update_world();
    return nodes;
}

fn BreakableRecipeDesc serial_breakable_recipe(Fixture* fixture, SerialBreakableNodes nodes) @private {
    BreakableRecipeDesc recipe = physics::default_breakable_recipe_desc();
    recipe.settings.sleep_until_hit = false;
    recipe.settings.density = 1;
    recipe.evaluation = SAMPLED_REACTION;
    recipe.strength = { .force = 800, .twist = 60, .bending = 90 };
    recipe.pieces = alloc::new_array(tmem, BreakablePieceView, nodes.pieces.len);
    foreach (index, node : nodes.pieces) {
        recipe.pieces[index] = { .node = node.id, .hulls = (&fixture.geometry)[:1], .rest_frame = node.local };
    }
    recipe.pieces[0].has_strength = true;
    recipe.pieces[0].strength = { .force = 600, .twist = 50, .bending = 80 };
    recipe.pieces[2].has_strength = true;
    recipe.pieces[2].strength = { .force = 700, .twist = 40, .bending = 100 };
    Quat frame_rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, 0.35f);
    recipe.welds = alloc::new_array(tmem, BreakableWeldDesc, 3);
    foreach (uint index, &weld : recipe.welds) {
        *weld = {
            .piece_a = index,
            .piece_b = index + 1,
            .frame_a = { .position = { 0.5f, 0, 0 }, .rotation = frame_rotation, .scale = { 1, 1, 1 } },
            .frame_b = { .position = { -0.5f, 0, 0 }, .rotation = frame_rotation, .scale = { 1, 1, 1 } },
            .moment_axis = { 1, 0, 0 },
        };
    }
    recipe.welds[0].has_strength_override = true;
    recipe.welds[0].strength_override = physics::default_breakable_strength(0);
    recipe.welds[1].has_strength_override = true;
    recipe.welds[1].strength_override = { .force = 900, .twist = 20, .bending = float::max };
    recipe.anchors = alloc::new_array(tmem, BreakableAnchorDesc, 2);
    recipe.anchors[0] = {
        .piece = 0,
        .target = nodes.first_support.id,
        .frame_a = { .position = { -0.5f, 0, 0 }, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
        .frame_b = { .position = { 0.5f, 0, 0 }, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
        .moment_axis = { 0, 0, 1 },
        .target_strength = { .force = 1200, .twist = 70, .bending = 90 },
        .strength_override = physics::default_breakable_strength(float::max),
        .has_target_strength = true,
        .has_strength_override = true,
    };
    recipe.anchors[1] = {
        .piece = 3,
        .target = nodes.last_support.id,
        .frame_a = { .position = { 0.5f, 0, 0 }, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
        .frame_b = { .position = { -0.5f, 0, 0 }, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
        .moment_axis = { 0, 1, 0 },
        .strength_override = physics::default_breakable_strength(float::max),
        .has_strength_override = true,
    };
    return recipe;
}

fn void test_breakable_authored_rest_round_trips_without_mutation_and_remaps_survivors() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            SerialBreakableNodes nodes = add_serial_breakable_nodes(&fixture);
            BreakableRecipeDesc recipe = serial_breakable_recipe(&fixture, nodes);
            PhysicsWorld source_world = create_world(&fixture.source, &fixture.assets);
            defer physics::destroy_physics_world(&source_world);
            source_world.update(0);
            source_world.add_breakable_recipe(fixture.root, recipe)!!;
            source_world.update(physics::DEFAULT_FIXED_DT);
            BreakableState* original = fixture.source.get(fixture.root, Breakable).state;
            assert(original.welds[0].broken && !original.welds[1].broken);
            source_world.teleport(node: nodes.pieces[1], position: { 14, 4, 5 }, rotation: maths::TRANSFORM_IDENTITY.rotation);
            source_world.set_velocity(nodes.pieces[1], { 2, 3, 4 }, { 0, 1, 0 });
            fixture.source.update_world();
            b3::BodyId source_body = source_world.body(nodes.pieces[1])!!;
            b3::JointId source_joint = original.welds[1].joint;
            uint free_assets = fixture.assets.geometries.free_count;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: nodes.common,
                text_mode: text_mode,
            )!!;
            assert(nodes.pieces[1].world_position() == (Vec3){ 14, 4, 5 });
            assert(source_body.linear_velocity() == (Vec3){ 2, 3, 4 } && source_joint.is_valid());
            assert(original.welds[0].broken && original.welds.len == 3 && original.anchor_count() == 2);
            assert(fixture.assets.geometries.free_count == free_assets);
            if (text_mode) {
                String text = (String)bytes;
                assert(text.contains("AUTHORED_REST") && text.contains("SAMPLED_REACTION") && text.contains("moment_axis"));
                assert(!text.contains("\"broken\"") && !text.contains("\"loads\"") && !text.contains("\"body_id\""));
            }

            Node* restored = decode(&fixture, bytes, text_mode)!!;
            Node* root = child_named(restored, "physics");
            Node* support = child_named(restored, "support_a");
            BreakableState* pending = fixture.destination.get(root, Breakable).state;
            assert(!fixture.destination.get(root, Breakable).is_prepared() && pending.recipe_kind == AUTHORED_REST);
            assert(pending.welds.len == 3 && pending.anchor_count() == 2 && pending.evaluation == SAMPLED_REACTION);
            assert(c3d::same_id(pending.anchor_view(0).authored.target, support.id));
            assert(pending.anchor_view(0).authored.has_target_strength && pending.anchor_view(0).authored.target_strength.force == 1200);
            assert(pending.weld_view(1).has_strength_override && pending.weld_view(1).strength.twist == 20);
            assert(pending.weld_view(1).frame_a.rotation.v == recipe.welds[1].frame_a.rotation.v);
            assert(pending.piece_view(2).has_strength && pending.piece_view(2).strength.bending == 100);
            assert(pending.runtime.frames.ptr != original.runtime.frames.ptr);
            assert(fixture.destination.count(PhysicsBody) == 2 && fixture.destination.count(RigidBody) == 0);
            foreach (index, entity : pending.pieces) {
                Vec3 expected = { 3 + (float)index, 4, 5 };
                assert((fixture.destination.node(entity).world_position() - expected).length() < 1e-5f);
            }

            PhysicsWorld world = create_world(&fixture.destination, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            assert(@catch(world.prepare_breakable(root)) == physics::NO_BODY);
            assert(fixture.destination.get(root, Breakable).state == pending && world.world.counters().body_count == 0);
            world.update(0);
            world.prepare_breakable(root)!!;
            BreakableState* loaded = fixture.destination.get(root, Breakable).state;
            assert(loaded.alive_welds == 3 && loaded.alive_anchors == 2);
            assert(world.world.counters().body_count == 6 && world.world.counters().joint_count == 5);
            foreach (entity : loaded.pieces) {
                b3::BodyId body = world.body(fixture.destination.node(entity))!!;
                assert(body.linear_velocity() == (Vec3){} && body.angular_velocity() == (Vec3){});
            }

            fixture.source.remove(nodes.pieces[1]);
            fixture.source.remove(nodes.last_support);
            char[] pruned = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: nodes.common,
                text_mode: text_mode,
            )!!;
            Node* pruned_root = child_named(decode(&fixture, pruned, text_mode)!!, "physics");
            BreakableState* survivors = fixture.destination.get(pruned_root, Breakable).state;
            assert(survivors.pieces.len == 3 && survivors.welds.len == 1 && survivors.anchor_count() == 1);
            assert(survivors.piece_view(1).rest_frame.position.x == 2 && survivors.piece_view(2).rest_frame.position.x == 3);
            assert(survivors.weld_view(0).piece_a == 1 && survivors.weld_view(0).piece_b == 2);
            assert(survivors.anchor_view(0).authored.piece == 0);
            assert(original.pieces.len == 4 && original.welds.len == 3 && original.anchor_count() == 2);
            fixture.source.remove(nodes.pieces[2]);
            fixture.source.remove(nodes.pieces[3]);
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: nodes.common,
                text_mode: text_mode,
            )) == c3d::UNSUPPORTED);
        };
    }
}

fn void test_breakable_authored_empty_graph_stays_empty_in_both_formats() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            SerialBreakableNodes nodes = add_serial_breakable_nodes(&fixture);
            BreakableRecipeDesc recipe = serial_breakable_recipe(&fixture, nodes);
            recipe.welds = {};
            recipe.anchors = {};
            fixture.source.attach_breakable_recipe(assets: &fixture.assets, root: fixture.root, recipe: recipe)!!;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: nodes.common,
                text_mode: text_mode,
            )!!;
            Node* root = child_named(decode(&fixture, bytes, text_mode)!!, "physics");
            BreakableState* pending = fixture.destination.get(root, Breakable).state;
            assert(pending.welds.len == 0 && pending.anchor_count() == 0);
            PhysicsWorld world = create_world(&fixture.destination, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            world.prepare_breakable(root)!!;
            assert(fixture.destination.get(root, Breakable).state.welds.len == 0 && world.world.counters().joint_count == 0);
        };
    }
}

fn uint breakable_text_value(serial::TextDocument* document) @private {
    foreach (uint index, value : document.values) {
        if (value.name == "breakable") return serial::json_member(document, index, "value");
    }
    unreachable();
}

fn void test_breakable_authored_restore_rejects_malformed_values_and_reclaims_failed_attachment() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            @pool() {
                RejectSize rejector = { .backing = &tracker };
                Fixture fixture;
                create_fixture(&fixture, &rejector);
                defer destroy_fixture(&fixture);
                SerialBreakableNodes nodes = add_serial_breakable_nodes(&fixture);
                BreakableRecipeDesc recipe = serial_breakable_recipe(&fixture, nodes);
                fixture.source.attach_breakable_recipe(assets: &fixture.assets, root: fixture.root, recipe: recipe)!!;
                BreakableState* original = fixture.source.get(fixture.root, Breakable).state;
                rejector.size = (char*)(original.runtime.assembly_pieces.ptr + original.runtime.assembly_pieces.len) - (char*)original;
                char[] bytes = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: nodes.common,
                    text_mode: text_mode,
                )!!;
                Node* existing = fixture.destination.add_node(name: "untouched")!!;
                uint available = fixture.destination.world.entities.free_count;
                serial::ReadOptions options = serial::READ_OPTIONS_DEFAULT;
                options.allocator = mem;
                rejector.enabled = true;
                defer rejector.enabled = false;
                assert(@catch(decode(
                    fixture: &fixture,
                    bytes: bytes,
                    text_mode: text_mode,
                    options: options,
                )) == c3d::CAPACITY_EXCEEDED);
                rejector.enabled = false;
                assert(rejector.failures == 1 && fixture.destination.world.entities.free_count == available);
                assert(fixture.destination.count(Breakable) == 0 && fixture.destination.count(PhysicsBody) == 0);
                assert(fixture.destination.count(scene::Mesh) == 0 && existing.name == "untouched");

                if (text_mode) {
                    serial::SerialDiagnostic diagnostic = serial::create_serial_diagnostic(tmem);
                    defer serial::destroy_serial_diagnostic(&diagnostic);
                    serial::TextDocument document = serial::parse_text(
                        allocator: tmem,
                        source: (String)bytes,
                        limits: serial::TEXT_LIMITS_DEFAULT,
                        diagnostic: &diagnostic,
                    )!!;
                    defer serial::destroy_text_document(&document);
                    uint value = breakable_text_value(&document);
                    uint weld = serial::json_member(&document, value, "welds") + 1;
                    uint frame = serial::json_member(&document, weld, "frame_a");
                    uint position = serial::json_member(&document, frame, "position") + 1;
                    uint strength = serial::json_member(&document, value, "strength");
                    uint[3] fields = {
                        serial::json_member(&document, weld, "piece_a"),
                        position,
                        serial::json_member(&document, strength, "force"),
                    };
                    String[3] invalid = { "99", "10", "-1" };
                    foreach (index, field : fields) {
                        char[] changed = (char[])replace_token((String)bytes, document.values[field], invalid[index]);
                        assert(@catch(decode(&fixture, changed, true)) == c3d::INVALID_ARGUMENT);
                        assert(fixture.destination.world.entities.free_count == available);
                        assert(fixture.destination.count(Breakable) == 0 && fixture.destination.count(PhysicsBody) == 0);
                    }
                }
                assert(@ok(decode(&fixture, bytes, text_mode)));
            };
        }
        assert(!tracker.has_leaks());
    }
}

fn void? collect_breakable_with_omitted_target(void* component, serial::WriteContext* context) @private {
    physics::collect_breakable(component, context)!;
    Breakable* owner = component;
    Node* target = context.scene.node(owner.state.anchor_view(0).authored.target);
    context.omit_node(target)!;
}

fn void test_breakable_authored_export_rejects_omitted_anchor_targets() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            SerialBreakableNodes nodes = add_serial_breakable_nodes(&fixture);
            BreakableRecipeDesc recipe = serial_breakable_recipe(&fixture, nodes);
            fixture.source.attach_breakable_recipe(assets: &fixture.assets, root: fixture.root, recipe: recipe)!!;
            serial::ComponentCodec* codec = &serial::codecs[ecs::assigned_slot(Breakable)!!].codec;
            serial::CollectFn original = codec.collect;
            codec.collect = &collect_breakable_with_omitted_target;
            defer codec.collect = original;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: nodes.common,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            assert(fixture.source.world.is_alive(nodes.first_support.id));
            assert(fixture.source.has(nodes.first_support, PhysicsBody));
            codec.collect = original;
            assert(@ok(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: nodes.common,
                text_mode: text_mode,
            )));
        };
    }
}
