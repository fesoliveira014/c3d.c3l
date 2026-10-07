module c3d::serial::test_described;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import c3d::serial;
import std::math;

fn void? collect_projected_number(void* component, WriteContext* context) @private {
    ulong mode = ((Owner*)component).total;
    if (mode == 1) context.omit_component(context.node.parent, ecs::assigned_slot(Number)!!)!;
    context.project_component(context.node.parent, (Number){ .count = 7, .gain = 0.75f, .target = context.node.id })!;
    if (mode == 2) context.omit_component(context.node.parent, ecs::assigned_slot(Number)!!)!;
    if (mode == 3) context.project_component(context.node.parent, (Number){ .count = 8 })!;
}

fn void test_component_projection_keeps_normal_record_and_rejects_conflicting_owners() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_described(Owner, {
            .name = "owner", .collect = &collect_projected_number, .attach = &attach_owner,
        })!!;
        Node* source = fixture_tree(&fixture);
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored;
            if (encoding == 0) {
                char[] bytes = serial::write_subtree(
                    allocator: tmem,
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: source,
                )!!;
                restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
            } else {
                String text = serial::write_subtree_text(
                    allocator: tmem,
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: source,
                )!!;
                restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            }
            Number* projected = fixture.destination.get(restored, Number);
            assert(projected.count == 7 && projected.gain == 0.75f);
            assert(c3d::same_id(projected.target, restored.first_child.id));
            Number* original = fixture.source.get(source, Number);
            assert(original.count == 21 && bitcast(original.gain, uint) == 0x80000000);
            fixture.destination.remove(restored);
        }
        Node* conflict = fixture.source.add_node(source, "conflict")!!;
        fixture.source.add(conflict, (Owner){});
        if (catch excuse = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false);
        }
        if (catch excuse = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false);
        }
        assert(fixture.source.get(source, Number).count == 21);
    };
}

fn void test_component_projection_rejects_omission_duplicates_and_absent_components() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_described(Owner, {
            .name = "owner", .collect = &collect_projected_number, .attach = &attach_owner,
        })!!;
        Node* source = fixture_tree(&fixture);
        Owner* owner = fixture.source.get(source.first_child, Owner);
        for (ulong mode = 1; mode <= 3; mode++) {
            owner.total = mode;
            assert(@catch(export_projection(&fixture, source, false)) == c3d::INVALID_ARGUMENT);
            assert(@catch(export_projection(&fixture, source, true)) == c3d::INVALID_ARGUMENT);
            assert(fixture.source.get(source, Number).count == 21);
        }
        owner.total = ulong::max;
        fixture.source.remove_component(source, Number);
        assert(@catch(export_projection(&fixture, source, false)) == c3d::INVALID_ARGUMENT);
        assert(@catch(export_projection(&fixture, source, true)) == c3d::INVALID_ARGUMENT);
        assert(!fixture.source.has(source, Number));
    };
}

fn void? export_projection(Fixture* fixture, Node* root, bool text_mode) @private {
    if (text_mode) {
        (void)serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!;
    } else {
        (void)serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!;
    }
}
fn void? collect_projected_transform(void* component, WriteContext* context) @private {
    maths::Transform local = maths::TRANSFORM_IDENTITY;
    local.position = { 3, 4, 5 };
    context.set_transform(context.node.parent, local, TransformSpace.WORLD)!;
    switch (((Owner*)component).total) {
        case 1: context.set_transform(context.node.parent, local, TransformSpace.WORLD)!;
        case 2: context.set_transform(context.node.parent, local, TransformSpace.PARENT)!;
        case 3:
            local.position.x += 1;
            context.set_local(context.node.parent, local)!;
        default:
    }
}

fn void test_transform_projection_preserves_space_and_rejects_conflicts() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_described(Owner, {
            .name = "owner", .collect = &collect_projected_transform, .attach = &attach_owner,
        })!!;
        Node* source = fixture_tree(&fixture);
        Owner* owner = fixture.source.get(source.first_child, Owner);
        owner.total = 1;
        foreach (text_mode : (bool[2]){ false, true }) {
            Node* loaded = text_mode
              ? serial::read_subtree_text(&fixture.destination, &fixture.assets, fixture_text(&fixture, source))!!
              : serial::read_subtree(&fixture.destination, &fixture.assets, fixture_bytes(&fixture, source))!!;
            assert(loaded.transform_space == TransformSpace.WORLD && loaded.local.position == (Vec3){ 3, 4, 5 });
            assert(source.transform_space == TransformSpace.PARENT && source.local.position == (Vec3){});
            fixture.destination.remove(loaded);
        }
        for (ulong mode = 2; mode <= 3; mode++) {
            owner.total = mode;
            assert(@catch(export_projection(&fixture, source, false)) == c3d::INVALID_ARGUMENT);
            assert(@catch(export_projection(&fixture, source, true)) == c3d::INVALID_ARGUMENT);
        }
        owner.total = 1;
        Node* second = fixture.source.add_node(source, "second-owner")!!;
        fixture.source.add(second, (Owner){ .total = 1 });
        assert(@catch(export_projection(&fixture, source, false)) == c3d::INVALID_ARGUMENT);
        assert(@catch(export_projection(&fixture, source, true)) == c3d::INVALID_ARGUMENT);
        assert(source.transform_space == TransformSpace.PARENT && source.local.position == (Vec3){});
    };
}

fn void? collect_interleaved_claims(void* component, WriteContext* context) @private {
    for (Node* node = context.node.first_child; node; node = node.next_sibling) {
        Number value = *context.scene.get(node, Number);
        value.count += 1000;
        context.project_component(node, value)!;
    }
    for (Node* node = context.node.first_child; node; node = node.next_sibling) {
        context.omit_component(node, ecs::assigned_slot(Item)!!)!;
        context.omit_component(node, ecs::assigned_slot(Item)!!)!;
    }
}

fn void test_interleaved_claims_preserve_each_nodes_projection_and_omission() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 128);
        defer destroy_fixture(&fixture);
        serial::register_described(Owner, {
            .name = "owner", .collect = &collect_interleaved_claims, .attach = &attach_owner,
        })!!;
        fixture.source.register(Item)!!;
        fixture.destination.register(Item)!!;
        Node* source = fixture.source.add_node(name: "owner")!!;
        fixture.source.add(source, (Owner){});
        for (uint index = 0; index < 100; index++) {
            Node* node = fixture.source.add_node(source, "claimed")!!;
            fixture.source.add(node, (Number){ .count = index });
            fixture.source.add(node, (Item){ .label = "omitted" });
        }
        foreach (text_mode : (bool[2]){ false, true }) {
            Node* restored;
            if (text_mode) {
                String first = fixture_text(&fixture, source);
                assert(first == fixture_text(&fixture, source));
                restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, first)!!;
            } else {
                char[] first = fixture_bytes(&fixture, source);
                assert(first == fixture_bytes(&fixture, source));
                restored = serial::read_subtree(&fixture.destination, &fixture.assets, first)!!;
            }
            Node* original = source.first_child;
            uint visited;
            for (Node* node = restored.first_child; node; node = node.next_sibling) {
                assert(fixture.destination.get(node, Number).count == fixture.source.get(original, Number).count + 1000);
                assert(fixture.source.get(original, Number).count < 100);
                assert(!fixture.destination.has(node, Item) && fixture.source.has(original, Item));
                original = original.next_sibling;
                visited++;
            }
            assert(visited == 100 && !original);
            fixture.destination.remove(restored);
        }
    };
}
