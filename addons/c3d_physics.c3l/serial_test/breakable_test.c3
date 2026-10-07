module c3d_physics_serial_test;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import c3d::serial;
import std::core::mem::allocators;
import std::core::string;
import std::math;
import b3;

fn Node*[] add_breakable_row(Fixture* fixture, uint count) @private {
    serial::register_core_codecs()!!;
    Node*[] nodes = alloc::new_array(tmem, Node*, count);
    for (uint index = 0; index < count; index++) {
        nodes[index] = fixture.source.add_mesh(
            geometry: fixture.geometry,
            material: {},
            parent: fixture.root,
            name: string::tformat("piece_%d", index),
        )!!;
        nodes[index].local.position.x = (float)index;
    }
    fixture.source.update_world();
    return nodes;
}

fn void attach_pending_breakable(Fixture* fixture, Node*[] nodes) @private {
    BreakablePieceView[] pieces = alloc::new_array(tmem, BreakablePieceView, nodes.len);
    foreach (index, node : nodes) {
        pieces[index] = { .node = node.id, .hulls = (&fixture.geometry)[:1], .rest_frame = node.local };
    }
    fixture.source.attach_breakable_pieces(
        assets: &fixture.assets,
        root: fixture.root,
        pieces: pieces,
        desc: physics::default_breakable_desc(),
    )!!;
}

fn void test_breakable_both_formats_restart_survivors_at_current_world_placements() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        foreach (assembly : (bool[2]){ false, true }) {
            @pool() {
                Fixture fixture;
                create_fixture(&fixture);
                defer destroy_fixture(&fixture);
                fixture.root.local.position = { 3, 4, 5 };
                Node*[] nodes = add_breakable_row(&fixture, 5);
                Node* render_child = fixture.source.add_mesh(
                    geometry: fixture.geometry,
                    material: {},
                    parent: nodes[0],
                    name: "authored-render",
                )!!;
                render_child.local.position = { 0, 2, 0 };
                fixture.source.update_world();
                BreakablePieceDesc[5] pieces;
                foreach (index, node : nodes) pieces[index] = { .node = node.id, .hulls = (&fixture.geometry)[:1] };
                BreakableDesc desc = physics::default_breakable_desc();
                desc.sleep_until_hit = assembly;
                desc.density = 1;
                desc.break_force = 0.01f;
                PhysicsWorld source_world = create_world(&fixture.source, &fixture.assets);
                defer physics::destroy_physics_world(&source_world);
                source_world.add_breakable_pieces(root: fixture.root, pieces: &pieces, desc: desc)!!;
                if (assembly) source_world.wake_breakable(fixture.root)!!;
                BreakableState* original = fixture.source.get(fixture.root, Breakable).state;
                source_world.apply_impulse(node: nodes[0], impulse: { -12, 0, 0 }, world_point: nodes[0].world_position());
                uint attempts;
                while (!original.welds[0].broken && attempts++ < 120) {
                    source_world.update(physics::DEFAULT_FIXED_DT);
                    fixture.source.update_world();
                }
                assert(original.welds[0].broken);
                fixture.source.remove(nodes[4]);
                source_world.update(0);
                Vec3[4] positions = { { 3, 4, 5 }, { 4, 4, 5 }, { 8, 4, 5 }, { 12, 4, 5 } };
                foreach (index, position : positions) {
                    source_world.teleport(node: nodes[index], position: position, rotation: { .v = { 0, 0, 0, 1 } });
                    source_world.set_velocity(nodes[index], {}, {});
                }
                fixture.source.update_world();
                Vec3 child_position = render_child.world_position();
                uint geometries = fixture.assets.geometries.free_count;
                char[] bytes = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )!!;
                assert(nodes[0].transform_space == TransformSpace.WORLD && nodes[0].local.position == positions[0]);
                assert(original.welds[0].broken && original.pieces.len == 5 && fixture.source.count(PhysicsBody) == 4);
                Node* restored = decode(&fixture, bytes, text_mode)!!;
                Breakable* owner = fixture.destination.get(restored, Breakable);
                assert(owner && !owner.is_prepared() && owner.state.pieces.len == 4 && owner.state.welds.len == 0);
                assert(fixture.destination.count(PhysicsBody) == 0 && fixture.destination.count(RigidBody) == 0);
                assert(fixture.destination.count(scene::Mesh) == 5 && fixture.assets.geometries.free_count == geometries);
                foreach (uint index, entity : owner.state.pieces) {
                    Node* piece = fixture.destination.node(entity);
                    assert(piece.transform_space == TransformSpace.PARENT);
                    assert((piece.world_position() - positions[index]).length() < 1e-4f);
                    assert(owner.state.piece_view(index).hulls.len == 1);
                }
                Node* loaded_child = child_named(fixture.destination.node(owner.state.pieces[0]), "authored-render");
                assert(loaded_child && (loaded_child.world_position() - child_position).length() < 1e-4f);
                assert(child_named(restored, "piece_4") == null);
                assert(bytes == encode(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                    text_mode: text_mode,
                )!!);
                PhysicsWorld world = create_world(&fixture.destination, &fixture.assets);
                defer physics::destroy_physics_world(&world);
                world.prepare_breakable_subtree(restored)!!;
                world.update(0);
                assert(owner.is_prepared() && owner.state.alive_welds == 1 && owner.state.welds.len == 1);
                assert(owner.state.welds[0].piece_a == 0 && owner.state.welds[0].piece_b == 1 && !owner.state.welds[0].broken);
                if (assembly) world.wake_breakable(restored)!!;
                assert(world.world.counters().joint_count == 1 && world.world.counters().body_count == 4);
                world.update(physics::DEFAULT_FIXED_DT);
                assert(owner.state.alive_welds == 1);
                for (uint index = 0; index < 3; index++) fixture.source.remove(nodes[index]);
                source_world.update(0);
                SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
                defer serial::destroy_serial_diagnostic(&diagnostic);
                assert(@catch(encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                    options: { .diagnostic = &diagnostic },
                )) == c3d::UNSUPPORTED);
                assert(diagnostic.cause == c3d::UNSUPPORTED && diagnostic.type_name == "breakable" && diagnostic.node_path == "/nodes/0");
            };
        }
    }
}

