module c3d::serial::test_described;

import c3d;
import c3d::ecs;
import c3d::scene;
import c3d::serial;

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