fn void test_breakable_pending_pose_mismatch_survives_both_formats() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Node*[] nodes = add_breakable_row(&fixture, 2);
            attach_pending_breakable(&fixture, nodes);
            nodes[1].local.position.x = 1.5f;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            Breakable* owner = fixture.destination.get(restored, Breakable);
            Node* displaced = fixture.destination.node(owner.state.pieces[1]);
            assert(displaced.local.position.x == 1.5f && owner.state.piece_view(1).rest_frame.position.x == 1);
            PhysicsWorld world = create_world(&fixture.destination, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            assert(@catch(world.prepare_breakable(restored)) == c3d::INVALID_ARGUMENT);
            BreakableMismatch* mismatch = owner.preparation_mismatch();
            assert(mismatch && mismatch.piece_a == 0 && mismatch.piece_b == 1);
            assert(!owner.is_prepared() && fixture.destination.count(PhysicsBody) == 0);
            displaced.local.position.x = 1;
            fixture.destination.update_world();
            world.prepare_breakable(restored)!!;
            assert(owner.is_prepared() && owner.state.welds.len == 1 && !owner.preparation_mismatch());
        };
    }
}

fn void test_breakable_rejects_modified_owned_body_and_unclaimed_body() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Node*[] nodes = add_breakable_row(&fixture, 2);
            attach_pending_breakable(&fixture, nodes);
            PhysicsWorld world = create_world(&fixture.source, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            world.prepare_breakable(fixture.root)!!;
            PhysicsBody* body = fixture.source.get(fixture.root, PhysicsBody);
            body.colliders[0].density += 1;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            body.colliders[0].density -= 1;
            add_sphere(
                scene: &fixture.source,
                parent: nodes[0],
                name: "extra-body",
                kind: STATIC,
            );
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
        };
    }
}

fn void test_breakable_recipe_allocation_failure_rolls_back_meshes() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            RejectSize failure = { .backing = &tracker };
            Fixture fixture;
            create_fixture(&fixture, &failure);
            defer destroy_fixture(&fixture);
            @pool() {
                Node*[] nodes = add_breakable_row(&fixture, 2);
                attach_pending_breakable(&fixture, nodes);
                BreakableState* source = fixture.source.get(fixture.root, Breakable).state;
                failure.size = (char*)(source.runtime.assembly_pieces.ptr + source.runtime.assembly_pieces.len) - (char*)source;
                char[] bytes = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )!!;
                ReadOptions options = serial::READ_OPTIONS_DEFAULT;
                options.allocator = mem;
                uint before = fixture.destination.world.entities.free_count;
                failure.enabled = true;
                assert(@catch(decode(
                    fixture: &fixture,
                    bytes: bytes,
                    text_mode: text_mode,
                    options: options,
                )) == c3d::CAPACITY_EXCEEDED);
                failure.enabled = false;
                assert(failure.failures == 1 && fixture.destination.world.entities.free_count == before);
                assert(fixture.destination.count(scene::Mesh) == 0 && fixture.destination.count(Breakable) == 0);
                assert(@ok(decode(&fixture, bytes, text_mode)));
            };
        }
        assert(!tracker.has_leaks());
    }
}

fn void test_breakable_nested_legacy_pieces_project_parent_space_without_mutation() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            serial::register_core_codecs()!!;
            Node* first = fixture.source.add_mesh(
                geometry: fixture.geometry,
                material: {},
                parent: fixture.root,
                name: "first",
            )!!;
            Node* second = fixture.source.add_mesh(
                geometry: fixture.geometry,
                material: {},
                parent: first,
                name: "second",
            )!!;
            second.local.position.x = 1;
            Node* child = fixture.source.add_node(second, "authored-child")!!;
            child.local.position.y = 2;
            fixture.source.update_world();
            BreakableDesc desc = physics::default_breakable_desc();
            desc.sleep_until_hit = false;
            PhysicsWorld source_world = create_world(&fixture.source, &fixture.assets);
            defer physics::destroy_physics_world(&source_world);
            source_world.add_breakable(fixture.root, desc)!!;
            source_world.teleport(node: first, position: { 4, 5, 6 }, rotation: { .v = { 0, 0, 0, 1 } });
            source_world.teleport(node: second, position: { 5, 5, 6 }, rotation: { .v = { 0, 0, 0, 1 } });
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            assert(first.transform_space == TransformSpace.WORLD && second.transform_space == TransformSpace.WORLD);
            assert(first.local.position == (Vec3){ 4, 5, 6 } && second.local.position == (Vec3){ 5, 5, 6 });
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            Node* loaded_first = child_named(restored, "first");
            Node* loaded_second = child_named(loaded_first, "second");
            assert(loaded_first.transform_space == TransformSpace.PARENT && loaded_second.transform_space == TransformSpace.PARENT);
            assert(loaded_first.world_position() == (Vec3){ 4, 5, 6 } && loaded_second.world_position() == (Vec3){ 5, 5, 6 });
            assert(child_named(loaded_second, "authored-child").world_position() == (Vec3){ 5, 7, 6 });
            PhysicsWorld world = create_world(&fixture.destination, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            world.prepare_breakable(restored)!!;
            assert(fixture.destination.get(restored, Breakable).state.alive_welds == 1);
        };
    }
}
